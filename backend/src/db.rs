//! Database access. Queries live here so the rest of the code never
//! builds SQL.

use chrono::{DateTime, NaiveDate, NaiveDateTime, Utc};
use sqlx::postgres::{PgPool, PgPoolOptions};
use sqlx::Row;

use uuid::Uuid;

use crate::routines::breath;
use crate::routines::gym::Activity;
use crate::routines::weight::{self, Unit};

pub static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("./migrations");

pub async fn connect(database_url: &str) -> anyhow::Result<PgPool> {
    let pool = PgPoolOptions::new()
        .max_connections(5)
        .connect(database_url)
        .await?;
    MIGRATOR.run(&pool).await?;
    Ok(pool)
}

// --- Owner and device sessions -------------------------------------------

pub async fn password_hash(pool: &PgPool) -> sqlx::Result<Option<String>> {
    sqlx::query_scalar("select password_hash from owner")
        .fetch_optional(pool)
        .await
}

/// Stores a new password hash and signs every device out.
pub async fn set_password_hash(pool: &PgPool, hash: &str) -> sqlx::Result<()> {
    let mut tx = pool.begin().await?;
    sqlx::query(
        "insert into owner (id, password_hash) values (true, $1)
         on conflict (id) do update set password_hash = excluded.password_hash, updated_at = now()",
    )
    .bind(hash)
    .execute(&mut *tx)
    .await?;
    sqlx::query("update device_sessions set revoked_at = now() where revoked_at is null")
        .execute(&mut *tx)
        .await?;
    tx.commit().await
}

pub async fn insert_session(pool: &PgPool, token_hash: &[u8], device_name: &str) -> sqlx::Result<()> {
    sqlx::query("insert into device_sessions (token_hash, device_name) values ($1, $2)")
        .bind(token_hash)
        .bind(device_name)
        .execute(pool)
        .await?;
    Ok(())
}

/// Returns the session id when the token is known and not revoked, and
/// records that it was used.
pub async fn touch_session(pool: &PgPool, token_hash: &[u8]) -> sqlx::Result<Option<i64>> {
    sqlx::query_scalar(
        "update device_sessions set last_used_at = now()
         where token_hash = $1 and revoked_at is null
         returning id",
    )
    .bind(token_hash)
    .fetch_optional(pool)
    .await
}

pub async fn revoke_session(pool: &PgPool, session_id: i64) -> sqlx::Result<()> {
    sqlx::query("update device_sessions set revoked_at = now() where id = $1 and revoked_at is null")
        .bind(session_id)
        .execute(pool)
        .await?;
    Ok(())
}

// --- Push notifications --------------------------------------------------

/// Records where Apple delivers notifications for this device. The same
/// install signing in again moves its token to the newer session.
pub async fn set_push_token(pool: &PgPool, session_id: i64, apns_token: &str) -> sqlx::Result<()> {
    let mut tx = pool.begin().await?;
    sqlx::query("update device_sessions set apns_token = null, apns_environment = null where apns_token = $1 and id <> $2")
        .bind(apns_token)
        .bind(session_id)
        .execute(&mut *tx)
        .await?;
    sqlx::query(
        "update device_sessions
         set apns_environment = case when apns_token = $1 then apns_environment end,
             apns_token = $1, apns_token_at = now()
         where id = $2",
    )
    .bind(apns_token)
    .bind(session_id)
    .execute(&mut *tx)
    .await?;
    tx.commit().await
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PushTarget {
    pub session_id: i64,
    pub device_name: String,
    pub apns_token: String,
    pub apns_environment: Option<String>,
}

/// Signed-in devices that can be notified.
pub async fn push_targets(pool: &PgPool) -> sqlx::Result<Vec<PushTarget>> {
    let rows = sqlx::query(
        "select id, device_name, apns_token, apns_environment from device_sessions
         where revoked_at is null and apns_token is not null
         order by id",
    )
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|r| PushTarget {
            session_id: r.get("id"),
            device_name: r.get("device_name"),
            apns_token: r.get("apns_token"),
            apns_environment: r.get("apns_environment"),
        })
        .collect())
}

/// Remembers which Apple service accepted a device's token.
pub async fn set_push_environment(pool: &PgPool, session_id: i64, environment: &str) -> sqlx::Result<()> {
    sqlx::query("update device_sessions set apns_environment = $2 where id = $1")
        .bind(session_id)
        .bind(environment)
        .execute(pool)
        .await?;
    Ok(())
}

/// Forgets a token Apple no longer accepts (the app was removed, or
/// notifications were re-registered).
pub async fn clear_push_token(pool: &PgPool, session_id: i64) -> sqlx::Result<()> {
    sqlx::query("update device_sessions set apns_token = null, apns_environment = null where id = $1")
        .bind(session_id)
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn notification_sent(pool: &PgPool, kind: &str, period: NaiveDate) -> sqlx::Result<bool> {
    sqlx::query_scalar("select exists (select 1 from notifications where kind = $1 and period = $2)")
        .bind(kind)
        .bind(period)
        .fetch_one(pool)
        .await
}

pub async fn record_notification(
    pool: &PgPool,
    kind: &str,
    period: NaiveDate,
    title: &str,
    body: &str,
) -> sqlx::Result<()> {
    sqlx::query(
        "insert into notifications (kind, period, title, body) values ($1, $2, $3, $4)
         on conflict (kind, period) do nothing",
    )
    .bind(kind)
    .bind(period)
    .bind(title)
    .bind(body)
    .execute(pool)
    .await?;
    Ok(())
}

// --- Garmin activities ---------------------------------------------------

#[derive(Debug, Clone, PartialEq)]
pub struct StoredActivity {
    pub activity_id: i64,
    pub type_key: String,
    pub name: Option<String>,
    pub start_local: NaiveDateTime,
    pub start_gmt: DateTime<Utc>,
    pub duration_s: f64,
    pub raw: serde_json::Value,
}

/// Inserts or refreshes one activity. Returns true when it was not stored
/// before.
pub async fn upsert_activity(
    conn: &mut sqlx::PgConnection,
    a: &StoredActivity,
) -> sqlx::Result<bool> {
    let inserted: bool = sqlx::query_scalar(
        "insert into garmin_activities
            (activity_id, type_key, name, start_local, start_gmt, duration_s, raw)
         values ($1, $2, $3, $4, $5, $6, $7)
         on conflict (activity_id) do update set
            type_key = excluded.type_key,
            name = excluded.name,
            start_local = excluded.start_local,
            start_gmt = excluded.start_gmt,
            duration_s = excluded.duration_s,
            raw = excluded.raw,
            last_seen_at = now(),
            gone_at = null
         returning (xmax = 0)",
    )
    .bind(a.activity_id)
    .bind(&a.type_key)
    .bind(&a.name)
    .bind(a.start_local)
    .bind(a.start_gmt)
    .bind(a.duration_s)
    .bind(&a.raw)
    .fetch_one(conn)
    .await?;
    Ok(inserted)
}

/// Marks as gone every stored activity that started on or after `from` and
/// is not in `seen_ids`. Returns how many were marked.
pub async fn mark_missing_gone(
    conn: &mut sqlx::PgConnection,
    from: NaiveDate,
    seen_ids: &[i64],
) -> sqlx::Result<u64> {
    let result = sqlx::query(
        "update garmin_activities set gone_at = now()
         where gone_at is null and start_local >= $1 and activity_id <> all($2)",
    )
    .bind(from.and_hms_opt(0, 0, 0).expect("midnight exists"))
    .bind(seen_ids)
    .execute(conn)
    .await?;
    Ok(result.rows_affected())
}

pub async fn latest_activity_date(pool: &PgPool) -> sqlx::Result<Option<NaiveDate>> {
    let latest: Option<NaiveDateTime> =
        sqlx::query_scalar("select max(start_local) from garmin_activities")
            .fetch_one(pool)
            .await?;
    Ok(latest.map(|t| t.date()))
}

/// Every activity still present in Garmin that started on or before `to`.
pub async fn activities_until(pool: &PgPool, to: NaiveDate) -> sqlx::Result<Vec<Activity>> {
    activities_between(pool, NaiveDate::from_ymd_opt(1970, 1, 1).expect("a real date"), to).await
}

/// Activities still present in Garmin that started within `[from, to]`.
pub async fn activities_between(
    pool: &PgPool,
    from: NaiveDate,
    to: NaiveDate,
) -> sqlx::Result<Vec<Activity>> {
    let rows = sqlx::query(
        "select activity_id, type_key, name, start_local, duration_s
         from garmin_activities
         where gone_at is null and start_local >= $1 and start_local < $2
         order by start_local",
    )
    .bind(from.and_hms_opt(0, 0, 0).expect("midnight exists"))
    .bind((to + chrono::Duration::days(1)).and_hms_opt(0, 0, 0).expect("midnight exists"))
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|r| Activity {
            activity_id: r.get("activity_id"),
            type_key: r.get("type_key"),
            name: r.get("name"),
            start_local: r.get("start_local"),
            duration_s: r.get("duration_s"),
        })
        .collect())
}

// --- Breath sessions -----------------------------------------------------

/// A breath session as the phone captured it.
#[derive(Debug, Clone, PartialEq)]
pub struct StoredBreathSession {
    pub id: Uuid,
    pub started_at: DateTime<Utc>,
    pub ended_at: DateTime<Utc>,
    pub round_s: i32,
    pub rounds: i32,
    /// (round counted from 1, hold in milliseconds), in round order.
    pub holds: Vec<(i32, i32)>,
}

/// Stores a session with its holds. Returns false, and changes nothing,
/// when a session with this id is already stored.
pub async fn insert_breath_session(
    pool: &PgPool,
    session: &StoredBreathSession,
    device_session_id: i64,
) -> sqlx::Result<bool> {
    let mut tx = pool.begin().await?;
    let inserted = sqlx::query(
        "insert into breath_sessions (id, started_at, ended_at, round_s, rounds, device_session_id)
         values ($1, $2, $3, $4, $5, $6)
         on conflict (id) do nothing",
    )
    .bind(session.id)
    .bind(session.started_at)
    .bind(session.ended_at)
    .bind(session.round_s)
    .bind(session.rounds)
    .bind(device_session_id)
    .execute(&mut *tx)
    .await?
    .rows_affected()
        == 1;
    if inserted {
        let (rounds, holds): (Vec<i32>, Vec<i32>) = session.holds.iter().copied().unzip();
        sqlx::query(
            "insert into breath_holds (session_id, round, hold_ms)
             select $1, * from unnest($2::integer[], $3::integer[])",
        )
        .bind(session.id)
        .bind(&rounds)
        .bind(&holds)
        .execute(&mut *tx)
        .await?;
    }
    tx.commit().await?;
    Ok(inserted)
}

/// Every breath session, oldest first, with its start read in the owner's
/// time zone.
pub async fn breath_sessions(pool: &PgPool, timezone: chrono_tz::Tz) -> sqlx::Result<Vec<breath::Session>> {
    let rows = sqlx::query(
        "select s.id, s.started_at, s.round_s, s.rounds,
                coalesce(array_agg(h.round order by h.round) filter (where h.round is not null), '{}') as hold_rounds,
                coalesce(array_agg(h.hold_ms order by h.round) filter (where h.round is not null), '{}') as hold_ms
         from breath_sessions s
         left join breath_holds h on h.session_id = s.id
         group by s.id
         order by s.started_at, s.id",
    )
    .fetch_all(pool)
    .await?;
    Ok(rows
        .into_iter()
        .map(|r| {
            let started_at: DateTime<Utc> = r.get("started_at");
            let rounds: Vec<i32> = r.get("hold_rounds");
            let holds: Vec<i32> = r.get("hold_ms");
            breath::Session {
                id: r.get("id"),
                started_local: started_at.with_timezone(&timezone).naive_local(),
                round_s: r.get::<i32, _>("round_s") as u32,
                rounds: r.get::<i32, _>("rounds") as u32,
                holds: rounds
                    .into_iter()
                    .zip(holds)
                    .map(|(round, hold_ms)| breath::Hold { round: round as u32, hold_ms: hold_ms as u32 })
                    .collect(),
            }
        })
        .collect())
}

// --- Weigh-ins -----------------------------------------------------------

/// A weight as the phone captured it.
#[derive(Debug, Clone, PartialEq)]
pub struct StoredWeighIn {
    pub id: Uuid,
    pub measured_at: DateTime<Utc>,
    pub grams: i32,
    /// The unit it was typed in.
    pub unit: Unit,
}

/// Stores a weigh-in. Returns false, and changes nothing, when one with
/// this id is already stored.
pub async fn insert_weigh_in(pool: &PgPool, weigh_in: &StoredWeighIn, device_session_id: i64) -> sqlx::Result<bool> {
    let result = sqlx::query(
        "insert into weigh_ins (id, measured_at, grams, unit, device_session_id)
         values ($1, $2, $3, $4, $5)
         on conflict (id) do nothing",
    )
    .bind(weigh_in.id)
    .bind(weigh_in.measured_at)
    .bind(weigh_in.grams)
    .bind(weigh_in.unit.as_str())
    .bind(device_session_id)
    .execute(pool)
    .await?;
    Ok(result.rows_affected() == 1)
}

/// Every weigh-in, oldest first, with its time read in the owner's time
/// zone.
pub async fn weigh_ins(pool: &PgPool, timezone: chrono_tz::Tz) -> sqlx::Result<Vec<weight::WeighIn>> {
    let rows = sqlx::query("select id, measured_at, grams from weigh_ins order by measured_at, id")
        .fetch_all(pool)
        .await?;
    Ok(rows
        .into_iter()
        .map(|r| {
            let measured_at: DateTime<Utc> = r.get("measured_at");
            weight::WeighIn {
                id: r.get("id"),
                measured_local: measured_at.with_timezone(&timezone).naive_local(),
                grams: r.get::<i32, _>("grams") as u32,
            }
        })
        .collect())
}

// --- Source freshness ----------------------------------------------------

#[derive(Debug, Clone, Default, PartialEq)]
pub struct SourceSync {
    pub last_attempt_at: Option<DateTime<Utc>>,
    pub last_success_at: Option<DateTime<Utc>>,
    pub last_error: Option<String>,
}

pub async fn source_sync(pool: &PgPool, source: &str) -> sqlx::Result<SourceSync> {
    let row = sqlx::query(
        "select last_attempt_at, last_success_at, last_error from source_sync where source = $1",
    )
    .bind(source)
    .fetch_optional(pool)
    .await?;
    Ok(row
        .map(|r| SourceSync {
            last_attempt_at: r.get("last_attempt_at"),
            last_success_at: r.get("last_success_at"),
            last_error: r.get("last_error"),
        })
        .unwrap_or_default())
}

pub async fn record_sync_success(pool: &PgPool, source: &str) -> sqlx::Result<()> {
    sqlx::query(
        "insert into source_sync (source, last_attempt_at, last_success_at, last_error)
         values ($1, now(), now(), null)
         on conflict (source) do update set
            last_attempt_at = now(), last_success_at = now(), last_error = null",
    )
    .bind(source)
    .execute(pool)
    .await?;
    Ok(())
}

pub async fn record_sync_failure(pool: &PgPool, source: &str, error: &str) -> sqlx::Result<()> {
    sqlx::query(
        "insert into source_sync (source, last_attempt_at, last_error)
         values ($1, now(), $2)
         on conflict (source) do update set last_attempt_at = now(), last_error = excluded.last_error",
    )
    .bind(source)
    .bind(error)
    .execute(pool)
    .await?;
    Ok(())
}
