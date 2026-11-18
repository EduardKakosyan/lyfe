//! Drives the real router, database and Garmin client against a stand-in
//! Garmin server. Needs PostgreSQL: set DATABASE_URL (see README).

use std::path::PathBuf;
use std::sync::Arc;

use axum::body::Body;
use axum::http::{Request, StatusCode};
use chrono::{DateTime, Utc};
use http_body_util::BodyExt;
use serde_json::{json, Value};
use sqlx::PgPool;
use tower::ServiceExt;
use wiremock::matchers::{header, method, path, query_param};
use wiremock::{Mock, MockServer, ResponseTemplate};

use lyfe_server::api::{self, AppState};
use lyfe_server::auth::{self, SignInThrottle};
use lyfe_server::db;
use lyfe_server::garmin::sync::Syncer;
use lyfe_server::garmin::GarminClient;
use lyfe_server::routines::gym::GymRules;

const TOKEN_PATH: &str = "/personalapitoken-service/personal-api/personal-api-key/token";
const SEARCH_PATH: &str = "/activitylist-service/activities/search/activities";
const PASSWORD: &str = "a long test password";

struct Harness {
    state: AppState,
    garmin: MockServer,
    _key_dir: tempdir::Dir,
}

mod tempdir {
    //! A throwaway directory removed when dropped.
    use std::path::PathBuf;

    pub struct Dir(pub PathBuf);

    impl Dir {
        pub fn new() -> Self {
            let mut bytes = [0u8; 8];
            getrandom::fill(&mut bytes).unwrap();
            let name: String = bytes.iter().map(|b| format!("{b:02x}")).collect();
            let path = std::env::temp_dir().join(format!("lyfe-test-{name}"));
            std::fs::create_dir(&path).unwrap();
            Dir(path)
        }
    }

    impl Drop for Dir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
}

fn at(time: &str) -> DateTime<Utc> {
    time.parse().unwrap()
}

/// A harness whose clock reads Tuesday 17 November 2026, 11:00 in San Juan.
async fn harness(pool: PgPool) -> Harness {
    harness_at(pool, "2026-11-17T15:00:00Z", true).await
}

async fn harness_at(pool: PgPool, now: &str, with_key: bool) -> Harness {
    let garmin = MockServer::start().await;
    let key_dir = tempdir::Dir::new();
    let key_file: PathBuf = key_dir.0.join("api-key");
    std::fs::write(&key_file, "test-key\n").unwrap();
    let client = with_key.then(|| GarminClient::new(&garmin.uri(), key_file).unwrap());
    let now = at(now);
    let state = AppState {
        pool: pool.clone(),
        syncer: Arc::new(Syncer::new(pool, client, 180, 30)),
        throttle: Arc::new(SignInThrottle::new()),
        timezone: chrono_tz::America::Puerto_Rico,
        gym_rules: Arc::new(GymRules {
            counted_types: lyfe_server::config::parse_types(GymRules::DEFAULT_TYPES),
            min_duration_s: 15.0 * 60.0,
        }),
        breath_rules: Arc::new(lyfe_server::routines::breath::BreathRules::default()),
        // Kilograms here; pounds, the default, have their own test.
        weight: lyfe_server::routines::weight::WeightSettings {
            unit: lyfe_server::routines::weight::Unit::Kg,
            ..Default::default()
        },
        push_ready: false,
        now: Arc::new(move || now),
    };
    Harness { state, garmin, _key_dir: key_dir }
}

impl Harness {
    async fn mock_token(&self) {
        Mock::given(method("POST"))
            .and(path(TOKEN_PATH))
            .and(header("Authorization", "ApiKey test-key"))
            .respond_with(ResponseTemplate::new(200).set_body_string("header.payload.signature"))
            .mount(&self.garmin)
            .await;
    }

    /// Serves `activities` as the whole search result until replaced.
    async fn mock_activities(&self, activities: Value) {
        self.garmin.reset().await;
        self.mock_token().await;
        Mock::given(method("GET"))
            .and(path(SEARCH_PATH))
            .and(header("Authorization", "Bearer header.payload.signature"))
            .respond_with(ResponseTemplate::new(200).set_body_json(activities))
            .mount(&self.garmin)
            .await;
    }

    async fn poll(&self) -> lyfe_server::garmin::sync::SyncReport {
        self.state
            .syncer
            .poll_once((self.state.now)())
            .await
            .expect("garmin is configured")
            .expect("poll succeeds")
    }

    async fn request(&self, request: Request<Body>) -> (StatusCode, Value) {
        let response = api::router(self.state.clone()).oneshot(request).await.unwrap();
        let status = response.status();
        let bytes = response.into_body().collect().await.unwrap().to_bytes();
        let body = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
        (status, body)
    }

    async fn get(&self, uri: &str, token: Option<&str>) -> (StatusCode, Value) {
        let mut builder = Request::get(uri);
        if let Some(token) = token {
            builder = builder.header("Authorization", format!("Bearer {token}"));
        }
        self.request(builder.body(Body::empty()).unwrap()).await
    }

    async fn post(&self, uri: &str, token: Option<&str>, body: Option<Value>) -> (StatusCode, Value) {
        let mut builder = Request::post(uri);
        if let Some(token) = token {
            builder = builder.header("Authorization", format!("Bearer {token}"));
        }
        let body = match body {
            Some(json) => {
                builder = builder.header("Content-Type", "application/json");
                Body::from(json.to_string())
            }
            None => Body::empty(),
        };
        self.request(builder.body(body).unwrap()).await
    }

    async fn set_password(&self) {
        let hash = auth::hash_password(PASSWORD).unwrap();
        db::set_password_hash(&self.state.pool, &hash).await.unwrap();
    }

    async fn sign_in(&self) -> String {
        let (status, body) = self
            .post("/v1/auth/sign-in", None, Some(json!({"password": PASSWORD, "device_name": "test phone"})))
            .await;
        assert_eq!(status, StatusCode::OK, "{body}");
        body["token"].as_str().unwrap().to_string()
    }

    async fn signed_in(&self) -> String {
        self.set_password().await;
        self.sign_in().await
    }
}

fn activity(id: i64, type_key: &str, start_local: &str, minutes: f64) -> Value {
    // San Juan is UTC-4 in November.
    let local = chrono::NaiveDateTime::parse_from_str(start_local, "%Y-%m-%d %H:%M:%S").unwrap();
    let gmt = local + chrono::Duration::hours(4);
    json!({
        "activityId": id,
        "activityName": "Session",
        "startTimeLocal": start_local,
        "startTimeGMT": gmt.format("%Y-%m-%d %H:%M:%S").to_string(),
        "activityType": {"typeId": 13, "typeKey": type_key, "parentTypeId": 29},
        "duration": minutes * 60.0,
        "ownerFullName": "Test Owner"
    })
}

// --- Watch to Home screen ------------------------------------------------

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_strength_session_fills_a_square(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;

    h.mock_activities(json!([])).await;
    h.poll().await;
    let (status, home) = h.get("/v1/home", Some(&token)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(home["today"], "2026-11-17");
    assert_eq!(home["week"]["iso_week"], 47);
    assert_eq!(home["week"]["starts_on"], "2026-11-16");
    assert_eq!(home["week"]["ends_on"], "2026-11-22");
    assert_eq!(home["gym"]["target"], 4);
    assert_eq!(home["gym"]["done"], 0);
    assert_eq!(home["gym"]["remaining"], 4);
    assert_eq!(home["gym"]["days_left"], 6);
    assert_eq!(home["sources"]["garmin"]["state"], "ok");
    assert_eq!(home["generated_at"], "2026-11-17T15:00:00Z");
    let synced_at = home["sources"]["garmin"]["last_success_at"].as_str().unwrap();
    assert_eq!(synced_at.len(), "2026-11-17T15:00:00Z".len(), "whole seconds: {synced_at}");

    // The watch syncs a strength session; nothing is entered in lyfe.
    h.mock_activities(json!([activity(501, "strength_training", "2026-11-17 06:05:00", 58.0)])).await;
    let report = h.poll().await;
    assert_eq!((report.fetched, report.new), (1, 1));

    let (_, home) = h.get("/v1/home", Some(&token)).await;
    assert_eq!(home["gym"]["done"], 1);
    assert_eq!(home["gym"]["remaining"], 3);
    let session = &home["gym"]["sessions"][0];
    assert_eq!(session["date"], "2026-11-17");
    assert_eq!(session["activity_type"], "strength_training");
    assert_eq!(session["duration_min"], 58);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn polling_again_never_counts_a_session_twice(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    h.mock_activities(json!([
        activity(501, "strength_training", "2026-11-16 06:05:00", 58.0),
        activity(502, "strength_training", "2026-11-17 06:05:00", 61.0),
    ]))
    .await;
    assert_eq!(h.poll().await.new, 2);
    for _ in 0..3 {
        let report = h.poll().await;
        assert_eq!((report.fetched, report.new, report.gone), (2, 0, 0));
    }
    let (_, home) = h.get("/v1/home", Some(&token)).await;
    assert_eq!(home["gym"]["done"], 2);
    let stored: i64 = sqlx::query_scalar("select count(*) from garmin_activities")
        .fetch_one(&h.state.pool)
        .await
        .unwrap();
    assert_eq!(stored, 2);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn only_gym_sessions_of_this_week_count_and_a_day_counts_once(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    h.mock_activities(json!([
        activity(1, "strength_training", "2026-11-15 09:00:00", 60.0), // Sunday of last week
        activity(2, "walking", "2026-11-16 12:00:00", 45.0),           // not a gym type
        activity(3, "indoor_cycling", "2026-11-17 06:00:00", 16.0),    // warm-up, same day as 4
        activity(4, "strength_training", "2026-11-17 06:20:00", 55.0),
        activity(5, "strength_training", "2026-11-16 06:00:00", 2.0),  // accidental start
        activity(6, "lap_swimming", "2026-11-16 18:00:00", 35.0),
    ]))
    .await;
    h.poll().await;
    let (_, home) = h.get("/v1/home", Some(&token)).await;
    assert_eq!(home["gym"]["done"], 2);
    let ids: Vec<i64> = home["gym"]["sessions"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["activity_id"].as_i64().unwrap())
        .collect();
    assert_eq!(ids, vec![6, 4]);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn the_week_follows_the_owners_time_zone(pool: PgPool) {
    // 02:00 UTC on Monday 23 November is still Sunday evening in San Juan.
    let h = harness_at(pool, "2026-11-23T02:00:00Z", true).await;
    let token = h.signed_in().await;
    h.mock_activities(json!([activity(1, "strength_training", "2026-11-22 20:30:00", 50.0)])).await;
    h.poll().await;
    let (_, home) = h.get("/v1/home", Some(&token)).await;
    assert_eq!(home["today"], "2026-11-22");
    assert_eq!(home["week"]["iso_week"], 47);
    assert_eq!(home["gym"]["done"], 1);
    assert_eq!(home["gym"]["days_left"], 1);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn an_activity_deleted_in_garmin_empties_its_square(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    let monday = activity(1, "strength_training", "2026-11-16 06:00:00", 60.0);
    let tuesday = activity(2, "strength_training", "2026-11-17 06:00:00", 60.0);
    h.mock_activities(json!([monday, tuesday])).await;
    h.poll().await;

    h.mock_activities(json!([monday])).await;
    assert_eq!(h.poll().await.gone, 1);
    let (_, home) = h.get("/v1/home", Some(&token)).await;
    assert_eq!(home["gym"]["done"], 1);

    // An empty answer is not taken as "everything was deleted".
    h.mock_activities(json!([])).await;
    assert_eq!(h.poll().await.gone, 0);
    let (_, home) = h.get("/v1/home", Some(&token)).await;
    assert_eq!(home["gym"]["done"], 1);

    // If Garmin lists it again, it counts again.
    h.mock_activities(json!([monday, tuesday])).await;
    h.poll().await;
    let (_, home) = h.get("/v1/home", Some(&token)).await;
    assert_eq!(home["gym"]["done"], 2);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn first_poll_backfills_and_later_polls_use_the_short_window(pool: PgPool) {
    let h = harness(pool).await;
    h.mock_token().await;
    Mock::given(method("GET"))
        .and(path(SEARCH_PATH))
        .and(query_param("startDate", "2026-05-21")) // 180 days before 17 November
        .and(query_param("endDate", "2026-11-18"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!([activity(
            1,
            "strength_training",
            "2026-06-01 06:00:00",
            60.0
        )])))
        .expect(1)
        .mount(&h.garmin)
        .await;
    Mock::given(method("GET"))
        .and(path(SEARCH_PATH))
        .and(query_param("startDate", "2026-10-18")) // 30 days before
        .respond_with(ResponseTemplate::new(200).set_body_json(json!([])))
        .expect(1)
        .mount(&h.garmin)
        .await;
    assert_eq!(h.poll().await.new, 1);
    let second = h.poll().await;
    // The June activity is outside the short window and must not be marked gone.
    assert_eq!((second.fetched, second.gone), (0, 0));
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn long_histories_are_read_page_by_page(pool: PgPool) {
    let h = harness(pool).await;
    h.mock_token().await;
    let page = |from: i64, count: i64| -> Value {
        Value::Array(
            (from..from + count)
                .map(|i| activity(i, "walking", "2026-11-01 12:00:00", 30.0))
                .collect(),
        )
    };
    for (start, count) in [(0, 50), (50, 50), (100, 20)] {
        Mock::given(method("GET"))
            .and(path(SEARCH_PATH))
            .and(query_param("limit", "50"))
            .and(query_param("start", start.to_string()))
            .respond_with(ResponseTemplate::new(200).set_body_json(page(start, count)))
            .expect(1)
            .mount(&h.garmin)
            .await;
    }
    let report = h.poll().await;
    assert_eq!((report.fetched, report.new), (120, 120));
}

// --- Garmin token handling and failures ----------------------------------

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn the_access_token_is_reused_between_polls(pool: PgPool) {
    let h = harness(pool).await;
    Mock::given(method("POST"))
        .and(path(TOKEN_PATH))
        .respond_with(ResponseTemplate::new(200).set_body_string("header.payload.signature"))
        .expect(1)
        .mount(&h.garmin)
        .await;
    Mock::given(method("GET"))
        .and(path(SEARCH_PATH))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!([])))
        .expect(3)
        .mount(&h.garmin)
        .await;
    for _ in 0..3 {
        h.poll().await;
    }
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_revoked_token_is_replaced_once(pool: PgPool) {
    let h = harness(pool).await;
    Mock::given(method("POST"))
        .and(path(TOKEN_PATH))
        .respond_with(ResponseTemplate::new(200).set_body_string("old.token.value"))
        .up_to_n_times(1)
        .mount(&h.garmin)
        .await;
    Mock::given(method("POST"))
        .and(path(TOKEN_PATH))
        .respond_with(ResponseTemplate::new(200).set_body_string("new.token.value"))
        .mount(&h.garmin)
        .await;
    Mock::given(method("GET"))
        .and(path(SEARCH_PATH))
        .and(header("Authorization", "Bearer old.token.value"))
        .respond_with(ResponseTemplate::new(401))
        .mount(&h.garmin)
        .await;
    Mock::given(method("GET"))
        .and(path(SEARCH_PATH))
        .and(header("Authorization", "Bearer new.token.value"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!([activity(
            1,
            "strength_training",
            "2026-11-17 06:00:00",
            60.0
        )])))
        .mount(&h.garmin)
        .await;
    assert_eq!(h.poll().await.new, 1);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_rejected_key_is_reported_and_old_data_stays(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    h.mock_activities(json!([activity(1, "strength_training", "2026-11-17 06:00:00", 60.0)])).await;
    h.poll().await;

    // A fresh client (as after a restart) meets an expired key.
    let h2 = harness(h.state.pool.clone()).await;
    Mock::given(method("POST"))
        .and(path(TOKEN_PATH))
        .respond_with(ResponseTemplate::new(401).set_body_string("secret detail that must not be stored"))
        .mount(&h2.garmin)
        .await;
    let outcome = h2.state.syncer.poll_once((h2.state.now)()).await.unwrap();
    assert!(outcome.is_err());

    let (status, home) = h2.get("/v1/home", Some(&token)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(home["gym"]["done"], 1);
    let garmin = &home["sources"]["garmin"];
    assert_eq!(garmin["state"], "failing");
    assert!(garmin["message"].as_str().unwrap().contains("rejected the API key"));
    assert!(!garmin["message"].as_str().unwrap().contains("secret detail"));
    assert!(garmin["last_success_at"].is_string());
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn garmin_being_down_is_reported_without_losing_data(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    h.mock_token().await;
    Mock::given(method("GET"))
        .and(path(SEARCH_PATH))
        .respond_with(ResponseTemplate::new(503))
        .mount(&h.garmin)
        .await;
    assert!(h.state.syncer.poll_once((h.state.now)()).await.unwrap().is_err());
    let (_, home) = h.get("/v1/home", Some(&token)).await;
    assert_eq!(home["sources"]["garmin"]["state"], "failing");
    assert_eq!(home["sources"]["garmin"]["message"], "Garmin answered with HTTP 503");
    assert!(home["sources"]["garmin"]["last_success_at"].is_null());
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn without_a_key_file_the_server_still_answers(pool: PgPool) {
    let h = harness_at(pool, "2026-11-17T15:00:00Z", false).await;
    let token = h.signed_in().await;
    assert!(h.state.syncer.poll_once((h.state.now)()).await.is_none());
    let (status, sources) = h.post("/v1/sync", Some(&token), None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(sources["garmin"]["state"], "not_configured");
    let (status, home) = h.get("/v1/home", Some(&token)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(home["gym"]["done"], 0);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn the_app_can_ask_for_a_sync_but_not_hammer_garmin(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    h.mock_token().await;
    Mock::given(method("GET"))
        .and(path(SEARCH_PATH))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!([activity(
            1,
            "strength_training",
            "2026-11-17 06:00:00",
            60.0
        )])))
        .expect(1)
        .mount(&h.garmin)
        .await;
    // The recorded attempt time is the database's real "now", so move the
    // harness clock there for this test.
    let mut state = h.state.clone();
    state.now = Arc::new(Utc::now);
    let h = Harness { state, ..h };
    for _ in 0..3 {
        let (status, sources) = h.post("/v1/sync", Some(&token), None).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(sources["garmin"]["state"], "ok");
    }
}

// --- Sign-in -------------------------------------------------------------

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn nothing_is_readable_without_signing_in(pool: PgPool) {
    let h = harness(pool).await;
    for (status, _) in [
        h.get("/v1/home", None).await,
        h.get("/v1/home", Some("made-up-token")).await,
        h.post("/v1/sync", None, None).await,
        h.post("/v1/auth/sign-out", None, None).await,
    ] {
        assert_eq!(status, StatusCode::UNAUTHORIZED);
    }
    let (status, _) = h.get("/healthz", None).await;
    assert_eq!(status, StatusCode::OK);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn sign_in_needs_the_right_password(pool: PgPool) {
    let h = harness(pool).await;
    let attempt = json!({"password": PASSWORD, "device_name": "test phone"});

    let (status, body) = h.post("/v1/auth/sign-in", None, Some(attempt.clone())).await;
    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(body["error"], "no_password_set");

    h.set_password().await;
    let (status, body) = h
        .post("/v1/auth/sign-in", None, Some(json!({"password": "not the password", "device_name": "x"})))
        .await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(body["error"], "wrong_password");

    let (status, body) = h.post("/v1/auth/sign-in", None, Some(attempt)).await;
    assert_eq!(status, StatusCode::OK);
    let token = body["token"].as_str().unwrap();
    let (status, _) = h.get("/v1/home", Some(token)).await;
    assert_eq!(status, StatusCode::OK);

    // Only a hash of the token is stored.
    let stored: Vec<u8> = sqlx::query_scalar("select token_hash from device_sessions")
        .fetch_one(&h.state.pool)
        .await
        .unwrap();
    assert_eq!(stored, auth::token_hash(token));
    assert_ne!(stored, token.as_bytes());
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn signing_out_and_changing_the_password_end_sessions(pool: PgPool) {
    let h = harness(pool).await;
    let phone = h.signed_in().await;
    let mac = h.sign_in().await;

    let (status, _) = h.post("/v1/auth/sign-out", Some(&phone), None).await;
    assert_eq!(status, StatusCode::NO_CONTENT);
    assert_eq!(h.get("/v1/home", Some(&phone)).await.0, StatusCode::UNAUTHORIZED);
    assert_eq!(h.get("/v1/home", Some(&mac)).await.0, StatusCode::OK);

    h.set_password().await;
    assert_eq!(h.get("/v1/home", Some(&mac)).await.0, StatusCode::UNAUTHORIZED);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn repeated_wrong_passwords_are_slowed_down(pool: PgPool) {
    let h = harness(pool).await;
    h.set_password().await;
    let wrong = json!({"password": "not the password", "device_name": "x"});
    for _ in 0..5 {
        let (status, _) = h.post("/v1/auth/sign-in", None, Some(wrong.clone())).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
    }
    // Even the right password has to wait now.
    let (status, body) = h
        .post("/v1/auth/sign-in", None, Some(json!({"password": PASSWORD, "device_name": "x"})))
        .await;
    assert_eq!(status, StatusCode::TOO_MANY_REQUESTS);
    assert_eq!(body["error"], "too_many_attempts");
    assert!(body["retry_after_s"].as_u64().unwrap() >= 1);
}

// --- Streaks and recovery ------------------------------------------------

/// One 50-minute strength session on each of the first `count` days of
/// the week starting on `monday`.
fn week_of_sessions(monday: &str, count: u32) -> Vec<Value> {
    let monday: chrono::NaiveDate = monday.parse().unwrap();
    (0..count)
        .map(|day| {
            let on = monday + chrono::Duration::days(day as i64);
            let id = chrono::Datelike::num_days_from_ce(&on) as i64;
            activity(id, "strength_training", &format!("{on} 06:30:00"), 50.0)
        })
        .collect()
}

/// Weeks of sessions starting Monday 5 October 2026 (ISO week 41), one
/// count per week. Week 47 is the seventh.
fn history(counts: &[u32]) -> Value {
    let monday: chrono::NaiveDate = "2026-10-05".parse().unwrap();
    Value::Array(
        counts
            .iter()
            .enumerate()
            .flat_map(|(index, count)| {
                week_of_sessions(&(monday + chrono::Duration::days(7 * index as i64)).to_string(), *count)
            })
            .collect(),
    )
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn home_shows_the_streak_built_from_history(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    h.mock_activities(history(&[4, 5, 4, 4, 6, 4, 1])).await;
    h.poll().await;

    let (status, home) = h.get("/v1/home", Some(&token)).await;
    assert_eq!(status, StatusCode::OK);
    let streak = &home["gym"]["streak"];
    assert_eq!(streak["weeks"], 6);
    assert_eq!(streak["state"], "on_track");
    assert_eq!(streak["previous_best"], 0);
    assert_eq!(streak["remaining"], 3);
    // Tuesday with only Monday trained: Tuesday to Sunday are open.
    assert_eq!(streak["open_days"], 6);
    assert_eq!(streak["reachable"], true);
    let recent = streak["recent"].as_array().unwrap();
    assert_eq!(recent.len(), 6);
    assert_eq!(recent[0], json!({"iso_year": 2026, "iso_week": 41, "starts_on": "2026-10-05", "done": 4, "mark": "kept"}));
    assert_eq!(recent[5]["iso_week"], 46);
    assert_eq!(home["notifications"]["server_ready"], false);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_missed_week_is_recovered_by_the_next_and_two_end_the_streak(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;

    // Week 46 had two sessions; this week has one so far.
    h.mock_activities(history(&[4, 4, 4, 4, 4, 2, 1])).await;
    h.poll().await;
    let (_, home) = h.get("/v1/home", Some(&token)).await;
    let streak = &home["gym"]["streak"];
    assert_eq!((streak["weeks"].as_u64(), streak["state"].as_str()), (Some(5), Some("recovering")));
    assert_eq!(streak["recent"][5]["mark"], "awaiting_recovery");

    // Thursday evening, with four sessions this week: recovered, and the
    // week counts at once.
    let later = harness_at(h.state.pool.clone(), "2026-11-19T22:00:00Z", true).await;
    later.mock_activities(history(&[4, 4, 4, 4, 4, 2, 4])).await;
    later.poll().await;
    let (_, home) = later.get("/v1/home", Some(&token)).await;
    let streak = &home["gym"]["streak"];
    assert_eq!((streak["weeks"].as_u64(), streak["state"].as_str()), (Some(6), Some("kept")));
    assert_eq!(streak["recent"][5]["mark"], "recovered");

    // Had this week been missed too, the streak would have ended.
    let ended = harness_at(h.state.pool.clone(), "2026-11-23T15:00:00Z", true).await;
    ended.mock_activities(history(&[4, 4, 4, 4, 4, 2, 2])).await;
    ended.poll().await;
    let (_, home) = ended.get("/v1/home", Some(&token)).await;
    let streak = &home["gym"]["streak"];
    assert_eq!((streak["weeks"].as_u64(), streak["state"].as_str()), (Some(0), Some("not_started")));
    assert_eq!(streak["previous_best"], 5);
    assert_eq!(streak["recent"][5]["mark"], "missed");
    assert_eq!(streak["recent"][6]["mark"], "missed");
}

// --- Notifications -------------------------------------------------------

use lyfe_server::push::apns::{ApnsClient, Environment};
use lyfe_server::push::notifier::{Notifier, Outcome};
use wiremock::matchers::path_regex;

const DEVICE_TOKEN: &str = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

/// A key made for one test, in the form Apple issues them. No key is kept
/// in the repository.
fn throwaway_apns_key() -> String {
    use p256::pkcs8::{EncodePrivateKey, LineEnding};
    loop {
        let mut bytes = [0u8; 32];
        getrandom::fill(&mut bytes).unwrap();
        if let Ok(key) = p256::ecdsa::SigningKey::from_slice(&bytes) {
            return key.to_pkcs8_pem(LineEnding::LF).unwrap().to_string();
        }
    }
}

/// A notifier that talks to `apple` instead of Apple: its development
/// service under /dev and its production service under /prod.
fn notifier(h: &Harness, apple: &MockServer) -> Notifier {
    let key_file = h._key_dir.0.join("AuthKey_TESTKEY123.p8");
    std::fs::write(&key_file, throwaway_apns_key()).unwrap();
    Notifier {
        pool: h.state.pool.clone(),
        syncer: h.state.syncer.clone(),
        apns: ApnsClient::with_urls(
            key_file,
            "TESTKEY123".into(),
            "TESTTEAM12".into(),
            "com.example.lyfe".into(),
            &format!("{}/dev", apple.uri()),
            &format!("{}/prod", apple.uri()),
        )
        .unwrap(),
        default_environment: Environment::Development,
        timezone: h.state.timezone,
        gym_rules: h.state.gym_rules.clone(),
        from_hour: 7,
        until_hour: 18,
        weight: h.state.weight,
    }
}

async fn apple_answers(apple: &MockServer, service: &str, status: u16, reason: Option<&str>) {
    let response = match reason {
        Some(reason) => ResponseTemplate::new(status).set_body_json(json!({ "reason": reason })),
        None => ResponseTemplate::new(status),
    };
    Mock::given(method("POST"))
        .and(path_regex(format!("^/{service}/3/device/")))
        .respond_with(response)
        .mount(apple)
        .await;
}

async fn register_device(h: &Harness, token: &str) {
    let (status, _) = h
        .post("/v1/push-token", Some(token), Some(json!({ "apns_token": DEVICE_TOKEN })))
        .await;
    assert_eq!(status, StatusCode::NO_CONTENT);
}

/// Six kept weeks, then Monday and Tuesday of week 47: two more needed.
async fn two_more_needed(h: &Harness) {
    h.mock_activities(history(&[4, 4, 4, 4, 4, 4, 2])).await;
    h.poll().await;
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_device_registers_where_apple_reaches_it(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;

    let (status, _) = h.post("/v1/push-token", None, Some(json!({ "apns_token": DEVICE_TOKEN }))).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    for bad in ["", "not hex at all, not hex at all, not hex", "abc123"] {
        let (status, _) = h.post("/v1/push-token", Some(&token), Some(json!({ "apns_token": bad }))).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{bad}");
    }
    assert!(db::push_targets(&h.state.pool).await.unwrap().is_empty());

    register_device(&h, &token).await;
    let targets = db::push_targets(&h.state.pool).await.unwrap();
    assert_eq!(targets.len(), 1);
    assert_eq!((targets[0].apns_token.as_str(), targets[0].apns_environment.as_deref()), (DEVICE_TOKEN, None));

    // The same install signing in again is one device, not two.
    let second = h.sign_in().await;
    register_device(&h, &second).await;
    assert_eq!(db::push_targets(&h.state.pool).await.unwrap().len(), 1);

    // A signed-out device is not notified.
    h.post("/v1/auth/sign-out", Some(&second), None).await;
    assert!(db::push_targets(&h.state.pool).await.unwrap().is_empty());
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn the_day_every_remaining_day_is_needed_prompts_once(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    register_device(&h, &token).await;
    two_more_needed(&h).await;
    let apple = MockServer::start().await;
    apple_answers(&apple, "dev", 200, None).await;
    let notifier = notifier(&h, &apple);

    // Friday 08:00 in San Juan: three days left for two sessions. Nothing yet.
    assert_eq!(notifier.tick(at("2026-11-20T12:00:00Z")).await.unwrap(), Outcome::NothingDue);
    // Saturday 08:00: today and Sunday are both needed.
    let saturday = at("2026-11-21T12:00:00Z");
    assert_eq!(
        notifier.tick(saturday).await.unwrap(),
        Outcome::Sent {
            title: "Gym: 2 more by Sunday".into(),
            body: "Train today to keep your 6-week streak. It takes every day left this week.".into(),
            devices: 1,
        }
    );
    assert_eq!(notifier.tick(at("2026-11-21T12:05:00Z")).await.unwrap(), Outcome::AlreadySent);

    let requests = apple.received_requests().await.unwrap();
    assert_eq!(requests.len(), 1);
    let request = &requests[0];
    assert_eq!(request.url.path(), format!("/dev/3/device/{DEVICE_TOKEN}"));
    let header = |name: &str| request.headers.get(name).unwrap().to_str().unwrap().to_string();
    assert_eq!(header("apns-topic"), "com.example.lyfe");
    assert_eq!(header("apns-push-type"), "alert");
    assert_eq!(header("apns-collapse-id"), "gym_train_today");
    // Dropped if not delivered by 18:00 in San Juan.
    assert_eq!(header("apns-expiration"), at("2026-11-21T22:00:00Z").timestamp().to_string());
    let bearer = header("authorization");
    assert!(bearer.starts_with("Bearer ") && bearer.split('.').count() == 3, "{bearer}");
    let body: Value = serde_json::from_slice(&request.body).unwrap();
    assert_eq!(body["aps"]["alert"]["title"], "Gym: 2 more by Sunday");

    // Apple's development service took it, and that is remembered.
    let targets = db::push_targets(&h.state.pool).await.unwrap();
    assert_eq!(targets[0].apns_environment.as_deref(), Some("development"));
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn nothing_is_sent_at_night_or_without_a_device(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    two_more_needed(&h).await;
    let apple = MockServer::start().await;
    apple_answers(&apple, "dev", 200, None).await;
    let notifier = notifier(&h, &apple);

    // Saturday 08:00, a prompt is due, but no device accepts notifications.
    assert_eq!(notifier.tick(at("2026-11-21T12:00:00Z")).await.unwrap(), Outcome::NoDevices);
    register_device(&h, &token).await;
    // 06:59 and 18:00 in San Juan are outside the window.
    assert_eq!(notifier.tick(at("2026-11-21T10:59:00Z")).await.unwrap(), Outcome::Quiet);
    assert_eq!(notifier.tick(at("2026-11-21T22:00:00Z")).await.unwrap(), Outcome::Quiet);
    assert!(apple.received_requests().await.unwrap().is_empty());
    // 17:59 is inside it.
    assert!(matches!(notifier.tick(at("2026-11-21T21:59:00Z")).await.unwrap(), Outcome::Sent { .. }));
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_session_recorded_this_morning_cancels_the_prompt(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    register_device(&h, &token).await;
    two_more_needed(&h).await;
    let apple = MockServer::start().await;
    apple_answers(&apple, "dev", 200, None).await;
    let notifier = notifier(&h, &apple);

    // The watch synced a Saturday-morning session that lyfe has not polled yet.
    let mut activities = history(&[4, 4, 4, 4, 4, 4, 2]);
    activities
        .as_array_mut()
        .unwrap()
        .push(activity(7001, "strength_training", "2026-11-21 06:30:00", 45.0));
    h.mock_activities(activities).await;

    assert_eq!(notifier.tick(at("2026-11-21T12:00:00Z")).await.unwrap(), Outcome::NothingDue);
    assert!(apple.received_requests().await.unwrap().is_empty());
    // Sunday morning the last one is needed.
    assert_eq!(
        notifier.tick(at("2026-11-22T12:00:00Z")).await.unwrap(),
        Outcome::Sent {
            title: "Gym: 1 more today".into(),
            body: "Train today to keep your 6-week streak.".into(),
            devices: 1,
        }
    );
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_missed_week_prompts_recovery_once_that_week(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    register_device(&h, &token).await;
    // Week 46 had two sessions; week 47 has none yet.
    h.mock_activities(history(&[4, 4, 4, 4, 4, 2])).await;
    h.poll().await;
    let apple = MockServer::start().await;
    apple_answers(&apple, "dev", 200, None).await;
    let notifier = notifier(&h, &apple);

    assert_eq!(
        notifier.tick(at("2026-11-16T12:00:00Z")).await.unwrap(),
        Outcome::Sent {
            title: "Gym: last week was missed".into(),
            body: "4 sessions by Sunday recovers your 5-week streak. Nothing to make up.".into(),
            devices: 1,
        }
    );
    assert_eq!(notifier.tick(at("2026-11-17T12:00:00Z")).await.unwrap(), Outcome::AlreadySent);
    assert_eq!(notifier.tick(at("2026-11-18T12:00:00Z")).await.unwrap(), Outcome::AlreadySent);
    // Thursday: all four remaining days are needed, which is its own prompt.
    assert_eq!(
        notifier.tick(at("2026-11-19T12:00:00Z")).await.unwrap(),
        Outcome::Sent {
            title: "Gym: 4 more by Sunday".into(),
            body: "Train today to recover your 5-week streak. It takes every day left this week.".into(),
            devices: 1,
        }
    );
    // Friday without Thursday's session: out of reach, so nothing to act on.
    assert_eq!(notifier.tick(at("2026-11-20T12:00:00Z")).await.unwrap(), Outcome::NothingDue);
    assert_eq!(apple.received_requests().await.unwrap().len(), 2);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn apples_other_service_is_tried_and_remembered(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    register_device(&h, &token).await;
    two_more_needed(&h).await;
    let apple = MockServer::start().await;
    apple_answers(&apple, "dev", 400, Some("BadDeviceToken")).await;
    apple_answers(&apple, "prod", 200, None).await;
    let notifier = notifier(&h, &apple);

    assert!(matches!(notifier.tick(at("2026-11-21T12:00:00Z")).await.unwrap(), Outcome::Sent { devices: 1, .. }));
    let targets = db::push_targets(&h.state.pool).await.unwrap();
    assert_eq!(targets[0].apns_environment.as_deref(), Some("production"));

    // The next alert goes straight to the service that worked.
    let alert = lyfe_server::push::apns::Alert {
        title: "lyfe".into(),
        body: "Another".into(),
        collapse_id: "test".into(),
        expires_at: at("2026-11-21T13:00:00Z"),
        category: None,
    };
    assert_eq!(notifier.deliver(&targets, &alert, at("2026-11-21T12:10:00Z")).await, 1);
    let paths: Vec<String> = apple
        .received_requests()
        .await
        .unwrap()
        .iter()
        .map(|r| r.url.path()[..5].trim_end_matches('/').to_string())
        .collect();
    assert_eq!(paths, vec!["/dev", "/prod", "/prod"]);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_device_apple_no_longer_knows_is_forgotten(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    register_device(&h, &token).await;
    two_more_needed(&h).await;
    let apple = MockServer::start().await;
    apple_answers(&apple, "dev", 400, Some("BadDeviceToken")).await;
    apple_answers(&apple, "prod", 410, Some("Unregistered")).await;
    let notifier = notifier(&h, &apple);

    assert_eq!(notifier.tick(at("2026-11-21T12:00:00Z")).await.unwrap(), Outcome::Undelivered);
    assert!(db::push_targets(&h.state.pool).await.unwrap().is_empty());
    assert_eq!(notifier.tick(at("2026-11-21T12:05:00Z")).await.unwrap(), Outcome::NoDevices);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_prompt_apple_could_not_take_is_tried_again(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    register_device(&h, &token).await;
    two_more_needed(&h).await;
    let apple = MockServer::start().await;
    apple_answers(&apple, "dev", 503, Some("ServiceUnavailable")).await;
    let notifier = notifier(&h, &apple);

    assert_eq!(notifier.tick(at("2026-11-21T12:00:00Z")).await.unwrap(), Outcome::Undelivered);
    // The device is kept: the fault was Apple's, not the token's.
    assert_eq!(db::push_targets(&h.state.pool).await.unwrap().len(), 1);

    apple.reset().await;
    apple_answers(&apple, "dev", 200, None).await;
    assert!(matches!(notifier.tick(at("2026-11-21T12:05:00Z")).await.unwrap(), Outcome::Sent { .. }));
}

// --- Breath sessions -----------------------------------------------------

/// A session of six rounds as the phone sends it, with one hold per entry
/// in seconds from round 1 on.
fn breath_session(n: u32, started_at: &str, round_s: u32, holds_s: &[u32]) -> Value {
    let ended_at = at(started_at) + chrono::Duration::seconds(i64::from(round_s) * 6);
    let holds: Vec<Value> = holds_s
        .iter()
        .enumerate()
        .map(|(index, s)| json!({"round": index + 1, "hold_ms": s * 1000}))
        .collect();
    json!({
        "id": format!("00000000-0000-4000-8000-{n:012}"),
        "started_at": started_at,
        "ended_at": ended_at.to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
        "round_s": round_s,
        "rounds": 6,
        "holds": holds,
    })
}

const GOOD_HOLDS: &[u32] = &[125, 132, 120, 118, 121, 119];

impl Harness {
    async fn record_breath(&self, token: &str, session: Value) -> Value {
        let (status, body) = self.post("/v1/breath/sessions", Some(token), Some(session)).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        body
    }

    /// Three full sessions (Monday, Wednesday, Friday evening) in each week
    /// starting on the given Mondays.
    async fn breath_weeks(&self, token: &str, mondays: &[&str]) {
        for (week, monday) in mondays.iter().enumerate() {
            for (index, day) in [0, 2, 4].into_iter().enumerate() {
                let date: chrono::NaiveDate = monday.parse().unwrap();
                let started_at = format!("{}T23:00:00Z", date + chrono::Duration::days(day));
                let n = 1000 + (week * 10 + index) as u32;
                self.record_breath(token, breath_session(n, &started_at, 240, GOOD_HOLDS)).await;
            }
        }
    }
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_breath_session_fills_a_square_and_sets_the_next_table(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;

    // Before any session: the first table, from the settings.
    let (_, before) = h.get("/v1/home", Some(&token)).await;
    let breath = &before["breath"];
    assert_eq!((&breath["target"], &breath["done"], &breath["remaining"]), (&json!(3), &json!(0), &json!(3)));
    assert_eq!(breath["done_today"], false);
    assert_eq!(breath["streak"]["state"], "not_started");
    assert_eq!(breath["table"]["round_s"], 240);
    assert_eq!(breath["table"]["rounds"], 6);
    assert_eq!(breath["table"]["changed_from_s"], Value::Null);
    assert_eq!(breath["table"]["last_holds_ms"], json!([null, null, null, null, null, null]));
    assert_eq!(breath["best_ms"], Value::Null);

    // A session this morning (10:30 in San Juan). The answer is Home.
    let after = h
        .record_breath(&token, breath_session(1, "2026-11-17T14:30:00Z", 240, GOOD_HOLDS))
        .await;
    assert_eq!(after["today"], "2026-11-17");
    let breath = &after["breath"];
    assert_eq!((&breath["done"], &breath["remaining"]), (&json!(1), &json!(2)));
    assert_eq!(breath["done_today"], true);
    assert_eq!(breath["best_ms"], 132_000);
    let session = &breath["sessions"][0];
    assert_eq!(session["date"], "2026-11-17");
    assert_eq!(session["counts"], true);
    assert_eq!(session["holds_ms"], json!([125000, 132000, 120000, 118000, 121000, 119000]));
    assert_eq!(session["best_ms"], 132_000);
    assert_eq!(session["mean_ms"], 122_500);
    assert_eq!(session["tightest_recovery_ms"], 108_000);
    // Recovery had room, so the same rounds again, with these holds to beat.
    assert_eq!(breath["table"]["round_s"], 240);
    assert_eq!(breath["table"]["changed_from_s"], Value::Null);
    assert_eq!(breath["table"]["advance_under_s"], 45);
    assert_eq!(breath["table"]["step_s"], 15);
    assert_eq!(breath["table"]["last_holds_ms"][1], 132_000);
    // The gym is untouched by it.
    assert_eq!(after["gym"]["done"], 0);

    let (_, home) = h.get("/v1/home", Some(&token)).await;
    assert_eq!(home["breath"], after["breath"]);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_session_sent_twice_is_counted_once(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    let session = breath_session(1, "2026-11-17T14:30:00Z", 240, GOOD_HOLDS);

    let first = h.record_breath(&token, session.clone()).await;
    // The phone did not hear the answer and sends it again.
    let second = h.record_breath(&token, session).await;
    assert_eq!(second["breath"], first["breath"]);
    assert_eq!(second["breath"]["done"], 1);
    assert_eq!(second["breath"]["sessions"].as_array().unwrap().len(), 1);

    // Even a different body under the same id changes nothing.
    let altered = breath_session(1, "2026-11-17T14:30:00Z", 240, &[10, 10, 10]);
    let third = h.record_breath(&token, altered).await;
    assert_eq!(third["breath"], first["breath"]);
    let holds: i64 = sqlx::query_scalar("select count(*) from breath_holds")
        .fetch_one(&h.state.pool)
        .await
        .unwrap();
    assert_eq!(holds, 6);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_breath_session_belongs_to_the_owners_day(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;

    // 23:30 on Monday in San Juan is already Tuesday in UTC.
    let home = h
        .record_breath(&token, breath_session(1, "2026-11-17T03:30:00Z", 240, GOOD_HOLDS))
        .await;
    assert_eq!(home["breath"]["sessions"][0]["date"], "2026-11-16");
    assert_eq!(home["breath"]["done"], 1);
    assert_eq!(home["breath"]["done_today"], false);

    // 23:00 on Sunday in San Juan belongs to last week.
    let home = h
        .record_breath(&token, breath_session(2, "2026-11-16T03:00:00Z", 240, GOOD_HOLDS))
        .await;
    assert_eq!(home["breath"]["done"], 1);
    assert_eq!(home["breath"]["sessions"].as_array().unwrap().len(), 1);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_session_cut_short_counts_and_an_abandoned_one_does_not(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;

    // One hold, then the session was given up: stored, but not a session.
    let home = h
        .record_breath(&token, breath_session(1, "2026-11-16T23:00:00Z", 240, &[150]))
        .await;
    assert_eq!(home["breath"]["done"], 0);
    assert_eq!(home["breath"]["sessions"][0]["counts"], false);
    // Its hold is still the best so far, and it does not move the table.
    assert_eq!(home["breath"]["best_ms"], 150_000);
    assert_eq!(home["breath"]["table"]["last_holds_ms"][0], Value::Null);

    // Three of six rounds: counts, with rounds four to six left empty.
    let home = h
        .record_breath(&token, breath_session(2, "2026-11-17T14:30:00Z", 240, &[100, 110, 105]))
        .await;
    assert_eq!(home["breath"]["done"], 1);
    assert_eq!(home["breath"]["sessions"][1]["counts"], true);
    assert_eq!(home["breath"]["sessions"][1]["holds_ms"], json!([100000, 110000, 105000, null, null, null]));
    assert_eq!(home["breath"]["table"]["last_holds_ms"], json!([100000, 110000, 105000, null, null, null]));
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn two_sessions_on_one_day_fill_one_square(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    h.record_breath(&token, breath_session(1, "2026-11-17T11:00:00Z", 240, GOOD_HOLDS)).await;
    let home = h
        .record_breath(&token, breath_session(2, "2026-11-17T14:30:00Z", 240, GOOD_HOLDS))
        .await;
    assert_eq!(home["breath"]["done"], 1);
    assert_eq!(home["breath"]["sessions"].as_array().unwrap().len(), 2);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn tight_recovery_makes_the_next_rounds_longer(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;

    // A 3:20 hold leaves 0:40 of a 4:00 round: under the 0:45 threshold.
    let home = h
        .record_breath(&token, breath_session(1, "2026-11-16T23:00:00Z", 240, &[180, 200, 175, 170, 165, 160]))
        .await;
    assert_eq!(home["breath"]["table"]["round_s"], 255);
    assert_eq!(home["breath"]["table"]["changed_from_s"], 240);

    // The next session runs 4:15 rounds with room to spare: 4:15 again.
    let home = h
        .record_breath(&token, breath_session(2, "2026-11-17T14:30:00Z", 255, &[185, 201, 176, 170, 166, 161]))
        .await;
    assert_eq!(home["breath"]["table"]["round_s"], 255);
    assert_eq!(home["breath"]["table"]["changed_from_s"], Value::Null);
    assert_eq!(home["breath"]["table"]["last_holds_ms"][1], 201_000);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn breath_weeks_build_a_streak_with_the_same_recovery_rule(pool: PgPool) {
    let h = harness(pool.clone()).await;
    let token = h.signed_in().await;

    // Weeks 44 and 45 kept; week 46 had two sessions; Monday of week 47 done.
    h.breath_weeks(&token, &["2026-10-26", "2026-11-02"]).await;
    h.record_breath(&token, breath_session(1, "2026-11-09T23:00:00Z", 240, GOOD_HOLDS)).await;
    h.record_breath(&token, breath_session(2, "2026-11-11T23:00:00Z", 240, GOOD_HOLDS)).await;
    let home = h
        .record_breath(&token, breath_session(3, "2026-11-16T23:00:00Z", 240, GOOD_HOLDS))
        .await;
    let streak = &home["breath"]["streak"];
    assert_eq!((&streak["weeks"], &streak["state"]), (&json!(2), &json!("recovering")));
    assert_eq!((&streak["remaining"], &streak["open_days"], &streak["reachable"]), (&json!(2), &json!(6), &json!(true)));
    let marks: Vec<&str> = streak["recent"]
        .as_array()
        .unwrap()
        .iter()
        .map(|w| w["mark"].as_str().unwrap())
        .collect();
    assert_eq!(marks, vec!["kept", "kept", "awaiting_recovery"]);
    assert_eq!(streak["recent"][2]["done"], 2);

    // By Thursday evening the week has its three sessions: recovered.
    let thursday = harness_at(pool, "2026-11-19T23:30:00Z", true).await;
    thursday.record_breath(&token, breath_session(4, "2026-11-18T23:00:00Z", 240, GOOD_HOLDS)).await;
    let home = thursday
        .record_breath(&token, breath_session(5, "2026-11-19T23:00:00Z", 240, GOOD_HOLDS))
        .await;
    let streak = &home["breath"]["streak"];
    assert_eq!((&streak["weeks"], &streak["state"], &streak["remaining"]), (&json!(3), &json!("kept"), &json!(0)));
    assert_eq!(streak["recent"][2]["mark"], "recovered");
    assert_eq!(home["breath"]["done_today"], true);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_breath_session_that_makes_no_sense_is_refused(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    let good = breath_session(1, "2026-11-17T14:30:00Z", 240, GOOD_HOLDS);

    let (status, _) = h.post("/v1/breath/sessions", None, Some(good.clone())).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    let mut round_seven = good.clone();
    round_seven["holds"][0]["round"] = json!(7);
    let mut twice = good.clone();
    twice["holds"][1]["round"] = json!(1);
    let mut too_long = good.clone();
    too_long["holds"][0]["hold_ms"] = json!(240_001);
    let mut backwards = good.clone();
    backwards["ended_at"] = json!("2026-11-17T14:00:00Z");
    let mut next_week = good.clone();
    next_week["started_at"] = json!("2026-11-24T14:30:00Z");
    next_week["ended_at"] = json!("2026-11-24T15:00:00Z");
    let mut no_rounds = good.clone();
    no_rounds["rounds"] = json!(0);
    for bad in [round_seven, twice, too_long, backwards, next_week, no_rounds] {
        let (status, body) = h.post("/v1/breath/sessions", Some(&token), Some(bad.clone())).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{bad} {body}");
    }
    let (status, _) = h
        .post("/v1/breath/sessions", Some(&token), Some(json!({"id": "not-an-id"})))
        .await;
    assert!(status.is_client_error());

    let (_, home) = h.get("/v1/home", Some(&token)).await;
    assert_eq!(home["breath"]["sessions"], json!([]));
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_breath_streak_prompts_on_the_day_every_day_left_is_needed(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    register_device(&h, &token).await;
    // Weeks 45 and 46 kept, and Monday of week 47 done: two more needed.
    h.breath_weeks(&token, &["2026-11-02", "2026-11-09"]).await;
    h.record_breath(&token, breath_session(1, "2026-11-16T23:00:00Z", 240, GOOD_HOLDS)).await;
    let apple = MockServer::start().await;
    apple_answers(&apple, "dev", 200, None).await;
    let notifier = notifier(&h, &apple);

    // Friday 08:00 in San Juan: three days left for two sessions.
    assert_eq!(notifier.tick(at("2026-11-20T12:00:00Z")).await.unwrap(), Outcome::NothingDue);
    // Saturday 08:00: today and Sunday are both needed.
    assert_eq!(
        notifier.tick(at("2026-11-21T12:00:00Z")).await.unwrap(),
        Outcome::Sent {
            title: "Breath: 2 more by Sunday".into(),
            body: "Do a session today to keep your 2-week streak. It takes every day left this week.".into(),
            devices: 1,
        }
    );
    assert_eq!(notifier.tick(at("2026-11-21T12:05:00Z")).await.unwrap(), Outcome::AlreadySent);
    let requests = apple.received_requests().await.unwrap();
    assert_eq!(requests[0].headers.get("apns-collapse-id").unwrap(), "breath_train_today");

    // A session that morning, and Sunday has nothing to say before its own.
    let saturday = harness_at(h.state.pool.clone(), "2026-11-21T13:00:00Z", true).await;
    saturday.record_breath(&token, breath_session(2, "2026-11-21T12:30:00Z", 240, GOOD_HOLDS)).await;
    assert_eq!(notifier.tick(at("2026-11-21T13:05:00Z")).await.unwrap(), Outcome::NothingDue);
    assert!(matches!(
        notifier.tick(at("2026-11-22T12:00:00Z")).await.unwrap(),
        Outcome::Sent { title, .. } if title == "Breath: 1 more today"
    ));
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn when_both_routines_need_today_each_gets_its_own_prompt(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    register_device(&h, &token).await;
    two_more_needed(&h).await;
    h.breath_weeks(&token, &["2026-11-02", "2026-11-09"]).await;
    h.record_breath(&token, breath_session(1, "2026-11-16T23:00:00Z", 240, GOOD_HOLDS)).await;
    let apple = MockServer::start().await;
    apple_answers(&apple, "dev", 200, None).await;
    let notifier = notifier(&h, &apple);

    let sent = |outcome: Outcome| match outcome {
        Outcome::Sent { title, .. } => title,
        other => panic!("expected a prompt, got {other:?}"),
    };
    assert_eq!(sent(notifier.tick(at("2026-11-21T12:00:00Z")).await.unwrap()), "Gym: 2 more by Sunday");
    assert_eq!(sent(notifier.tick(at("2026-11-21T12:05:00Z")).await.unwrap()), "Breath: 2 more by Sunday");
    assert_eq!(notifier.tick(at("2026-11-21T12:10:00Z")).await.unwrap(), Outcome::AlreadySent);
    assert_eq!(apple.received_requests().await.unwrap().len(), 2);
}

// --- Weigh-ins -----------------------------------------------------------

/// A weigh-in as the phone sends it.
fn weigh_in(n: u32, measured_at: &str, value: f64, unit: &str) -> Value {
    json!({
        "id": format!("00000000-0000-4000-9000-{n:012}"),
        "measured_at": measured_at,
        "value": value,
        "unit": unit,
    })
}

impl Harness {
    async fn record_weight(&self, token: &str, body: Value) -> Value {
        let (status, home) = self.post("/v1/weigh-ins", Some(token), Some(body)).await;
        assert_eq!(status, StatusCode::OK, "{home}");
        home
    }
}

async fn weigh_in_count(pool: &PgPool) -> i64 {
    sqlx::query_scalar("select count(*) from weigh_ins").fetch_one(pool).await.unwrap()
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_weight_typed_into_the_prompt_shows_on_home(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;

    let (status, home) = h.get("/v1/home", Some(&token)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        home["weight"],
        json!({"unit": "kg", "prompt_at": "06:30", "latest": null, "average": null, "days_weighed": 0,
               "change": null, "change_pct": null, "days": []})
    );

    let body = weigh_in(1, "2026-11-17T10:35:00Z", 82.4, "kg");
    let (status, _) = h.post("/v1/weigh-ins", None, Some(body.clone())).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(weigh_in_count(&h.state.pool).await, 0);

    // 06:35 in San Juan: Tuesday's weight. The answer is Home as it now stands.
    let home = h.record_weight(&token, body).await;
    assert_eq!(home["weight"]["latest"], json!({"date": "2026-11-17", "value": 82.4}));
    assert_eq!(home["weight"]["days_weighed"], 1);
    assert_eq!(home["weight"]["average"], Value::Null);
    assert_eq!(home["weight"]["days"], json!([{"date": "2026-11-17", "value": 82.4, "average": null}]));
    assert_eq!(home["gym"]["target"], 4);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_weigh_in_sent_twice_is_stored_once_and_a_retype_corrects_the_day(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;

    let slip = weigh_in(1, "2026-11-17T10:35:00Z", 28.4, "kg");
    h.record_weight(&token, slip.clone()).await;
    h.record_weight(&token, slip).await;
    assert_eq!(weigh_in_count(&h.state.pool).await, 1);

    // Typed again a minute later: the day's weight is the later one.
    let home = h.record_weight(&token, weigh_in(2, "2026-11-17T10:36:00Z", 82.4, "kg")).await;
    assert_eq!(home["weight"]["latest"]["value"], 82.4);
    assert_eq!(home["weight"]["days_weighed"], 1);
    assert_eq!(weigh_in_count(&h.state.pool).await, 2);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn the_seven_day_average_and_its_change_on_last_week(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;

    // Fourteen mornings to Tuesday 17 November, down 0.1 kg a day from 84.0.
    for day in 0..14u32 {
        let date = chrono::NaiveDate::from_ymd_opt(2026, 11, 4 + day).unwrap();
        let measured = format!("{date}T10:30:00Z");
        h.record_weight(&token, weigh_in(day, &measured, 84.0 - f64::from(day) * 0.1, "kg")).await;
    }
    let (_, home) = h.get("/v1/home", Some(&token)).await;
    let weight = &home["weight"];
    assert_eq!(weight["latest"], json!({"date": "2026-11-17", "value": 82.7}));
    assert_eq!(weight["average"], 83.0);
    assert_eq!(weight["days_weighed"], 7);
    assert_eq!(weight["change"], -0.7);
    assert_eq!(weight["change_pct"], -0.84);
    let days = weight["days"].as_array().unwrap();
    assert_eq!(days.len(), 14);
    assert_eq!(days[0], json!({"date": "2026-11-04", "value": 84.0, "average": null}));
    assert_eq!(days[2], json!({"date": "2026-11-06", "value": 83.8, "average": 83.9}));
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_weight_in_pounds_is_kept_as_the_same_weight(pool: PgPool) {
    let mut h = harness(pool).await;
    let token = h.signed_in().await;

    let home = h.record_weight(&token, weigh_in(1, "2026-11-17T10:35:00Z", 181.4, "lb")).await;
    assert_eq!(home["weight"]["unit"], "kg");
    assert_eq!(home["weight"]["latest"]["value"], 82.28);

    // A server left on its default, pounds, shows it as typed and asks in pounds.
    h.state.weight = lyfe_server::routines::weight::WeightSettings::default();
    let (_, home) = h.get("/v1/home", Some(&token)).await;
    assert_eq!(home["weight"]["unit"], "lb");
    assert_eq!(home["weight"]["latest"]["value"], 181.4);
    assert_eq!(
        lyfe_server::routines::weight::prompt_body(h.state.weight.unit),
        "Hold this and type your weight in lb. No need to open lyfe."
    );
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_weight_that_makes_no_sense_is_refused(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;

    for (body, why) in [
        (weigh_in(1, "2026-11-17T10:35:00Z", 824.0, "kg"), "a slipped decimal point"),
        (weigh_in(2, "2026-11-17T10:35:00Z", 8.24, "kg"), "the other way"),
        (weigh_in(3, "2026-11-17T10:35:00Z", 82.4, "st"), "an unknown unit"),
        (weigh_in(4, "2026-11-19T10:35:00Z", 82.4, "kg"), "in the future"),
    ] {
        let (status, body) = h.post("/v1/weigh-ins", Some(&token), Some(body)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{why}: {body}");
    }
    assert_eq!(weigh_in_count(&h.state.pool).await, 0);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn the_weigh_in_prompt_comes_once_at_its_time_with_a_reply_field(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    register_device(&h, &token).await;
    let apple = MockServer::start().await;
    apple_answers(&apple, "dev", 200, None).await;
    let notifier = notifier(&h, &apple);

    // Wednesday 18 November in San Juan (UTC-4): not before 06:30...
    assert_eq!(notifier.weigh_in(at("2026-11-18T10:29:00Z")).await.unwrap(), Outcome::Quiet);
    // ...then once, before the daytime window for streak prompts opens.
    assert_eq!(
        notifier.weigh_in(at("2026-11-18T10:30:00Z")).await.unwrap(),
        Outcome::Sent {
            title: "Morning weigh-in".into(),
            body: "Hold this and type your weight in kg. No need to open lyfe.".into(),
            devices: 1,
        }
    );
    assert_eq!(notifier.weigh_in(at("2026-11-18T10:35:00Z")).await.unwrap(), Outcome::AlreadySent);

    let requests = apple.received_requests().await.unwrap();
    assert_eq!(requests.len(), 1);
    let header = |name: &str| requests[0].headers.get(name).unwrap().to_str().unwrap().to_string();
    assert_eq!(header("apns-collapse-id"), "weigh_in");
    // Dropped if not delivered by 09:30: it is a morning weigh-in.
    assert_eq!(header("apns-expiration"), at("2026-11-18T13:30:00Z").timestamp().to_string());
    let body: Value = serde_json::from_slice(&requests[0].body).unwrap();
    assert_eq!(body["aps"]["category"], "WEIGH_IN");
    assert_eq!(body["aps"]["alert"]["title"], "Morning weigh-in");

    // A missed morning is just missed: no second reminder, nothing after 09:30.
    assert_eq!(notifier.weigh_in(at("2026-11-18T16:00:00Z")).await.unwrap(), Outcome::Quiet);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_server_down_at_the_time_still_prompts_that_morning(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    register_device(&h, &token).await;
    let apple = MockServer::start().await;
    apple_answers(&apple, "dev", 200, None).await;
    let notifier = notifier(&h, &apple);

    // Up again at 09:29: still the morning.
    assert!(matches!(notifier.weigh_in(at("2026-11-18T13:29:00Z")).await.unwrap(), Outcome::Sent { .. }));
    // Up at 09:30 the next day: too late, nothing that day.
    assert_eq!(notifier.weigh_in(at("2026-11-19T13:30:00Z")).await.unwrap(), Outcome::Quiet);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn no_weigh_in_prompt_once_today_is_weighed_or_when_it_is_off(pool: PgPool) {
    let mut h = harness(pool).await;
    let token = h.signed_in().await;
    register_device(&h, &token).await;
    let apple = MockServer::start().await;
    apple_answers(&apple, "dev", 200, None).await;

    // Weighed at 06:10, before the prompt, from the app.
    h.record_weight(&token, weigh_in(1, "2026-11-17T10:10:00Z", 82.4, "kg")).await;
    let notifier_on = notifier(&h, &apple);
    assert_eq!(notifier_on.weigh_in(at("2026-11-17T10:30:00Z")).await.unwrap(), Outcome::NothingDue);

    h.state.weight.prompt_at = None;
    let notifier_off = notifier(&h, &apple);
    assert_eq!(notifier_off.weigh_in(at("2026-11-18T10:30:00Z")).await.unwrap(), Outcome::Quiet);
    assert!(apple.received_requests().await.unwrap().is_empty());
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn the_weigh_in_prompt_and_streak_prompts_do_not_crowd_each_other_out(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    register_device(&h, &token).await;
    two_more_needed(&h).await;
    let apple = MockServer::start().await;
    apple_answers(&apple, "dev", 200, None).await;
    let notifier = notifier(&h, &apple);

    // Saturday: the weigh-in at 06:30 and the gym prompt once the day opens.
    assert!(matches!(notifier.weigh_in(at("2026-11-21T10:30:00Z")).await.unwrap(), Outcome::Sent { .. }));
    assert_eq!(notifier.tick(at("2026-11-21T10:30:00Z")).await.unwrap(), Outcome::Quiet);
    assert!(matches!(
        notifier.tick(at("2026-11-21T11:00:00Z")).await.unwrap(),
        Outcome::Sent { title, .. } if title == "Gym: 2 more by Sunday"
    ));
    assert_eq!(notifier.weigh_in(at("2026-11-21T11:00:00Z")).await.unwrap(), Outcome::AlreadySent);
}
