//! Database access. Queries live here so the rest of the code never
//! builds SQL.

use chrono::{DateTime, NaiveDate, NaiveDateTime, Utc};
use sqlx::postgres::{PgPool, PgPoolOptions};
use sqlx::Row;

use crate::routines::gym::Activity;

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
