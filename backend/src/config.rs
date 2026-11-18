//! Runtime settings, all read from the environment. Secrets are referenced
//! by file path and never appear in settings themselves.

use std::path::PathBuf;

use clap::Args;

use crate::push::apns::Environment;
use crate::routines::breath::BreathRules;
use crate::routines::gym::GymRules;
use crate::routines::weight::{Unit, WeightSettings};

#[derive(Debug, Clone, Args)]
pub struct DatabaseConfig {
    /// PostgreSQL connection string.
    #[arg(long, env = "LYFE_DATABASE_URL", hide_env_values = true)]
    pub database_url: String,
}

#[derive(Debug, Clone, Args)]
pub struct GarminConfig {
    /// File holding the Garmin Connect Personal API key. Without it the
    /// server runs but imports nothing.
    #[arg(long, env = "LYFE_GARMIN_KEY_FILE")]
    pub garmin_key_file: Option<PathBuf>,

    #[arg(long, env = "LYFE_GARMIN_BASE_URL", default_value = "https://personal.connectapi.garmin.com")]
    pub garmin_base_url: String,

    /// Seconds between background polls.
    #[arg(long, env = "LYFE_GARMIN_POLL_SECONDS", default_value_t = 900)]
    pub garmin_poll_seconds: u64,

    /// Days of history fetched on the first poll, when nothing is stored yet.
    #[arg(long, env = "LYFE_GARMIN_BACKFILL_DAYS", default_value_t = 180)]
    pub garmin_backfill_days: i64,

    /// Days re-read on every later poll, so a watch synced late or an
    /// activity deleted in Garmin Connect is still picked up.
    #[arg(long, env = "LYFE_GARMIN_WINDOW_DAYS", default_value_t = 30)]
    pub garmin_window_days: i64,
}

#[derive(Debug, Clone, Args)]
pub struct PushConfig {
    /// The key Apple issued for sending notifications (a `.p8` file from
    /// the developer account). Without it the server runs and sends none.
    #[arg(long, env = "LYFE_APNS_KEY_FILE")]
    pub apns_key_file: Option<PathBuf>,

    /// The key's ID. Read from the file name when it is still called
    /// `AuthKey_<id>.p8`, as Apple names it.
    #[arg(long, env = "LYFE_APNS_KEY_ID")]
    pub apns_key_id: Option<String>,

    /// The developer team the key belongs to.
    #[arg(long, env = "LYFE_APNS_TEAM_ID")]
    pub apns_team_id: Option<String>,

    /// The app's bundle identifier.
    #[arg(long, env = "LYFE_APNS_TOPIC", default_value = "com.eduardkakosyan.lyfe")]
    pub apns_topic: String,

    /// Which Apple service to try first for a new device: `development`
    /// for an app installed from Xcode, `production` for TestFlight or the
    /// App Store. The other is tried when the first does not know the device.
    #[arg(long, env = "LYFE_APNS_ENVIRONMENT", default_value = "development", value_parser = parse_environment)]
    pub apns_environment: Environment,

    /// Prompts are sent from this hour of the owner's day (0 to 23)...
    #[arg(long, env = "LYFE_NOTIFY_FROM_HOUR", default_value_t = 7, value_parser = clap::value_parser!(u32).range(0..24))]
    pub notify_from_hour: u32,

    /// ...until this hour (1 to 24), and never outside it.
    #[arg(long, env = "LYFE_NOTIFY_UNTIL_HOUR", default_value_t = 18, value_parser = clap::value_parser!(u32).range(1..25))]
    pub notify_until_hour: u32,
}

fn parse_environment(text: &str) -> Result<Environment, String> {
    Environment::parse(text).ok_or_else(|| "use development or production".to_string())
}

#[derive(Debug, Clone, Args)]
pub struct ServeConfig {
    #[command(flatten)]
    pub database: DatabaseConfig,

    #[command(flatten)]
    pub garmin: GarminConfig,

    #[command(flatten)]
    pub push: PushConfig,

    /// Address to listen on. Keep it on loopback and publish it to the
    /// tailnet with `tailscale serve`.
    #[arg(long, env = "LYFE_LISTEN_ADDR", default_value = "127.0.0.1:8787")]
    pub listen_addr: std::net::SocketAddr,

    /// The owner's time zone (IANA name), which decides what "today" and
    /// "this week" mean.
    #[arg(long, env = "LYFE_TIMEZONE")]
    pub timezone: chrono_tz::Tz,

    /// Garmin activity types that count as a gym session, comma separated.
    #[arg(long, env = "LYFE_GYM_ACTIVITY_TYPES", default_value = GymRules::DEFAULT_TYPES)]
    pub gym_activity_types: String,

    /// Activities shorter than this many minutes do not count.
    #[arg(long, env = "LYFE_GYM_MIN_MINUTES", default_value_t = GymRules::DEFAULT_MIN_MINUTES)]
    pub gym_min_minutes: u32,

    /// Round length of the first breath table, in seconds. After the first
    /// session the table follows what was recorded.
    #[arg(long, env = "LYFE_BREATH_START_ROUND_SECONDS", default_value_t = BreathRules::DEFAULT_START_ROUND_SECONDS, value_parser = clap::value_parser!(u32).range(30..=1800))]
    pub breath_start_round_seconds: u32,

    /// Rounds in a breath table.
    #[arg(long, env = "LYFE_BREATH_ROUNDS", default_value_t = BreathRules::DEFAULT_ROUNDS, value_parser = clap::value_parser!(u32).range(1..=20))]
    pub breath_rounds: u32,

    /// The rounds get longer once a session leaves less recovery than this
    /// many seconds after its longest hold...
    #[arg(long, env = "LYFE_BREATH_ADVANCE_UNDER_SECONDS", default_value_t = BreathRules::DEFAULT_ADVANCE_UNDER_SECONDS, value_parser = clap::value_parser!(u32).range(0..=600))]
    pub breath_advance_under_seconds: u32,

    /// ...by this many seconds.
    #[arg(long, env = "LYFE_BREATH_STEP_SECONDS", default_value_t = BreathRules::DEFAULT_STEP_SECONDS, value_parser = clap::value_parser!(u32).range(1..=120))]
    pub breath_step_seconds: u32,

    /// The unit weights are typed and shown in: `kg` or `lb`. Weights are
    /// stored in grams, so changing it later changes only what is shown.
    #[arg(long, env = "LYFE_WEIGHT_UNIT", default_value = "lb", value_parser = parse_unit)]
    pub weight_unit: Unit,

    /// When the morning weigh-in prompt goes out, in the owner's time zone
    /// (`06:30`), or `off` for none.
    #[arg(long, env = "LYFE_WEIGH_IN_AT", default_value = "06:30", value_parser = parse_prompt_at)]
    pub weigh_in_at: PromptAt,
}

/// A time of day for a prompt, or none.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PromptAt(pub Option<chrono::NaiveTime>);

fn parse_prompt_at(text: &str) -> Result<PromptAt, String> {
    let text = text.trim();
    if text.eq_ignore_ascii_case("off") {
        return Ok(PromptAt(None));
    }
    chrono::NaiveTime::parse_from_str(text, "%H:%M")
        .map(|at| PromptAt(Some(at)))
        .map_err(|_| "use a time like 06:30, or off".to_string())
}

fn parse_unit(text: &str) -> Result<Unit, String> {
    Unit::parse(text).ok_or_else(|| "use kg or lb".to_string())
}

impl ServeConfig {
    pub fn breath_rules(&self) -> BreathRules {
        BreathRules {
            start_round_s: self.breath_start_round_seconds,
            rounds: self.breath_rounds,
            advance_under_s: self.breath_advance_under_seconds,
            step_s: self.breath_step_seconds,
        }
    }

    pub fn weight_settings(&self) -> WeightSettings {
        WeightSettings { unit: self.weight_unit, prompt_at: self.weigh_in_at.0 }
    }

    pub fn gym_rules(&self) -> GymRules {
        GymRules {
            counted_types: parse_types(&self.gym_activity_types),
            min_duration_s: f64::from(self.gym_min_minutes) * 60.0,
        }
    }
}

pub fn parse_types(list: &str) -> Vec<String> {
    list.split(',')
        .map(|t| t.trim().to_string())
        .filter(|t| !t.is_empty())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_types_parse_cleanly() {
        let types = parse_types(GymRules::DEFAULT_TYPES);
        assert!(types.contains(&"strength_training".to_string()));
        assert!(types.contains(&"indoor_rowing".to_string()));
        assert!(types.iter().all(|t| !t.contains(' ') && !t.is_empty()));
        assert!(!types.contains(&"walking".to_string()));
    }

    #[test]
    fn the_weigh_in_time_is_a_time_of_day_or_off() {
        assert_eq!(parse_prompt_at("06:30"), Ok(PromptAt(chrono::NaiveTime::from_hms_opt(6, 30, 0))));
        assert_eq!(parse_prompt_at(" OFF "), Ok(PromptAt(None)));
        assert!(parse_prompt_at("6.30").is_err());
        assert!(parse_prompt_at("25:00").is_err());
    }
}
