//! Draws meal photos as Poster illustrations with FLUX.2 klein 4B on the
//! Spark, in the background.
//!
//! The model runs in a program of its own (`deploy/spark/lyfe-illustrate.py`),
//! which lyfe starts only when a photo is waiting and the shared machine has
//! the memory free. The program loads the model once, which takes a minute
//! or two, draws every photo waiting, and is let go a few minutes after the
//! last, so meals logged together are drawn together and its memory is given
//! back when it exits. Talking to it is one line of JSON each way per photo
//! (`crate::routines::illustration`). A meal is never held up by any of
//! this: it is logged and counted without its illustration, and the app
//! shows the photo until one comes.

use std::path::PathBuf;
use std::process::Stdio;
use std::sync::Arc;
use std::time::{Duration, Instant};

use base64::Engine;
use sqlx::PgPool;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, Lines};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::Notify;

use crate::db::{self, PendingIllustration};
use crate::estimator::free_memory_gb;
use crate::routines::illustration;

/// How lyfe runs the illustrator.
#[derive(Debug, Clone, PartialEq)]
pub struct IllustratorSettings {
    /// The program and its arguments; `None` when illustrations are off.
    pub program: Option<Vec<String>>,
    /// The program is not started unless this much memory is free.
    pub min_free_gb: u32,
    /// How long the program is kept, with the model loaded, after the last
    /// photo.
    pub keep_alive: Duration,
    /// How long loading the model may take.
    pub load_timeout: Duration,
    /// How long drawing one photo may take.
    pub draw_timeout: Duration,
    /// Where the machine says how much memory is free.
    pub meminfo: PathBuf,
}

impl Default for IllustratorSettings {
    fn default() -> Self {
        IllustratorSettings {
            program: None,
            min_free_gb: 24,
            keep_alive: Duration::from_secs(180),
            // Two minutes from a warm disk in the test; more when it is cold.
            load_timeout: Duration::from_secs(600),
            // About seven seconds each in the test.
            draw_timeout: Duration::from_secs(180),
            meminfo: PathBuf::from("/proc/meminfo"),
        }
    }
}

/// What one turn of the illustrator came to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// Nothing was waiting.
    Idle,
    /// The program ran and drew this many photos; any it could not draw
    /// are tried again later.
    Drew(usize),
    /// Nothing could be drawn now; every photo waiting is tried again later.
    PutOff(String),
}

/// How long to wait before trying again, by what went wrong.
const RETRY_NO_MEMORY: chrono::Duration = chrono::Duration::minutes(5);
const RETRY_NOT_INSTALLED: chrono::Duration = chrono::Duration::minutes(30);
const RETRY_NO_LOAD: chrono::Duration = chrono::Duration::minutes(10);
const RETRY_PICTURE: chrono::Duration = chrono::Duration::minutes(1);
/// Looked at this often when nothing wakes it, for retries that fall due.
const IDLE_CHECK: Duration = Duration::from_secs(30);
/// Looked at this often while the model is loaded: a photo's estimate,
/// which it waits for, does not wake it.
const LOADED_CHECK: Duration = Duration::from_secs(5);
/// How long the program has to exit once told it is done.
const EXIT_GRACE: Duration = Duration::from_secs(30);

pub struct Illustrator {
    pool: PgPool,
    settings: IllustratorSettings,
    wake: Arc<Notify>,
}

impl Illustrator {
    pub fn new(pool: PgPool, settings: IllustratorSettings, wake: Arc<Notify>) -> Illustrator {
        Illustrator { pool, settings, wake }
    }

    pub fn settings(&self) -> &IllustratorSettings {
        &self.settings
    }

    /// Draws whatever is waiting, then waits to be woken by a new photo,
    /// or for a retry to fall due. Does nothing when illustrations are off.
    pub async fn run_forever(self: Arc<Self>) {
        if self.settings.program.is_none() {
            return;
        }
        loop {
            if let Err(error) = self.run_once().await {
                tracing::error!(%error, "database error while drawing a meal");
            }
            tokio::select! {
                _ = self.wake.notified() => {}
                _ = tokio::time::sleep(IDLE_CHECK) => {}
            }
        }
    }

    /// Starts the program if a photo's turn has come, draws until nothing
    /// has been waiting for the keep-alive time, then lets it go.
    pub async fn run_once(&self) -> sqlx::Result<Outcome> {
        let Some(first) = db::next_pending_illustration(&self.pool).await? else {
            return Ok(Outcome::Idle);
        };
        let Some(program) = &self.settings.program else {
            return Ok(Outcome::Idle);
        };
        if let Some(free_gb) = free_memory_gb(&self.settings.meminfo)
            && free_gb < f64::from(self.settings.min_free_gb)
        {
            let words = format!(
                "The Spark is busy: {free_gb:.0} GB free, and the illustrator needs {}.",
                self.settings.min_free_gb
            );
            return self.put_off(words, RETRY_NO_MEMORY).await;
        }
        let started = Instant::now();
        let mut running = match Running::start(program, self.settings.load_timeout).await {
            Ok(running) => running,
            Err(Unstarted::NotInstalled) => {
                let words = format!("The illustrator is not installed ({}).", program[0]);
                return self.put_off(words, RETRY_NOT_INSTALLED).await;
            }
            Err(Unstarted::Failed(words)) => return self.put_off(words, RETRY_NO_LOAD).await,
        };
        tracing::info!(load_s = started.elapsed().as_secs(), "illustrator loaded");

        let mut drew = 0;
        let mut next = Some(first);
        loop {
            let meal = match next.take() {
                Some(meal) => meal,
                None => match self.wait_for_next().await? {
                    Some(meal) => meal,
                    None => break,
                },
            };
            match running.draw(&meal, self.settings.draw_timeout).await {
                Ok(png) => {
                    db::record_illustration(&self.pool, meal.id, &png).await?;
                    drew += 1;
                    // What was eaten is not logged; it is the owner's.
                    tracing::info!(id = %meal.id, bytes = png.len(), "meal illustrated");
                }
                Err(Undrawn::Picture(words)) => {
                    self.picture_failed(&meal, &words).await?;
                }
                Err(Undrawn::Program(words)) => {
                    // The program is gone or stuck on this picture. It is
                    // counted against the picture, so one that kills the
                    // model is not tried for ever.
                    self.picture_failed(&meal, &words).await?;
                    running.kill().await;
                    return Ok(Outcome::Drew(drew));
                }
            }
        }
        running.stop().await;
        tracing::info!(drew, "illustrator let go");
        Ok(Outcome::Drew(drew))
    }

    /// The next photo whose turn comes before the keep-alive time is up.
    async fn wait_for_next(&self) -> sqlx::Result<Option<PendingIllustration>> {
        let until = Instant::now() + self.settings.keep_alive;
        loop {
            if let Some(meal) = db::next_pending_illustration(&self.pool).await? {
                return Ok(Some(meal));
            }
            let left = until.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return Ok(None);
            }
            tokio::select! {
                _ = self.wake.notified() => {}
                _ = tokio::time::sleep(left.min(LOADED_CHECK)) => {}
            }
        }
    }

    async fn picture_failed(&self, meal: &PendingIllustration, words: &str) -> sqlx::Result<()> {
        let gave_up = db::record_illustration_problem(&self.pool, meal.id, words, RETRY_PICTURE).await?;
        if gave_up {
            tracing::warn!(id = %meal.id, problem = %words, "meal not illustrated; its photo is shown instead");
        } else {
            tracing::warn!(id = %meal.id, problem = %words, "meal not illustrated this time");
        }
        Ok(())
    }

    async fn put_off(&self, words: String, retry: chrono::Duration) -> sqlx::Result<Outcome> {
        let waiting = db::put_off_illustrations(&self.pool, &words, retry).await?;
        tracing::warn!(waiting, problem = %words, retry_minutes = retry.num_minutes(), "meals not illustrated for now");
        Ok(Outcome::PutOff(words))
    }

    /// Draws one photo without storing anything: for checking the model
    /// from the command line. Gives the PNG and how long loading and drawing
    /// took, or what went wrong in words.
    pub async fn check(&self, note: &str, jpeg: Vec<u8>) -> Result<(Vec<u8>, Duration, Duration), String> {
        let program = self.settings.program.as_ref().ok_or("illustrations are off")?;
        let started = Instant::now();
        let mut running = Running::start(program, self.settings.load_timeout).await.map_err(|unstarted| match unstarted {
            Unstarted::NotInstalled => format!("the illustrator is not installed ({})", program[0]),
            Unstarted::Failed(words) => words,
        })?;
        let loaded = started.elapsed();
        let meal = PendingIllustration { id: uuid::Uuid::nil(), note: note.to_string(), jpeg, tries: 0 };
        let drawn = running.draw(&meal, self.settings.draw_timeout).await;
        let drawing = started.elapsed() - loaded;
        running.stop().await;
        match drawn {
            Ok(png) => Ok((png, loaded, drawing)),
            Err(Undrawn::Picture(words) | Undrawn::Program(words)) => Err(words),
        }
    }
}

/// Why the program is not running.
enum Unstarted {
    NotInstalled,
    Failed(String),
}

/// Why a photo was not drawn.
enum Undrawn {
    /// The program answered, but not with a picture.
    Picture(String),
    /// The program stopped, or did not answer in time.
    Program(String),
}

/// The illustrator program, with the model loaded.
struct Running {
    child: Child,
    input: Option<ChildStdin>,
    output: Lines<BufReader<ChildStdout>>,
}

impl Running {
    async fn start(program: &[String], load_timeout: Duration) -> Result<Running, Unstarted> {
        let (command, arguments) = program.split_first().ok_or(Unstarted::NotInstalled)?;
        let mut child = Command::new(command)
            .args(arguments)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            // What it says on the side goes to lyfe's own log.
            .stderr(Stdio::inherit())
            // Never left running with the model loaded if lyfe stops.
            .kill_on_drop(true)
            .spawn()
            .map_err(|error| match error.kind() {
                std::io::ErrorKind::NotFound => Unstarted::NotInstalled,
                _ => Unstarted::Failed(format!("The illustrator could not be started: {error}.")),
            })?;
        let input = child.stdin.take();
        let output = BufReader::new(child.stdout.take().expect("piped")).lines();
        let mut running = Running { child, input, output };
        let first = match tokio::time::timeout(load_timeout, running.output.next_line()).await {
            Ok(Ok(Some(line))) => line,
            Ok(_) => {
                running.kill().await;
                return Err(Unstarted::Failed("The illustrator stopped while loading the model.".into()));
            }
            Err(_) => {
                running.kill().await;
                return Err(Unstarted::Failed(format!(
                    "The illustrator took more than {} s to load the model.",
                    load_timeout.as_secs()
                )));
            }
        };
        if let Err(words) = illustration::read_ready(&first) {
            running.kill().await;
            return Err(Unstarted::Failed(capitalised(&words)));
        }
        Ok(running)
    }

    async fn draw(&mut self, meal: &PendingIllustration, timeout: Duration) -> Result<Vec<u8>, Undrawn> {
        let prompt = illustration::prompt(&meal.note);
        let request = illustration::Request {
            id: meal.id,
            prompt: &prompt,
            jpeg: base64::engine::general_purpose::STANDARD.encode(&meal.jpeg),
        };
        let mut line = serde_json::to_vec(&request).expect("a request is JSON");
        line.push(b'\n');
        let input = self.input.as_mut().ok_or_else(|| Undrawn::Program("The illustrator is closed.".into()))?;
        let sent = async {
            input.write_all(&line).await?;
            input.flush().await
        };
        if sent.await.is_err() {
            return Err(Undrawn::Program("The illustrator stopped.".into()));
        }
        match tokio::time::timeout(timeout, self.output.next_line()).await {
            Ok(Ok(Some(answer))) => illustration::read_answer(&answer, meal.id)
                .map(|drawn| drawn.png)
                .map_err(|words| Undrawn::Picture(capitalised(&words))),
            Ok(_) => Err(Undrawn::Program("The illustrator stopped while drawing.".into())),
            Err(_) => Err(Undrawn::Program(format!("The illustrator took more than {} s to draw.", timeout.as_secs()))),
        }
    }

    /// Tells the program it is done, which gives back its memory as it
    /// exits.
    async fn stop(mut self) {
        drop(self.input.take());
        if tokio::time::timeout(EXIT_GRACE, self.child.wait()).await.is_err() {
            self.kill().await;
        }
    }

    async fn kill(&mut self) {
        let _ = self.child.kill().await;
    }
}

fn capitalised(words: &str) -> String {
    let mut chars = words.chars();
    let mut text = match chars.next() {
        Some(first) => first.to_uppercase().chain(chars).collect(),
        None => String::new(),
    };
    if !text.ends_with('.') {
        text.push('.');
    }
    text
}
