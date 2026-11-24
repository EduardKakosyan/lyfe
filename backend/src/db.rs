//! Database access. Queries live here so the rest of the code never
//! builds SQL.

use chrono::{DateTime, NaiveDate, NaiveDateTime, Utc};
use sqlx::postgres::{PgPool, PgPoolOptions};
use sqlx::Row;

use uuid::Uuid;

use crate::money::{self, fire, ledger, worth};
use crate::routines::breath;
use crate::routines::food::{self, Detail, Figures, Label, PhotoDetail, Quantity, Slot};
use crate::routines::illustration;
use crate::routines::photo::{self, Oil};
use crate::routines::product::{self, Origin, Product};
use crate::routines::gym::Activity;
use crate::routines::weight::{self, Unit};

pub static MIGRATOR: sqlx::migrate::Migrator = sqlx::migrate!("./migrations");

pub async fn connect(database_url: &str) -> anyhow::Result<PgPool> {
    let pool = PgPoolOptions::new()
        .max_connections(5)
        .connect(database_url)
        .await?;
    migrate(&pool).await?;
    Ok(pool)
}

/// A migration whose wording changed after databases had run it. It made
/// only the two tables the next migration drops, so a database that ran
/// the earlier wording ends up exactly where one that ran this wording
/// does.
const REWORDED_MIGRATION: i64 = 13;

/// Brings the database up to date. Every migration already run must be the
/// one in this build, as sqlx checks, except the reworded one: a database
/// that ran its earlier wording, on the Spark or restored from a backup,
/// is told it ran this one, so that it is not refused.
pub async fn migrate(pool: &PgPool) -> anyhow::Result<()> {
    let reworded = MIGRATOR.iter().find(|migration| migration.version == REWORDED_MIGRATION);
    let has_run_any: bool = sqlx::query_scalar("select to_regclass('_sqlx_migrations') is not null").fetch_one(pool).await?;
    if let (Some(reworded), true) = (reworded, has_run_any) {
        let accepted = sqlx::query("update _sqlx_migrations set checksum = $2 where version = $1 and success and checksum <> $2")
            .bind(REWORDED_MIGRATION)
            .bind(reworded.checksum.as_ref())
            .execute(pool)
            .await?
            .rows_affected();
        if accepted > 0 {
            tracing::info!(version = REWORDED_MIGRATION, "a migration reworded since this database ran it is taken as run");
        }
    }
    MIGRATOR.run(pool).await?;
    Ok(())
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

// --- Food ----------------------------------------------------------------

/// A slot read back from the database, where only the four names can be.
fn stored_slot(text: &str) -> Slot {
    Slot::parse(text).unwrap_or(Slot::Snack)
}

/// Stores a saved meal with its ingredients, replacing the recipe when the
/// meal is already stored. Saving a meal that was removed brings it back.
pub async fn upsert_saved_meal(pool: &PgPool, meal: &food::SavedMeal) -> sqlx::Result<()> {
    let mut tx = pool.begin().await?;
    sqlx::query(
        "insert into saved_meals (id, name, slot, portions) values ($1, $2, $3, $4)
         on conflict (id) do update set
            name = excluded.name, slot = excluded.slot, portions = excluded.portions,
            updated_at = now(), archived_at = null",
    )
    .bind(meal.id)
    .bind(&meal.name)
    .bind(meal.slot.as_str())
    .bind(meal.portions as i32)
    .execute(&mut *tx)
    .await?;
    sqlx::query("delete from saved_meal_ingredients where meal_id = $1")
        .bind(meal.id)
        .execute(&mut *tx)
        .await?;
    let positions: Vec<i32> = (1..=meal.ingredients.len() as i32).collect();
    let names: Vec<&str> = meal.ingredients.iter().map(|i| i.name.as_str()).collect();
    let weighed = |pick: fn(f64, f64, f64) -> f64| -> Vec<Option<f64>> {
        meal.ingredients
            .iter()
            .map(|i| match i.quantity {
                Quantity::Weighed { grams, kcal_per_100g, protein_per_100g } => {
                    Some(pick(grams, kcal_per_100g, protein_per_100g))
                }
                Quantity::Whole { .. } => None,
            })
            .collect()
    };
    let whole = |pick: fn(f64, f64) -> f64| -> Vec<Option<f64>> {
        meal.ingredients
            .iter()
            .map(|i| match i.quantity {
                Quantity::Whole { kcal, protein_g } => Some(pick(kcal, protein_g)),
                Quantity::Weighed { .. } => None,
            })
            .collect()
    };
    let estimated: Vec<bool> = meal.ingredients.iter().map(|i| i.estimated).collect();
    let codes: Vec<Option<&str>> = meal.ingredients.iter().map(|i| i.code.as_deref()).collect();
    sqlx::query(
        "insert into saved_meal_ingredients
            (meal_id, position, name, grams, kcal_per_100g, protein_per_100g, kcal, protein_g, estimated, barcode, carbs_g, fat_g)
         select $1, * from unnest($2::integer[], $3::text[], $4::double precision[], $5::double precision[],
                                  $6::double precision[], $7::double precision[], $8::double precision[],
                                  $9::boolean[], $10::text[], $11::double precision[], $12::double precision[])",
    )
    .bind(meal.id)
    .bind(&positions)
    .bind(&names)
    .bind(weighed(|grams, _, _| grams))
    .bind(weighed(|_, kcal, _| kcal))
    .bind(weighed(|_, _, protein| protein))
    .bind(whole(|kcal, _| kcal))
    .bind(whole(|_, protein| protein))
    .bind(&estimated)
    .bind(&codes)
    .bind(meal.ingredients.iter().map(|i| i.carbs_g).collect::<Vec<_>>())
    .bind(meal.ingredients.iter().map(|i| i.fat_g).collect::<Vec<_>>())
    .execute(&mut *tx)
    .await?;
    tx.commit().await
}

/// Takes a saved meal out of use. Entries logged from it stay. Returns
/// false when no meal in use has this id.
pub async fn archive_saved_meal(pool: &PgPool, id: Uuid) -> sqlx::Result<bool> {
    let result = sqlx::query("update saved_meals set archived_at = now() where id = $1 and archived_at is null")
        .bind(id)
        .execute(pool)
        .await?;
    Ok(result.rows_affected() == 1)
}

/// Saved meals with their ingredients in the order added: those in use,
/// or with `id` the one meal with that id whether in use or not.
async fn saved_meals_where(pool: &PgPool, id: Option<Uuid>) -> sqlx::Result<Vec<food::SavedMeal>> {
    let rows = sqlx::query(
        "select id, name, slot, portions from saved_meals
         where case when $1::uuid is null then archived_at is null else id = $1 end
         order by created_at, id",
    )
    .bind(id)
    .fetch_all(pool)
    .await?;
    let mut meals: Vec<food::SavedMeal> = rows
        .into_iter()
        .map(|r| food::SavedMeal {
            id: r.get("id"),
            name: r.get("name"),
            slot: stored_slot(r.get("slot")),
            portions: r.get::<i32, _>("portions") as u32,
            ingredients: Vec::new(),
        })
        .collect();
    let ids: Vec<Uuid> = meals.iter().map(|meal| meal.id).collect();
    let rows = sqlx::query(
        "select meal_id, name, grams, kcal_per_100g, protein_per_100g, kcal, protein_g, estimated, barcode, carbs_g, fat_g
         from saved_meal_ingredients where meal_id = any($1) order by meal_id, position",
    )
    .bind(&ids)
    .fetch_all(pool)
    .await?;
    for r in rows {
        let meal_id: Uuid = r.get("meal_id");
        let quantity = match r.get::<Option<f64>, _>("grams") {
            Some(grams) => Quantity::Weighed {
                grams,
                kcal_per_100g: r.get::<Option<f64>, _>("kcal_per_100g").unwrap_or_default(),
                protein_per_100g: r.get::<Option<f64>, _>("protein_per_100g").unwrap_or_default(),
            },
            None => Quantity::Whole {
                kcal: r.get::<Option<f64>, _>("kcal").unwrap_or_default(),
                protein_g: r.get::<Option<f64>, _>("protein_g").unwrap_or_default(),
            },
        };
        if let Some(meal) = meals.iter_mut().find(|meal| meal.id == meal_id) {
            meal.ingredients.push(food::Ingredient {
                carbs_g: r.get("carbs_g"), fat_g: r.get("fat_g"),
                name: r.get("name"),
                quantity,
                estimated: r.get("estimated"),
                code: r.get("barcode"),
            });
        }
    }
    Ok(meals)
}

/// The saved meals in use.
pub async fn saved_meals(pool: &PgPool) -> sqlx::Result<Vec<food::SavedMeal>> {
    saved_meals_where(pool, None).await
}

/// One saved meal, in use or not: a meal tapped on a phone that was
/// offline can arrive after the meal was removed.
pub async fn saved_meal(pool: &PgPool, id: Uuid) -> sqlx::Result<Option<food::SavedMeal>> {
    Ok(saved_meals_where(pool, Some(id)).await?.into_iter().next())
}

/// A logged meal as it is stored: the recipe's name and figures as they
/// stood when it arrived.
#[derive(Debug, Clone, PartialEq)]
pub struct StoredFoodEntry {
    pub carbs_g: Option<f64>,
    pub fat_g: Option<f64>,

    pub id: Uuid,
    pub eaten_at: DateTime<Utc>,
    pub slot: Slot,
    pub meal_id: Option<Uuid>,
    pub name: String,
    pub servings: f64,
    pub amount: food::Amount,
    /// The part of `amount` that came from estimated ingredients.
    pub estimated: food::Amount,
}

/// Stores a logged meal. Returns false, and changes nothing, when an entry
/// with this id is already stored, taken back or not.
pub async fn insert_food_entry(pool: &PgPool, entry: &StoredFoodEntry, device_session_id: i64) -> sqlx::Result<bool> {
    let result = sqlx::query(
        "insert into food_entries
            (id, eaten_at, slot, meal_id, name, servings, kcal, protein_dg, device_session_id, kcal_estimated,
             protein_dg_estimated, carbs_g, fat_g)
         values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
         on conflict (id) do nothing",
    )
    .bind(entry.id)
    .bind(entry.eaten_at)
    .bind(entry.slot.as_str())
    .bind(entry.meal_id)
    .bind(&entry.name)
    .bind(entry.servings)
    .bind(entry.amount.kcal as i32)
    .bind(entry.amount.protein_dg as i32)
    .bind(device_session_id)
    .bind(entry.estimated.kcal as i32)
    .bind(entry.estimated.protein_dg as i32)
    .bind(entry.carbs_g).bind(entry.fat_g)
    .execute(pool)
    .await?;
    Ok(result.rows_affected() == 1)
}

/// Takes a logged meal back, with its parts when it is a built one, or
/// takes one part out of a built meal; a meal left with no parts goes with
/// its last one. Returns false when no entry with this id was counted.
pub async fn remove_food_entry(pool: &PgPool, id: Uuid) -> sqlx::Result<bool> {
    let mut tx = pool.begin().await?;
    let removed: Vec<(Uuid, Option<Uuid>)> = sqlx::query_as(
        "update food_entries set removed_at = now()
         where (id = $1 or part_of = $1) and removed_at is null
         returning id, part_of",
    )
    .bind(id)
    .fetch_all(&mut *tx)
    .await?;
    let meal = removed.iter().find(|(removed, _)| *removed == id).and_then(|(_, part_of)| *part_of);
    if let Some(meal) = meal {
        sqlx::query(
            "update food_entries set removed_at = now()
             where id = $1 and source = 'built' and removed_at is null
               and not exists (select 1 from food_entries p where p.part_of = $1 and p.removed_at is null)",
        )
        .bind(meal)
        .execute(&mut *tx)
        .await?;
    }
    tx.commit().await?;
    Ok(!removed.is_empty())
}

/// The columns an entry is read from.
const ENTRY_COLUMNS: &str = "e.carbs_g, e.fat_g, e.id, e.eaten_at, e.slot, e.meal_id, e.name, e.servings, e.kcal, e.protein_dg, e.source,
    e.figures, e.note, e.oil_asked, e.oil, e.typed, e.estimate_problem, e.barcode, e.grams, e.part_of, e.position,
    e.kcal_per_100g, e.protein_per_100g, e.kcal_estimated, e.protein_dg_estimated,
    exists (select 1 from food_photos p where p.entry_id = e.id) as has_photo,
    (select (extract(epoch from p.illustrated_at) * 1000)::bigint from food_photos p
      where p.entry_id = e.id and p.illustration is not null) as illustration_version";

fn read_entry(
    r: &sqlx::postgres::PgRow,
    timezone: chrono_tz::Tz,
    items: &mut std::collections::HashMap<Uuid, Vec<photo::Item>>,
) -> food::Entry {
    let id: Uuid = r.get("id");
    let eaten_at: DateTime<Utc> = r.get("eaten_at");
    let grams: Option<f64> = r.get("grams");
    let label = match (r.get::<Option<f64>, _>("kcal_per_100g"), r.get::<Option<f64>, _>("protein_per_100g")) {
        (Some(kcal_per_100g), Some(protein_per_100g)) => Some(Label { kcal_per_100g, protein_per_100g }),
        _ => None,
    };
    let detail = match r.get::<&str, _>("source") {
        "photo" => Detail::Photo(PhotoDetail {
            note: r.get::<Option<String>, _>("note").unwrap_or_default(),
            has_photo: r.get("has_photo"),
            illustration_version: r.get("illustration_version"),
            items: items.remove(&id).unwrap_or_default(),
            oil_asked: r.get("oil_asked"),
            oil: r.get::<Option<&str>, _>("oil").and_then(Oil::parse),
            typed: r.get("typed"),
            problem: r.get("estimate_problem"),
        }),
        "barcode" => Detail::Barcode {
            code: r.get::<Option<String>, _>("barcode").unwrap_or_default(),
            grams: grams.unwrap_or_default(),
            label,
        },
        "typed" => Detail::Typed { grams, label },
        "built" => Detail::Built,
        _ => Detail::Saved,
    };
    food::Entry {
        carbs_g: r.get("carbs_g"), fat_g: r.get("fat_g"),
        id,
        eaten_local: eaten_at.with_timezone(&timezone).naive_local(),
        slot: stored_slot(r.get("slot")),
        meal_id: r.get("meal_id"),
        name: r.get("name"),
        servings: r.get("servings"),
        amount: food::Amount { kcal: r.get::<i32, _>("kcal") as u32, protein_dg: r.get::<i32, _>("protein_dg") as u32 },
        estimated: food::Amount {
            kcal: r.get::<i32, _>("kcal_estimated") as u32,
            protein_dg: r.get::<i32, _>("protein_dg_estimated") as u32,
        },
        figures: Figures::parse(r.get("figures")).unwrap_or(Figures::Known),
        detail,
        part_of: r.get("part_of"),
        position: r.get("position"),
    }
}

/// Every logged meal not taken back, oldest first, with its time read in
/// the owner's time zone; the parts of built meals are entries among them.
/// A part whose meal has not arrived, or was taken back, is left out. What
/// a photo's model saw is read only for meals eaten from `items_since` on,
/// the days the apps show.
pub async fn food_entries(
    pool: &PgPool,
    timezone: chrono_tz::Tz,
    items_since: DateTime<Utc>,
) -> sqlx::Result<Vec<food::Entry>> {
    let rows = sqlx::query(&format!(
        "select {ENTRY_COLUMNS}
         from food_entries e
         where e.removed_at is null
           and (e.part_of is null
                or exists (select 1 from food_entries m where m.id = e.part_of and m.removed_at is null))
         order by e.eaten_at, e.id"
    ))
    .fetch_all(pool)
    .await?;
    let mut items = estimate_items_since(pool, items_since).await?;
    Ok(rows.iter().map(|r| read_entry(r, timezone, &mut items)).collect())
}

/// Photos sent to be estimated for a meal still being put together on the
/// phone: parts whose meal has not arrived. Oldest first.
pub async fn draft_parts(pool: &PgPool, timezone: chrono_tz::Tz) -> sqlx::Result<Vec<food::Entry>> {
    let rows = sqlx::query(&format!(
        "select {ENTRY_COLUMNS}
         from food_entries e
         where e.removed_at is null and e.part_of is not null
           and not exists (select 1 from food_entries m where m.id = e.part_of)
         order by e.received_at, e.id"
    ))
    .fetch_all(pool)
    .await?;
    let ids: Vec<Uuid> = rows.iter().map(|r| r.get("id")).collect();
    let mut items = estimate_items_of(pool, &ids).await?;
    Ok(rows.iter().map(|r| read_entry(r, timezone, &mut items)).collect())
}

/// Drafts nothing came of: photos sent for a meal that was never logged,
/// a week on. They are marked as taken back, like any entry.
pub async fn drop_stale_drafts(pool: &PgPool) -> sqlx::Result<u64> {
    let result = sqlx::query(
        "update food_entries e set removed_at = now()
         where e.removed_at is null and e.part_of is not null
           and e.received_at < now() - interval '7 days'
           and not exists (select 1 from food_entries m where m.id = e.part_of)",
    )
    .execute(pool)
    .await?;
    Ok(result.rows_affected())
}

/// The built meal an arriving part says it belongs to.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum MealOfPart {
    /// No entry has this id: the meal has not arrived yet.
    NotArrived,
    /// The meal is logged; its part joins it at its time and slot.
    Logged { eaten_at: DateTime<Utc>, slot: Slot, next_position: i32 },
    /// The entry with this id is not a built meal, or was taken back.
    Unusable,
}

pub async fn meal_of_part(pool: &PgPool, part_of: Uuid) -> sqlx::Result<MealOfPart> {
    let row = sqlx::query(
        "select m.eaten_at, m.slot, m.source, m.removed_at is not null as removed,
                (select coalesce(max(p.position), 0) + 1 from food_entries p where p.part_of = m.id) as next_position
         from food_entries m where m.id = $1",
    )
    .bind(part_of)
    .fetch_optional(pool)
    .await?;
    Ok(match row {
        None => MealOfPart::NotArrived,
        Some(r) if r.get::<&str, _>("source") != "built" || r.get::<bool, _>("removed") => MealOfPart::Unusable,
        Some(r) => MealOfPart::Logged {
            eaten_at: r.get("eaten_at"),
            slot: stored_slot(r.get("slot")),
            next_position: r.get("next_position"),
        },
    })
}

/// What the model saw in each photo meal eaten from `since` on, by entry.
async fn estimate_items_since(
    pool: &PgPool,
    since: DateTime<Utc>,
) -> sqlx::Result<std::collections::HashMap<Uuid, Vec<photo::Item>>> {
    let rows = sqlx::query(
        "select i.entry_id, i.name, i.grams_seen, i.kcal_seen, i.protein_g_seen, i.grams
         from food_estimate_items i join food_entries e on e.id = i.entry_id
         where e.eaten_at >= $1
         order by i.entry_id, i.position",
    )
    .bind(since)
    .fetch_all(pool)
    .await?;
    Ok(items_by_entry(rows))
}

/// What the model saw in each of these photo meals, by entry.
async fn estimate_items_of(
    pool: &PgPool,
    ids: &[Uuid],
) -> sqlx::Result<std::collections::HashMap<Uuid, Vec<photo::Item>>> {
    let rows = sqlx::query(
        "select entry_id, name, grams_seen, kcal_seen, protein_g_seen, grams
         from food_estimate_items where entry_id = any($1)
         order by entry_id, position",
    )
    .bind(ids)
    .fetch_all(pool)
    .await?;
    Ok(items_by_entry(rows))
}

fn items_by_entry(rows: Vec<sqlx::postgres::PgRow>) -> std::collections::HashMap<Uuid, Vec<photo::Item>> {
    let mut items: std::collections::HashMap<Uuid, Vec<photo::Item>> = std::collections::HashMap::new();
    for r in rows {
        items.entry(r.get("entry_id")).or_default().push(read_item(&r));
    }
    items
}

fn read_item(r: &sqlx::postgres::PgRow) -> photo::Item {
    photo::Item {
        name: r.get("name"),
        grams_seen: r.get("grams_seen"),
        kcal_seen: r.get("kcal_seen"),
        protein_g_seen: r.get("protein_g_seen"),
        grams: r.get("grams"),
    }
}

// --- Photo meals ---------------------------------------------------------

/// A photo meal as it arrives from the phone, before the model has seen it.
#[derive(Debug, Clone, PartialEq)]
pub struct NewPhotoEntry {
    pub id: Uuid,
    pub eaten_at: DateTime<Utc>,
    pub slot: Slot,
    pub note: String,
    pub jpeg: Option<Vec<u8>>,
    /// The built meal it is a part of, and where it stands in it.
    pub part_of: Option<Uuid>,
    pub position: i32,
}

/// Stores a photo meal, to be estimated. Returns false, and changes
/// nothing, when an entry with this id is already stored.
pub async fn insert_photo_entry(pool: &PgPool, entry: &NewPhotoEntry, device_session_id: i64) -> sqlx::Result<bool> {
    let mut tx = pool.begin().await?;
    let result = sqlx::query(
        "insert into food_entries
            (id, eaten_at, slot, name, servings, kcal, protein_dg, device_session_id, source, figures, note,
             estimate_due_at, part_of, position)
         values ($1, $2, $3, $4, 1, 0, 0, $5, 'photo', 'estimating', $6, now(), $7, $8)
         on conflict (id) do nothing",
    )
    .bind(entry.id)
    .bind(entry.eaten_at)
    .bind(entry.slot.as_str())
    .bind(photo::name_for(&entry.note))
    .bind(device_session_id)
    .bind(&entry.note)
    .bind(entry.part_of)
    .bind(entry.position)
    .execute(&mut *tx)
    .await?;
    if result.rows_affected() == 0 {
        return Ok(false);
    }
    if let Some(jpeg) = &entry.jpeg {
        sqlx::query("insert into food_photos (entry_id, jpeg) values ($1, $2)")
            .bind(entry.id)
            .bind(jpeg)
            .execute(&mut *tx)
            .await?;
    }
    tx.commit().await?;
    Ok(true)
}

/// A photo meal waiting for the model.
#[derive(Debug, Clone, PartialEq)]
pub struct PendingPhoto {
    pub id: Uuid,
    pub note: String,
    pub jpeg: Option<Vec<u8>>,
    /// Answers the model gave that could not be used.
    pub tries: i32,
}

/// The photo meal waiting longest whose next try is due, if any.
pub async fn next_pending_photo(pool: &PgPool) -> sqlx::Result<Option<PendingPhoto>> {
    let row = sqlx::query(
        "select e.id, e.note, e.estimate_tries, p.jpeg
         from food_entries e left join food_photos p on p.entry_id = e.id
         where e.figures = 'estimating' and e.removed_at is null
           and coalesce(e.estimate_due_at, '-infinity') <= now()
         order by e.received_at, e.id
         limit 1",
    )
    .fetch_optional(pool)
    .await?;
    Ok(row.map(|r| PendingPhoto {
        id: r.get("id"),
        note: r.get::<Option<String>, _>("note").unwrap_or_default(),
        jpeg: r.get("jpeg"),
        tries: r.get("estimate_tries"),
    }))
}

/// Stores what the model saw and what it comes to. An entry the owner has
/// typed figures for or taken back since is left alone.
pub async fn record_estimate(pool: &PgPool, id: Uuid, estimate: &photo::ModelEstimate) -> sqlx::Result<bool> {
    let mut tx = pool.begin().await?;
    let amount = photo::amount(&estimate.items, estimate.oil_asked, None);
    let result = sqlx::query(
        "update food_entries set
            figures = 'known', kcal = $2, protein_dg = $3, oil_asked = $4, estimated_at = now(),
            estimate_problem = null, estimate_due_at = null
         where id = $1 and figures = 'estimating'",
    )
    .bind(id)
    .bind(amount.kcal as i32)
    .bind(amount.protein_dg as i32)
    .bind(estimate.oil_asked)
    .execute(&mut *tx)
    .await?;
    if result.rows_affected() == 0 {
        return Ok(false);
    }
    write_items(&mut tx, id, &estimate.items).await?;
    tx.commit().await?;
    Ok(true)
}

async fn write_items(tx: &mut sqlx::PgConnection, id: Uuid, items: &[photo::Item]) -> sqlx::Result<()> {
    sqlx::query("delete from food_estimate_items where entry_id = $1").bind(id).execute(&mut *tx).await?;
    let positions: Vec<i32> = (1..=items.len() as i32).collect();
    let names: Vec<&str> = items.iter().map(|i| i.name.as_str()).collect();
    let grams_seen: Vec<f64> = items.iter().map(|i| i.grams_seen).collect();
    let kcal_seen: Vec<f64> = items.iter().map(|i| i.kcal_seen).collect();
    let protein_seen: Vec<f64> = items.iter().map(|i| i.protein_g_seen).collect();
    let grams: Vec<f64> = items.iter().map(|i| i.grams).collect();
    sqlx::query(
        "insert into food_estimate_items (entry_id, position, name, grams_seen, kcal_seen, protein_g_seen, grams)
         select $1, * from unnest($2::integer[], $3::text[], $4::double precision[], $5::double precision[],
                                  $6::double precision[], $7::double precision[])",
    )
    .bind(id)
    .bind(&positions)
    .bind(&names)
    .bind(&grams_seen)
    .bind(&kcal_seen)
    .bind(&protein_seen)
    .bind(&grams)
    .execute(&mut *tx)
    .await?;
    Ok(())
}

/// Why the model gave no estimate this time, and when to try again. With
/// `counts`, the answer could not be used and the try is counted; after
/// `photo::MAX_TRIES` of those the meal is left for the owner to type.
pub async fn record_estimate_problem(
    pool: &PgPool,
    id: Uuid,
    problem: &str,
    counts: bool,
    retry_in: chrono::Duration,
) -> sqlx::Result<()> {
    sqlx::query(
        "update food_entries set
            estimate_problem = $2,
            estimate_tries = estimate_tries + $3::integer,
            estimate_due_at = now() + make_interval(secs => $4),
            figures = case when estimate_tries + $3::integer >= $5 then 'failed' else figures end
         where id = $1 and figures = 'estimating'",
    )
    .bind(id)
    .bind(problem)
    .bind(i32::from(counts))
    .bind(retry_in.num_seconds() as f64)
    .bind(photo::MAX_TRIES)
    .execute(pool)
    .await?;
    Ok(())
}

/// Stops asking the model about a meal and leaves it for the owner to type.
pub async fn give_up_estimate(pool: &PgPool, id: Uuid, problem: &str) -> sqlx::Result<()> {
    sqlx::query(
        "update food_entries set figures = 'failed', estimate_problem = $2, estimate_due_at = null
         where id = $1 and figures = 'estimating'",
    )
    .bind(id)
    .bind(problem)
    .execute(pool)
    .await?;
    Ok(())
}

/// A photo meal as the owner corrects it.
#[derive(Debug, Clone, PartialEq)]
pub struct PhotoMeal {
    pub figures: Figures,
    pub items: Vec<photo::Item>,
    pub oil_asked: bool,
    pub oil: Option<Oil>,
    pub typed: bool,
}

/// A photo meal not taken back, or `None`.
pub async fn photo_meal(pool: &PgPool, id: Uuid) -> sqlx::Result<Option<PhotoMeal>> {
    let Some(row) = sqlx::query(
        "select figures, oil_asked, oil, typed from food_entries
         where id = $1 and source = 'photo' and removed_at is null",
    )
    .bind(id)
    .fetch_optional(pool)
    .await?
    else {
        return Ok(None);
    };
    let items = sqlx::query(
        "select name, grams_seen, kcal_seen, protein_g_seen, grams from food_estimate_items
         where entry_id = $1 order by position",
    )
    .bind(id)
    .fetch_all(pool)
    .await?
    .iter()
    .map(read_item)
    .collect();
    Ok(Some(PhotoMeal {
        figures: Figures::parse(row.get("figures")).unwrap_or(Figures::Known),
        items,
        oil_asked: row.get("oil_asked"),
        oil: row.get::<Option<&str>, _>("oil").and_then(Oil::parse),
        typed: row.get("typed"),
    }))
}

/// Stores a photo meal as the owner corrected it: the grams of what the
/// model saw and the oil answer, or figures typed instead.
pub async fn correct_photo_meal(pool: &PgPool, id: Uuid, meal: &PhotoMeal, amount: food::Amount) -> sqlx::Result<()> {
    let mut tx = pool.begin().await?;
    sqlx::query(
        "update food_entries set
            figures = $2, kcal = $3, protein_dg = $4, oil = $5, typed = $6,
            estimate_problem = case when $2 = 'known' then null else estimate_problem end
         where id = $1",
    )
    .bind(id)
    .bind(meal.figures.as_str())
    .bind(amount.kcal as i32)
    .bind(amount.protein_dg as i32)
    .bind(meal.oil.map(Oil::as_str))
    .bind(meal.typed)
    .execute(&mut *tx)
    .await?;
    if !meal.items.is_empty() {
        write_items(&mut tx, id, &meal.items).await?;
    }
    tx.commit().await
}

/// The photo of a meal not taken back, as the phone sent it.
pub async fn food_photo(pool: &PgPool, id: Uuid) -> sqlx::Result<Option<Vec<u8>>> {
    sqlx::query_scalar(
        "select p.jpeg from food_photos p join food_entries e on e.id = p.entry_id
         where p.entry_id = $1 and e.removed_at is null",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
}

// --- Illustrations --------------------------------------------------------

/// A meal photo waiting to be drawn.
#[derive(Debug, Clone)]
pub struct PendingIllustration {
    pub id: Uuid,
    pub note: String,
    pub jpeg: Vec<u8>,
    pub tries: i32,
}

/// The photo waiting longest whose turn has come. Only photos on a day are
/// drawn: not taken back, and, as a part, in a meal that has arrived. A
/// photo still being estimated waits for its figures, which matter more,
/// so the two models are not loaded on the shared machine at once for it.
pub async fn next_pending_illustration(pool: &PgPool) -> sqlx::Result<Option<PendingIllustration>> {
    let row = sqlx::query(
        "select e.id, e.note, p.jpeg, p.illustration_tries
         from food_photos p join food_entries e on e.id = p.entry_id
         where p.illustration_due_at <= now() and e.removed_at is null and e.figures <> 'estimating'
           and (e.part_of is null
                or exists (select 1 from food_entries m where m.id = e.part_of and m.removed_at is null))
         order by p.illustration_due_at, e.id
         limit 1",
    )
    .fetch_optional(pool)
    .await?;
    Ok(row.map(|r| PendingIllustration {
        id: r.get("id"),
        note: r.get::<Option<String>, _>("note").unwrap_or_default(),
        jpeg: r.get("jpeg"),
        tries: r.get("illustration_tries"),
    }))
}

/// Attaches a meal's illustration, drawn in the look of now, in place of
/// one drawn in an older look if it had one. Returns false when the photo
/// was not waiting to be drawn.
pub async fn record_illustration(pool: &PgPool, id: Uuid, png: &[u8]) -> sqlx::Result<bool> {
    let result = sqlx::query(
        "update food_photos set
            illustration = $2, illustration_look = $3, illustrated_at = now(), illustration_due_at = null,
            illustration_problem = null
         where entry_id = $1 and illustration_due_at is not null",
    )
    .bind(id)
    .bind(png)
    .bind(illustration::LOOK)
    .execute(pool)
    .await?;
    Ok(result.rows_affected() == 1)
}

/// A picture the model could not draw. It is tried again after `retry_in`,
/// and after `illustration::MAX_TRIES` failures not at all. Returns true
/// when it has been given up on. One that was being drawn again keeps the
/// drawing it had.
pub async fn record_illustration_problem(
    pool: &PgPool,
    id: Uuid,
    problem: &str,
    retry_in: chrono::Duration,
) -> sqlx::Result<bool> {
    let gave_up: Option<bool> = sqlx::query_scalar(
        "update food_photos set
            illustration_problem = $2,
            illustration_tries = illustration_tries + 1,
            illustration_due_at = case when illustration_tries + 1 >= $4 then null
                                       else now() + make_interval(secs => $3) end
         where entry_id = $1 and illustration_due_at is not null
         returning illustration_due_at is null",
    )
    .bind(id)
    .bind(problem)
    .bind(retry_in.num_seconds() as f64)
    .bind(illustration::MAX_TRIES)
    .fetch_optional(pool)
    .await?;
    Ok(gave_up.unwrap_or(false))
}

/// Puts off every photo whose turn has come, when the Spark cannot draw
/// any of them now: too little memory, or the model would not load. No
/// picture is blamed for it.
pub async fn put_off_illustrations(pool: &PgPool, problem: &str, retry_in: chrono::Duration) -> sqlx::Result<u64> {
    let result = sqlx::query(
        "update food_photos set illustration_problem = $1, illustration_due_at = now() + make_interval(secs => $2)
         where illustration_due_at <= now()",
    )
    .bind(problem)
    .bind(retry_in.num_seconds() as f64)
    .execute(pool)
    .await?;
    Ok(result.rows_affected())
}

/// Marks every photo drawn in a look older than the one of now to be
/// drawn again, oldest first. Each keeps the drawing it has until the new
/// one replaces it. Returns how many were marked.
pub async fn redraw_older_looks(pool: &PgPool) -> sqlx::Result<u64> {
    let result = sqlx::query(
        "update food_photos set illustration_due_at = received_at, illustration_tries = 0, illustration_problem = null
         where illustration is not null and illustration_due_at is null and coalesce(illustration_look, 0) < $1",
    )
    .bind(illustration::LOOK)
    .execute(pool)
    .await?;
    Ok(result.rows_affected())
}

/// The illustration of a meal not taken back, once drawn.
pub async fn food_illustration(pool: &PgPool, id: Uuid) -> sqlx::Result<Option<Vec<u8>>> {
    sqlx::query_scalar(
        "select p.illustration from food_photos p join food_entries e on e.id = p.entry_id
         where p.entry_id = $1 and e.removed_at is null and p.illustration is not null",
    )
    .bind(id)
    .fetch_optional(pool)
    .await
}

// --- Food icons ----------------------------------------------------------

/// A food's icon waiting to be drawn.
#[derive(Debug, Clone)]
pub struct PendingIcon {
    pub id: Uuid,
    /// The food's name, as the phone gave it.
    pub name: String,
    pub tries: i32,
}

/// Where a food's icon stands when the phone asks for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IconAsked {
    /// Drawn, in the look of now.
    Drawn(Vec<u8>),
    /// Waiting to be drawn, since this asking or an earlier one.
    Waiting,
    /// The model could not draw it; it is not tried again in this look.
    GivenUp,
}

/// The phone asks for a food's icon, which is what gets it drawn: one
/// never asked for joins the queue, and so does one drawn, or given up on,
/// in an older look. Asking again moves it to the front. `key` is
/// `illustration::icon_key` of `name`.
pub async fn ask_food_icon(pool: &PgPool, key: &str, name: &str) -> sqlx::Result<IconAsked> {
    let row = sqlx::query(
        "insert into food_icons (key, name) values ($1, $2)
         on conflict (key) do update set
            asked_at = now(),
            tries = case when food_icons.due_at is null and coalesce(food_icons.look, 0) < $3 then 0
                         else food_icons.tries end,
            due_at = case when food_icons.due_at is null and coalesce(food_icons.look, 0) < $3 then now()
                          else food_icons.due_at end
         returning case when look = $3 then png end as png, due_at is not null as waiting",
    )
    .bind(key)
    .bind(name.trim())
    .bind(illustration::ICON_LOOK)
    .fetch_one(pool)
    .await?;
    Ok(match (row.get::<Option<Vec<u8>>, _>("png"), row.get::<bool, _>("waiting")) {
        (Some(png), false) => IconAsked::Drawn(png),
        (_, true) => IconAsked::Waiting,
        (None, false) => IconAsked::GivenUp,
    })
}

/// How many icons there are of each kind: drawn, waiting, given up on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct IconCounts {
    pub drawn: i64,
    pub waiting: i64,
    pub given_up: i64,
}

/// Puts a food's icon in the queue ahead of anyone asking for it, so that
/// it is already drawn when the phone first shows the food. `place` is
/// where it stands in the list being queued: icons queued this way are
/// drawn in that order, and after any the phone is asking for now. One
/// already drawn in the look of now, waiting, or given up on is left as it
/// is. Returns whether it was queued.
pub async fn queue_food_icon(pool: &PgPool, key: &str, name: &str, place: i64) -> sqlx::Result<bool> {
    let queued: Option<bool> = sqlx::query_scalar(
        "insert into food_icons (key, name, asked_at) values ($1, $2, to_timestamp(-$4::float8))
         on conflict (key) do update set tries = 0, due_at = now(), asked_at = excluded.asked_at
            where food_icons.due_at is null and coalesce(food_icons.look, 0) < $3
         returning true",
    )
    .bind(key)
    .bind(name.trim())
    .bind(illustration::ICON_LOOK)
    .bind(place)
    .fetch_optional(pool)
    .await?;
    Ok(queued.is_some())
}

pub async fn food_icon_counts(pool: &PgPool) -> sqlx::Result<IconCounts> {
    let row = sqlx::query(
        "select count(*) filter (where png is not null and look = $1) as drawn,
                count(*) filter (where due_at is not null) as waiting,
                count(*) filter (where due_at is null and (png is null or look <> $1)) as given_up
         from food_icons",
    )
    .bind(illustration::ICON_LOOK)
    .fetch_one(pool)
    .await?;
    Ok(IconCounts { drawn: row.get("drawn"), waiting: row.get("waiting"), given_up: row.get("given_up") })
}

/// The icon whose turn has come that was asked for latest: the one the
/// owner is looking at now, ahead of ones scrolled past earlier, and
/// those ahead of ones queued before anyone asked.
pub async fn next_pending_food_icon(pool: &PgPool) -> sqlx::Result<Option<PendingIcon>> {
    let row = sqlx::query(
        "select id, name, tries from food_icons where due_at <= now() order by asked_at desc, key limit 1",
    )
    .fetch_optional(pool)
    .await?;
    Ok(row.map(|r| PendingIcon { id: r.get("id"), name: r.get("name"), tries: r.get("tries") }))
}

/// Keeps a food's icon, drawn in the look of now, in place of one drawn in
/// an older look if it had one. Returns false when it was not waiting.
pub async fn record_food_icon(pool: &PgPool, id: Uuid, png: &[u8]) -> sqlx::Result<bool> {
    let result = sqlx::query(
        "update food_icons set png = $2, look = $3, drawn_at = now(), due_at = null, problem = null, tries = 0
         where id = $1 and due_at is not null",
    )
    .bind(id)
    .bind(png)
    .bind(illustration::ICON_LOOK)
    .execute(pool)
    .await?;
    Ok(result.rows_affected() == 1)
}

/// An icon the model could not draw. It is tried again after `retry_in`,
/// and after `illustration::MAX_TRIES` failures not until the look moves
/// on. Returns true when it has been given up on. One that was being drawn
/// again keeps the drawing it had.
pub async fn record_food_icon_problem(
    pool: &PgPool,
    id: Uuid,
    problem: &str,
    retry_in: chrono::Duration,
) -> sqlx::Result<bool> {
    let gave_up: Option<bool> = sqlx::query_scalar(
        "update food_icons set
            problem = $2,
            tries = tries + 1,
            look = case when tries + 1 >= $4 then $5 else look end,
            due_at = case when tries + 1 >= $4 then null else now() + make_interval(secs => $3) end
         where id = $1 and due_at is not null
         returning due_at is null",
    )
    .bind(id)
    .bind(problem)
    .bind(retry_in.num_seconds() as f64)
    .bind(illustration::MAX_TRIES)
    .bind(illustration::ICON_LOOK)
    .fetch_optional(pool)
    .await?;
    Ok(gave_up.unwrap_or(false))
}

/// Puts off every icon whose turn has come, when the Spark cannot draw any
/// of them now. No icon is blamed for it.
pub async fn put_off_food_icons(pool: &PgPool, problem: &str, retry_in: chrono::Duration) -> sqlx::Result<u64> {
    let result = sqlx::query(
        "update food_icons set problem = $1, due_at = now() + make_interval(secs => $2) where due_at <= now()",
    )
    .bind(problem)
    .bind(retry_in.num_seconds() as f64)
    .execute(pool)
    .await?;
    Ok(result.rows_affected())
}

// --- Packaged food -------------------------------------------------------

fn read_product(r: &sqlx::postgres::PgRow, origin: Origin) -> Product {
    Product {
        code: r.get("code"),
        name: r.get("name"),
        kcal_per_100g: r.get("kcal_per_100g"),
        protein_per_100g: r.get("protein_per_100g"),
        serving_g: r.get("serving_g"),
        origin,
    }
}

/// The product with this code: the label the owner typed if there is one,
/// else the food database's. Either form of a UPC or EAN is found.
pub async fn product(pool: &PgPool, code: &str) -> sqlx::Result<Option<Product>> {
    let codes = product::lookup_codes(code);
    for (table, origin) in [("owner_products", Origin::Label), ("barcode_products", Origin::Database)] {
        let row = sqlx::query(&format!(
            "select code, name, kcal_per_100g, protein_per_100g, serving_g from {table}
             where code = any($1) order by code = $2 desc limit 1"
        ))
        .bind(&codes)
        .bind(code)
        .fetch_optional(pool)
        .await?;
        if let Some(row) = row {
            return Ok(Some(read_product(&row, origin)));
        }
    }
    Ok(None)
}

/// A barcode meal as it arrives from the phone, with the product's figures
/// when they are known.
#[derive(Debug, Clone, PartialEq)]
pub struct NewBarcodeEntry {
    pub id: Uuid,
    pub eaten_at: DateTime<Utc>,
    pub slot: Slot,
    pub code: String,
    pub grams: f64,
    pub product: Option<Product>,
    /// The built meal it is a part of, and where it stands in it.
    pub part_of: Option<Uuid>,
    pub position: i32,
}

/// Stores a barcode meal: with the label's figures when the product is
/// known, else waiting for the owner to type the label. Returns false, and
/// changes nothing, when an entry with this id is already stored.
pub async fn insert_barcode_entry(pool: &PgPool, entry: &NewBarcodeEntry, device_session_id: i64) -> sqlx::Result<bool> {
    let mut conn = pool.acquire().await?;
    write_barcode_entry(&mut conn, entry, device_session_id).await
}

async fn write_barcode_entry(
    conn: &mut sqlx::PgConnection,
    entry: &NewBarcodeEntry,
    device_session_id: i64,
) -> sqlx::Result<bool> {
    let (name, amount, figures) = match &entry.product {
        Some(product) => (product.name.clone(), product.amount(entry.grams), Figures::Known),
        None => (format!("Barcode {}", entry.code), food::Amount::default(), Figures::NeedsLabel),
    };
    let result = sqlx::query(
        "insert into food_entries
            (id, eaten_at, slot, name, servings, kcal, protein_dg, device_session_id, source, figures, barcode, grams,
             part_of, position, kcal_per_100g, protein_per_100g)
         values ($1, $2, $3, $4, 1, $5, $6, $7, 'barcode', $8, $9, $10, $11, $12, $13, $14)
         on conflict (id) do nothing",
    )
    .bind(entry.id)
    .bind(entry.eaten_at)
    .bind(entry.slot.as_str())
    .bind(name)
    .bind(amount.kcal as i32)
    .bind(amount.protein_dg as i32)
    .bind(device_session_id)
    .bind(figures.as_str())
    .bind(&entry.code)
    .bind(entry.grams)
    .bind(entry.part_of)
    .bind(entry.position)
    .bind(entry.product.as_ref().map(|product| product.kcal_per_100g))
    .bind(entry.product.as_ref().map(|product| product.protein_per_100g))
    .execute(&mut *conn)
    .await?;
    Ok(result.rows_affected() == 1)
}

// --- Typed food and built meals ------------------------------------------

/// A food the owner typed, as it arrives from the phone: weighed with its
/// label's figures, or just what it came to.
#[derive(Debug, Clone, PartialEq)]
pub struct NewTypedEntry {
    pub id: Uuid,
    pub eaten_at: DateTime<Utc>,
    pub slot: Slot,
    /// Checked: its name and figures are what is stored.
    pub food: food::Ingredient,
    /// The built meal it is a part of, and where it stands in it.
    pub part_of: Option<Uuid>,
    pub position: i32,
}

/// Stores a typed food. Returns false, and changes nothing, when an entry
/// with this id is already stored.
pub async fn insert_typed_entry(pool: &PgPool, entry: &NewTypedEntry, device_session_id: i64) -> sqlx::Result<bool> {
    let mut conn = pool.acquire().await?;
    write_typed_entry(&mut conn, entry, device_session_id).await
}

async fn write_typed_entry(
    conn: &mut sqlx::PgConnection,
    entry: &NewTypedEntry,
    device_session_id: i64,
) -> sqlx::Result<bool> {
    let amount = entry.food.quantity.amount();
    let (grams, kcal_per_100g, protein_per_100g) = match entry.food.quantity {
        Quantity::Weighed { grams, kcal_per_100g, protein_per_100g } => {
            (Some(grams), Some(kcal_per_100g), Some(protein_per_100g))
        }
        Quantity::Whole { .. } => (None, None, None),
    };
    let result = sqlx::query(
        "insert into food_entries
            (id, eaten_at, slot, name, servings, kcal, protein_dg, device_session_id, source, figures, grams,
             part_of, position, kcal_per_100g, protein_per_100g, carbs_g, fat_g)
         values ($1, $2, $3, $4, 1, $5, $6, $7, 'typed', 'known', $8, $9, $10, $11, $12, $13, $14)
         on conflict (id) do nothing",
    )
    .bind(entry.id)
    .bind(entry.eaten_at)
    .bind(entry.slot.as_str())
    .bind(&entry.food.name)
    .bind(amount.kcal as i32)
    .bind(amount.protein_dg as i32)
    .bind(device_session_id)
    .bind(grams)
    .bind(entry.part_of)
    .bind(entry.position)
    .bind(kcal_per_100g)
    .bind(protein_per_100g)
    .bind(entry.food.carbs_g).bind(entry.food.fat_g)
    .execute(&mut *conn)
    .await?;
    Ok(result.rows_affected() == 1)
}

/// One part of a built meal as it arrives with the meal.
#[derive(Debug, Clone, PartialEq)]
pub enum NewPart {
    /// A photo sent ahead of the meal, to be estimated meanwhile.
    Photo { id: Uuid },
    /// Scanned: the product is `None` for a code lyfe does not know.
    Barcode { id: Uuid, code: String, grams: f64, product: Option<Product> },
    Typed { id: Uuid, food: food::Ingredient },
}

/// A meal built from parts, as it arrives from the phone.
#[derive(Debug, Clone, PartialEq)]
pub struct NewBuiltMeal {
    pub id: Uuid,
    pub eaten_at: DateTime<Utc>,
    pub slot: Slot,
    pub name: String,
    /// In the order added.
    pub parts: Vec<NewPart>,
}

/// Stores a built meal and its parts, all or none. Photos sent ahead of it
/// join it at its time and slot. Returns false, and changes nothing, when
/// an entry with this id is already stored.
pub async fn insert_built_meal(pool: &PgPool, meal: &NewBuiltMeal, device_session_id: i64) -> sqlx::Result<bool> {
    let mut tx = pool.begin().await?;
    let result = sqlx::query(
        "insert into food_entries (id, eaten_at, slot, name, servings, kcal, protein_dg, device_session_id, source)
         values ($1, $2, $3, $4, 1, 0, 0, $5, 'built')
         on conflict (id) do nothing",
    )
    .bind(meal.id)
    .bind(meal.eaten_at)
    .bind(meal.slot.as_str())
    .bind(&meal.name)
    .bind(device_session_id)
    .execute(&mut *tx)
    .await?;
    if result.rows_affected() == 0 {
        return Ok(false);
    }
    for (index, part) in meal.parts.iter().enumerate() {
        let position = index as i32 + 1;
        match part {
            NewPart::Photo { id } => {
                sqlx::query("update food_entries set eaten_at = $3, slot = $4, position = $5 where id = $1 and part_of = $2")
                    .bind(id)
                    .bind(meal.id)
                    .bind(meal.eaten_at)
                    .bind(meal.slot.as_str())
                    .bind(position)
                    .execute(&mut *tx)
                    .await?;
            }
            NewPart::Barcode { id, code, grams, product } => {
                let entry = NewBarcodeEntry {
                    id: *id,
                    eaten_at: meal.eaten_at,
                    slot: meal.slot,
                    code: code.clone(),
                    grams: *grams,
                    product: product.clone(),
                    part_of: Some(meal.id),
                    position,
                };
                write_barcode_entry(&mut tx, &entry, device_session_id).await?;
            }
            NewPart::Typed { id, food } => {
                let entry = NewTypedEntry {
                    id: *id,
                    eaten_at: meal.eaten_at,
                    slot: meal.slot,
                    food: food.clone(),
                    part_of: Some(meal.id),
                    position,
                };
                write_typed_entry(&mut tx, &entry, device_session_id).await?;
            }
        }
    }
    // A photo sent ahead that the meal did not name still joins it.
    sqlx::query("update food_entries set eaten_at = $2, slot = $3 where part_of = $1")
        .bind(meal.id)
        .bind(meal.eaten_at)
        .bind(meal.slot.as_str())
        .execute(&mut *tx)
        .await?;
    tx.commit().await?;
    Ok(true)
}

/// Stores a label the owner typed, and gives every barcode meal still
/// waiting for it its figures. Meals already logged with the database's
/// figures keep them.
pub async fn set_owner_product(pool: &PgPool, product: &Product) -> sqlx::Result<u64> {
    let mut tx = pool.begin().await?;
    sqlx::query(
        "insert into owner_products (code, name, kcal_per_100g, protein_per_100g, serving_g) values ($1, $2, $3, $4, $5)
         on conflict (code) do update set
            name = excluded.name, kcal_per_100g = excluded.kcal_per_100g,
            protein_per_100g = excluded.protein_per_100g, serving_g = excluded.serving_g, set_at = now()",
    )
    .bind(&product.code)
    .bind(&product.name)
    .bind(product.kcal_per_100g)
    .bind(product.protein_per_100g)
    .bind(product.serving_g)
    .execute(&mut *tx)
    .await?;
    // Worked out here, as for a code that was known when scanned, so both
    // round the same way.
    let waiting = sqlx::query(
        "select id, grams from food_entries
         where source = 'barcode' and figures = 'needs_label' and barcode = any($1)
         for update",
    )
    .bind(product::lookup_codes(&product.code))
    .fetch_all(&mut *tx)
    .await?;
    for row in &waiting {
        let amount = product.amount(row.get::<Option<f64>, _>("grams").unwrap_or_default());
        sqlx::query(
            "update food_entries set
                figures = 'known', name = $2, kcal = $3, protein_dg = $4, kcal_per_100g = $5, protein_per_100g = $6
             where id = $1",
        )
        .bind(row.get::<Uuid, _>("id"))
        .bind(&product.name)
        .bind(amount.kcal as i32)
        .bind(amount.protein_dg as i32)
        .bind(product.kcal_per_100g)
        .bind(product.protein_per_100g)
        .execute(&mut *tx)
        .await?;
    }
    let filled = waiting.len() as u64;
    tx.commit().await?;
    Ok(filled)
}

/// Packaged food logged lately and still known, most recent first.
pub async fn recent_products(pool: &PgPool, limit: i64) -> sqlx::Result<Vec<Product>> {
    let codes: Vec<String> = sqlx::query_scalar(
        "select barcode from food_entries
         where source = 'barcode' and figures = 'known' and removed_at is null
         group by barcode order by max(eaten_at) desc limit $1",
    )
    .bind(limit)
    .fetch_all(pool)
    .await?;
    let mut products = Vec::with_capacity(codes.len());
    for code in codes {
        if let Some(product) = product(pool, &code).await? {
            products.push(product);
        }
    }
    Ok(products)
}

/// The downloaded food database while a new copy is being read in. It is
/// filled in a table of its own and swapped in whole at the end, so a
/// lookup meanwhile sees the old copy, never half of the new one.
pub struct ProductImport {
    pool: PgPool,
    pub stored: u64,
}

impl ProductImport {
    pub async fn begin(pool: &PgPool) -> sqlx::Result<ProductImport> {
        sqlx::query("drop table if exists barcode_products_next").execute(pool).await?;
        sqlx::query("create table barcode_products_next (like barcode_products including all)")
            .execute(pool)
            .await?;
        Ok(ProductImport { pool: pool.clone(), stored: 0 })
    }

    /// Adds products; a code already read is kept as first read.
    pub async fn add(&mut self, products: &[Product]) -> sqlx::Result<()> {
        let codes: Vec<&str> = products.iter().map(|p| p.code.as_str()).collect();
        let names: Vec<&str> = products.iter().map(|p| p.name.as_str()).collect();
        let kcal: Vec<f64> = products.iter().map(|p| p.kcal_per_100g).collect();
        let protein: Vec<f64> = products.iter().map(|p| p.protein_per_100g).collect();
        let serving: Vec<Option<f64>> = products.iter().map(|p| p.serving_g).collect();
        self.stored += sqlx::query(
            "insert into barcode_products_next (code, name, kcal_per_100g, protein_per_100g, serving_g)
             select * from unnest($1::text[], $2::text[], $3::double precision[], $4::double precision[],
                                  $5::double precision[])
             on conflict (code) do nothing",
        )
        .bind(&codes)
        .bind(&names)
        .bind(&kcal)
        .bind(&protein)
        .bind(&serving)
        .execute(&self.pool)
        .await?
        .rows_affected();
        Ok(())
    }

    /// Puts the new copy in place of the old.
    pub async fn finish(self) -> sqlx::Result<u64> {
        let mut tx = self.pool.begin().await?;
        sqlx::query("drop table barcode_products").execute(&mut *tx).await?;
        sqlx::query("alter table barcode_products_next rename to barcode_products").execute(&mut *tx).await?;
        tx.commit().await?;
        Ok(self.stored)
    }
}

/// Sets the targets from a day on. Setting them again the same day
/// replaces that day's.
pub async fn set_food_target(pool: &PgPool, target: &food::Target) -> sqlx::Result<()> {
    sqlx::query(
        "insert into food_targets (effective_on, kcal, protein_g) values ($1, $2, $3)
         on conflict (effective_on) do update set
            kcal = excluded.kcal, protein_g = excluded.protein_g, set_at = now()",
    )
    .bind(target.since)
    .bind(target.kcal as i32)
    .bind(target.protein_g as i32)
    .execute(pool)
    .await?;
    Ok(())
}

/// Every target ever set, oldest first.
pub async fn food_targets(pool: &PgPool) -> sqlx::Result<Vec<food::Target>> {
    let rows = sqlx::query("select effective_on, kcal, protein_g from food_targets order by effective_on")
        .fetch_all(pool)
        .await?;
    Ok(rows
        .into_iter()
        .map(|r| food::Target {
            since: r.get("effective_on"),
            kcal: r.get::<i32, _>("kcal") as u32,
            protein_g: r.get::<i32, _>("protein_g") as u32,
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

// --- Money ---------------------------------------------------------------

/// A bank connection as the bridge names it, with what it last said is
/// wrong: its code and its words. `today` dates a problem that starts now;
/// one already known keeps the day it started.
pub async fn upsert_money_connection(
    conn: &mut sqlx::PgConnection,
    connection: &money::Connection,
    problem: Option<(&str, &str)>,
    today: NaiveDate,
) -> sqlx::Result<()> {
    sqlx::query(
        "insert into money_connections (id, name, problem_code, problem, problem_since)
         values ($1, $2, $3, $4, case when $4::text is null then null else $5::date end)
         on conflict (id) do update set
            name = excluded.name, problem_code = excluded.problem_code, problem = excluded.problem,
            problem_since = case when excluded.problem is null then null
                                 else coalesce(money_connections.problem_since, excluded.problem_since) end,
            seen_at = now()",
    )
    .bind(&connection.id)
    .bind(&connection.name)
    .bind(problem.map(|(code, _)| code))
    .bind(problem.map(|(_, text)| text))
    .bind(today)
    .execute(conn)
    .await?;
    Ok(())
}

/// Stores an account's name and balance as the bank has them now, and
/// returns lyfe's id for it. A new account that holds investments starts
/// set aside; after that, whether it is set aside is the owner's to say
/// and is left alone. Whether it is an investment account is the bank's
/// to say, each time it lists what the account holds; an answer with no
/// such list leaves that as it was.
pub async fn upsert_money_account(
    conn: &mut sqlx::PgConnection,
    account: &money::BankAccount,
    problem: Option<&str>,
) -> sqlx::Result<Uuid> {
    sqlx::query_scalar(
        "insert into money_accounts
            (connection_id, provider_id, name, currency, balance_minor, available_minor, balance_at, problem,
             set_aside, invested)
         values ($1, $2, $3, $4, $5, $6, $7, $8, $9, coalesce($10, false))
         on conflict (connection_id, provider_id) do update set
            name = excluded.name, currency = excluded.currency, balance_minor = excluded.balance_minor,
            available_minor = excluded.available_minor, balance_at = excluded.balance_at,
            problem = excluded.problem, invested = coalesce($10, money_accounts.invested), seen_at = now()
         returning id",
    )
    .bind(&account.connection_id)
    .bind(&account.id)
    .bind(&account.name)
    .bind(&account.currency)
    .bind(account.balance_minor)
    .bind(account.available_minor)
    .bind(account.balance_at)
    .bind(problem)
    .bind(account.holds_investments)
    .bind(account.holdings.as_ref().map(|_| account.holds_investments))
    .fetch_one(conn)
    .await
}

/// Keeps what an account's balance was on `day`: the last one seen that
/// day stands.
pub async fn keep_money_balance(
    conn: &mut sqlx::PgConnection,
    account_id: Uuid,
    day: NaiveDate,
    balance_minor: i64,
) -> sqlx::Result<()> {
    sqlx::query(
        "insert into money_balances (account_id, day, balance_minor) values ($1, $2, $3)
         on conflict (account_id, day) do update set balance_minor = excluded.balance_minor",
    )
    .bind(account_id)
    .bind(day)
    .bind(balance_minor)
    .execute(conn)
    .await?;
    Ok(())
}

/// Makes what an account holds what the bank lists now: a holding it no
/// longer lists was sold and goes, and the rest are brought up to date.
pub async fn replace_money_holdings(
    conn: &mut sqlx::PgConnection,
    account_id: Uuid,
    holdings: &[money::BankHolding],
) -> sqlx::Result<()> {
    let listed: Vec<&str> = holdings.iter().map(|holding| holding.id.as_str()).collect();
    sqlx::query("delete from money_holdings where account_id = $1 and provider_id <> all($2)")
        .bind(account_id)
        .bind(&listed)
        .execute(&mut *conn)
        .await?;
    for holding in holdings {
        sqlx::query(
            "insert into money_holdings
                (account_id, provider_id, symbol, name, currency, shares_micro, value_minor, cost_minor)
             values ($1, $2, $3, $4, $5, $6, $7, $8)
             on conflict (account_id, provider_id) do update set
                symbol = excluded.symbol, name = excluded.name, currency = excluded.currency,
                shares_micro = excluded.shares_micro, value_minor = excluded.value_minor,
                cost_minor = excluded.cost_minor, seen_at = now()",
        )
        .bind(account_id)
        .bind(&holding.id)
        .bind(&holding.symbol)
        .bind(&holding.name)
        .bind(&holding.currency)
        .bind(holding.shares_micro)
        .bind(holding.value_minor)
        .bind(holding.cost_minor)
        .execute(&mut *conn)
        .await?;
    }
    Ok(())
}

/// What storing one transaction came to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stored {
    New,
    /// The bank changed something about one already stored.
    Changed,
    Same,
}

/// Stores one posted transaction under the bank's id for it, so the same
/// days imported again refresh a row and never add one. A new entry is
/// read from its sign until it is sorted with the rest; one already stored
/// keeps how it was sorted, unless the bank changed its amount to the other
/// sign, which starts it again.
pub async fn upsert_money_entry(
    conn: &mut sqlx::PgConnection,
    account_id: Uuid,
    transaction: &money::BankTransaction,
    day: NaiveDate,
) -> sqlx::Result<Stored> {
    let payee_key = ledger::payee_key(&transaction.payee, &transaction.description);
    let kind = if transaction.amount_minor < 0 { ledger::Kind::Expense } else { ledger::Kind::Income };
    let row = sqlx::query(
        "with before as (
            select day, posted_at, amount_minor, payee, description, memo
            from money_entries where account_id = $1 and provider_id = $2
         ), stored as (
            insert into money_entries
                (account_id, provider_id, day, posted_at, amount_minor, payee, description, memo, payee_key, kind)
            values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
            on conflict (account_id, provider_id) do update set
                day = excluded.day, posted_at = excluded.posted_at, amount_minor = excluded.amount_minor,
                payee = excluded.payee, description = excluded.description, memo = excluded.memo,
                payee_key = excluded.payee_key,
                kind = case when (money_entries.amount_minor < 0) = (excluded.amount_minor < 0)
                            then money_entries.kind else excluded.kind end,
                category = case when (money_entries.amount_minor < 0) = (excluded.amount_minor < 0)
                                then money_entries.category end,
                sorted_by = case when (money_entries.amount_minor < 0) = (excluded.amount_minor < 0)
                                 then money_entries.sorted_by else 'auto' end,
                peer_id = case when (money_entries.amount_minor < 0) = (excluded.amount_minor < 0)
                               then money_entries.peer_id end
            returning 1
         )
         select (select count(*) from before) = 0 as new,
                exists (select 1 from before
                        where (day, posted_at, amount_minor, payee, description, memo)
                              is distinct from ($3::date, $4::timestamptz, $5::bigint, $6::text, $7::text, $8::text)) as changed
         from stored",
    )
    .bind(account_id)
    .bind(&transaction.id)
    .bind(day)
    .bind(transaction.posted_at)
    .bind(transaction.amount_minor)
    .bind(&transaction.payee)
    .bind(&transaction.description)
    .bind(&transaction.memo)
    .bind(&payee_key)
    .bind(kind.as_str())
    .fetch_one(conn)
    .await?;
    Ok(match (row.get::<bool, _>("new"), row.get::<bool, _>("changed")) {
        (true, _) => Stored::New,
        (false, true) => Stored::Changed,
        (false, false) => Stored::Same,
    })
}

/// Records what the bridge said about the import as a whole.
pub async fn set_money_notes(conn: &mut sqlx::PgConnection, notes: &[String]) -> sqlx::Result<()> {
    sqlx::query("update money_notes set notes = $1").bind(notes).execute(conn).await?;
    Ok(())
}

fn read_sorting(r: &sqlx::postgres::PgRow) -> ledger::Sorting {
    ledger::Sorting {
        kind: ledger::Kind::parse(r.get("kind")).unwrap_or(ledger::Kind::Transfer),
        category: r.get("category"),
        sorted_by: ledger::SortedBy::parse(r.get("sorted_by")).unwrap_or(ledger::SortedBy::Auto),
        peer_id: r.get("peer_id"),
    }
}

/// Sorts every entry again by the rules as they now stand and writes what
/// changed. Returns how many entries that was. Run inside the transaction
/// that changed an entry, a rule or an account.
pub async fn resort_money(conn: &mut sqlx::PgConnection) -> sqlx::Result<u64> {
    let rules: std::collections::HashMap<String, ledger::Rule> =
        sqlx::query("select payee_key, kind, category from money_rules")
            .fetch_all(&mut *conn)
            .await?
            .into_iter()
            .filter_map(|r| {
                let rule = match (r.get::<&str, _>("kind"), r.get::<Option<String>, _>("category")) {
                    ("spending", Some(category)) => ledger::Rule::Spending(category),
                    ("income", _) => ledger::Rule::Income,
                    ("transfer", _) => ledger::Rule::Transfer,
                    _ => return None,
                };
                Some((r.get("payee_key"), rule))
            })
            .collect();
    let rows: Vec<ledger::Row> = sqlx::query(
        "select e.id, e.account_id, a.set_aside, a.currency, e.day, e.amount_minor, e.payee_key,
                e.kind, e.category, e.sorted_by, e.peer_id
         from money_entries e join money_accounts a on a.id = e.account_id
         order by e.day, e.id",
    )
    .fetch_all(&mut *conn)
    .await?
    .iter()
    .map(|r| ledger::Row {
        id: r.get("id"),
        account_id: r.get("account_id"),
        set_aside: r.get("set_aside"),
        currency: r.get("currency"),
        day: r.get("day"),
        amount_minor: r.get("amount_minor"),
        payee_key: r.get("payee_key"),
        sorting: read_sorting(r),
    })
    .collect();
    let sorted = ledger::sort_all(&rows, &rules);
    let mut changed = 0;
    for (row, sorting) in rows.iter().zip(sorted) {
        if row.sorting == sorting {
            continue;
        }
        sqlx::query("update money_entries set kind = $2, category = $3, sorted_by = $4, peer_id = $5 where id = $1")
            .bind(row.id)
            .bind(sorting.kind.as_str())
            .bind(&sorting.category)
            .bind(sorting.sorted_by.as_str())
            .bind(sorting.peer_id)
            .execute(&mut *conn)
            .await?;
        changed += 1;
    }
    Ok(changed)
}

const MONEY_ENTRY_COLUMNS: &str = "e.id, e.day, e.amount_minor, a.currency, e.payee, e.description, e.payee_key,
    a.name as account, a.set_aside, e.kind, e.category, e.sorted_by, e.peer_id";

fn read_money_entry(r: &sqlx::postgres::PgRow) -> ledger::Entry {
    ledger::Entry {
        id: r.get("id"),
        day: r.get("day"),
        amount_minor: r.get("amount_minor"),
        currency: r.get("currency"),
        payee: r.get("payee"),
        description: r.get("description"),
        payee_key: r.get("payee_key"),
        account: r.get("account"),
        set_aside: r.get("set_aside"),
        sorting: read_sorting(r),
    }
}

/// Entries that count on the days from `from` to `to`, both included.
pub async fn money_entries_between(pool: &PgPool, from: NaiveDate, to: NaiveDate) -> sqlx::Result<Vec<ledger::Entry>> {
    let rows = sqlx::query(&format!(
        "select {MONEY_ENTRY_COLUMNS} from money_entries e join money_accounts a on a.id = e.account_id
         where e.day between $1 and $2"
    ))
    .bind(from)
    .bind(to)
    .fetch_all(pool)
    .await?;
    Ok(rows.iter().map(read_money_entry).collect())
}

pub async fn money_entry(conn: &mut sqlx::PgConnection, id: Uuid) -> sqlx::Result<Option<ledger::Entry>> {
    let row = sqlx::query(&format!(
        "select {MONEY_ENTRY_COLUMNS} from money_entries e join money_accounts a on a.id = e.account_id
         where e.id = $1 for update of e"
    ))
    .bind(id)
    .fetch_optional(conn)
    .await?;
    Ok(row.as_ref().map(read_money_entry))
}

/// Where the stored entries lie around the days from `from` to `to`.
pub async fn money_history(pool: &PgPool, from: NaiveDate, to: NaiveDate) -> sqlx::Result<ledger::History> {
    let row = sqlx::query(
        "select min(day) as first, max(day) filter (where day < $1) as before, min(day) filter (where day > $2) as after
         from money_entries",
    )
    .bind(from)
    .bind(to)
    .fetch_one(pool)
    .await?;
    Ok(ledger::History { first: row.get("first"), before: row.get("before"), after: row.get("after") })
}

/// True of a connection `c` the bridge still lists: one seen in the last
/// import. One deleted at the bridge drops out.
const MONEY_LISTED: &str = "c.seen_at >= (select max(seen_at) from money_connections) - interval '1 hour'";

/// True of an account `a` under a connection `c` when the bridge still
/// lists both: the account was seen in the last import, like its
/// connection. One closed at its bank drops out. While its bank has a
/// problem, an account is held to the last import that bank's accounts
/// were seen in instead: a bank waiting to be signed in to again has not
/// lost its accounts, whether or not the bridge goes on listing them, and
/// one closed before that stays out.
const MONEY_ACCOUNT_LISTED: &str = "c.seen_at >= (select max(seen_at) from money_connections) - interval '1 hour'
    and a.seen_at >= (case when c.problem is null then (select max(seen_at) from money_accounts)
                           else (select max(sibling.seen_at) from money_accounts sibling
                                 where sibling.connection_id = a.connection_id) end) - interval '1 hour'";

/// The accounts the bridge still lists, a bank at a time. One closed at
/// its bank, or whose connection was deleted at the bridge, drops out;
/// what was imported from it stays in its months.
pub async fn money_accounts(pool: &PgPool) -> sqlx::Result<Vec<ledger::Account>> {
    let rows = sqlx::query(&format!(
        "select a.id, a.name, c.name as connection, a.currency, a.balance_minor, a.available_minor, a.balance_at,
                a.set_aside, a.invested, a.problem
         from money_accounts a join money_connections c on c.id = a.connection_id
         where {MONEY_ACCOUNT_LISTED}
         order by a.set_aside, c.name, a.name, a.id"
    ))
    .fetch_all(pool)
    .await?;
    Ok(rows
        .iter()
        .map(|r| ledger::Account {
            id: r.get("id"),
            name: r.get("name"),
            connection: r.get("connection"),
            currency: r.get("currency"),
            balance_minor: r.get("balance_minor"),
            available_minor: r.get("available_minor"),
            balance_at: r.get("balance_at"),
            set_aside: r.get("set_aside"),
            invested: r.get("invested"),
            problem: r.get("problem"),
        })
        .collect())
}

/// What the accounts the bridge still lists hold.
pub async fn money_holdings(pool: &PgPool) -> sqlx::Result<Vec<worth::Holding>> {
    let rows = sqlx::query(&format!(
        "select h.account_id, h.symbol, h.name, h.currency, h.shares_micro, h.value_minor, h.cost_minor
         from money_holdings h join money_accounts a on a.id = h.account_id
              join money_connections c on c.id = a.connection_id
         where {MONEY_ACCOUNT_LISTED}
         order by a.name, a.id, h.provider_id"
    ))
    .fetch_all(pool)
    .await?;
    Ok(rows
        .iter()
        .map(|r| worth::Holding {
            account_id: r.get("account_id"),
            symbol: r.get("symbol"),
            name: r.get("name"),
            currency: r.get("currency"),
            shares_micro: r.get("shares_micro"),
            value_minor: r.get("value_minor"),
            cost_minor: r.get("cost_minor"),
        })
        .collect())
}

/// Every balance kept, of every account ever imported: an account closed
/// since still counts on the days it was there.
pub async fn money_balances(pool: &PgPool) -> sqlx::Result<Vec<worth::Balance>> {
    let rows = sqlx::query(
        "select b.account_id, a.currency, b.day, b.balance_minor
         from money_balances b join money_accounts a on a.id = b.account_id
         order by b.day, b.account_id",
    )
    .fetch_all(pool)
    .await?;
    Ok(rows
        .iter()
        .map(|r| worth::Balance {
            account_id: r.get("account_id"),
            currency: r.get("currency"),
            day: r.get("day"),
            balance_minor: r.get("balance_minor"),
        })
        .collect())
}

/// What the owner assumes about the way to financial independence.
pub async fn money_plan(pool: &PgPool) -> sqlx::Result<fire::Plan> {
    let row = sqlx::query("select withdrawal_bp, return_bp, birth_year, coast_age from money_plan").fetch_optional(pool).await?;
    Ok(row.map_or_else(fire::Plan::default, |r| fire::Plan {
        withdrawal_bp: r.get::<i32, _>("withdrawal_bp") as u32,
        return_bp: r.get::<i32, _>("return_bp") as u32,
        birth_year: r.get("birth_year"),
        coast_age: r.get::<i32, _>("coast_age") as u32,
    }))
}

pub async fn set_money_plan(pool: &PgPool, plan: &fire::Plan) -> sqlx::Result<()> {
    sqlx::query(
        "insert into money_plan (id, withdrawal_bp, return_bp, birth_year, coast_age) values (true, $1, $2, $3, $4)
         on conflict (id) do update set
            withdrawal_bp = excluded.withdrawal_bp, return_bp = excluded.return_bp,
            birth_year = excluded.birth_year, coast_age = excluded.coast_age",
    )
    .bind(plan.withdrawal_bp as i32)
    .bind(plan.return_bp as i32)
    .bind(plan.birth_year)
    .bind(plan.coast_age as i32)
    .execute(pool)
    .await?;
    Ok(())
}

/// The day of the oldest entry stored, which is as far back as a month can
/// be held whole.
pub async fn money_first_day(pool: &PgPool) -> sqlx::Result<Option<NaiveDate>> {
    sqlx::query_scalar("select min(day) from money_entries").fetch_one(pool).await
}

/// A connection the bridge says is broken.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BrokenConnection {
    pub name: String,
    pub code: String,
    pub problem: String,
    pub since: NaiveDate,
}

pub async fn broken_money_connections(pool: &PgPool) -> sqlx::Result<Vec<BrokenConnection>> {
    let rows = sqlx::query(&format!(
        "select c.name, c.problem_code, c.problem, c.problem_since from money_connections c
         where c.problem is not null and {MONEY_LISTED}
         order by c.problem_since, c.name"
    ))
    .fetch_all(pool)
    .await?;
    Ok(rows
        .iter()
        .map(|r| BrokenConnection {
            name: r.get("name"),
            code: r.get("problem_code"),
            problem: r.get("problem"),
            since: r.get("problem_since"),
        })
        .collect())
}

pub async fn money_notes(pool: &PgPool) -> sqlx::Result<Vec<String>> {
    sqlx::query_scalar("select notes from money_notes").fetch_optional(pool).await.map(Option::unwrap_or_default)
}

/// True once anything has been imported.
pub async fn has_money(pool: &PgPool) -> sqlx::Result<bool> {
    sqlx::query_scalar("select exists (select 1 from money_accounts)").fetch_one(pool).await
}

/// Says what one entry is, on the owner's word, whatever its payee's rule.
pub async fn sort_money_entry(conn: &mut sqlx::PgConnection, id: Uuid, sorting: &ledger::Sorting) -> sqlx::Result<()> {
    sqlx::query("update money_entries set kind = $2, category = $3, sorted_by = 'owner', peer_id = null where id = $1")
        .bind(id)
        .bind(sorting.kind.as_str())
        .bind(&sorting.category)
        .execute(conn)
        .await?;
    Ok(())
}

/// Takes the owner's word off one entry, so the rules decide it again.
pub async fn unsort_money_entry(conn: &mut sqlx::PgConnection, id: Uuid) -> sqlx::Result<()> {
    sqlx::query(
        "update money_entries set kind = case when amount_minor < 0 then 'expense' else 'income' end,
                category = null, sorted_by = 'auto', peer_id = null
         where id = $1 and sorted_by = 'owner'",
    )
    .bind(id)
    .execute(conn)
    .await?;
    Ok(())
}

/// Says what a payee is from now on, or with `None` forgets what was said.
pub async fn set_money_rule(conn: &mut sqlx::PgConnection, payee_key: &str, rule: Option<&ledger::Rule>) -> sqlx::Result<()> {
    let Some(rule) = rule else {
        sqlx::query("delete from money_rules where payee_key = $1").bind(payee_key).execute(conn).await?;
        return Ok(());
    };
    let (kind, category) = match rule {
        ledger::Rule::Spending(category) => ("spending", Some(category.as_str())),
        ledger::Rule::Income => ("income", None),
        ledger::Rule::Transfer => ("transfer", None),
    };
    sqlx::query(
        "insert into money_rules (payee_key, kind, category) values ($1, $2, $3)
         on conflict (payee_key) do update set kind = excluded.kind, category = excluded.category, set_at = now()",
    )
    .bind(payee_key)
    .bind(kind)
    .bind(category)
    .execute(conn)
    .await?;
    Ok(())
}

/// Sets an account aside or brings it back. False when there is no such
/// account.
pub async fn set_money_account_aside(conn: &mut sqlx::PgConnection, id: Uuid, set_aside: bool) -> sqlx::Result<bool> {
    let result = sqlx::query("update money_accounts set set_aside = $2 where id = $1")
        .bind(id)
        .bind(set_aside)
        .execute(conn)
        .await?;
    Ok(result.rows_affected() == 1)
}
