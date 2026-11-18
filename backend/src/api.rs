//! The HTTP API the apps use. Everything except the health check and
//! sign-in needs a device token.

use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::extract::{FromRequestParts, State};
use axum::http::request::Parts;
use axum::http::{header, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use chrono::{DateTime, Datelike, NaiveDate, Utc};
use serde::{Deserialize, Serialize};
use serde_json::json;
use sqlx::PgPool;

use crate::auth::{self, SignInThrottle};
use crate::db;
use crate::garmin::sync::{Syncer, SOURCE as GARMIN};
use crate::routines::gym::{self, GymRules, GymSession, GymStreak, Week};

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
    sources: Sources,
    notifications: Notifications,
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
    let now = (state.now)();
    let today = now.with_timezone(&state.timezone).date_naive();
    let week = Week::containing(today);
    let activities = db::activities_until(&state.pool, week.ends_on).await?;
    let sessions = gym::sessions_in_week(&state.gym_rules, week, &activities);
    let streak = gym::streak(&state.gym_rules, today, &activities);
    let done = sessions.len() as u32;
    Ok(Json(HomeResponse {
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
        sources: Sources { garmin: garmin_status(&state).await? },
        notifications: Notifications { server_ready: state.push_ready },
    }))
}

/// Asks Garmin for new activities now, unless that was just done. The app
/// calls this when opened so a freshly synced watch shows up at once.
async fn sync_now(State(state): State<AppState>, _device: Device) -> Result<Json<Sources>, ApiError> {
    state.syncer.poll_if_stale((state.now)(), REFRESH_MIN_AGE).await;
    Ok(Json(Sources { garmin: garmin_status(&state).await? }))
}
