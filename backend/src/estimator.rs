//! Estimates photo meals with the vision model on the Spark, in the
//! background, one meal at a time.
//!
//! The model runs in the Spark's Ollama, which other people use too. So
//! it is loaded only when a meal is waiting, after checking that the
//! machine has the memory free; its context is capped, so it does not take
//! more than it needs; and it is let go a couple of minutes after the last
//! meal, so meals logged together are estimated together. A meal is never
//! held up by any of this: it is logged when it arrives, and the estimate
//! is added when the model answers.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use base64::Engine;
use serde::Deserialize;
use serde_json::json;
use sqlx::PgPool;
use tokio::sync::Notify;

use crate::db::{self, PendingPhoto};
use crate::routines::photo;

/// How lyfe reaches the model.
#[derive(Debug, Clone, PartialEq)]
pub struct EstimatorSettings {
    /// Ollama's address; `None` when photo estimates are switched off.
    pub ollama_url: Option<String>,
    pub model: String,
    /// The context the model is loaded with, in tokens. A photo and the
    /// answer take a few thousand; Ollama's default takes far more memory.
    pub context: u32,
    /// The model is not loaded unless this much memory is free.
    pub min_free_gb: u32,
    /// How long the model stays loaded after the last meal.
    pub keep_alive_s: u32,
    /// Where the machine says how much memory is free.
    pub meminfo: PathBuf,
}

impl Default for EstimatorSettings {
    fn default() -> Self {
        EstimatorSettings {
            ollama_url: Some("http://127.0.0.1:11434".into()),
            model: "gemma4:31b".into(),
            context: 8_192,
            min_free_gb: 32,
            keep_alive_s: 120,
            meminfo: PathBuf::from("/proc/meminfo"),
        }
    }
}

/// What one try at estimating came to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// Nothing was waiting.
    Idle,
    Estimated,
    /// No estimate this time; it is tried again later.
    Deferred(String),
    /// Left for the owner to type.
    GaveUp(String),
}

pub struct Estimator {
    pool: PgPool,
    http: reqwest::Client,
    settings: EstimatorSettings,
    wake: Arc<Notify>,
}

/// How long to wait before asking again, by what went wrong.
const RETRY_UNREACHABLE: chrono::Duration = chrono::Duration::minutes(2);
const RETRY_NO_MEMORY: chrono::Duration = chrono::Duration::minutes(5);
const RETRY_NO_MODEL: chrono::Duration = chrono::Duration::minutes(30);
const RETRY_BAD_ANSWER: chrono::Duration = chrono::Duration::seconds(5);
/// Loading the model from disk can take two minutes before it answers.
const ANSWER_TIMEOUT: Duration = Duration::from_secs(300);
/// Looked at this often even when nothing wakes it, for retries that fall due.
const IDLE_CHECK: Duration = Duration::from_secs(30);

impl Estimator {
    pub fn new(pool: PgPool, settings: EstimatorSettings, wake: Arc<Notify>) -> anyhow::Result<Estimator> {
        let http = reqwest::Client::builder().connect_timeout(Duration::from_secs(5)).build()?;
        Ok(Estimator { pool, http, settings, wake })
    }

    pub fn settings(&self) -> &EstimatorSettings {
        &self.settings
    }

    /// Estimates whatever is waiting, then waits to be woken by a new
    /// photo, or for a retry to fall due.
    pub async fn run_forever(self: Arc<Self>) {
        loop {
            loop {
                match self.estimate_next().await {
                    Ok(Outcome::Idle) => break,
                    Ok(Outcome::Deferred(_)) => break,
                    Ok(_) => continue,
                    Err(error) => {
                        tracing::error!(%error, "database error while estimating a photo meal");
                        break;
                    }
                }
            }
            tokio::select! {
                _ = self.wake.notified() => {}
                _ = tokio::time::sleep(IDLE_CHECK) => {}
            }
        }
    }

    /// Tries the photo meal waiting longest whose turn has come.
    pub async fn estimate_next(&self) -> sqlx::Result<Outcome> {
        let Some(meal) = db::next_pending_photo(&self.pool).await? else {
            return Ok(Outcome::Idle);
        };
        let outcome = self.estimate(&meal).await;
        match &outcome {
            Ok(estimate) => {
                db::record_estimate(&self.pool, meal.id, estimate).await?;
                // What was eaten is not logged; it is the owner's.
                tracing::info!(id = %meal.id, items = estimate.items.len(), "photo meal estimated");
                Ok(Outcome::Estimated)
            }
            Err(Problem::Off) => {
                // Nothing will ever estimate it: it is the owner's to type.
                let words = "Photo estimates are switched off on the server. Type the figures instead.";
                db::give_up_estimate(&self.pool, meal.id, words).await?;
                Ok(Outcome::GaveUp(words.into()))
            }
            Err(problem) => {
                let (words, counts, retry) = problem.explain(&self.settings);
                tracing::warn!(id = %meal.id, problem = %words, "photo meal not estimated this time");
                db::record_estimate_problem(&self.pool, meal.id, &words, counts, retry).await?;
                if counts && meal.tries + 1 >= photo::MAX_TRIES {
                    Ok(Outcome::GaveUp(words))
                } else {
                    Ok(Outcome::Deferred(words))
                }
            }
        }
    }

    /// Asks the model about one meal without storing anything: for checking
    /// the model from the command line. Says what went wrong in words.
    pub async fn ask(&self, note: &str, jpeg: Option<Vec<u8>>) -> Result<photo::ModelEstimate, String> {
        let meal = PendingPhoto { id: uuid::Uuid::nil(), note: note.to_string(), jpeg, tries: 0 };
        self.estimate(&meal).await.map_err(|problem| problem.explain(&self.settings).0)
    }

    async fn estimate(&self, meal: &PendingPhoto) -> Result<photo::ModelEstimate, Problem> {
        let url = self.settings.ollama_url.as_deref().ok_or(Problem::Off)?.trim_end_matches('/');
        if !self.model_loaded(url).await?
            && let Some(free_gb) = free_memory_gb(&self.settings.meminfo)
            && free_gb < f64::from(self.settings.min_free_gb)
        {
            return Err(Problem::ShortOfMemory { free_gb });
        }
        let mut message = json!({
            "role": "user",
            "content": photo::prompt(&meal.note, meal.jpeg.is_some()),
        });
        if let Some(jpeg) = &meal.jpeg {
            message["images"] = json!([base64::engine::general_purpose::STANDARD.encode(jpeg)]);
        }
        let request = json!({
            "model": self.settings.model,
            "messages": [message],
            "stream": false,
            // Reasoning made small models worse at this, and slower.
            "think": false,
            "format": photo::answer_schema(),
            "keep_alive": format!("{}s", self.settings.keep_alive_s),
            "options": {"num_ctx": self.settings.context, "temperature": 0},
        });
        let response = self
            .http
            .post(format!("{url}/api/chat"))
            .timeout(ANSWER_TIMEOUT)
            .json(&request)
            .send()
            .await
            .map_err(|error| Problem::Unreachable(error.without_url().to_string()))?;
        let status = response.status();
        if status == reqwest::StatusCode::NOT_FOUND {
            return Err(Problem::NoModel);
        }
        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            return Err(Problem::Unreachable(format!("Ollama answered {status}: {}", first_line(&body))));
        }
        #[derive(Deserialize)]
        struct Chat {
            message: ChatMessage,
        }
        #[derive(Deserialize)]
        struct ChatMessage {
            content: String,
        }
        let chat: Chat = response
            .json()
            .await
            .map_err(|error| Problem::Unreachable(format!("Ollama's reply could not be read: {error}")))?;
        photo::read_answer(&chat.message.content).map_err(Problem::BadAnswer)
    }

    /// Whether the model is already in memory, in which case loading it
    /// takes nothing more.
    async fn model_loaded(&self, url: &str) -> Result<bool, Problem> {
        #[derive(Deserialize)]
        struct Running {
            models: Vec<RunningModel>,
        }
        #[derive(Deserialize)]
        struct RunningModel {
            name: String,
        }
        let running: Running = self
            .http
            .get(format!("{url}/api/ps"))
            .timeout(Duration::from_secs(10))
            .send()
            .await
            .and_then(|response| response.error_for_status())
            .map_err(|error| Problem::Unreachable(error.without_url().to_string()))?
            .json()
            .await
            .map_err(|error| Problem::Unreachable(format!("Ollama's list of loaded models could not be read: {error}")))?;
        Ok(running.models.iter().any(|m| m.name == self.settings.model))
    }
}

/// Why there is no estimate this time.
#[derive(Debug)]
enum Problem {
    Off,
    Unreachable(String),
    NoModel,
    ShortOfMemory { free_gb: f64 },
    BadAnswer(String),
}

impl Problem {
    /// In words for the owner, whether it counts as one of the model's
    /// tries, and when to try again.
    fn explain(&self, settings: &EstimatorSettings) -> (String, bool, chrono::Duration) {
        match self {
            Problem::Off => ("Photo estimates are switched off on the server.".into(), true, chrono::Duration::zero()),
            Problem::Unreachable(why) => {
                (format!("The model on the Spark could not be reached ({why}). Trying again shortly."), false, RETRY_UNREACHABLE)
            }
            Problem::NoModel => (
                format!("The model {} is not installed on the Spark. Trying again later.", settings.model),
                false,
                RETRY_NO_MODEL,
            ),
            Problem::ShortOfMemory { free_gb } => (
                format!(
                    "The Spark is busy: {free_gb:.0} GB free, and the model needs {}. Trying again in a few minutes.",
                    settings.min_free_gb
                ),
                false,
                RETRY_NO_MEMORY,
            ),
            Problem::BadAnswer(why) => (format!("The model's answer could not be used: {why}."), true, RETRY_BAD_ANSWER),
        }
    }
}

fn first_line(text: &str) -> String {
    text.lines().next().unwrap_or_default().chars().take(200).collect()
}

/// Memory free for a new model, in GB, as the machine reports it. `None`
/// where it does not say (not Linux), and then nothing is held back.
pub fn free_memory_gb(meminfo: &std::path::Path) -> Option<f64> {
    let text = std::fs::read_to_string(meminfo).ok()?;
    parse_mem_available(&text)
}

fn parse_mem_available(text: &str) -> Option<f64> {
    let line = text.lines().find(|line| line.starts_with("MemAvailable:"))?;
    let kb: f64 = line.split_whitespace().nth(1)?.parse().ok()?;
    Some(kb / 1024.0 / 1024.0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn free_memory_is_read_from_meminfo() {
        let text = "MemTotal:       128000000 kB\nMemFree:  1000 kB\nMemAvailable:   75945216 kB\n";
        let gb = parse_mem_available(text).unwrap();
        assert!((gb - 72.4).abs() < 0.1, "{gb}");
        assert_eq!(parse_mem_available("MemTotal: 1 kB\n"), None);
        assert_eq!(free_memory_gb(std::path::Path::new("/no/such/file")), None);
    }
}
