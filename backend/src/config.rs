//! Runtime settings, all read from the environment. Secrets are referenced
//! by file path and never appear in settings themselves.

use std::path::PathBuf;

use clap::Args;

use crate::routines::gym::GymRules;

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
pub struct ServeConfig {
    #[command(flatten)]
    pub database: DatabaseConfig,

    #[command(flatten)]
    pub garmin: GarminConfig,

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
}

impl ServeConfig {
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
}
