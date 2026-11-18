//! Pulls activities from Garmin into the database. Safe to run as often as
//! wanted: an activity is stored under Garmin's own id, so a repeat poll
//! refreshes it instead of adding it again.

use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, NaiveDate, NaiveDateTime, Utc};
use serde_json::Value;
use sqlx::PgPool;

use super::{GarminClient, GarminError};
use crate::db::{self, StoredActivity};

pub const SOURCE: &str = "garmin";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct SyncReport {
    /// Activities Garmin returned for the window.
    pub fetched: usize,
    /// Of those, how many were not stored before.
    pub new: usize,
    /// Stored activities Garmin no longer lists.
    pub gone: u64,
    /// Entries that could not be read and were left out.
    pub unreadable: usize,
}

#[derive(Debug, thiserror::Error)]
pub enum SyncError {
    #[error(transparent)]
    Garmin(#[from] GarminError),
    #[error("the database refused the update")]
    Database(#[from] sqlx::Error),
}

pub struct Syncer {
    pool: PgPool,
    client: Option<GarminClient>,
    backfill_days: i64,
    window_days: i64,
    /// One poll at a time, whether started by the timer or by the app.
    running: tokio::sync::Mutex<()>,
}

impl Syncer {
    pub fn new(pool: PgPool, client: Option<GarminClient>, backfill_days: i64, window_days: i64) -> Self {
        Self {
            pool,
            client,
            backfill_days: backfill_days.max(1),
            window_days: window_days.max(1),
            running: tokio::sync::Mutex::new(()),
        }
    }

    pub fn is_configured(&self) -> bool {
        self.client.is_some()
    }

    /// Polls Garmin once and records the outcome as the source's freshness.
    /// Returns `None` when no key file is configured.
    pub async fn poll_once(&self, now: DateTime<Utc>) -> Option<Result<SyncReport, SyncError>> {
        let client = self.client.as_ref()?;
        let _guard = self.running.lock().await;
        let result = self.poll(client, now.date_naive()).await;
        let recorded = match &result {
            Ok(_) => db::record_sync_success(&self.pool, SOURCE).await,
            Err(error) => db::record_sync_failure(&self.pool, SOURCE, &error.to_string()).await,
        };
        if let Err(error) = recorded {
            tracing::error!(%error, "could not record Garmin sync outcome");
        }
        Some(result)
    }

    /// Polls unless an attempt was already made within `min_age`. Used when
    /// the app asks for fresh data, so opening it repeatedly cannot hammer
    /// Garmin.
    pub async fn poll_if_stale(&self, now: DateTime<Utc>, min_age: Duration) {
        if !self.is_configured() {
            return;
        }
        let recent = match db::source_sync(&self.pool, SOURCE).await {
            Ok(sync) => sync
                .last_attempt_at
                .is_some_and(|at| (now - at).to_std().is_ok_and(|age| age < min_age)),
            Err(_) => false,
        };
        if !recent {
            self.poll_once(now).await;
        }
    }

    /// Background loop: poll, wait, repeat. Failures are recorded and the
    /// loop carries on.
    pub async fn run_forever(self: Arc<Self>, every: Duration) {
        let mut ticker = tokio::time::interval(every.max(Duration::from_secs(60)));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            ticker.tick().await;
            match self.poll_once(Utc::now()).await {
                Some(Ok(report)) => tracing::info!(
                    fetched = report.fetched,
                    new = report.new,
                    gone = report.gone,
                    unreadable = report.unreadable,
                    "Garmin sync finished"
                ),
                Some(Err(error)) => tracing::warn!(%error, "Garmin sync failed"),
                None => return,
            }
        }
    }

    async fn poll(&self, client: &GarminClient, today: NaiveDate) -> Result<SyncReport, SyncError> {
        let first_run = db::latest_activity_date(&self.pool).await?.is_none();
        let days_back = if first_run { self.backfill_days } else { self.window_days };
        let from = today - chrono::Duration::days(days_back);
        // Ask a day past today: the watch's local date can be ahead of UTC.
        let to = today + chrono::Duration::days(1);

        let items = client.activities_between(from, to).await?;
        let mut report = SyncReport { fetched: items.len(), ..SyncReport::default() };
        let mut seen_ids = Vec::with_capacity(items.len());
        let mut activities = Vec::with_capacity(items.len());
        let mut every_id_known = true;
        for item in &items {
            match item.get("activityId").and_then(Value::as_i64) {
                Some(id) => seen_ids.push(id),
                None => every_id_known = false,
            }
            match parse_activity(item) {
                Some(activity) => activities.push(activity),
                None => report.unreadable += 1,
            }
        }

        let mut tx = self.pool.begin().await?;
        for activity in &activities {
            if db::upsert_activity(&mut tx, activity).await? {
                report.new += 1;
            }
        }
        // Only when every returned entry could be identified is absence
        // evidence of deletion, and an entirely empty answer is treated as
        // a hiccup, not as everything having been deleted. The first day of
        // the window is left alone because Garmin's date filter may cut it
        // at a different hour.
        if every_id_known && !items.is_empty() {
            report.gone =
                db::mark_missing_gone(&mut tx, from + chrono::Duration::days(1), &seen_ids).await?;
        }
        tx.commit().await?;
        Ok(report)
    }
}

/// Reads the fields lyfe needs out of one Garmin activity. The raw entry is
/// kept for later steps, minus the account owner's name and picture links.
pub fn parse_activity(item: &Value) -> Option<StoredActivity> {
    let object = item.as_object()?;
    let activity_id = object.get("activityId")?.as_i64()?;
    let start_local = parse_garmin_time(object.get("startTimeLocal")?.as_str()?)?;
    let start_gmt = parse_garmin_time(object.get("startTimeGMT")?.as_str()?)?.and_utc();
    let type_key = object
        .get("activityType")
        .and_then(|t| t.get("typeKey"))
        .and_then(Value::as_str)
        .unwrap_or("unknown")
        .to_string();
    let name = object
        .get("activityName")
        .and_then(Value::as_str)
        .map(str::to_string);
    let duration_s = object.get("duration").and_then(Value::as_f64).unwrap_or(0.0);
    let raw: serde_json::Map<String, Value> = object
        .iter()
        .filter(|(key, _)| !key.starts_with("owner"))
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect();
    Some(StoredActivity {
        activity_id,
        type_key,
        name,
        start_local,
        start_gmt,
        duration_s,
        raw: Value::Object(raw),
    })
}

fn parse_garmin_time(text: &str) -> Option<NaiveDateTime> {
    ["%Y-%m-%d %H:%M:%S", "%Y-%m-%d %H:%M:%S%.f", "%Y-%m-%dT%H:%M:%S%.f"]
        .iter()
        .find_map(|format| NaiveDateTime::parse_from_str(text, format).ok())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn reads_a_list_entry() {
        let item = json!({
            "activityId": 123456789012i64,
            "activityName": "Strength",
            "startTimeLocal": "2026-11-17 06:05:11",
            "startTimeGMT": "2026-11-17 10:05:11",
            "activityType": {"typeId": 13, "typeKey": "strength_training", "parentTypeId": 29},
            "duration": 3480.5,
            "ownerFullName": "Someone",
            "ownerProfileImageUrlLarge": "https://example.invalid/x.png",
            "calories": 400.0
        });
        let activity = parse_activity(&item).unwrap();
        assert_eq!(activity.activity_id, 123456789012);
        assert_eq!(activity.type_key, "strength_training");
        assert_eq!(activity.name.as_deref(), Some("Strength"));
        assert_eq!(activity.start_local.to_string(), "2026-11-17 06:05:11");
        assert_eq!(activity.start_gmt.to_rfc3339(), "2026-11-17T10:05:11+00:00");
        assert_eq!(activity.duration_s, 3480.5);
        assert!(activity.raw.get("calories").is_some());
        assert!(activity.raw.get("ownerFullName").is_none());
        assert!(activity.raw.get("ownerProfileImageUrlLarge").is_none());
    }

    #[test]
    fn tolerates_missing_optional_fields() {
        let item = json!({
            "activityId": 1,
            "startTimeLocal": "2026-11-17 06:05:11.0",
            "startTimeGMT": "2026-11-17T10:05:11.0"
        });
        let activity = parse_activity(&item).unwrap();
        assert_eq!(activity.type_key, "unknown");
        assert_eq!(activity.name, None);
        assert_eq!(activity.duration_s, 0.0);
    }

    #[test]
    fn rejects_entries_without_id_or_start() {
        assert!(parse_activity(&json!({"startTimeLocal": "2026-11-17 06:05:11", "startTimeGMT": "2026-11-17 10:05:11"})).is_none());
        assert!(parse_activity(&json!({"activityId": 1, "startTimeLocal": "yesterday", "startTimeGMT": "2026-11-17 10:05:11"})).is_none());
        assert!(parse_activity(&json!("nope")).is_none());
    }
}
