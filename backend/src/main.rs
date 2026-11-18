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

async fn serve(config: ServeConfig) -> anyhow::Result<()> {
    let pool = db::connect(&config.database.database_url)
        .await
        .context("could not open the database")?;
    if db::password_hash(&pool).await?.is_none() {
        tracing::warn!("no password is set yet; run `lyfe-server set-password` before signing in");
    }

    let client = garmin_client(&config.garmin)?;
    if client.is_none() {
        tracing::warn!("LYFE_GARMIN_KEY_FILE is not set; no activities will be imported");
    }
    let syncer = Arc::new(Syncer::new(
        pool.clone(),
        client,
        config.garmin.garmin_backfill_days,
        config.garmin.garmin_window_days,
    ));
    tokio::spawn(
        syncer
            .clone()
            .run_forever(Duration::from_secs(config.garmin.garmin_poll_seconds)),
    );

    let state = AppState {
        pool,
        syncer,
        throttle: Arc::new(SignInThrottle::new()),
        timezone: config.timezone,
        gym_rules: Arc::new(config.gym_rules()),
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
