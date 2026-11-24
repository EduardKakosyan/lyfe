use std::io::{BufRead, IsTerminal};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{bail, Context};
use chrono::{Datelike, Utc};
use clap::{Parser, Subcommand};

use lyfe_server::api::{self, AppState};
use lyfe_server::auth::{self, SignInThrottle};
use lyfe_server::config::{DatabaseConfig, GarminConfig, IllustrationConfig, MoneyConfig, PhotoConfig, ServeConfig};
use lyfe_server::db;
use lyfe_server::estimator::Estimator;
use lyfe_server::illustrator::Illustrator;
use lyfe_server::garmin::sync::{parse_activity, Syncer};
use lyfe_server::garmin::GarminClient;
use lyfe_server::money::sync::Importer;
use lyfe_server::money::{self, BridgeClient};
use lyfe_server::push::apns::{Alert, ApnsClient};
use lyfe_server::push::notifier::Notifier;
use lyfe_server::routines::gym::{self, Week};
use lyfe_server::routines::{photo, product};
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
    /// Connect lyfe to SimpleFIN Bridge: asks for a setup token made there
    /// (typed hidden), trades it for the access address and writes that to
    /// the access file. Done once; the banks themselves are connected at
    /// the bridge.
    MoneyConnect {
        #[command(flatten)]
        money: MoneyConfig,
    },
    /// Ask the bridge for the last week and print counts only. Touches no
    /// database; use it to confirm the access file works. It uses one of
    /// the day's requests.
    MoneyCheck {
        #[command(flatten)]
        money: MoneyConfig,
    },
    /// Import accounts and transactions now, without waiting for the next
    /// time one is due, and print counts only. It uses one of the day's
    /// requests.
    MoneyImport(Box<ServeConfig>),
    /// Read the Open Food Facts export (tab separated, unzipped) from
    /// standard input and make it the food database barcodes are looked up
    /// in, replacing the last one.
    ImportFoodDb {
        #[command(flatten)]
        database: DatabaseConfig,
    },
    /// Ask the vision model to estimate one meal photo and print what it
    /// answers. Stores nothing; use it to check the model works.
    PhotoCheck {
        #[command(flatten)]
        photo: PhotoConfig,
        /// A JPEG of the meal.
        jpeg: Option<std::path::PathBuf>,
        /// The one line that goes with it.
        #[arg(long, default_value = "")]
        note: String,
    },
    /// Draw one meal photo as a Poster illustration with the image model and
    /// write it out. Stores nothing; use it to check the illustrator works.
    IllustrationCheck {
        #[command(flatten)]
        illustration: IllustrationConfig,
        /// A JPEG of the meal.
        jpeg: std::path::PathBuf,
        /// The one line that goes with it.
        #[arg(long, default_value = "")]
        note: String,
        /// Where to write the illustration (a PNG).
        #[arg(long, default_value = "illustration.png")]
        out: std::path::PathBuf,
    },
    /// Read food names from standard input, one a line, and queue the icon
    /// of each to be drawn ahead of anyone looking at it. The running
    /// server draws them in the background, in the order given, after any
    /// meal photos and any icon the phone is asking for. Ones already drawn
    /// are left alone, so it can be run again to see how far along it is.
    QueueIcons {
        #[command(flatten)]
        database: DatabaseConfig,
    },
    /// Draw the icon of one food with the image model, from its name alone,
    /// and write it out. Stores nothing; use it to see what an icon looks
    /// like.
    IconCheck {
        #[command(flatten)]
        illustration: IllustrationConfig,
        /// The food's name, as the ingredient catalogue has it.
        name: String,
        /// Where to write the icon (a PNG).
        #[arg(long, default_value = "icon.png")]
        out: std::path::PathBuf,
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
        Command::MoneyConnect { money } => money_connect(money).await,
        Command::MoneyCheck { money } => money_check(money).await,
        Command::MoneyImport(config) => money_import(*config).await,
        Command::ImportFoodDb { database } => import_food_db(database).await,
        Command::PhotoCheck { photo, jpeg, note } => photo_check(photo, jpeg, note).await,
        Command::IllustrationCheck { illustration, jpeg, note, out } => {
            illustration_check(illustration, Some(jpeg), note, out).await
        }
        Command::IconCheck { illustration, name, out } => illustration_check(illustration, None, name, out).await,
        Command::QueueIcons { database } => queue_icons(database).await,
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

fn money_importer(config: &ServeConfig, pool: &sqlx::PgPool) -> anyhow::Result<Arc<Importer>> {
    let client = config.money.simplefin_access_file.clone().map(BridgeClient::new).transpose()?;
    Ok(Arc::new(Importer::new(
        pool.clone(),
        client,
        config.timezone,
        i64::from(config.money.money_backfill_days),
        i64::from(config.money.money_window_days),
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
        study_rules: Arc::new(config.study_rules()),
        from_hour: push.notify_from_hour,
        until_hour: push.notify_until_hour,
        weight: config.weight_settings(),
        food: config.food_settings(),
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
                    food_prompt_at = ?notifier.food.prompt_at.map(|at| at.format("%H:%M").to_string()),
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

    let importer = money_importer(&config, &pool)?;
    if importer.is_configured() {
        tracing::info!(every_hours = config.money.money_sync_hours, "accounts and transactions are imported from SimpleFIN Bridge");
    } else {
        tracing::warn!("LYFE_SIMPLEFIN_ACCESS_FILE is not set; no accounts or transactions will be imported");
    }
    tokio::spawn(
        importer
            .clone()
            .run_forever(Duration::from_secs(u64::from(config.money.money_sync_hours) * 3600)),
    );

    let estimator_wake = Arc::new(tokio::sync::Notify::new());
    let illustrator_wake = Arc::new(tokio::sync::Notify::new());
    let estimator = Arc::new(
        Estimator::new(pool.clone(), config.photo.estimator_settings(), estimator_wake.clone())?
            .waking(illustrator_wake.clone()),
    );
    match &estimator.settings().ollama_url {
        Some(url) => tracing::info!(
            ollama = %url,
            model = %estimator.settings().model,
            context = estimator.settings().context,
            min_free_gb = estimator.settings().min_free_gb,
            "photo meals are estimated on this machine"
        ),
        None => tracing::warn!("LYFE_OLLAMA_URL is off; photo meals are not estimated and are typed in by hand"),
    }
    tokio::spawn(estimator.run_forever());

    let illustrator =
        Arc::new(Illustrator::new(pool.clone(), config.illustration.illustrator_settings(), illustrator_wake.clone()));
    match &illustrator.settings().program {
        Some(program) if std::path::Path::new(&program[0]).exists() => tracing::info!(
            program = %program[0],
            min_free_gb = illustrator.settings().min_free_gb,
            "meal photos are illustrated, and food icons drawn, on this machine"
        ),
        Some(program) => tracing::warn!(
            program = %program[0],
            "the illustrator is not installed (see lyfe-illustrator-setup); meals keep their photos, and foods \
             their category's icon, until it is"
        ),
        None => tracing::warn!("LYFE_ILLUSTRATOR is off; meals keep their photos, and foods their category's icon"),
    }
    let food_icons = illustrator.settings().program.is_some();
    if illustrator.settings().program.is_some() {
        let redrawn = db::redraw_older_looks(&pool).await?;
        if redrawn > 0 {
            tracing::info!(redrawn, "meals drawn in an older look will be drawn again");
        }
    }
    tokio::spawn(illustrator.run_forever());

    let state = AppState {
        pool,
        syncer,
        throttle: Arc::new(SignInThrottle::new()),
        timezone: config.timezone,
        gym_rules: Arc::new(config.gym_rules()),
        breath_rules: Arc::new(config.breath_rules()),
        study_rules: Arc::new(config.study_rules()),
        weight: config.weight_settings(),
        push_ready,
        estimate_range_pct: config.photo.photo_range_percent,
        estimator_wake,
        illustrator_wake,
        food_icons,
        money: importer,
        money_currency: config.money.money_currency.clone(),
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

fn access_file(config: &MoneyConfig) -> anyhow::Result<std::path::PathBuf> {
    config
        .simplefin_access_file
        .clone()
        .context("set LYFE_SIMPLEFIN_ACCESS_FILE or pass --simplefin-access-file")
}

async fn money_connect(config: MoneyConfig) -> anyhow::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;

    let path = access_file(&config)?;
    if path.exists() {
        bail!(
            "{} already holds an access address; lyfe is connected. To start over, revoke it at the bridge and delete the file",
            path.display()
        );
    }
    // Opened before the token is spent, so a place that cannot be written
    // does not cost a token. Only this account can read it.
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)
        .with_context(|| format!("could not create {}", path.display()))?;
    let token = if std::io::stdin().is_terminal() {
        rpassword::prompt_password("SimpleFIN setup token (hidden): ")?
    } else {
        let mut line = String::new();
        std::io::stdin().lock().read_line(&mut line)?;
        line
    };
    let access = match money::claim(&token).await {
        Ok(access) => access,
        Err(error) => {
            let _ = std::fs::remove_file(&path);
            bail!("{error}");
        }
    };
    file.write_all(access.as_bytes()).and_then(|()| file.sync_all()).with_context(|| {
        format!("the token was spent but {} could not be written; revoke it at the bridge and make a new one", path.display())
    })?;
    println!("Connected. The access address is in {}.", path.display());
    println!("Check it with `lyfe-server money-check`, then restart lyfe-server.");
    Ok(())
}

async fn money_check(config: MoneyConfig) -> anyhow::Result<()> {
    let client = BridgeClient::new(access_file(&config)?)?;
    let now = Utc::now();
    let set = client.accounts(now - chrono::Duration::days(7), now + chrono::Duration::days(1)).await?;
    println!(
        "The bridge returned {} accounts under {} connections ({} unreadable).",
        set.accounts.len(),
        set.connections.len(),
        set.unreadable_accounts
    );
    for (index, account) in set.accounts.iter().enumerate() {
        println!(
            "  account {}: {} posted in the last week ({} unreadable), balance as of {}",
            index + 1,
            account.transactions.len(),
            account.unreadable,
            account.balance_at.format("%Y-%m-%d %H:%M UTC")
        );
        // Counts and a share only: what is held and what it is worth stay out of the terminal.
        if let Some(holdings) = account.holdings.as_ref().filter(|_| account.holds_investments) {
            let same_currency = holdings.iter().filter(|holding| holding.currency == account.currency);
            let held: i64 = same_currency.clone().map(|holding| holding.value_minor).sum();
            let of_balance = if same_currency.count() == holdings.len() && account.balance_minor > 0 {
                format!(", coming to {}% of its balance", (held as f64 / account.balance_minor as f64 * 100.0).round())
            } else {
                String::new()
            };
            println!(
                "    it lists {} holdings ({} unreadable, {} with what was paid){}",
                holdings.len(),
                account.unreadable_holdings,
                holdings.iter().filter(|holding| holding.cost_minor.is_some()).count(),
                of_balance
            );
        }
    }
    for trouble in &set.troubles {
        println!("  the bridge says: {}", trouble.text);
    }
    Ok(())
}

async fn money_import(config: ServeConfig) -> anyhow::Result<()> {
    let pool = db::connect(&config.database.database_url)
        .await
        .context("could not open the database")?;
    let importer = money_importer(&config, &pool)?;
    let Some(result) = importer.import_once(Utc::now()).await else {
        bail!("set LYFE_SIMPLEFIN_ACCESS_FILE to the file `lyfe-server money-connect` wrote; see the README");
    };
    let report = result?;
    println!(
        "Imported {} accounts, asking the bridge {} time(s): {} posted transactions, {} new, {} changed by the bank, {} unreadable.",
        report.accounts, report.requests, report.fetched, report.new, report.changed, report.unreadable
    );
    println!(
        "{} entries were sorted again; the investment accounts list {} holdings; the bridge reported {} problems.",
        report.resorted, report.holdings, report.troubles
    );
    Ok(())
}

async fn import_food_db(database: DatabaseConfig) -> anyhow::Result<()> {
    let pool = db::connect(&database.database_url)
        .await
        .context("could not open the database")?;
    let mut lines = std::io::stdin().lock().lines();
    let header = lines.next().context("nothing came in on standard input")??;
    let columns = product::Columns::from_header(&header).map_err(anyhow::Error::msg)?;
    let mut import = db::ProductImport::begin(&pool).await?;
    let (mut read, mut skipped) = (0u64, 0u64);
    let mut batch = Vec::with_capacity(5_000);
    for line in lines {
        // A line that is not text is skipped like any other unusable line.
        let Ok(line) = line else {
            skipped += 1;
            continue;
        };
        read += 1;
        match columns.product(&line) {
            Some(found) => batch.push(found),
            None => skipped += 1,
        }
        if batch.len() == 5_000 {
            import.add(&batch).await?;
            batch.clear();
        }
        if read % 500_000 == 0 {
            eprintln!("  {read} lines read, {} products so far", import.stored + batch.len() as u64);
        }
    }
    import.add(&batch).await?;
    let stored = import.finish().await?;
    println!("Food database replaced: {stored} products from {read} lines ({skipped} without a name, energy or protein).");
    Ok(())
}

async fn photo_check(config: PhotoConfig, jpeg: Option<std::path::PathBuf>, note: String) -> anyhow::Result<()> {
    let settings = config.estimator_settings();
    if settings.ollama_url.is_none() {
        bail!("LYFE_OLLAMA_URL is off");
    }
    let jpeg = jpeg.map(std::fs::read).transpose().context("could not read the photo")?;
    if jpeg.is_none() && note.trim().is_empty() {
        bail!("give a photo, a --note, or both");
    }
    // No database: nothing is stored.
    let pool = sqlx::postgres::PgPoolOptions::new().connect_lazy("postgres://unused")?;
    let estimator = Estimator::new(pool, settings, Arc::new(tokio::sync::Notify::new()))?;
    let started = std::time::Instant::now();
    let estimate = estimator.ask(&note, jpeg).await.map_err(anyhow::Error::msg)?;
    println!("Answered in {:.1} s.", started.elapsed().as_secs_f64());
    for item in &estimate.items {
        println!("  {:<30} {:>6.0} g {:>6.0} kcal {:>6.1} g protein", item.name, item.grams, item.kcal_seen, item.protein_g_seen);
    }
    let amount = photo::amount(&estimate.items, estimate.oil_asked, None);
    let (low, high) = photo::range(amount.kcal, config.photo_range_percent);
    println!(
        "Total {} kcal ({low} to {high}), {:.1} g protein{}.",
        amount.kcal,
        amount.protein_g(),
        if estimate.oil_asked { ", with some oil counted: it would ask about oil" } else { "" }
    );
    Ok(())
}

async fn queue_icons(database: DatabaseConfig) -> anyhow::Result<()> {
    use lyfe_server::routines::illustration;
    let pool = db::connect(&database.database_url)
        .await
        .context("could not open the database")?;
    let (mut read, mut queued, mut unusable) = (0i64, 0u64, 0u64);
    for line in std::io::stdin().lock().lines() {
        let Ok(name) = line else {
            unusable += 1;
            continue;
        };
        if name.trim().is_empty() {
            continue;
        }
        read += 1;
        match illustration::icon_key(&name) {
            Some(key) if db::queue_food_icon(&pool, &key, &name, read).await? => queued += 1,
            Some(_) => {}
            None => unusable += 1,
        }
    }
    let counts = db::food_icon_counts(&pool).await?;
    println!("Read {read} names and queued {queued}; {unusable} were not names an icon is drawn for.");
    println!(
        "Icons now: {} drawn, {} waiting, {} given up on. The server draws the ones waiting in the background, \
         about a second each once the model is loaded.",
        counts.drawn, counts.waiting, counts.given_up
    );
    Ok(())
}

/// Draws one picture and writes it out: a meal photo with its line, or,
/// with no photo, the icon of the food the line names.
async fn illustration_check(
    config: IllustrationConfig,
    jpeg: Option<std::path::PathBuf>,
    note: String,
    out: std::path::PathBuf,
) -> anyhow::Result<()> {
    let settings = config.illustrator_settings();
    if settings.program.is_none() {
        bail!("LYFE_ILLUSTRATOR is off");
    }
    let jpeg = match jpeg {
        Some(path) => {
            let jpeg = std::fs::read(&path).context("could not read the photo")?;
            if !photo::is_jpeg(&jpeg) {
                bail!("the photo must be a JPEG");
            }
            Some(jpeg)
        }
        None if lyfe_server::routines::illustration::icon_key(&note).is_none() => {
            bail!("a food's name is 1 to 80 characters")
        }
        None => None,
    };
    if let Some(free_gb) = lyfe_server::estimator::free_memory_gb(&settings.meminfo)
        && free_gb < f64::from(settings.min_free_gb)
    {
        bail!("only {free_gb:.0} GB of memory are free, and the illustrator needs {}", settings.min_free_gb);
    }
    // No database: nothing is stored.
    let pool = sqlx::postgres::PgPoolOptions::new().connect_lazy("postgres://unused")?;
    let illustrator = Illustrator::new(pool, settings, Arc::new(tokio::sync::Notify::new()));
    let drawn = match jpeg {
        Some(jpeg) => illustrator.check(&note, jpeg).await,
        None => illustrator.check_icon(&note).await,
    };
    let (png, loading, drawing) = drawn.map_err(anyhow::Error::msg)?;
    std::fs::write(&out, &png).with_context(|| format!("could not write {}", out.display()))?;
    println!(
        "Loaded in {:.1} s, drew in {:.1} s. Wrote {} ({} kB).",
        loading.as_secs_f64(),
        drawing.as_secs_f64(),
        out.display(),
        png.len() / 1024
    );
    Ok(())
}
