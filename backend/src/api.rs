//! The HTTP API the apps use. Everything except the health check and
//! sign-in needs a device token.

use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::extract::{FromRequestParts, Path, State};
use axum::http::request::Parts;
use axum::http::{header, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{delete, get, post, put};
use axum::{Json, Router};
use chrono::{DateTime, Datelike, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sqlx::PgPool;
use uuid::Uuid;

use crate::auth::{self, SignInThrottle};
use crate::db;
use crate::garmin::sync::{Syncer, SOURCE as GARMIN};
use crate::routines::breath::{self, BreathRules};
use crate::routines::food::{self, FoodDay, Slot};
use crate::routines::gym::{self, GymRules, GymSession, GymStreak, Week};
use crate::routines::weekly::WeekStreak;
use crate::routines::weight::{self, Unit, WeightSettings, WeightTrend};

/// How recent a Garmin poll must be for an app refresh to skip polling again.
const REFRESH_MIN_AGE: Duration = Duration::from_secs(30);

pub type Clock = Arc<dyn Fn() -> DateTime<Utc> + Send + Sync>;

#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    pub syncer: Arc<Syncer>,
    pub throttle: Arc<SignInThrottle>,
    pub timezone: chrono_tz::Tz,
    pub gym_rules: Arc<GymRules>,
    pub breath_rules: Arc<BreathRules>,
    pub weight: WeightSettings,
    /// Whether this server can send notifications (it has Apple's key).
    pub push_ready: bool,
    pub now: Clock,
}

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/healthz", get(|| async { "ok" }))
        .route("/v1/auth/sign-in", post(sign_in))
        .route("/v1/auth/sign-out", post(sign_out))
        .route("/v1/sync", post(sync_now))
        .route("/v1/push-token", post(set_push_token))
        .route("/v1/home", get(home))
        .route("/v1/breath/sessions", post(record_breath_session))
        .route("/v1/weigh-ins", post(record_weigh_in))
        .route("/v1/food/entries", post(record_food_entry))
        .route("/v1/food/entries/{id}", delete(remove_food_entry))
        .route("/v1/food/meals/{id}", put(save_meal).delete(remove_meal))
        .route("/v1/food/targets", put(set_food_targets))
        .with_state(state)
}

// --- Errors --------------------------------------------------------------

#[derive(Debug)]
pub enum ApiError {
    Unauthorized,
    WrongPassword,
    NoPasswordSet,
    TooManyAttempts { retry_after_s: u64 },
    BadRequest(&'static str),
    Internal,
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, code) = match &self {
            ApiError::Unauthorized => (StatusCode::UNAUTHORIZED, "unauthorized"),
            ApiError::WrongPassword => (StatusCode::UNAUTHORIZED, "wrong_password"),
            ApiError::NoPasswordSet => (StatusCode::SERVICE_UNAVAILABLE, "no_password_set"),
            ApiError::TooManyAttempts { .. } => (StatusCode::TOO_MANY_REQUESTS, "too_many_attempts"),
            ApiError::BadRequest(_) => (StatusCode::BAD_REQUEST, "bad_request"),
            ApiError::Internal => (StatusCode::INTERNAL_SERVER_ERROR, "internal"),
        };
        let mut body = json!({ "error": code });
        match self {
            ApiError::TooManyAttempts { retry_after_s } => body["retry_after_s"] = json!(retry_after_s),
            ApiError::BadRequest(detail) => body["detail"] = json!(detail),
            _ => {}
        }
        (status, Json(body)).into_response()
    }
}

impl From<sqlx::Error> for ApiError {
    fn from(error: sqlx::Error) -> Self {
        tracing::error!(%error, "database error while answering a request");
        ApiError::Internal
    }
}

// --- Sign-in -------------------------------------------------------------

/// A signed-in device. Extracting it is what protects a route.
pub struct Device {
    pub session_id: i64,
}

impl FromRequestParts<AppState> for Device {
    type Rejection = ApiError;

    async fn from_request_parts(parts: &mut Parts, state: &AppState) -> Result<Self, Self::Rejection> {
        let token = parts
            .headers
            .get(header::AUTHORIZATION)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.strip_prefix("Bearer "))
            .map(str::trim)
            .filter(|token| !token.is_empty())
            .ok_or(ApiError::Unauthorized)?;
        match db::touch_session(&state.pool, &auth::token_hash(token)).await? {
            Some(session_id) => Ok(Device { session_id }),
            None => Err(ApiError::Unauthorized),
        }
    }
}

#[derive(Deserialize)]
struct SignInRequest {
    password: String,
    device_name: String,
}

#[derive(Serialize)]
struct SignInResponse {
    token: String,
}

async fn sign_in(
    State(state): State<AppState>,
    Json(request): Json<SignInRequest>,
) -> Result<Json<SignInResponse>, ApiError> {
    let device_name = request.device_name.trim();
    if device_name.is_empty() || device_name.chars().count() > 100 {
        return Err(ApiError::BadRequest("device_name must be 1 to 100 characters"));
    }
    if request.password.len() > 1024 {
        return Err(ApiError::BadRequest("password is too long"));
    }
    // Failed attempts are logged (never the password) so the owner can see
    // whether a device reached the server at all, and notice guessing.
    if let Some(wait) = state.throttle.wait_remaining(Instant::now()) {
        let retry_after_s = wait.as_secs().max(1);
        tracing::warn!(device = ?device_name, retry_after_s, "sign-in refused: too many wrong attempts");
        return Err(ApiError::TooManyAttempts { retry_after_s });
    }
    let Some(stored) = db::password_hash(&state.pool).await? else {
        tracing::warn!(device = ?device_name, "sign-in refused: no password has been set");
        return Err(ApiError::NoPasswordSet);
    };
    let password = request.password;
    let matches = tokio::task::spawn_blocking(move || auth::verify_password(&password, &stored))
        .await
        .map_err(|_| ApiError::Internal)?;
    if !matches {
        state.throttle.record_failure(Instant::now());
        tracing::warn!(device = ?device_name, "sign-in refused: wrong password");
        return Err(ApiError::WrongPassword);
    }
    state.throttle.record_success();
    let token = auth::new_token().map_err(|_| ApiError::Internal)?;
    db::insert_session(&state.pool, &auth::token_hash(&token), device_name).await?;
    tracing::info!(device = ?device_name, "device signed in");
    Ok(Json(SignInResponse { token }))
}

async fn sign_out(State(state): State<AppState>, device: Device) -> Result<StatusCode, ApiError> {
    db::revoke_session(&state.pool, device.session_id).await?;
    Ok(StatusCode::NO_CONTENT)
}

// --- Notifications -------------------------------------------------------

#[derive(Deserialize)]
struct PushTokenRequest {
    /// The device token Apple gave the app, in hexadecimal.
    apns_token: String,
}

/// Records where Apple delivers notifications for the calling device.
async fn set_push_token(
    State(state): State<AppState>,
    device: Device,
    Json(request): Json<PushTokenRequest>,
) -> Result<StatusCode, ApiError> {
    let token = request.apns_token.trim().to_ascii_lowercase();
    if !(32..=400).contains(&token.len()) || !token.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(ApiError::BadRequest("apns_token must be the device token in hexadecimal"));
    }
    db::set_push_token(&state.pool, device.session_id, &token).await?;
    Ok(StatusCode::NO_CONTENT)
}

// --- Home ----------------------------------------------------------------

/// Timestamps go out as whole seconds in UTC ("2026-11-17T15:00:00Z"),
/// which every client date parser reads without configuration.
mod seconds {
    use chrono::{DateTime, SecondsFormat, Utc};
    use serde::Serializer;

    pub fn required<S: Serializer>(at: &DateTime<Utc>, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&at.to_rfc3339_opts(SecondsFormat::Secs, true))
    }

    pub fn optional<S: Serializer>(at: &Option<DateTime<Utc>>, serializer: S) -> Result<S::Ok, S::Error> {
        match at {
            Some(at) => required(at, serializer),
            None => serializer.serialize_none(),
        }
    }
}

#[derive(Serialize)]
struct HomeResponse {
    #[serde(serialize_with = "seconds::required")]
    generated_at: DateTime<Utc>,
    today: NaiveDate,
    week: Week,
    gym: GymWeek,
    breath: BreathWeek,
    weight: WeightTrend,
    food: FoodDay,
    sources: Sources,
    notifications: Notifications,
}

#[derive(Serialize)]
struct BreathWeek {
    /// Sessions a week needs to count.
    target: u32,
    /// Days this week with a session that counts.
    done: u32,
    /// Sessions still needed this week.
    remaining: u32,
    /// Whether today already has a session that counts.
    done_today: bool,
    /// Every session started this week, counted or not, oldest first.
    sessions: Vec<breath::SessionSummary>,
    streak: WeekStreak,
    /// The table for the next session.
    table: breath::Table,
    /// The longest hold ever recorded.
    best_ms: Option<u32>,
}

#[derive(Serialize)]
struct Notifications {
    /// False when the server has no Apple key and so cannot send any.
    server_ready: bool,
}

#[derive(Serialize)]
struct GymWeek {
    /// Sessions a week needs to count.
    target: u32,
    /// Days this week with a session, which can exceed the target.
    done: u32,
    /// Sessions still needed this week.
    remaining: u32,
    /// Days left in the week, today included.
    days_left: u32,
    sessions: Vec<GymSession>,
    streak: GymStreak,
}

#[derive(Serialize)]
struct Sources {
    garmin: SourceStatus,
}

#[derive(Serialize)]
struct SourceStatus {
    state: SourceState,
    #[serde(serialize_with = "seconds::optional")]
    last_success_at: Option<DateTime<Utc>>,
    #[serde(serialize_with = "seconds::optional")]
    last_attempt_at: Option<DateTime<Utc>>,
    /// Why the last attempt failed, in words the owner can act on.
    message: Option<String>,
}

#[derive(Serialize, Debug, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum SourceState {
    Ok,
    Failing,
    NeverSynced,
    NotConfigured,
}

async fn garmin_status(state: &AppState) -> Result<SourceStatus, ApiError> {
    let sync = db::source_sync(&state.pool, GARMIN).await?;
    let source_state = if !state.syncer.is_configured() {
        SourceState::NotConfigured
    } else if sync.last_error.is_some() {
        SourceState::Failing
    } else if sync.last_success_at.is_some() {
        SourceState::Ok
    } else {
        SourceState::NeverSynced
    };
    Ok(SourceStatus {
        state: source_state,
        last_success_at: sync.last_success_at,
        last_attempt_at: sync.last_attempt_at,
        message: sync.last_error,
    })
}

async fn home(State(state): State<AppState>, _device: Device) -> Result<Json<HomeResponse>, ApiError> {
    Ok(Json(home_now(&state).await?))
}

/// Everything the Home screen shows, as of now.
async fn home_now(state: &AppState) -> Result<HomeResponse, ApiError> {
    let now = (state.now)();
    let today = now.with_timezone(&state.timezone).date_naive();
    let week = Week::containing(today);
    let activities = db::activities_until(&state.pool, week.ends_on).await?;
    let sessions = gym::sessions_in_week(&state.gym_rules, week, &activities);
    let streak = gym::streak(&state.gym_rules, today, &activities);
    let done = sessions.len() as u32;
    Ok(HomeResponse {
        generated_at: now,
        today,
        week,
        gym: GymWeek {
            target: gym::WEEKLY_TARGET,
            done,
            remaining: gym::WEEKLY_TARGET.saturating_sub(done),
            days_left: 7 - today.weekday().num_days_from_monday(),
            sessions,
            streak,
        },
        breath: breath_week(state, today).await?,
        weight: weight::trend(&state.weight, today, &db::weigh_ins(&state.pool, state.timezone).await?),
        food: food::day(
            today,
            &db::saved_meals(&state.pool).await?,
            &db::food_entries(&state.pool, state.timezone).await?,
            &db::food_targets(&state.pool).await?,
        ),
        sources: Sources { garmin: garmin_status(state).await? },
        notifications: Notifications { server_ready: state.push_ready },
    })
}

async fn breath_week(state: &AppState, today: NaiveDate) -> Result<BreathWeek, ApiError> {
    let week = Week::containing(today);
    let sessions = db::breath_sessions(&state.pool, state.timezone).await?;
    let mut counted_days: Vec<NaiveDate> = breath::session_days(&sessions)
        .into_iter()
        .filter(|day| week.contains(*day))
        .collect();
    counted_days.sort();
    counted_days.dedup();
    let done = counted_days.len() as u32;
    Ok(BreathWeek {
        target: breath::WEEKLY_TARGET,
        done,
        remaining: breath::WEEKLY_TARGET.saturating_sub(done),
        done_today: counted_days.contains(&today),
        sessions: breath::sessions_in_week(week, &sessions)
            .into_iter()
            .map(breath::Session::summary)
            .collect(),
        streak: breath::streak(today, &sessions),
        table: breath::next_table(&state.breath_rules, &sessions),
        best_ms: breath::best_ever_ms(&sessions),
    })
}

// --- Breath sessions -----------------------------------------------------

#[derive(Deserialize)]
struct BreathSessionRequest {
    /// Made on the phone when the session starts. Sending the same session
    /// again changes nothing.
    id: Uuid,
    started_at: DateTime<Utc>,
    ended_at: DateTime<Utc>,
    /// The table the session was run with.
    round_s: u32,
    rounds: u32,
    /// Rounds without a tap are left out.
    holds: Vec<HoldRequest>,
}

#[derive(Deserialize)]
struct HoldRequest {
    /// Counted from 1.
    round: u32,
    hold_ms: u32,
}

/// Stores a session captured on the phone and answers with Home as it now
/// stands: the week, the streak and the next table.
async fn record_breath_session(
    State(state): State<AppState>,
    device: Device,
    Json(request): Json<BreathSessionRequest>,
) -> Result<Json<HomeResponse>, ApiError> {
    if !(1..=50).contains(&request.rounds) || !(1..=3600).contains(&request.round_s) {
        return Err(ApiError::BadRequest("rounds must be 1 to 50 and round_s 1 to 3600"));
    }
    if request.ended_at < request.started_at {
        return Err(ApiError::BadRequest("ended_at is before started_at"));
    }
    if request.started_at > (state.now)() + chrono::Duration::days(1) {
        return Err(ApiError::BadRequest("started_at is in the future"));
    }
    let mut holds: Vec<(i32, i32)> = Vec::with_capacity(request.holds.len());
    for hold in &request.holds {
        if !(1..=request.rounds).contains(&hold.round) {
            return Err(ApiError::BadRequest("a hold names a round the table does not have"));
        }
        if hold.hold_ms > request.round_s * 1000 {
            return Err(ApiError::BadRequest("a hold is longer than its round"));
        }
        holds.push((hold.round as i32, hold.hold_ms as i32));
    }
    holds.sort();
    if holds.windows(2).any(|pair| pair[0].0 == pair[1].0) {
        return Err(ApiError::BadRequest("a round has two holds"));
    }
    let session = db::StoredBreathSession {
        id: request.id,
        started_at: request.started_at,
        ended_at: request.ended_at,
        round_s: request.round_s as i32,
        rounds: request.rounds as i32,
        holds,
    };
    if db::insert_breath_session(&state.pool, &session, device.session_id).await? {
        tracing::info!(id = %session.id, holds = session.holds.len(), "breath session recorded");
    }
    Ok(Json(home_now(&state).await?))
}

// --- Weigh-ins -----------------------------------------------------------

#[derive(Deserialize)]
struct WeighInRequest {
    /// Made on the phone when the weight is typed. Sending the same weigh-in
    /// again changes nothing.
    id: Uuid,
    measured_at: DateTime<Utc>,
    /// As typed, in `unit`.
    value: f64,
    unit: String,
}

/// Stores a weight typed on the phone, usually into the morning prompt,
/// and answers with Home as it now stands, the weight trend included.
async fn record_weigh_in(
    State(state): State<AppState>,
    device: Device,
    Json(request): Json<WeighInRequest>,
) -> Result<Json<HomeResponse>, ApiError> {
    let unit = Unit::parse(&request.unit).ok_or(ApiError::BadRequest("unit must be kg or lb"))?;
    let grams = unit
        .to_grams(request.value)
        .ok_or(ApiError::BadRequest("that is not a weight: use one between 20 and 400 kg"))?;
    if request.measured_at > (state.now)() + chrono::Duration::days(1) {
        return Err(ApiError::BadRequest("measured_at is in the future"));
    }
    let weigh_in = db::StoredWeighIn { id: request.id, measured_at: request.measured_at, grams: grams as i32, unit };
    if db::insert_weigh_in(&state.pool, &weigh_in, device.session_id).await? {
        // The weight itself is not logged; it is the owner's.
        tracing::info!(id = %weigh_in.id, "weigh-in recorded");
    }
    Ok(Json(home_now(&state).await?))
}

// --- Food ----------------------------------------------------------------

#[derive(Deserialize)]
struct FoodEntryRequest {
    /// Made on the phone when the meal is tapped. Sending the same entry
    /// again changes nothing.
    id: Uuid,
    eaten_at: DateTime<Utc>,
    /// The saved meal that was eaten.
    meal_id: Uuid,
    /// Portions of it; one when left out.
    servings: Option<f64>,
}

/// Logs a saved meal tapped on the phone and answers with Home as it now
/// stands: the day against its targets, and the logging streak. The name
/// and figures are taken from the recipe as it stands now and kept with
/// the entry.
async fn record_food_entry(
    State(state): State<AppState>,
    device: Device,
    Json(request): Json<FoodEntryRequest>,
) -> Result<Json<HomeResponse>, ApiError> {
    let servings = request.servings.unwrap_or(1.0);
    if !food::servings_make_sense(servings) {
        return Err(ApiError::BadRequest("servings must be above 0 and at most 10"));
    }
    if request.eaten_at > (state.now)() + chrono::Duration::days(1) {
        return Err(ApiError::BadRequest("eaten_at is in the future"));
    }
    // A meal removed since it was tapped is still logged: it was eaten.
    let meal = db::saved_meal(&state.pool, request.meal_id)
        .await?
        .ok_or(ApiError::BadRequest("no saved meal has this meal_id"))?;
    let entry = db::StoredFoodEntry {
        id: request.id,
        eaten_at: request.eaten_at,
        slot: meal.slot,
        meal_id: Some(meal.id),
        name: meal.name.clone(),
        servings,
        amount: meal.amount(servings),
    };
    if db::insert_food_entry(&state.pool, &entry, device.session_id).await? {
        // What was eaten is not logged; it is the owner's.
        tracing::info!(id = %entry.id, "food entry recorded");
    }
    Ok(Json(home_now(&state).await?))
}

/// Takes a logged meal back, for a tap that was a slip. Taking back an
/// entry that is already gone changes nothing.
async fn remove_food_entry(
    State(state): State<AppState>,
    _device: Device,
    Path(id): Path<Uuid>,
) -> Result<Json<HomeResponse>, ApiError> {
    if db::remove_food_entry(&state.pool, id).await? {
        tracing::info!(%id, "food entry taken back");
    }
    Ok(Json(home_now(&state).await?))
}

#[derive(Deserialize)]
struct MealRequest {
    name: String,
    /// "breakfast", "lunch", "dinner" or "snack".
    slot: String,
    /// Portions the weighed recipe makes.
    portions: u32,
    ingredients: Vec<IngredientRequest>,
}

#[derive(Deserialize)]
struct IngredientRequest {
    name: String,
    /// As weighed.
    grams: f64,
    /// From the label.
    kcal_per_100g: f64,
    protein_per_100g: f64,
}

/// Stores a saved meal under the id the phone made for it, replacing the
/// recipe when it is already stored. Entries already logged keep the
/// figures they were logged with.
async fn save_meal(
    State(state): State<AppState>,
    _device: Device,
    Path(id): Path<Uuid>,
    Json(request): Json<MealRequest>,
) -> Result<Json<HomeResponse>, ApiError> {
    let slot = Slot::parse(&request.slot).ok_or(ApiError::BadRequest("slot must be breakfast, lunch, dinner or snack"))?;
    let ingredients = request
        .ingredients
        .into_iter()
        .map(|i| food::Ingredient {
            name: i.name,
            grams: i.grams,
            kcal_per_100g: i.kcal_per_100g,
            protein_per_100g: i.protein_per_100g,
        })
        .collect();
    let meal = food::SavedMeal::new(id, &request.name, slot, request.portions, ingredients).map_err(ApiError::BadRequest)?;
    db::upsert_saved_meal(&state.pool, &meal).await?;
    tracing::info!(%id, ingredients = meal.ingredients.len(), "saved meal stored");
    Ok(Json(home_now(&state).await?))
}

/// Takes a saved meal out of the list. What was logged from it stays.
async fn remove_meal(
    State(state): State<AppState>,
    _device: Device,
    Path(id): Path<Uuid>,
) -> Result<Json<HomeResponse>, ApiError> {
    if db::archive_saved_meal(&state.pool, id).await? {
        tracing::info!(%id, "saved meal removed");
    }
    Ok(Json(home_now(&state).await?))
}

#[derive(Deserialize)]
struct FoodTargetsRequest {
    kcal: u32,
    protein_g: u32,
}

/// Sets the calorie and protein targets from today on. Earlier days keep
/// the target they were held to. Only the owner sets these; lyfe never
/// changes a target by itself.
async fn set_food_targets(
    State(state): State<AppState>,
    _device: Device,
    Json(request): Json<FoodTargetsRequest>,
) -> Result<Json<HomeResponse>, ApiError> {
    let today = (state.now)().with_timezone(&state.timezone).date_naive();
    let target = food::Target::new(today, request.kcal, request.protein_g).map_err(ApiError::BadRequest)?;
    db::set_food_target(&state.pool, &target).await?;
    // The figures are not logged; they are the owner's.
    tracing::info!("food targets set");
    Ok(Json(home_now(&state).await?))
}

/// Asks Garmin for new activities now, unless that was just done. The app
/// calls this when opened so a freshly synced watch shows up at once.
async fn sync_now(State(state): State<AppState>, _device: Device) -> Result<Json<Sources>, ApiError> {
    state.syncer.poll_if_stale((state.now)(), REFRESH_MIN_AGE).await;
    Ok(Json(Sources { garmin: garmin_status(&state).await? }))
}
