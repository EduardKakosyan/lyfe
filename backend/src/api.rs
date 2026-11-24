//! The HTTP API the apps use. Everything except the health check and
//! sign-in needs a device token.

use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::extract::{DefaultBodyLimit, FromRequestParts, Path, Query, State};
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
mod goals;
mod money;
mod progress;

use crate::auth::{self, SignInThrottle};
use crate::db;
use crate::garmin::sync::{Syncer, SOURCE as GARMIN};
use crate::money::sync::Importer;
use crate::routines::breath::{self, BreathRules};
use crate::routines::food::{self, FoodDay, Slot};
use crate::routines::illustration;
use crate::routines::photo::{self, Oil};
use crate::routines::product::{self, Product};
use crate::routines::study::{self, StudyRules, StudyWeek};
use crate::routines::gym::{self, GymRules, GymSession, GymStreak, Week};
use crate::routines::weekly::WeekStreak;
use crate::routines::weight::{self, Unit, WeightSettings, WeightTrend};

/// How recent a Garmin poll must be for an app refresh to skip polling again.
const REFRESH_MIN_AGE: Duration = Duration::from_secs(30);
/// The largest request a photo meal can be: the photo, as base64, and a line.
const PHOTO_BODY_LIMIT: usize = photo::MAX_PHOTO_BYTES / 3 * 4 + 64 * 1024;
/// Packaged food the apps are sent, so a code scanned again can be looked
/// up without a connection.
const RECENT_PRODUCTS: i64 = 40;

pub type Clock = Arc<dyn Fn() -> DateTime<Utc> + Send + Sync>;

#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    pub syncer: Arc<Syncer>,
    pub throttle: Arc<SignInThrottle>,
    pub timezone: chrono_tz::Tz,
    pub gym_rules: Arc<GymRules>,
    pub breath_rules: Arc<BreathRules>,
    pub study_rules: Arc<StudyRules>,
    pub weight: WeightSettings,
    /// Whether this server can send notifications (it has Apple's key).
    pub push_ready: bool,
    /// How far either way a photo estimate may be, in percent.
    pub estimate_range_pct: u32,
    /// Wakes the photo estimator when a photo meal arrives.
    pub estimator_wake: Arc<tokio::sync::Notify>,
    /// Wakes the illustrator when a photo can be drawn: it arrives, or the
    /// built meal it is a part of does.
    pub illustrator_wake: Arc<tokio::sync::Notify>,
    /// Whether this server draws the icons of the foods in the ingredient
    /// catalogue: it does while the illustrator is on.
    pub food_icons: bool,
    /// Imports accounts and transactions from the bridge.
    pub money: Arc<Importer>,
    /// The currency money is totalled in, when set; otherwise the one most
    /// accounts are in.
    pub money_currency: Option<String>,
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
        .route("/v1/progress", post(progress::record))
        .route("/v1/breath/sessions", post(record_breath_session))
        .route("/v1/study/sessions", post(record_study_session))
        .route("/v1/weigh-ins", post(record_weigh_in))
        .route("/v1/food/entries", post(record_food_entry))
        .route("/v1/food/entries/{id}", delete(remove_food_entry))
        .route(
            "/v1/food/photo-entries",
            post(record_photo_entry).layer(DefaultBodyLimit::max(PHOTO_BODY_LIMIT)),
        )
        .route("/v1/food/barcode-entries", post(record_barcode_entry))
        .route("/v1/food/typed-entries", post(record_typed_entry))
        .route("/v1/food/built-entries", post(record_built_meal))
        .route("/v1/food/entries/{id}/estimate", put(correct_estimate))
        .route("/v1/food/entries/{id}/photo", get(food_photo))
        .route("/v1/food/entries/{id}/illustration", get(food_illustration))
        .route("/v1/food/icons", get(food_icon))
        .route("/v1/food/products/{code}", get(find_product).put(set_product))
        .route("/v1/food/meals/{id}", put(save_meal).delete(remove_meal))
        .route("/v1/food/targets", put(set_food_targets))
        .route("/v1/goals/{id}", put(goals::set))
        .route("/v1/goals/{id}/status", post(goals::set_status))
        .route("/v1/goals/{id}/scores", post(goals::record_practice))
        .route("/v1/goals/{id}/result", post(goals::record_result))
        .route("/v1/money", get(money::month))
        .route("/v1/money/entries/{id}/sort", post(money::sort))
        .route("/v1/money/accounts/{id}", put(money::set_account))
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
    NotFound,
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
            ApiError::NotFound => (StatusCode::NOT_FOUND, "not_found"),
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
    progress: progress::Progress,
    #[serde(serialize_with = "seconds::required")]
    generated_at: DateTime<Utc>,
    today: NaiveDate,
    week: Week,
    gym: GymWeek,
    breath: BreathWeek,
    study: StudyWeek,
    goals: crate::routines::goals::GoalsView,
    weight: WeightTrend,
    food: FoodDay,
    /// Missing while no bank is set up and nothing was ever imported.
    #[serde(skip_serializing_if = "Option::is_none")]
    money: Option<money::Glance>,
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
        progress: progress::snapshot(state, today).await?,
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
        study: study::week(&state.study_rules, today, &db::study_sessions(&state.pool, state.timezone).await?),
        goals: goals::snapshot(state, today).await?,
        weight: weight::trend(&state.weight, today, &db::weigh_ins(&state.pool, state.timezone).await?),
        food: food_day(state, now, today).await?,
        money: money::glance(state).await?,
        sources: Sources { garmin: garmin_status(state).await? },
        notifications: Notifications { server_ready: state.push_ready },
    })
}

/// Food as the apps show it today.
async fn food_day(state: &AppState, now: DateTime<Utc>, today: NaiveDate) -> Result<FoodDay, ApiError> {
    // What a photo showed is read only for the days the apps show.
    let items_since = now - chrono::Duration::days(2);
    let mut day = food::day(
        today,
        &db::saved_meals(&state.pool).await?,
        &db::food_entries(&state.pool, state.timezone, items_since).await?,
        &db::food_targets(&state.pool).await?,
        state.estimate_range_pct,
    );
    day.drafts = food::draft_views(&db::draft_parts(&state.pool, state.timezone).await?, state.estimate_range_pct);
    day.products = db::recent_products(&state.pool, RECENT_PRODUCTS).await?;
    day.icon_look = state.food_icons.then_some(illustration::ICON_LOOK);
    Ok(day)
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

// --- Study sessions ------------------------------------------------------

#[derive(Deserialize)]
struct StudySessionRequest {
    /// Made on the phone when the timer starts. Sending the same session
    /// again changes nothing.
    id: Uuid,
    started_at: DateTime<Utc>,
    ended_at: DateTime<Utc>,
    /// Seconds on the timer, less any pause.
    active_s: u32,
    /// The subject by name; a new name is a new subject.
    subject: String,
    /// `questions`, `reading` or `build`.
    kind: String,
    answered: Option<u32>,
    right_first: Option<u32>,
    /// What was built and why, for a build session.
    explain_back: Option<String>,
}

/// The longest a session can be, start to end.
const STUDY_LONGEST_S: i64 = 24 * 3600;
/// The longest explain-back kept, in characters.
const EXPLAIN_BACK_LONGEST: usize = 4000;

/// Stores a session timed on the phone and answers with Home as it now
/// stands: the week and the streak.
async fn record_study_session(
    State(state): State<AppState>,
    device: Device,
    Json(request): Json<StudySessionRequest>,
) -> Result<Json<HomeResponse>, ApiError> {
    let span = (request.ended_at - request.started_at).num_seconds();
    if span < 0 {
        return Err(ApiError::BadRequest("ended_at is before started_at"));
    }
    if span > STUDY_LONGEST_S {
        return Err(ApiError::BadRequest("a session is at most a day long"));
    }
    if request.started_at > (state.now)() + chrono::Duration::days(1) {
        return Err(ApiError::BadRequest("started_at is in the future"));
    }
    // A minute's grace for clocks read a moment apart.
    if i64::from(request.active_s) > span + 60 {
        return Err(ApiError::BadRequest("active_s is longer than the session"));
    }
    let Some(subject) = study::subject_name(&request.subject) else {
        return Err(ApiError::BadRequest("a subject is 1 to 60 characters"));
    };
    let Some(kind) = study::Kind::parse(&request.kind) else {
        return Err(ApiError::BadRequest("kind is questions, reading or build"));
    };
    if request.answered.is_some_and(|answered| answered > 1000) {
        return Err(ApiError::BadRequest("answered is at most 1000"));
    }
    match (request.answered, request.right_first) {
        (None, Some(_)) => return Err(ApiError::BadRequest("right_first needs answered")),
        (Some(answered), Some(right)) if right > answered => {
            return Err(ApiError::BadRequest("right_first is more than answered"))
        }
        _ => {}
    }
    let explain_back = request
        .explain_back
        .as_deref()
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(str::to_string);
    if explain_back.as_ref().is_some_and(|text| text.chars().count() > EXPLAIN_BACK_LONGEST) {
        return Err(ApiError::BadRequest("an explain-back is at most 4000 characters"));
    }
    let session = db::StoredStudySession {
        id: request.id,
        started_at: request.started_at,
        ended_at: request.ended_at,
        active_s: request.active_s as i32,
        subject,
        kind,
        answered: request.answered.map(|n| n as i32),
        right_first: request.right_first.map(|n| n as i32),
        explain_back,
    };
    if db::insert_study_session(&state.pool, &session, device.session_id).await? {
        tracing::info!(id = %session.id, minutes = session.active_s / 60, kind = kind.as_str(), "study session recorded");
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
        carbs_g: meal.ingredients.iter().map(|i| i.carbs_g).sum::<Option<f64>>().map(|g| g * servings / meal.portions as f64),
        fat_g: meal.ingredients.iter().map(|i| i.fat_g).sum::<Option<f64>>().map(|g| g * servings / meal.portions as f64),
        amount: meal.amount(servings),
        estimated: meal.estimated(servings),
    };
    if db::insert_food_entry(&state.pool, &entry, device.session_id).await? {
        // What was eaten is not logged; it is the owner's.
        tracing::info!(id = %entry.id, "food entry recorded");
    }
    Ok(Json(home_now(&state).await?))
}

/// Takes a logged meal back, for a tap that was a slip, or takes one part
/// out of a built meal. A built meal goes with its parts, and with its last
/// part. Taking back an entry that is already gone changes nothing.
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
struct PhotoEntryRequest {
    /// Made on the phone when the photo is taken. Sending the same meal
    /// again changes nothing.
    id: Uuid,
    eaten_at: DateTime<Utc>,
    /// "breakfast", "lunch", "dinner" or "snack".
    slot: String,
    /// The one line typed with it.
    #[serde(default)]
    note: String,
    /// The photo, a JPEG, in base64. A meal can be described without one.
    photo_jpeg: Option<String>,
    /// The built meal this is a part of. It may not have arrived yet: a
    /// photo is sent while its meal is still being put together.
    part_of: Option<Uuid>,
}

/// Where an arriving part goes: at its meal's time and slot once that meal
/// is logged, or as sent while it is not.
struct Place {
    eaten_at: DateTime<Utc>,
    slot: Slot,
    position: i32,
}

/// Places a part. `ahead` says whether it may arrive before its meal, as
/// only a photo does.
async fn place(
    state: &AppState,
    part_of: Option<Uuid>,
    eaten_at: DateTime<Utc>,
    slot: Slot,
    ahead: bool,
) -> Result<Place, ApiError> {
    let as_sent = Place { eaten_at, slot, position: 0 };
    let Some(meal) = part_of else {
        return Ok(as_sent);
    };
    match db::meal_of_part(&state.pool, meal).await? {
        db::MealOfPart::Logged { eaten_at, slot, next_position } => Ok(Place { eaten_at, slot, position: next_position }),
        db::MealOfPart::NotArrived if ahead => Ok(as_sent),
        db::MealOfPart::NotArrived | db::MealOfPart::Unusable => {
            Err(ApiError::BadRequest("no logged meal has this part_of id"))
        }
    }
}

/// Logs a meal from a photo and one line, and answers with Home as it now
/// stands. The meal counts for the day at once; its figures follow when
/// the model on the Spark has estimated it. Sent as a part of a meal that
/// has not arrived, it is estimated all the same and counts once the meal
/// does.
async fn record_photo_entry(
    State(state): State<AppState>,
    device: Device,
    Json(request): Json<PhotoEntryRequest>,
) -> Result<Json<HomeResponse>, ApiError> {
    let slot = Slot::parse(&request.slot).ok_or(ApiError::BadRequest("slot must be breakfast, lunch, dinner or snack"))?;
    let note = photo::clean_note(&request.note).map_err(ApiError::BadRequest)?;
    let jpeg = match &request.photo_jpeg {
        Some(text) => {
            let bytes = base64::Engine::decode(&base64::engine::general_purpose::STANDARD, text.trim())
                .map_err(|_| ApiError::BadRequest("photo_jpeg must be base64"))?;
            if bytes.len() > photo::MAX_PHOTO_BYTES {
                return Err(ApiError::BadRequest("the photo is too large"));
            }
            if !photo::is_jpeg(&bytes) {
                return Err(ApiError::BadRequest("the photo must be a JPEG"));
            }
            Some(bytes)
        }
        None => None,
    };
    if jpeg.is_none() && note.is_empty() {
        return Err(ApiError::BadRequest("a photo meal needs a photo or a line saying what it was"));
    }
    if request.eaten_at > (state.now)() + chrono::Duration::days(1) {
        return Err(ApiError::BadRequest("eaten_at is in the future"));
    }
    let place = place(&state, request.part_of, request.eaten_at, slot, true).await?;
    let entry = db::NewPhotoEntry {
        id: request.id,
        eaten_at: place.eaten_at,
        slot: place.slot,
        note,
        jpeg,
        part_of: request.part_of,
        position: place.position,
    };
    if db::insert_photo_entry(&state.pool, &entry, device.session_id).await? {
        // What was eaten is not logged; it is the owner's.
        tracing::info!(id = %entry.id, photo = entry.jpeg.is_some(), part = entry.part_of.is_some(), "photo meal recorded");
        state.estimator_wake.notify_one();
        state.illustrator_wake.notify_one();
        if entry.part_of.is_some() {
            let dropped = db::drop_stale_drafts(&state.pool).await?;
            if dropped > 0 {
                tracing::info!(dropped, "photos for meals never logged were dropped");
            }
        }
    }
    Ok(Json(home_now(&state).await?))
}

#[derive(Deserialize)]
struct BarcodeEntryRequest {
    /// Made on the phone when the code is scanned. Sending the same meal
    /// again changes nothing.
    id: Uuid,
    eaten_at: DateTime<Utc>,
    slot: String,
    code: String,
    /// What was eaten, in grams.
    grams: f64,
    /// The logged built meal this joins as a part.
    part_of: Option<Uuid>,
}

/// Logs packaged food by its barcode and the grams eaten, and answers with
/// Home as it now stands. The figures come from the label: the one the
/// owner typed, else the food database's. A code neither has is logged
/// and waits for the owner to type its label.
async fn record_barcode_entry(
    State(state): State<AppState>,
    device: Device,
    Json(request): Json<BarcodeEntryRequest>,
) -> Result<Json<HomeResponse>, ApiError> {
    let slot = Slot::parse(&request.slot).ok_or(ApiError::BadRequest("slot must be breakfast, lunch, dinner or snack"))?;
    let code = product::normalize_code(&request.code).ok_or(ApiError::BadRequest("a barcode is 8 to 14 digits"))?;
    if !product::grams_make_sense(request.grams) {
        return Err(ApiError::BadRequest("grams must be above 0 and at most 3000"));
    }
    if request.eaten_at > (state.now)() + chrono::Duration::days(1) {
        return Err(ApiError::BadRequest("eaten_at is in the future"));
    }
    let place = place(&state, request.part_of, request.eaten_at, slot, false).await?;
    let product = db::product(&state.pool, &code).await?;
    let known = product.is_some();
    let entry = db::NewBarcodeEntry {
        id: request.id,
        eaten_at: place.eaten_at,
        slot: place.slot,
        code,
        grams: request.grams,
        product,
        part_of: request.part_of,
        position: place.position,
    };
    if db::insert_barcode_entry(&state.pool, &entry, device.session_id).await? {
        tracing::info!(id = %entry.id, known, "barcode meal recorded");
    }
    Ok(Json(home_now(&state).await?))
}

/// A food as typed: weighed, with `grams` and the label's two figures per
/// 100 g, or whole, with `kcal` and `protein_g`.
#[derive(Deserialize)]
struct TypedFood {
    carbs_g: Option<f64>,
    fat_g: Option<f64>,
    name: String,
    grams: Option<f64>,
    kcal_per_100g: Option<f64>,
    protein_per_100g: Option<f64>,
    kcal: Option<f64>,
    protein_g: Option<f64>,
    /// For a saved meal's ingredient: what a photo was estimated at.
    #[serde(default)]
    estimated: bool,
    /// For a saved meal's ingredient: the barcode it was scanned from.
    code: Option<String>,
}

impl TypedFood {
    /// The food, checked, or what is wrong with it.
    fn read(self) -> Result<food::Ingredient, &'static str> {
        let quantity = match (self.grams, self.kcal_per_100g, self.protein_per_100g, self.kcal, self.protein_g) {
            (Some(grams), Some(kcal_per_100g), Some(protein_per_100g), None, None) => {
                food::Quantity::Weighed { grams, kcal_per_100g, protein_per_100g }
            }
            (None, None, None, Some(kcal), Some(protein_g)) => food::Quantity::Whole { kcal, protein_g },
            _ => return Err("give grams, kcal_per_100g and protein_per_100g, or kcal and protein_g"),
        };
        food::Ingredient { name: self.name, quantity, carbs_g: self.carbs_g, fat_g: self.fat_g, estimated: self.estimated, code: self.code }.checked()
    }
}

#[derive(Deserialize)]
struct TypedEntryRequest {
    /// Made on the phone when the food is typed. Sending the same entry
    /// again changes nothing.
    id: Uuid,
    eaten_at: DateTime<Utc>,
    slot: String,
    #[serde(flatten)]
    food: TypedFood,
    /// The logged built meal this joins as a part.
    part_of: Option<Uuid>,
}

/// Logs a food the owner typed, weighed with its label's figures or just
/// what it came to, and answers with Home as it now stands. Typed figures
/// are measured.
async fn record_typed_entry(
    State(state): State<AppState>,
    device: Device,
    Json(request): Json<TypedEntryRequest>,
) -> Result<Json<HomeResponse>, ApiError> {
    let slot = Slot::parse(&request.slot).ok_or(ApiError::BadRequest("slot must be breakfast, lunch, dinner or snack"))?;
    let food = request.food.read().map_err(ApiError::BadRequest)?;
    if request.eaten_at > (state.now)() + chrono::Duration::days(1) {
        return Err(ApiError::BadRequest("eaten_at is in the future"));
    }
    let place = place(&state, request.part_of, request.eaten_at, slot, false).await?;
    let entry = db::NewTypedEntry {
        id: request.id,
        eaten_at: place.eaten_at,
        slot: place.slot,
        food,
        part_of: request.part_of,
        position: place.position,
    };
    if db::insert_typed_entry(&state.pool, &entry, device.session_id).await? {
        tracing::info!(id = %entry.id, "typed food recorded");
    }
    Ok(Json(home_now(&state).await?))
}

#[derive(Deserialize)]
struct BuiltMealRequest {
    /// Made on the phone when the meal is started. Sending the same meal
    /// again changes nothing.
    id: Uuid,
    eaten_at: DateTime<Utc>,
    slot: String,
    /// What the meal is called; the part of the day when left out.
    #[serde(default)]
    name: String,
    /// In the order added.
    parts: Vec<PartRequest>,
}

/// One part of a built meal. With a `code` it was scanned and needs its
/// `grams`; with a `name` it was typed, weighed or whole; with neither it
/// is a photo sent ahead under this id as a part of this meal.
#[derive(Deserialize)]
struct PartRequest {
    carbs_g: Option<f64>,
    fat_g: Option<f64>,
    id: Uuid,
    code: Option<String>,
    name: Option<String>,
    grams: Option<f64>,
    kcal_per_100g: Option<f64>,
    protein_per_100g: Option<f64>,
    kcal: Option<f64>,
    protein_g: Option<f64>,
}

/// Logs a meal built from parts, scanned, typed and photographed, as one
/// meal, and answers with Home as it now stands. Each part keeps its own
/// figures: a label's are measured, a photo's estimated, and one not known
/// yet is left out of the total until it is.
async fn record_built_meal(
    State(state): State<AppState>,
    device: Device,
    Json(request): Json<BuiltMealRequest>,
) -> Result<Json<HomeResponse>, ApiError> {
    let slot = Slot::parse(&request.slot).ok_or(ApiError::BadRequest("slot must be breakfast, lunch, dinner or snack"))?;
    let name = match request.name.trim() {
        "" => slot.title().to_string(),
        name if name.chars().count() <= food::MAX_NAME_CHARS => name.to_string(),
        _ => return Err(ApiError::BadRequest("the meal's name must be at most 60 characters")),
    };
    if request.parts.is_empty() || request.parts.len() > food::MAX_INGREDIENTS {
        return Err(ApiError::BadRequest("a meal has 1 to 40 parts"));
    }
    if request.eaten_at > (state.now)() + chrono::Duration::days(1) {
        return Err(ApiError::BadRequest("eaten_at is in the future"));
    }
    let mut parts = Vec::with_capacity(request.parts.len());
    for part in request.parts {
        parts.push(match (part.code, part.name) {
            (Some(code), _) => {
                let code = product::normalize_code(&code).ok_or(ApiError::BadRequest("a barcode is 8 to 14 digits"))?;
                let grams = part.grams.filter(|grams| product::grams_make_sense(*grams));
                let grams = grams.ok_or(ApiError::BadRequest("a scanned part's grams must be above 0 and at most 3000"))?;
                let product = db::product(&state.pool, &code).await?;
                db::NewPart::Barcode { id: part.id, code, grams, product }
            }
            (None, Some(name)) => {
                let food = TypedFood {
                    name,
                    carbs_g: part.carbs_g, fat_g: part.fat_g,
                    grams: part.grams,
                    kcal_per_100g: part.kcal_per_100g,
                    protein_per_100g: part.protein_per_100g,
                    kcal: part.kcal,
                    protein_g: part.protein_g,
                    estimated: false,
                    code: None,
                };
                db::NewPart::Typed { id: part.id, food: food.read().map_err(ApiError::BadRequest)? }
            }
            (None, None) => db::NewPart::Photo { id: part.id },
        });
    }
    let meal = db::NewBuiltMeal { id: request.id, eaten_at: request.eaten_at, slot, name, parts };
    if db::insert_built_meal(&state.pool, &meal, device.session_id).await? {
        // What was eaten is not logged; it is the owner's.
        tracing::info!(id = %meal.id, parts = meal.parts.len(), "built meal recorded");
        // Its photos, sent ahead, are on a day now and can be drawn.
        state.illustrator_wake.notify_one();
    }
    Ok(Json(home_now(&state).await?))
}

#[derive(Deserialize)]
struct EstimateRequest {
    /// The grams of each item the model saw, in its order.
    grams: Option<Vec<f64>>,
    /// "none", "some" or "a_lot", for a meal asked about.
    oil: Option<String>,
    /// Figures for the whole meal, typed instead of the model's.
    kcal: Option<u32>,
    protein_g: Option<f64>,
}

/// Corrects a photo meal: the grams of what the model saw and how much oil
/// or sauce went in, or figures the owner types instead of the model's,
/// for a meal it could not estimate or got wrong. Answers with Home.
async fn correct_estimate(
    State(state): State<AppState>,
    _device: Device,
    Path(id): Path<Uuid>,
    Json(request): Json<EstimateRequest>,
) -> Result<Json<HomeResponse>, ApiError> {
    let mut meal = db::photo_meal(&state.pool, id).await?.ok_or(ApiError::NotFound)?;
    let amount = match (request.kcal, request.protein_g) {
        (Some(kcal), Some(protein_g)) => {
            let amount = photo::typed(kcal, protein_g).map_err(ApiError::BadRequest)?;
            meal.typed = true;
            amount
        }
        (None, None) => {
            if meal.items.is_empty() {
                return Err(ApiError::BadRequest("the model has not estimated this meal; type its figures instead"));
            }
            if let Some(grams) = &request.grams {
                meal.items = photo::correct(&meal.items, grams).map_err(ApiError::BadRequest)?;
            }
            if let Some(oil) = &request.oil {
                if !meal.oil_asked {
                    return Err(ApiError::BadRequest("this meal was not asked about oil"));
                }
                meal.oil = Some(Oil::parse(oil).ok_or(ApiError::BadRequest("oil must be none, some or a_lot"))?);
            }
            // Back to the model's figures, as corrected.
            meal.typed = false;
            photo::amount(&meal.items, meal.oil_asked, meal.oil)
        }
        _ => return Err(ApiError::BadRequest("give both kcal and protein_g, or neither")),
    };
    meal.figures = food::Figures::Known;
    db::correct_photo_meal(&state.pool, id, &meal, amount).await?;
    tracing::info!(%id, typed = meal.typed, "photo meal corrected");
    Ok(Json(home_now(&state).await?))
}

/// The photo of a meal, as the phone sent it.
async fn food_photo(State(state): State<AppState>, _device: Device, Path(id): Path<Uuid>) -> Result<Response, ApiError> {
    let jpeg = db::food_photo(&state.pool, id).await?.ok_or(ApiError::NotFound)?;
    Ok(([(header::CONTENT_TYPE, "image/jpeg"), (header::CACHE_CONTROL, "private, max-age=86400")], jpeg).into_response())
}

/// A meal's photo drawn as a Poster illustration, once it has been. Until
/// then, and for a meal never drawn, there is none and the app shows the
/// photo. The app may keep it: it changes only when the photo is drawn
/// again in a new look, which the meal's `illustration_version` says.
async fn food_illustration(State(state): State<AppState>, _device: Device, Path(id): Path<Uuid>) -> Result<Response, ApiError> {
    let png = db::food_illustration(&state.pool, id).await?.ok_or(ApiError::NotFound)?;
    Ok(([(header::CONTENT_TYPE, "image/png"), (header::CACHE_CONTROL, "private, no-cache")], png).into_response())
}

#[derive(Deserialize)]
struct IconQuery {
    /// The food's name, as the ingredient catalogue has it.
    name: String,
}

/// The icon of a food in the ingredient catalogue: a small drawing of it,
/// made on the Spark from its name. Asking is what gets it drawn: the
/// first time, and until it is, the answer is 202 and the app shows the
/// drawing it has for the food's category. The app may keep an icon for
/// as long as the day's `icon_look` stays what it was. Not found when this
/// server draws none, or the model could not draw this one.
async fn food_icon(State(state): State<AppState>, _device: Device, Query(query): Query<IconQuery>) -> Result<Response, ApiError> {
    let key = illustration::icon_key(&query.name).ok_or(ApiError::BadRequest("a food's name is 1 to 80 characters"))?;
    if !state.food_icons {
        return Err(ApiError::NotFound);
    }
    match db::ask_food_icon(&state.pool, &key, &query.name).await? {
        db::IconAsked::Drawn(png) => {
            Ok(([(header::CONTENT_TYPE, "image/png"), (header::CACHE_CONTROL, "private, no-cache")], png).into_response())
        }
        db::IconAsked::Waiting => {
            state.illustrator_wake.notify_one();
            Ok((StatusCode::ACCEPTED, Json(json!({ "state": "waiting" }))).into_response())
        }
        db::IconAsked::GivenUp => Err(ApiError::NotFound),
    }
}

/// The label lyfe has for a barcode: the one the owner typed, else the
/// food database's. Not found when neither has it.
async fn find_product(
    State(state): State<AppState>,
    _device: Device,
    Path(code): Path<String>,
) -> Result<Json<Product>, ApiError> {
    let code = product::normalize_code(&code).ok_or(ApiError::BadRequest("a barcode is 8 to 14 digits"))?;
    Ok(Json(db::product(&state.pool, &code).await?.ok_or(ApiError::NotFound)?))
}

#[derive(Deserialize)]
struct ProductRequest {
    name: String,
    kcal_per_100g: f64,
    protein_per_100g: f64,
    serving_g: Option<f64>,
}

/// Stores a label the owner typed for a barcode, which wins over the food
/// database's from then on, and gives meals waiting for it their figures.
/// Answers with Home.
async fn set_product(
    State(state): State<AppState>,
    _device: Device,
    Path(code): Path<String>,
    Json(request): Json<ProductRequest>,
) -> Result<Json<HomeResponse>, ApiError> {
    let product = Product::typed(&code, &request.name, request.kcal_per_100g, request.protein_per_100g, request.serving_g)
        .map_err(ApiError::BadRequest)?;
    let filled = db::set_owner_product(&state.pool, &product).await?;
    tracing::info!(filled, "label typed for a barcode");
    Ok(Json(home_now(&state).await?))
}

#[derive(Deserialize)]
struct MealRequest {
    name: String,
    /// "breakfast", "lunch", "dinner" or "snack".
    slot: String,
    /// Portions the weighed recipe makes.
    portions: u32,
    ingredients: Vec<TypedFood>,
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
        .map(TypedFood::read)
        .collect::<Result<Vec<_>, _>>()
        .map_err(ApiError::BadRequest)?;
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
