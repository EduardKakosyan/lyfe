use std::io::{BufRead, IsTerminal};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{bail, Context};
use chrono::{Datelike, Utc};
use clap::{Parser, Subcommand};

use lyfe_server::api::{self, AppState};
use lyfe_server::auth::{self, SignInThrottle};
use lyfe_server::config::{DatabaseConfig, GarminConfig, ServeConfig};
use lyfe_server::db;
use lyfe_server::garmin::sync::{parse_activity, Syncer};
use lyfe_server::garmin::GarminClient;
use lyfe_server::push::apns::{Alert, ApnsClient};
use lyfe_server::push::notifier::Notifier;
use lyfe_server::routines::gym::{self, Week};
use lyfe_server::routines::streak::{Mark, State};

#[derive(Parser)]
#[command(name = "lyfe-server", about = "The lyfe backend", version)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Run the API server and the Garmin poller.
    Serve(Box<ServeConfig>),
    /// Set the owner's password. Signs every device out.
    SetPassword {
        #[command(flatten)]
        database: DatabaseConfig,
    },
    /// Print every gym week as the streak rules count it, from the stored
    /// activities. Changes nothing.
    GymWeeks(Box<ServeConfig>),
    /// Send a test notification to every signed-in device.
    PushTest(Box<ServeConfig>),
    /// Ask Garmin for recent activities and print counts only. Touches no
    /// database; use it to confirm the key file works.
    GarminCheck {
        #[command(flatten)]
        garmin: GarminConfig,
        /// Days of history to ask for.
        #[arg(long, default_value_t = 30)]
        days: i64,
    },
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info,sqlx=warn".into()),
        )
        .init();

    match Cli::parse().command {
        Command::Serve(config) => serve(*config).await,
        Command::SetPassword { database } => set_password(database).await,
        Command::GymWeeks(config) => gym_weeks(*config).await,
        Command::PushTest(config) => push_test(*config).await,
        Command::GarminCheck { garmin, days } => garmin_check(garmin, days).await,
    }
}

fn garmin_client(config: &GarminConfig) -> anyhow::Result<Option<GarminClient>> {
    config
        .garmin_key_file
        .clone()
        .map(|key_file| GarminClient::new(&config.garmin_base_url, key_file))
        .transpose()
}

fn garmin_syncer(config: &ServeConfig, pool: &sqlx::PgPool) -> anyhow::Result<Arc<Syncer>> {
    Ok(Arc::new(Syncer::new(
        pool.clone(),
        garmin_client(&config.garmin)?,
        config.garmin.garmin_backfill_days,
        config.garmin.garmin_window_days,
    )))
}

/// The notifier, or `None` when no Apple key file is configured.
fn notifier(config: &ServeConfig, pool: &sqlx::PgPool, syncer: Arc<Syncer>) -> anyhow::Result<Option<Notifier>> {
    let push = &config.push;
    let Some(key_file) = push.apns_key_file.clone() else {
        return Ok(None);
    };
    let key_id = push
        .apns_key_id
        .clone()
        .or_else(|| ApnsClient::key_id_from_file_name(&key_file))
        .context("set LYFE_APNS_KEY_ID, or keep the key file's name as Apple gave it (AuthKey_<id>.p8)")?;
    let team_id = push
        .apns_team_id
        .clone()
        .context("set LYFE_APNS_TEAM_ID to your Apple developer team ID")?;
    if push.notify_from_hour >= push.notify_until_hour {
        bail!("LYFE_NOTIFY_FROM_HOUR must be earlier than LYFE_NOTIFY_UNTIL_HOUR");
    }
    Ok(Some(Notifier {
        pool: pool.clone(),
        syncer,
        apns: ApnsClient::new(key_file, key_id, team_id, push.apns_topic.clone())?,
        default_environment: push.apns_environment,
        timezone: config.timezone,
        gym_rules: Arc::new(config.gym_rules()),
        from_hour: push.notify_from_hour,
        until_hour: push.notify_until_hour,
        weight: config.weight_settings(),
    }))
}

async fn serve(config: ServeConfig) -> anyhow::Result<()> {
    let pool = db::connect(&config.database.database_url)
        .await
        .context("could not open the database")?;
    if db::password_hash(&pool).await?.is_none() {
        tracing::warn!("no password is set yet; run `lyfe-server set-password` before signing in");
    }

    let syncer = garmin_syncer(&config, &pool)?;
    if !syncer.is_configured() {
        tracing::warn!("LYFE_GARMIN_KEY_FILE is not set; no activities will be imported");
    }
    tokio::spawn(
        syncer
            .clone()
            .run_forever(Duration::from_secs(config.garmin.garmin_poll_seconds)),
    );

    let notifier = notifier(&config, &pool, syncer.clone())?;
    let push_ready = match notifier {
        Some(notifier) => match notifier.apns.check_key(Utc::now()).await {
            Ok(()) => {
                tracing::info!(
                    from_hour = notifier.from_hour,
                    until_hour = notifier.until_hour,
                    weigh_in_at = ?notifier.weight.prompt_at.map(|at| at.format("%H:%M").to_string()),
                    "notifications are on"
                );
                tokio::spawn(Arc::new(notifier).run_forever(Duration::from_secs(300)));
                true
            }
            Err(error) => {
                tracing::error!(%error, "notifications are off: the Apple key cannot be used");
                false
            }
        },
        None => {
            tracing::warn!("LYFE_APNS_KEY_FILE is not set; no notifications will be sent");
            false
        }
    };

    let state = AppState {
        pool,
        syncer,
        throttle: Arc::new(SignInThrottle::new()),
        timezone: config.timezone,
        gym_rules: Arc::new(config.gym_rules()),
        breath_rules: Arc::new(config.breath_rules()),
        weight: config.weight_settings(),
        push_ready,
        now: Arc::new(Utc::now),
    };
    let listener = tokio::net::TcpListener::bind(config.listen_addr)
        .await
        .with_context(|| format!("could not listen on {}", config.listen_addr))?;
    tracing::info!(addr = %config.listen_addr, timezone = %config.timezone, "lyfe-server listening");
    axum::serve(listener, api::router(state))
        .with_graceful_shutdown(shutdown_signal())
        .await?;
    Ok(())
}

async fn shutdown_signal() {
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .expect("can listen for SIGTERM");
    tokio::select! {
        _ = tokio::signal::ctrl_c() => {}
        _ = terminate.recv() => {}
    }
}

async fn set_password(database: DatabaseConfig) -> anyhow::Result<()> {
    let password = if std::io::stdin().is_terminal() {
        let first = rpassword::prompt_password("New lyfe password: ")?;
        let second = rpassword::prompt_password("Again: ")?;
        if first != second {
            bail!("the two entries differ; nothing was changed");
        }
        first
    } else {
        let mut line = String::new();
        std::io::stdin().lock().read_line(&mut line)?;
        line.trim_end_matches(['\r', '\n']).to_string()
    };
    if password.chars().count() < auth::MIN_PASSWORD_CHARS {
        bail!("use at least {} characters; nothing was changed", auth::MIN_PASSWORD_CHARS);
    }
    let pool = db::connect(&database.database_url)
        .await
        .context("could not open the database")?;
    let hash = tokio::task::spawn_blocking(move || auth::hash_password(&password)).await??;
    db::set_password_hash(&pool, &hash).await?;
    println!("Password set. Every device has been signed out.");
    Ok(())
}

async fn gym_weeks(config: ServeConfig) -> anyhow::Result<()> {
    let pool = db::connect(&config.database.database_url)
        .await
        .context("could not open the database")?;
    let rules = config.gym_rules();
    let today = Utc::now().with_timezone(&config.timezone).date_naive();
    let this_week = Week::containing(today);
    let activities = db::activities_until(&pool, this_week.ends_on).await?;
    // Every recorded week, not only the recent ones shown on Home.
    let weeks = gym::all_weeks_until(&rules, today, &activities);
    let kept: Vec<bool> = weeks[..weeks.len() - 1]
        .iter()
        .map(|(_, done)| *done >= gym::WEEKLY_TARGET)
        .collect();
    let streak = gym::streak(&rules, today, &activities);
    let current = if streak.state == State::Kept {
        lyfe_server::routines::streak::Current::Kept
    } else {
        lyfe_server::routines::streak::Current::Open
    };
    let standing = lyfe_server::routines::streak::standing(&kept, current);

    println!("Gym weeks as lyfe counts them ({} sessions keep a week; today is {today}):", gym::WEEKLY_TARGET);
    println!();
    println!("  week      Monday       sessions  days                  result");
    for (index, (week, done)) in weeks.iter().enumerate() {
        let sessions = gym::sessions_in_week(&rules, *week, &activities);
        let days: Vec<String> = sessions.iter().map(|s| s.date.format("%a").to_string()).collect();
        let result = match standing.marks.get(index) {
            Some(Mark::Kept) => "kept",
            Some(Mark::Recovered) => "missed, then recovered",
            Some(Mark::AwaitingRecovery) => "missed, recover this week",
            Some(Mark::Missed) => "not kept",
            None if *done >= gym::WEEKLY_TARGET => "kept (this week)",
            None => "this week, still open",
        };
        println!(
            "  {}-W{:02}  {}   {:>8}  {:<20}  {result}",
            week.iso_year,
            week.iso_week,
            week.starts_on,
            done,
            days.join(" ")
        );
    }
    println!();
    let state = match streak.state {
        State::NotStarted => "no streak is alive",
        State::OnTrack => "on track",
        State::Recovering => "recovering from a missed week",
        State::Kept => "this week is already kept",
    };
    println!("Streak: {} weeks in a row ({state}). Previous best: {}.", streak.weeks, streak.previous_best);
    if streak.remaining > 0 {
        println!(
            "This week needs {} more, with {} days still open{}.",
            streak.remaining,
            streak.open_days,
            if streak.reachable { "" } else { ": out of reach" }
        );
    }
    let trained_today = gym::sessions_in_week(&rules, this_week, &activities)
        .iter()
        .any(|s| s.date == today);
    match gym::prompt(&streak, trained_today) {
        Some(prompt) => println!(
            "Prompt due today: \"{}\" / \"{}\"",
            prompt.title(&gym::WORDING, today),
            prompt.body(&gym::WORDING)
        ),
        None => println!("No prompt is due today."),
    }
    Ok(())
}

async fn push_test(config: ServeConfig) -> anyhow::Result<()> {
    let pool = db::connect(&config.database.database_url)
        .await
        .context("could not open the database")?;
    let syncer = garmin_syncer(&config, &pool)?;
    let Some(notifier) = notifier(&config, &pool, syncer)? else {
        bail!("set LYFE_APNS_KEY_FILE to the key Apple issued (.p8); see the README");
    };
    let now = Utc::now();
    notifier.apns.check_key(now).await?;
    let targets = db::push_targets(&pool).await?;
    if targets.is_empty() {
        bail!("no signed-in device accepts notifications yet; open lyfe on the phone and allow them");
    }
    let alert = Alert {
        title: "lyfe".to_string(),
        body: "Test notification. Prompts will arrive like this.".to_string(),
        collapse_id: "test".to_string(),
        expires_at: now + chrono::Duration::minutes(10),
        category: None,
    };
    let delivered = notifier.deliver(&targets, &alert, now).await;
    println!("Apple accepted the test for {delivered} of {} devices.", targets.len());
    if delivered == 0 {
        bail!("no device was reached; the log above says why");
    }
    Ok(())
}

async fn garmin_check(config: GarminConfig, days: i64) -> anyhow::Result<()> {
    let Some(client) = garmin_client(&config)? else {
        bail!("set LYFE_GARMIN_KEY_FILE or pass --garmin-key-file");
    };
    let today = Utc::now().date_naive();
    let items = client
        .activities_between(today - chrono::Duration::days(days), today + chrono::Duration::days(1))
        .await?;
    let activities: Vec<_> = items.iter().filter_map(parse_activity).collect();
    println!(
        "Garmin returned {} activities for the last {days} days ({} unreadable).",
        items.len(),
        items.len() - activities.len()
    );
    let mut by_type = std::collections::BTreeMap::<&str, usize>::new();
    let mut by_week = std::collections::BTreeMap::<(i32, u32), usize>::new();
    for activity in &activities {
        *by_type.entry(activity.type_key.as_str()).or_default() += 1;
        let week = activity.start_local.date().iso_week();
        *by_week.entry((week.year(), week.week())).or_default() += 1;
    }
    for (type_key, count) in by_type {
        println!("  {type_key}: {count}");
    }
    for ((year, week), count) in by_week {
        println!("  {year} week {week}: {count} activities");
    }
    Ok(())
}
