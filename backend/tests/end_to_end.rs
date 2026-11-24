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
        syncer: Arc::new(Syncer::new(pool.clone(), client, 180, 30)),
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
        estimate_range_pct: 35,
        estimator_wake: Arc::new(tokio::sync::Notify::new()),
        illustrator_wake: Arc::new(tokio::sync::Notify::new()),
        money: Arc::new(lyfe_server::money::sync::Importer::new(pool.clone(), None, chrono_tz::America::Puerto_Rico, 180, 14)),
        money_currency: None,
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
        food: lyfe_server::routines::food::FoodSettings::default(),
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
async fn progress_requires_complete_logs_and_explicit_approval(pool: PgPool) {
    let h = harness(pool.clone()).await;
    let token = h.signed_in().await;
    sqlx::raw_sql("insert into food_targets values ('2026-10-01',2000,100,now());
      insert into trend_goal values(true,0,'2026-10-01');
      insert into confirmed_food_days select date '2026-11-17'-i from generate_series(1,13) i;
      insert into food_entries(id,eaten_at,slot,name,servings,kcal,protein_dg,source)
        select gen_random_uuid(), timestamptz '2026-11-17 12:00Z'-i*interval '1 day','lunch','test',1,2000,1000,'typed' from generate_series(1,14) i;
      insert into weigh_ins(id,measured_at,grams,unit) select gen_random_uuid(),timestamptz '2026-11-17 12:00Z'-i*interval '1 day',80000-i*100,'kg' from generate_series(1,21) i;").execute(&pool).await.unwrap();
    let approve = json!({"kind":"approve","day":"2026-11-17","kcal":1900});
    assert_eq!(h.post("/v1/progress",Some(&token),Some(approve.clone())).await.0,StatusCode::BAD_REQUEST);
    sqlx::query("insert into confirmed_food_days values('2026-11-03')").execute(&pool).await.unwrap();
    let (_, home) = h.get("/v1/home",Some(&token)).await;
    assert_eq!(home["progress"]["proposed_kcal"],1900);
    assert_eq!(h.post("/v1/progress",Some(&token),Some(approve.clone())).await.0,StatusCode::OK);
    assert_eq!(h.post("/v1/progress",Some(&token),Some(approve)).await.0,StatusCode::BAD_REQUEST);
    let target:(i32,i32)=sqlx::query_as("select kcal,protein_g from food_targets where effective_on='2026-11-17'").fetch_one(&pool).await.unwrap();
    assert_eq!(target,(1900,100));
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn progress_captures_survive_retries(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    for (field, input) in [
        ("pools", json!({"kind":"pool","day":"2026-11-17","id":uuid::Uuid::from_u128(1),"metres":25})),
        ("tapes", json!({"kind":"tape","day":"2026-11-17","id":uuid::Uuid::from_u128(2),"height":180,"waist":90,"neck":40})),
    ] {
        for _ in 0..2 {
            let (status, home) = h.post("/v1/progress", Some(&token), Some(input.clone())).await;
            assert_eq!(status, StatusCode::OK);
            assert_eq!(home["progress"][field].as_array().unwrap().len(), 1);
            if field == "tapes" { assert_eq!(home["progress"]["tape_due"], false); }
        }
    }
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

// --- Food ----------------------------------------------------------------

fn food_id(n: u32) -> String {
    format!("00000000-0000-4000-9000-{n:012}")
}

/// The usual breakfast as weighed: 542 kcal and 43.1 g of protein.
fn breakfast_recipe() -> Value {
    json!({
        "name": "Usual breakfast", "slot": "breakfast", "portions": 1,
        "ingredients": [
            {"name": "Oats", "grams": 80, "kcal_per_100g": 379, "protein_per_100g": 13.2},
            {"name": "Milk 2%", "grams": 250, "kcal_per_100g": 50.4, "protein_per_100g": 3.4},
            {"name": "Whey", "grams": 30, "kcal_per_100g": 377, "protein_per_100g": 80},
        ],
    })
}

/// A pot that makes five lunches of 561 kcal and 49 g of protein.
fn lunch_recipe() -> Value {
    json!({
        "name": "Batch lunch", "slot": "lunch", "portions": 5,
        "ingredients": [
            {"name": "Chicken thigh", "grams": 900, "kcal_per_100g": 177, "protein_per_100g": 24},
            {"name": "Rice, dry", "grams": 300, "kcal_per_100g": 360, "protein_per_100g": 7},
            {"name": "Olive oil", "grams": 15, "kcal_per_100g": 884, "protein_per_100g": 0},
            {"name": "Frozen vegetables", "grams": 400, "kcal_per_100g": 0, "protein_per_100g": 2},
        ],
    })
}

impl Harness {
    async fn put(&self, uri: &str, token: Option<&str>, body: Value) -> (StatusCode, Value) {
        let mut builder = Request::put(uri).header("Content-Type", "application/json");
        if let Some(token) = token {
            builder = builder.header("Authorization", format!("Bearer {token}"));
        }
        self.request(builder.body(Body::from(body.to_string())).unwrap()).await
    }

    async fn delete(&self, uri: &str, token: Option<&str>) -> (StatusCode, Value) {
        let mut builder = Request::delete(uri);
        if let Some(token) = token {
            builder = builder.header("Authorization", format!("Bearer {token}"));
        }
        self.request(builder.body(Body::empty()).unwrap()).await
    }

    /// Saves meal number `n` and answers with Home.
    async fn save_meal(&self, token: &str, n: u32, recipe: Value) -> Value {
        let (status, home) = self.put(&format!("/v1/food/meals/{}", food_id(n)), Some(token), recipe).await;
        assert_eq!(status, StatusCode::OK, "{home}");
        home
    }

    /// Logs one tap on meal number `meal` and answers with Home.
    async fn log_meal(&self, token: &str, entry: u32, meal: u32, eaten_at: &str) -> Value {
        let body = json!({"id": food_id(entry), "eaten_at": eaten_at, "meal_id": food_id(meal)});
        let (status, home) = self.post("/v1/food/entries", Some(token), Some(body)).await;
        assert_eq!(status, StatusCode::OK, "{home}");
        home
    }
}

async fn food_entry_count(pool: &PgPool) -> i64 {
    sqlx::query_scalar("select count(*) from food_entries").fetch_one(pool).await.unwrap()
}

/// The states of the seven days Home shows, oldest first.
fn day_states(home: &Value) -> Vec<String> {
    home["food"]["streak"]["last_days"]
        .as_array()
        .unwrap()
        .iter()
        .map(|day| day["state"].as_str().unwrap().to_string())
        .collect()
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_meal_weighed_once_is_logged_with_one_tap(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;

    let (status, home) = h.get("/v1/home", Some(&token)).await;
    assert_eq!(status, StatusCode::OK);
    let food = &home["food"];
    assert_eq!(food["day"], "2026-11-17");
    assert_eq!(food["target"], Value::Null);
    assert_eq!((&food["kcal"], &food["protein_g"]), (&json!(0), &json!(0.0)));
    assert_eq!(food["open_slots"], json!(["breakfast", "lunch", "dinner"]));
    assert_eq!((&food["entries"], &food["meals"]), (&json!([]), &json!([])));
    assert_eq!(food["streak"]["state"], "not_started");

    let (status, _) = h.put(&format!("/v1/food/meals/{}", food_id(1)), None, breakfast_recipe()).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    // Defining the meal answers with what one portion comes to.
    let home = h.save_meal(&token, 1, breakfast_recipe()).await;
    let meal = &home["food"]["meals"][0];
    assert_eq!(meal["id"], food_id(1));
    assert_eq!((&meal["name"], &meal["slot"], &meal["portions"]), (&json!("Usual breakfast"), &json!("breakfast"), &json!(1)));
    assert_eq!((&meal["kcal"], &meal["protein_g"]), (&json!(542), &json!(43.1)));
    assert_eq!(
        meal["ingredients"][0],
        json!({"name": "Oats", "grams": 80.0, "kcal_per_100g": 379.0, "protein_per_100g": 13.2})
    );
    assert_eq!(meal["ingredients"].as_array().unwrap().len(), 3);
    // A batch is shared between its portions.
    let home = h.save_meal(&token, 2, lunch_recipe()).await;
    assert_eq!((&home["food"]["meals"][1]["kcal"], &home["food"]["meals"][1]["protein_g"]), (&json!(561), &json!(49.0)));

    let tap = json!({"id": food_id(11), "eaten_at": "2026-11-17T11:05:00Z", "meal_id": food_id(1)});
    let (status, _) = h.post("/v1/food/entries", None, Some(tap)).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(food_entry_count(&h.state.pool).await, 0);

    // 07:05 in San Juan: one tap, and the answer is Home as it now stands.
    let home = h.log_meal(&token, 11, 1, "2026-11-17T11:05:00Z").await;
    let food = &home["food"];
    assert_eq!(
        food["entries"],
        json!([{"id": food_id(11), "slot": "breakfast", "name": "Usual breakfast", "meal_id": food_id(1),
                "servings": 1.0, "kcal": 542, "protein_g": 43.1, "source": "saved", "figures": "known",
                "estimated": false}])
    );
    assert_eq!((&food["kcal"], &food["protein_g"]), (&json!(542), &json!(43.1)));
    // Lunch and dinner are unknown, not zero.
    assert_eq!(food["open_slots"], json!(["lunch", "dinner"]));
    assert_eq!((&food["streak"]["days"], &food["streak"]["state"]), (&json!(1), &json!("kept")));
    assert_eq!(food["streak"]["logged_today"], true);
    assert_eq!(home["gym"]["target"], 4);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_tap_sent_twice_is_logged_once_and_a_slip_can_be_taken_back(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    h.save_meal(&token, 1, breakfast_recipe()).await;

    h.log_meal(&token, 11, 1, "2026-11-17T11:05:00Z").await;
    let home = h.log_meal(&token, 11, 1, "2026-11-17T11:05:00Z").await;
    assert_eq!(food_entry_count(&h.state.pool).await, 1);
    assert_eq!(home["food"]["kcal"], 542);

    let entry = format!("/v1/food/entries/{}", food_id(11));
    let (status, _) = h.delete(&entry, None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (status, home) = h.delete(&entry, Some(&token)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!((&home["food"]["kcal"], &home["food"]["entries"]), (&json!(0), &json!([])));
    assert_eq!(home["food"]["streak"]["state"], "not_started");

    // Taking it back twice changes nothing, and neither does the first
    // tap arriving again late.
    let (status, _) = h.delete(&entry, Some(&token)).await;
    assert_eq!(status, StatusCode::OK);
    let home = h.log_meal(&token, 11, 1, "2026-11-17T11:05:00Z").await;
    assert_eq!(home["food"]["entries"], json!([]));
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn the_day_is_held_to_the_targets_the_owner_set(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    h.save_meal(&token, 1, breakfast_recipe()).await;
    h.save_meal(&token, 2, lunch_recipe()).await;

    let (status, _) = h.put("/v1/food/targets", None, json!({"kcal": 2500, "protein_g": 170})).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (status, home) = h.put("/v1/food/targets", Some(&token), json!({"kcal": 2500, "protein_g": 170})).await;
    assert_eq!(status, StatusCode::OK, "{home}");
    assert_eq!(home["food"]["target"], json!({"since": "2026-11-17", "kcal": 2500, "protein_g": 170}));
    assert_eq!((&home["food"]["kcal_left"], &home["food"]["protein_left_g"]), (&json!(2500), &json!(170.0)));

    h.log_meal(&token, 11, 1, "2026-11-17T11:05:00Z").await;
    let home = h.log_meal(&token, 12, 2, "2026-11-17T14:30:00Z").await;
    assert_eq!((&home["food"]["kcal"], &home["food"]["protein_g"]), (&json!(1103), &json!(92.1)));
    assert_eq!((&home["food"]["kcal_left"], &home["food"]["protein_left_g"]), (&json!(1397), &json!(77.9)));

    // Four more portions of lunch: over on both, shown as less than nothing left.
    let four = json!({"id": food_id(13), "eaten_at": "2026-11-17T14:40:00Z", "meal_id": food_id(2), "servings": 4});
    let (status, home) = h.post("/v1/food/entries", Some(&token), Some(four)).await;
    assert_eq!(status, StatusCode::OK, "{home}");
    assert_eq!((&home["food"]["kcal_left"], &home["food"]["protein_left_g"]), (&json!(-847), &json!(-118.1)));

    // Set again the same day: the new figures replace that day's.
    let (_, home) = h.put("/v1/food/targets", Some(&token), json!({"kcal": 2300, "protein_g": 175})).await;
    assert_eq!(home["food"]["target"], json!({"since": "2026-11-17", "kcal": 2300, "protein_g": 175}));
    let stored: i64 = sqlx::query_scalar("select count(*) from food_targets").fetch_one(&h.state.pool).await.unwrap();
    assert_eq!(stored, 1);

    for (body, why) in [
        (json!({"kcal": 250, "protein_g": 170}), "a digit short"),
        (json!({"kcal": 25000, "protein_g": 170}), "a digit too many"),
        (json!({"kcal": 2500, "protein_g": 1700}), "protein with a digit too many"),
    ] {
        let (status, body) = h.put("/v1/food/targets", Some(&token), body).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{why}: {body}");
    }
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_target_change_does_not_rewrite_earlier_days(pool: PgPool) {
    let mut h = harness(pool).await;
    let token = h.signed_in().await;
    h.put("/v1/food/targets", Some(&token), json!({"kcal": 2500, "protein_g": 170})).await;

    // A week later the owner lowers it.
    let later = at("2026-11-24T15:00:00Z");
    h.state.now = Arc::new(move || later);
    let (_, home) = h.put("/v1/food/targets", Some(&token), json!({"kcal": 2300, "protein_g": 175})).await;
    assert_eq!(home["food"]["target"], json!({"since": "2026-11-24", "kcal": 2300, "protein_g": 175}));

    // Looked at as of the Friday before, the day is held to the old target.
    let before = at("2026-11-20T15:00:00Z");
    h.state.now = Arc::new(move || before);
    let (_, home) = h.get("/v1/home", Some(&token)).await;
    assert_eq!(home["food"]["target"], json!({"since": "2026-11-17", "kcal": 2500, "protein_g": 170}));
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn changing_a_recipe_does_not_rewrite_what_was_logged(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    h.save_meal(&token, 2, lunch_recipe()).await;
    h.log_meal(&token, 11, 2, "2026-11-17T14:30:00Z").await;

    // Next week's pot: same meal, new weights and a new name.
    let mut recipe = lunch_recipe();
    recipe["name"] = json!("Batch lunch wk 48");
    recipe["ingredients"][0]["grams"] = json!(1000);
    let home = h.save_meal(&token, 2, recipe).await;
    let meals = home["food"]["meals"].as_array().unwrap();
    assert_eq!(meals.len(), 1);
    assert_eq!((&meals[0]["name"], &meals[0]["kcal"], &meals[0]["protein_g"]), (&json!("Batch lunch wk 48"), &json!(597), &json!(53.8)));
    assert_eq!(meals[0]["ingredients"].as_array().unwrap().len(), 4);
    assert_eq!((&home["food"]["entries"][0]["name"], &home["food"]["entries"][0]["kcal"]), (&json!("Batch lunch"), &json!(561)));

    // A second helping from the new pot carries the new figures.
    let home = h.log_meal(&token, 12, 2, "2026-11-17T14:50:00Z").await;
    assert_eq!(home["food"]["entries"][1]["kcal"], 597);
    assert_eq!(home["food"]["kcal"], 561 + 597);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_removed_meal_leaves_the_list_and_what_was_eaten_stays(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    h.save_meal(&token, 1, breakfast_recipe()).await;
    h.log_meal(&token, 11, 1, "2026-11-17T11:05:00Z").await;

    let meal = format!("/v1/food/meals/{}", food_id(1));
    let (status, _) = h.delete(&meal, None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (status, home) = h.delete(&meal, Some(&token)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(home["food"]["meals"], json!([]));
    assert_eq!(home["food"]["kcal"], 542);

    // Tapped on a phone that was offline before the meal was removed: it
    // was eaten, so it is logged.
    let home = h.log_meal(&token, 12, 1, "2026-11-17T13:00:00Z").await;
    assert_eq!(home["food"]["kcal"], 1084);
    assert_eq!(home["food"]["meals"], json!([]));

    // Saving it again brings it back.
    let home = h.save_meal(&token, 1, breakfast_recipe()).await;
    assert_eq!(home["food"]["meals"].as_array().unwrap().len(), 1);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_logged_meal_belongs_to_the_owners_day(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    h.save_meal(&token, 1, breakfast_recipe()).await;

    // 23:30 on Monday in San Juan, already Tuesday in UTC.
    let home = h.log_meal(&token, 11, 1, "2026-11-17T03:30:00Z").await;
    assert_eq!((&home["food"]["kcal"], &home["food"]["entries"]), (&json!(0), &json!([])));
    assert_eq!(home["food"]["open_slots"], json!(["breakfast", "lunch", "dinner"]));
    // Monday counts; Tuesday is still open.
    assert_eq!((&home["food"]["streak"]["days"], &home["food"]["streak"]["state"]), (&json!(1), &json!("on_track")));
    assert_eq!(home["food"]["streak"]["logged_today"], false);
    assert_eq!(day_states(&home), ["before", "before", "before", "before", "before", "kept", "open"]);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn logged_days_build_a_streak_with_the_same_recovery_rule(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    h.save_meal(&token, 1, breakfast_recipe()).await;

    // Logged on the 10th to the 13th and the 15th; the 14th and 16th missed.
    for (n, day) in [10, 11, 12, 13, 15].into_iter().enumerate() {
        h.log_meal(&token, 20 + n as u32, 1, &format!("2026-11-{day}T11:05:00Z")).await;
    }
    let (_, home) = h.get("/v1/home", Some(&token)).await;
    let streak = &home["food"]["streak"];
    assert_eq!((&streak["days"], &streak["state"], &streak["previous_best"]), (&json!(5), &json!("recovering"), &json!(0)));
    assert_eq!(day_states(&home), ["kept", "kept", "kept", "recovered", "kept", "awaiting_recovery", "open"]);
    assert_eq!(streak["last_days"][0]["date"], "2026-11-11");

    // One meal today recovers Monday. Nothing is made up for it.
    let home = h.log_meal(&token, 30, 1, "2026-11-17T11:05:00Z").await;
    assert_eq!((&home["food"]["streak"]["days"], &home["food"]["streak"]["state"]), (&json!(6), &json!("kept")));
    assert_eq!(day_states(&home)[5..], ["recovered", "kept"]);

    // Taken back, and with Sunday's taken back too, two days in a row are
    // missed: the streak has ended and its length is kept as the best.
    h.delete(&format!("/v1/food/entries/{}", food_id(30)), Some(&token)).await;
    let (_, home) = h.delete(&format!("/v1/food/entries/{}", food_id(24)), Some(&token)).await;
    let streak = &home["food"]["streak"];
    assert_eq!((&streak["days"], &streak["state"], &streak["previous_best"]), (&json!(0), &json!("not_started"), &json!(4)));
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn food_that_makes_no_sense_is_refused(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    h.save_meal(&token, 1, breakfast_recipe()).await;

    let with = |key: &str, value: Value| {
        let mut recipe = breakfast_recipe();
        recipe[key] = value;
        recipe
    };
    let mut slipped = breakfast_recipe();
    slipped["ingredients"][0]["kcal_per_100g"] = json!(3790);
    for (recipe, why) in [
        (with("slot", json!("brunch")), "an unknown slot"),
        (with("name", json!("   ")), "no name"),
        (with("portions", json!(0)), "no portions"),
        (with("ingredients", json!([])), "no ingredients"),
        (slipped, "a slipped decimal point"),
    ] {
        let (status, body) = h.put(&format!("/v1/food/meals/{}", food_id(9)), Some(&token), recipe).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{why}: {body}");
    }
    let (_, home) = h.get("/v1/home", Some(&token)).await;
    assert_eq!(home["food"]["meals"].as_array().unwrap().len(), 1);

    for (body, why) in [
        (json!({"id": food_id(11), "eaten_at": "2026-11-17T11:05:00Z", "meal_id": food_id(7)}), "no such meal"),
        (json!({"id": food_id(11), "eaten_at": "2026-11-17T11:05:00Z", "meal_id": food_id(1), "servings": 0}), "nothing eaten"),
        (json!({"id": food_id(11), "eaten_at": "2026-11-17T11:05:00Z", "meal_id": food_id(1), "servings": 40}), "forty portions"),
        (json!({"id": food_id(11), "eaten_at": "2026-11-19T11:05:00Z", "meal_id": food_id(1)}), "in the future"),
    ] {
        let (status, body) = h.post("/v1/food/entries", Some(&token), Some(body)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{why}: {body}");
    }
    assert_eq!(food_entry_count(&h.state.pool).await, 0);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_live_streak_with_nothing_logged_by_noon_is_prompted_for_once(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    register_device(&h, &token).await;
    h.save_meal(&token, 1, breakfast_recipe()).await;
    let apple = MockServer::start().await;
    apple_answers(&apple, "dev", 200, None).await;
    let notifier = notifier(&h, &apple);

    // No streak is alive: nothing to keep, nothing sent.
    assert_eq!(notifier.food(at("2026-11-17T16:00:00Z")).await.unwrap(), Outcome::NothingDue);

    // Logged Sunday and Monday; on Tuesday the morning is left alone...
    h.log_meal(&token, 11, 1, "2026-11-15T11:05:00Z").await;
    h.log_meal(&token, 12, 1, "2026-11-16T11:05:00Z").await;
    assert_eq!(notifier.food(at("2026-11-17T15:59:00Z")).await.unwrap(), Outcome::Quiet);
    // ...and at noon in San Juan, with nothing logged, it prompts once.
    assert_eq!(
        notifier.food(at("2026-11-17T16:00:00Z")).await.unwrap(),
        Outcome::Sent {
            title: "Fuel: nothing logged today".into(),
            body: "Log one meal to keep your 2-day streak.".into(),
            devices: 1,
        }
    );
    assert_eq!(notifier.food(at("2026-11-17T17:00:00Z")).await.unwrap(), Outcome::AlreadySent);
    let requests = apple.received_requests().await.unwrap();
    assert_eq!(requests.len(), 1);
    assert_eq!(requests[0].headers.get("apns-collapse-id").unwrap(), "food_log_today");
    // Dropped if not delivered by 18:00, and tapping it opens the Food screen.
    assert_eq!(
        requests[0].headers.get("apns-expiration").unwrap().to_str().unwrap(),
        at("2026-11-17T22:00:00Z").timestamp().to_string()
    );
    let body: Value = serde_json::from_slice(&requests[0].body).unwrap();
    assert_eq!(body["aps"]["category"], "FOOD_LOG");
    // Never at night.
    assert_eq!(notifier.food(at("2026-11-17T23:00:00Z")).await.unwrap(), Outcome::Quiet);

    // Tuesday stayed empty, so Wednesday is the day that recovers it.
    assert_eq!(
        notifier.food(at("2026-11-18T16:00:00Z")).await.unwrap(),
        Outcome::Sent {
            title: "Fuel: yesterday was missed".into(),
            body: "One meal logged today recovers your 2-day streak. Nothing to make up.".into(),
            devices: 1,
        }
    );

    // Once the day is logged there is nothing left to prompt for.
    h.log_meal(&token, 13, 1, "2026-11-18T14:00:00Z").await;
    assert_eq!(notifier.food(at("2026-11-18T17:00:00Z")).await.unwrap(), Outcome::NothingDue);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn the_food_prompt_can_be_switched_off(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    register_device(&h, &token).await;
    h.save_meal(&token, 1, breakfast_recipe()).await;
    h.log_meal(&token, 11, 1, "2026-11-16T11:05:00Z").await;
    let apple = MockServer::start().await;
    apple_answers(&apple, "dev", 200, None).await;
    let mut notifier = notifier(&h, &apple);
    notifier.food.prompt_at = None;

    assert_eq!(notifier.food(at("2026-11-17T16:00:00Z")).await.unwrap(), Outcome::Quiet);
    assert!(apple.received_requests().await.unwrap().is_empty());
}

// --- Photo and barcode meals ----------------------------------------------

/// The start of a JPEG, which is all the backend checks a photo for.
const JPEG: &[u8] = &[0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, b'J', b'F', b'I', b'F', 0x00, 0xFF, 0xD9];

fn jpeg_base64() -> String {
    base64::Engine::encode(&base64::engine::general_purpose::STANDARD, JPEG)
}

/// A stand-in for the Spark's Ollama, and an estimator that asks it, on a
/// machine with `free_gb` of memory free.
struct Model {
    server: MockServer,
    estimator: lyfe_server::estimator::Estimator,
    _dir: tempdir::Dir,
}

impl Model {
    async fn start(h: &Harness, free_gb: u64) -> Model {
        let server = MockServer::start().await;
        let dir = tempdir::Dir::new();
        let meminfo = dir.0.join("meminfo");
        std::fs::write(&meminfo, format!("MemTotal: 128000000 kB\nMemAvailable: {} kB\n", free_gb * 1024 * 1024)).unwrap();
        let settings = lyfe_server::estimator::EstimatorSettings {
            ollama_url: Some(server.uri()),
            meminfo,
            ..Default::default()
        };
        let estimator =
            lyfe_server::estimator::Estimator::new(h.state.pool.clone(), settings, h.state.estimator_wake.clone())
                .unwrap()
                .waking(h.state.illustrator_wake.clone());
        Model { server, estimator, _dir: dir }
    }

    /// Ollama with nothing loaded, answering every chat with `content`.
    async fn answers(&self, content: &str) {
        self.server.reset().await;
        Mock::given(method("GET"))
            .and(path("/api/ps"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({"models": []})))
            .mount(&self.server)
            .await;
        Mock::given(method("POST"))
            .and(path("/api/chat"))
            .respond_with(ResponseTemplate::new(200).set_body_json(json!({
                "model": "gemma4:31b", "done": true,
                "message": {"role": "assistant", "content": content},
            })))
            .mount(&self.server)
            .await;
    }

    async fn estimate(&self) -> lyfe_server::estimator::Outcome {
        self.estimator.estimate_next().await.unwrap()
    }

    /// The chats Ollama was sent.
    async fn chats(&self) -> Vec<Value> {
        self.server
            .received_requests()
            .await
            .unwrap()
            .into_iter()
            .filter(|r| r.url.path() == "/api/chat")
            .map(|r| serde_json::from_slice(&r.body).unwrap())
            .collect()
    }
}

/// Rice and chicken, judged fried: 458 kcal and 33 g before any oil.
const STIR_FRY: &str = r#"{"items": [{"name": "Rice", "grams": 200, "kcal": 260, "protein_g": 5.4},
                                      {"name": "Chicken", "grams": 120, "kcal": 198, "protein_g": 27.6}],
                           "fried_sauced_or_restaurant": true}"#;

impl Harness {
    async fn log_photo(&self, token: &str, entry: u32, eaten_at: &str, slot: &str, note: &str) -> Value {
        let body = json!({"id": food_id(entry), "eaten_at": eaten_at, "slot": slot, "note": note,
                          "photo_jpeg": jpeg_base64()});
        let (status, home) = self.post("/v1/food/photo-entries", Some(token), Some(body)).await;
        assert_eq!(status, StatusCode::OK, "{home}");
        home
    }

    async fn correct(&self, token: &str, entry: u32, body: Value) -> (StatusCode, Value) {
        self.put(&format!("/v1/food/entries/{}/estimate", food_id(entry)), Some(token), body).await
    }

    async fn log_barcode(&self, token: &str, entry: u32, code: &str, grams: f64) -> (StatusCode, Value) {
        let body = json!({"id": food_id(entry), "eaten_at": "2026-11-17T14:00:00Z", "slot": "snack",
                          "code": code, "grams": grams});
        self.post("/v1/food/barcode-entries", Some(token), Some(body)).await
    }

    /// The food database with a protein bar and oats in it.
    async fn import_products(&self) {
        let columns = lyfe_server::routines::product::Columns::from_header(
            "code\tproduct_name\tserving_quantity\tenergy-kcal_100g\tproteins_100g",
        )
        .unwrap();
        let products: Vec<_> = ["96385074\tProtein bar\t60\t350\t33", "0055577105019\tLarge flake oats\t40\t379\t13.2"]
            .iter()
            .map(|line| columns.product(line).unwrap())
            .collect();
        let mut import = db::ProductImport::begin(&self.state.pool).await.unwrap();
        import.add(&products).await.unwrap();
        assert_eq!(import.finish().await.unwrap(), 2);
    }
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_photo_meal_counts_at_once_and_its_estimate_follows(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    let model = Model::start(&h, 72).await;
    model.answers(STIR_FRY).await;

    // 19:00 in San Juan. Logged before the model has seen it.
    let home = h.log_photo(&token, 21, "2026-11-17T23:00:00Z", "dinner", " stir fry, rice, some oil ").await;
    let food = &home["food"];
    let dinner = &food["entries"][0];
    assert_eq!((&dinner["source"], &dinner["figures"], &dinner["estimated"]), (&json!("photo"), &json!("estimating"), &json!(true)));
    assert_eq!((&dinner["name"], &dinner["kcal"]), (&json!("stir fry, rice, some oil"), &json!(0)));
    assert_eq!(dinner["photo"]["note"], "stir fry, rice, some oil");
    assert_eq!(dinner["photo"]["has_photo"], true);
    // Unknown, not zero: dinner is logged, but nothing is added to the day.
    assert_eq!((&food["kcal"], &food["unknown"]), (&json!(0), &json!(1)));
    assert_eq!(food["open_slots"], json!(["breakfast", "lunch"]));
    assert_eq!(food["streak"]["state"], "kept");

    assert_eq!(model.estimate().await, lyfe_server::estimator::Outcome::Estimated);
    assert_eq!(model.estimate().await, lyfe_server::estimator::Outcome::Idle);

    // The model was asked with the photo and the line, its context capped,
    // reasoning off, and to let go of its memory soon after.
    let chats = model.chats().await;
    assert_eq!(chats.len(), 1);
    let chat = &chats[0];
    assert_eq!((&chat["model"], &chat["think"], &chat["stream"]), (&json!("gemma4:31b"), &json!(false), &json!(false)));
    assert_eq!((&chat["options"]["num_ctx"], &chat["keep_alive"]), (&json!(8192), &json!("120s")));
    assert_eq!(chat["messages"][0]["images"], json!([jpeg_base64()]));
    assert!(chat["messages"][0]["content"].as_str().unwrap().contains("\"stir fry, rice, some oil\""));
    assert_eq!(chat["format"]["required"], json!(["items", "fried_sauced_or_restaurant"]));

    let (_, home) = h.get("/v1/home", Some(&token)).await;
    let food = &home["food"];
    let dinner = &food["entries"][0];
    assert_eq!(dinner["figures"], "known");
    // 458 kcal seen, and some oil counted until the owner says.
    assert_eq!((&dinner["kcal"], &dinner["protein_g"]), (&json!(578), &json!(33.0)));
    assert_eq!((&dinner["kcal_low"], &dinner["kcal_high"]), (&json!(380), &json!(780)));
    let photo = &dinner["photo"];
    assert_eq!((&photo["oil_asked"], &photo["oil"], &photo["oil_counted"], &photo["oil_kcal"]), (&json!(true), &Value::Null, &json!("some"), &json!(120)));
    assert_eq!(
        photo["items"],
        json!([{"name": "Rice", "grams": 200.0, "grams_seen": 200.0, "kcal": 260, "protein_g": 5.4},
               {"name": "Chicken", "grams": 120.0, "grams_seen": 120.0, "kcal": 198, "protein_g": 27.6}])
    );
    assert_eq!((&food["kcal"], &food["kcal_estimated"], &food["kcal_measured"]), (&json!(578), &json!(578), &json!(0)));
    assert_eq!((&food["kcal_low"], &food["kcal_high"], &food["unknown"]), (&json!(380), &json!(780), &json!(0)));
    assert_eq!(food["estimate_range_pct"], 35);

    // The photo can be read back.
    let response = api::router(h.state.clone())
        .oneshot(
            Request::get(format!("/v1/food/entries/{}/photo", food_id(21)))
                .header("Authorization", format!("Bearer {token}"))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.headers()["content-type"], "image/jpeg");
    assert_eq!(response.into_body().collect().await.unwrap().to_bytes().as_ref(), JPEG);
    let (status, _) = h.get(&format!("/v1/food/entries/{}/photo", food_id(21)), None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_photo_meal_sent_twice_is_logged_and_estimated_once(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    let model = Model::start(&h, 72).await;
    model.answers(STIR_FRY).await;

    h.log_photo(&token, 21, "2026-11-17T23:00:00Z", "dinner", "stir fry").await;
    h.log_photo(&token, 21, "2026-11-17T23:00:00Z", "dinner", "stir fry").await;
    assert_eq!(food_entry_count(&h.state.pool).await, 1);
    model.estimate().await;
    // Arriving again after the estimate changes nothing either.
    let home = h.log_photo(&token, 21, "2026-11-17T23:00:00Z", "dinner", "stir fry").await;
    assert_eq!(home["food"]["entries"][0]["kcal"], 578);
    assert_eq!(model.estimate().await, lyfe_server::estimator::Outcome::Idle);
    assert_eq!(model.chats().await.len(), 1);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn the_owner_corrects_a_portion_and_answers_the_oil_question(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    let model = Model::start(&h, 72).await;
    model.answers(STIR_FRY).await;
    h.log_photo(&token, 21, "2026-11-17T23:00:00Z", "dinner", "stir fry").await;
    model.estimate().await;

    // More rice than the model judged, and a lot of oil.
    let (status, home) = h.correct(&token, 21, json!({"grams": [300, 120], "oil": "a_lot"})).await;
    assert_eq!(status, StatusCode::OK, "{home}");
    let dinner = &home["food"]["entries"][0];
    assert_eq!((&dinner["kcal"], &dinner["protein_g"]), (&json!(390 + 198 + 360), &json!(35.7)));
    assert_eq!(dinner["photo"]["items"][0], json!({"name": "Rice", "grams": 300.0, "grams_seen": 200.0, "kcal": 390, "protein_g": 8.1}));
    assert_eq!((&dinner["photo"]["oil"], &dinner["photo"]["oil_kcal"]), (&json!("a_lot"), &json!(360)));
    // Still an estimate, with its range.
    assert_eq!((&dinner["estimated"], &dinner["kcal_low"]), (&json!(true), &json!(620)));

    // The oil alone, later.
    let (_, home) = h.correct(&token, 21, json!({"oil": "none"})).await;
    assert_eq!(home["food"]["entries"][0]["kcal"], 588);

    // Figures typed instead, from a menu; then back to the model's.
    let (_, home) = h.correct(&token, 21, json!({"kcal": 650, "protein_g": 41.5})).await;
    let dinner = &home["food"]["entries"][0];
    assert_eq!((&dinner["kcal"], &dinner["protein_g"], &dinner["photo"]["typed"]), (&json!(650), &json!(41.5), &json!(true)));
    assert_eq!(dinner.get("kcal_low"), None);
    let (_, home) = h.correct(&token, 21, json!({"grams": [200, 120]})).await;
    assert_eq!((&home["food"]["entries"][0]["kcal"], &home["food"]["entries"][0]["photo"]["typed"]), (&json!(458), &json!(false)));
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_meal_the_model_cannot_estimate_is_left_for_the_owner_to_type(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    let model = Model::start(&h, 72).await;
    model.answers("It looks like about 600 calories.").await;
    h.log_photo(&token, 21, "2026-11-17T16:30:00Z", "lunch", "pho").await;

    use lyfe_server::estimator::Outcome;
    assert!(matches!(model.estimate().await, Outcome::Deferred(_)));
    // A retry falls due a few seconds later; bring it forward.
    let due = || sqlx::query("update food_entries set estimate_due_at = now()").execute(&h.state.pool);
    due().await.unwrap();
    assert!(matches!(model.estimate().await, Outcome::Deferred(_)));
    due().await.unwrap();
    assert!(matches!(model.estimate().await, Outcome::GaveUp(_)));
    assert_eq!(model.estimate().await, Outcome::Idle);

    let (_, home) = h.get("/v1/home", Some(&token)).await;
    let lunch = &home["food"]["entries"][0];
    assert_eq!((&lunch["figures"], &home["food"]["unknown"]), (&json!("failed"), &json!(1)));
    assert!(lunch["photo"]["problem"].as_str().unwrap().contains("could not be used"), "{lunch}");

    // Grams cannot be corrected with nothing seen; the figures can be typed.
    let (status, _) = h.correct(&token, 21, json!({"grams": []})).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, home) = h.correct(&token, 21, json!({"kcal": 520, "protein_g": 35})).await;
    assert_eq!(status, StatusCode::OK);
    let lunch = &home["food"]["entries"][0];
    assert_eq!((&lunch["figures"], &lunch["kcal"], &lunch["photo"]["problem"]), (&json!("known"), &json!(520), &Value::Null));
    assert_eq!((&home["food"]["kcal_estimated"], &home["food"]["unknown"]), (&json!(520), &json!(0)));
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_busy_or_unreachable_spark_puts_the_estimate_off(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    h.log_photo(&token, 21, "2026-11-17T16:30:00Z", "lunch", "pho").await;
    use lyfe_server::estimator::Outcome;

    // 12 GB free: the model is not loaded, and nothing counts against it.
    let busy = Model::start(&h, 12).await;
    busy.answers(STIR_FRY).await;
    let Outcome::Deferred(why) = busy.estimate().await else { panic!("not put off") };
    assert!(why.contains("12 GB free"), "{why}");
    assert!(busy.chats().await.is_empty());
    let (_, home) = h.get("/v1/home", Some(&token)).await;
    assert_eq!(home["food"]["entries"][0]["figures"], "estimating");
    assert_eq!(home["food"]["entries"][0]["photo"]["problem"], json!(why));
    // Not due again for a while.
    assert_eq!(busy.estimate().await, Outcome::Idle);

    sqlx::query("update food_entries set estimate_due_at = now()").execute(&h.state.pool).await.unwrap();
    // Already loaded, by an earlier meal: nothing more to find room for.
    busy.server.reset().await;
    Mock::given(method("GET"))
        .and(path("/api/ps"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"models": [{"name": "gemma4:31b"}]})))
        .mount(&busy.server)
        .await;
    Mock::given(method("POST"))
        .and(path("/api/chat"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"message": {"content": STIR_FRY}})))
        .mount(&busy.server)
        .await;
    assert_eq!(busy.estimate().await, Outcome::Estimated);

    // Ollama not running at all: put off, never given up on.
    h.log_photo(&token, 22, "2026-11-17T17:30:00Z", "snack", "an apple").await;
    let gone = Model::start(&h, 72).await;
    drop(gone.server);
    for _ in 0..5 {
        sqlx::query("update food_entries set estimate_due_at = now()").execute(&h.state.pool).await.unwrap();
        let Outcome::Deferred(why) = gone.estimator.estimate_next().await.unwrap() else { panic!("given up") };
        assert!(why.contains("could not be reached"), "{why}");
    }
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_photo_meal_that_makes_no_sense_is_refused(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    h.save_meal(&token, 1, breakfast_recipe()).await;
    h.log_meal(&token, 11, 1, "2026-11-17T11:05:00Z").await;
    let photo = |changes: Value| {
        let mut body = json!({"id": food_id(21), "eaten_at": "2026-11-17T23:00:00Z", "slot": "dinner",
                              "note": "stir fry", "photo_jpeg": jpeg_base64()});
        body.as_object_mut().unwrap().extend(changes.as_object().unwrap().clone());
        body
    };
    let png = base64::Engine::encode(&base64::engine::general_purpose::STANDARD, b"\x89PNG\r\n\x1a\nxxxx");
    for (changes, why) in [
        (json!({"photo_jpeg": png}), "not a JPEG"),
        (json!({"photo_jpeg": "not base64!"}), "not base64"),
        (json!({"photo_jpeg": null, "note": "  "}), "neither a photo nor a line"),
        (json!({"slot": "brunch"}), "no such slot"),
        (json!({"note": "x".repeat(141)}), "a note too long"),
        (json!({"eaten_at": "2026-11-20T12:00:00Z"}), "in the future"),
    ] {
        let (status, _) = h.post("/v1/food/photo-entries", Some(&token), Some(photo(changes))).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{why}");
    }
    let (status, _) = h.post("/v1/food/photo-entries", None, Some(photo(json!({})))).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    assert_eq!(food_entry_count(&h.state.pool).await, 1);

    // A meal described without a photo is taken.
    let (status, home) = h.post("/v1/food/photo-entries", Some(&token), Some(photo(json!({"photo_jpeg": null})))).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(home["food"]["entries"][1]["photo"]["has_photo"], false);

    // Only a photo meal is corrected, and only as it makes sense.
    let (status, _) = h.correct(&token, 11, json!({"oil": "none"})).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let model = Model::start(&h, 72).await;
    model.answers(&STIR_FRY.replace("true", "false")).await;
    model.estimate().await;
    for (body, why) in [
        (json!({"oil": "some"}), "oil not asked about"),
        (json!({"grams": [100]}), "grams for one item of two"),
        (json!({"grams": [100, 4000]}), "4 kg of chicken"),
        (json!({"kcal": 650}), "kcal without protein"),
        (json!({"kcal": 9000, "protein_g": 40}), "9000 kcal"),
    ] {
        let (status, _) = h.correct(&token, 21, body).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{why}");
    }
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_scanned_barcode_logs_the_labels_figures_as_measured(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    h.import_products().await;

    let (status, product) = h.get("/v1/food/products/96385074", Some(&token)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        product,
        json!({"code": "96385074", "name": "Protein bar", "kcal_per_100g": 350.0, "protein_per_100g": 33.0,
               "serving_g": 60.0, "origin": "database"})
    );
    // A scanner may read the oats' EAN as its 12-digit UPC.
    let (status, oats) = h.get("/v1/food/products/055577105019", Some(&token)).await;
    assert_eq!((status, &oats["name"]), (StatusCode::OK, &json!("Large flake oats")));
    let (status, _) = h.get("/v1/food/products/00000000", Some(&token)).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, _) = h.get("/v1/food/products/abc", Some(&token)).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let (status, _) = h.get("/v1/food/products/96385074", None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    let (status, home) = h.log_barcode(&token, 31, "96385074", 60.0).await;
    assert_eq!(status, StatusCode::OK, "{home}");
    let food = &home["food"];
    let bar = &food["entries"][0];
    assert_eq!((&bar["source"], &bar["figures"], &bar["estimated"]), (&json!("barcode"), &json!("known"), &json!(false)));
    assert_eq!((&bar["name"], &bar["kcal"], &bar["protein_g"], &bar["slot"]), (&json!("Protein bar"), &json!(210), &json!(19.8), &json!("snack")));
    assert_eq!(bar["barcode"], json!({"code": "96385074", "grams": 60.0}));
    assert_eq!(bar.get("kcal_low"), None);
    assert_eq!((&food["kcal_measured"], &food["kcal_estimated"]), (&json!(210), &json!(0)));
    // Lately logged, so it can be found again without a connection.
    assert_eq!(food["products"][0]["code"], "96385074");
    // Sent twice, logged once.
    h.log_barcode(&token, 31, "96385074", 60.0).await;
    assert_eq!(food_entry_count(&h.state.pool).await, 1);

    for (code, grams) in [("123", 50.0), ("96385074", 0.0), ("96385074", 3500.0)] {
        let (status, _) = h.log_barcode(&token, 32, code, grams).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{code} {grams}");
    }
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_code_the_database_does_not_have_waits_for_its_label(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    h.import_products().await;

    // Scanned offline, say, and sent later: logged, figures unknown.
    // 175 g: 19.25 g of protein, which rounds the same however the label arrives.
    let (status, home) = h.log_barcode(&token, 31, "0628915423456", 175.0).await;
    assert_eq!(status, StatusCode::OK);
    let food = &home["food"];
    assert_eq!((&food["entries"][0]["figures"], &food["entries"][0]["name"]), (&json!("needs_label"), &json!("Barcode 0628915423456")));
    assert_eq!((&food["kcal"], &food["unknown"], &food["streak"]["state"]), (&json!(0), &json!(1), &json!("kept")));
    assert_eq!(food["products"], json!([]));

    // The owner types the label; the waiting meal gets its figures.
    let label = json!({"name": "Skyr cup", "kcal_per_100g": 63, "protein_per_100g": 11, "serving_g": 175});
    let (status, home) = h.put("/v1/food/products/628915423456", Some(&token), label.clone()).await;
    assert_eq!(status, StatusCode::OK, "{home}");
    let cup = &home["food"]["entries"][0];
    assert_eq!((&cup["figures"], &cup["name"], &cup["kcal"], &cup["protein_g"]), (&json!("known"), &json!("Skyr cup"), &json!(110), &json!(19.3)));
    assert_eq!(home["food"]["unknown"], 0);
    let (_, product) = h.get("/v1/food/products/0628915423456", Some(&token)).await;
    assert_eq!((&product["name"], &product["origin"]), (&json!("Skyr cup"), &json!("label")));

    // A label typed for a code the database has wins from then on, and
    // what was logged before keeps its figures.
    h.log_barcode(&token, 32, "96385074", 60.0).await;
    let typed = json!({"name": "Protein bar (new recipe)", "kcal_per_100g": 400, "protein_per_100g": 33});
    h.put("/v1/food/products/96385074", Some(&token), typed).await;
    let (_, product) = h.get("/v1/food/products/96385074", Some(&token)).await;
    assert_eq!((&product["name"], &product["serving_g"]), (&json!("Protein bar (new recipe)"), &Value::Null));
    let (_, home) = h.get("/v1/home", Some(&token)).await;
    let bar = home["food"]["entries"].as_array().unwrap().iter().find(|e| e["id"] == food_id(32)).unwrap().clone();
    assert_eq!(bar["kcal"], 210);

    let (status, _) =
        h.put("/v1/food/products/96385074", Some(&token), json!({"name": "Bar", "kcal_per_100g": 3500, "protein_per_100g": 33})).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_new_food_database_replaces_the_old_whole(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    h.import_products().await;
    let columns = lyfe_server::routines::product::Columns::from_header("code\tproduct_name\tenergy_100g\tproteins_100g").unwrap();
    let mut import = db::ProductImport::begin(&h.state.pool).await.unwrap();
    // Until it is finished, lookups see the old copy.
    import.add(&[columns.product("5449000000996\tCola\t180\t0").unwrap()]).await.unwrap();
    let (status, _) = h.get("/v1/food/products/96385074", Some(&token)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(import.finish().await.unwrap(), 1);
    let (status, _) = h.get("/v1/food/products/96385074", Some(&token)).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (_, cola) = h.get("/v1/food/products/5449000000996", Some(&token)).await;
    assert_eq!(cola["kcal_per_100g"], 43.0);
}

// --- Meals built from parts ----------------------------------------------

/// A scanned bar, a banana typed with its label, a coffee typed whole, and
/// the photo sent ahead as part 34: four parts of meal 30.
fn breakfast_parts() -> Value {
    json!([
        {"id": food_id(31), "code": "96385074", "grams": 60},
        {"id": food_id(32), "name": " Banana ", "grams": 120, "kcal_per_100g": 89, "protein_per_100g": 1.1},
        {"id": food_id(33), "name": "Flat white", "kcal": 120, "protein_g": 6},
        {"id": food_id(34)},
    ])
}

impl Harness {
    /// Sends a photo as a part of meal number `meal`, which may not be
    /// logged yet.
    async fn send_photo_part(&self, token: &str, entry: u32, meal: u32, note: &str) -> (StatusCode, Value) {
        let body = json!({"id": food_id(entry), "eaten_at": "2026-11-17T11:00:00Z", "slot": "snack", "note": note,
                          "photo_jpeg": jpeg_base64(), "part_of": food_id(meal)});
        self.post("/v1/food/photo-entries", Some(token), Some(body)).await
    }

    async fn log_built(&self, token: &str, meal: u32, name: &str, parts: Value) -> (StatusCode, Value) {
        let body = json!({"id": food_id(meal), "eaten_at": "2026-11-17T11:30:00Z", "slot": "breakfast",
                          "name": name, "parts": parts});
        self.post("/v1/food/built-entries", Some(token), Some(body)).await
    }
}

fn names(entries: &Value) -> Vec<&str> {
    entries.as_array().unwrap().iter().map(|entry| entry["name"].as_str().unwrap()).collect()
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_meal_is_built_from_scanned_typed_and_photographed_parts(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    h.import_products().await;
    let model = Model::start(&h, 72).await;
    model.answers(STIR_FRY).await;

    // The photo goes ahead, while the meal is still being put together.
    // It is on no day and starts no streak.
    let (status, home) = h.send_photo_part(&token, 34, 30, "eggs on toast").await;
    assert_eq!(status, StatusCode::OK, "{home}");
    let food = &home["food"];
    assert_eq!((&food["entries"], &food["unknown"], &food["kcal"]), (&json!([]), &json!(0), &json!(0)));
    assert_eq!(food["open_slots"], json!(["breakfast", "lunch", "dinner"]));
    assert_eq!(food["streak"]["state"], "not_started");
    assert_eq!((&food["drafts"][0]["id"], &food["drafts"][0]["figures"]), (&json!(food_id(34)), &json!("estimating")));

    // It is estimated all the same, and the estimate shows before the meal
    // is logged.
    assert_eq!(model.estimate().await, lyfe_server::estimator::Outcome::Estimated);
    let (_, home) = h.get("/v1/home", Some(&token)).await;
    let draft = &home["food"]["drafts"][0];
    assert_eq!((&draft["figures"], &draft["kcal"], &draft["kcal_low"]), (&json!("known"), &json!(578), &json!(380)));
    assert_eq!(draft["photo"]["items"][0]["name"], "Rice");
    assert_eq!((&home["food"]["kcal"], &home["food"]["entries"]), (&json!(0), &json!([])));

    let (status, _) = h.post("/v1/food/built-entries", None, Some(json!({}))).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);

    // 07:30 in San Juan: the meal, with its parts in the order added.
    let (status, home) = h.log_built(&token, 30, "", breakfast_parts()).await;
    assert_eq!(status, StatusCode::OK, "{home}");
    let food = &home["food"];
    assert_eq!(food["drafts"], json!([]));
    assert_eq!(food["entries"].as_array().unwrap().len(), 1);
    let meal = &food["entries"][0];
    // Unnamed, it is called by its part of the day.
    assert_eq!((&meal["id"], &meal["source"], &meal["name"], &meal["slot"]), (&json!(food_id(30)), &json!("built"), &json!("Breakfast"), &json!("breakfast")));
    assert_eq!(names(&meal["parts"]), ["Protein bar", "Banana", "Flat white", "eggs on toast"]);
    assert_eq!((&meal["kcal"], &meal["protein_g"], &meal["figures"]), (&json!(210 + 107 + 120 + 578), &json!(60.1), &json!("known")));
    assert_eq!((&meal["estimated"], &meal["kcal_estimated"]), (&json!(true), &json!(578)));
    assert_eq!((&meal["kcal_low"], &meal["kcal_high"]), (&json!(437 + 380), &json!(437 + 780)));

    let parts = &meal["parts"];
    assert_eq!((&parts[0]["source"], &parts[0]["kcal"], &parts[0]["protein_g"]), (&json!("barcode"), &json!(210), &json!(19.8)));
    assert_eq!(parts[0]["weighed"], json!({"grams": 60.0, "kcal_per_100g": 350.0, "protein_per_100g": 33.0}));
    assert_eq!((&parts[1]["source"], &parts[1]["kcal"], &parts[1]["protein_g"]), (&json!("typed"), &json!(107), &json!(1.3)));
    assert_eq!(parts[1]["weighed"], json!({"grams": 120.0, "kcal_per_100g": 89.0, "protein_per_100g": 1.1}));
    assert_eq!((&parts[2]["source"], &parts[2]["kcal"], &parts[2]["estimated"]), (&json!("typed"), &json!(120), &json!(false)));
    assert_eq!(parts[2].get("weighed"), None);
    // The photo joined the meal at the meal's part of the day.
    assert_eq!((&parts[3]["source"], &parts[3]["slot"], &parts[3]["kcal_low"]), (&json!("photo"), &json!("breakfast"), &json!(380)));

    // The day counts each part once: labels and typed figures measured,
    // the photo estimated.
    assert_eq!((&food["kcal"], &food["kcal_measured"], &food["kcal_estimated"]), (&json!(1015), &json!(437), &json!(578)));
    assert_eq!((&food["kcal_low"], &food["kcal_high"], &food["unknown"]), (&json!(817), &json!(1217), &json!(0)));
    assert_eq!(food["open_slots"], json!(["lunch", "dinner"]));
    assert_eq!((&food["streak"]["days"], &food["streak"]["state"]), (&json!(1), &json!("kept")));
    // A bar scanned as a part is known on the phone next time, like any.
    assert_eq!(food["products"][0]["code"], "96385074");

    // Arriving again changes nothing.
    let (_, home) = h.log_built(&token, 30, "", breakfast_parts()).await;
    assert_eq!(home["food"]["kcal"], 1015);
    assert_eq!(food_entry_count(&h.state.pool).await, 5);

    // A part is corrected like a meal of one thing, and its meal follows.
    let (status, home) = h.correct(&token, 34, json!({"oil": "none"})).await;
    assert_eq!(status, StatusCode::OK, "{home}");
    assert_eq!((&home["food"]["entries"][0]["kcal"], &home["food"]["kcal_estimated"]), (&json!(437 + 458), &json!(458)));

    // One part taken out; then the meal, with what is left of it.
    let (_, home) = h.delete(&format!("/v1/food/entries/{}", food_id(33)), Some(&token)).await;
    let meal = &home["food"]["entries"][0];
    assert_eq!((names(&meal["parts"]), &meal["kcal"]), (vec!["Protein bar", "Banana", "eggs on toast"], &json!(317 + 458)));
    let (_, home) = h.delete(&format!("/v1/food/entries/{}", food_id(30)), Some(&token)).await;
    assert_eq!((&home["food"]["entries"], &home["food"]["kcal"], &home["food"]["drafts"]), (&json!([]), &json!(0), &json!([])));
    assert_eq!(home["food"]["streak"]["state"], "not_started");
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_meal_is_logged_before_its_photo_is_estimated(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    h.import_products().await;
    let model = Model::start(&h, 72).await;
    model.answers(STIR_FRY).await;

    h.send_photo_part(&token, 34, 30, "eggs on toast").await;
    let (_, home) = h.log_built(&token, 30, "Big breakfast", breakfast_parts()).await;
    let food = &home["food"];
    let meal = &food["entries"][0];
    // What is known is counted; the photo is unknown, not zero.
    assert_eq!((&meal["name"], &meal["figures"], &meal["kcal"]), (&json!("Big breakfast"), &json!("estimating"), &json!(437)));
    assert_eq!((&meal["estimated"], meal.get("kcal_low")), (&json!(true), None));
    assert_eq!((&food["kcal"], &food["unknown"]), (&json!(437), &json!(1)));

    // The estimate fills its part in.
    assert_eq!(model.estimate().await, lyfe_server::estimator::Outcome::Estimated);
    let (_, home) = h.get("/v1/home", Some(&token)).await;
    let meal = &home["food"]["entries"][0];
    assert_eq!((&meal["figures"], &meal["kcal"], &meal["parts"][3]["kcal"]), (&json!("known"), &json!(1015), &json!(578)));
    assert_eq!(home["food"]["unknown"], 0);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_part_joins_a_meal_already_logged(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    h.import_products().await;
    let (status, home) = h.log_built(&token, 30, "", json!([{"id": food_id(32), "name": "Banana", "kcal": 107, "protein_g": 1.3}])).await;
    assert_eq!(status, StatusCode::OK, "{home}");

    // Sent as a snack at 10:00, it joins breakfast: the meal decides.
    let bar = json!({"id": food_id(41), "eaten_at": "2026-11-17T14:00:00Z", "slot": "snack", "code": "96385074",
                     "grams": 60, "part_of": food_id(30)});
    let (status, home) = h.post("/v1/food/barcode-entries", Some(&token), Some(bar)).await;
    assert_eq!(status, StatusCode::OK, "{home}");
    let oats = json!({"id": food_id(42), "eaten_at": "2026-11-17T14:00:00Z", "slot": "snack", "name": "Oats",
                      "grams": 80, "kcal_per_100g": 379, "protein_per_100g": 13.2, "part_of": food_id(30)});
    let (status, _) = h.post("/v1/food/typed-entries", Some(&token), Some(oats)).await;
    assert_eq!(status, StatusCode::OK);
    // A photo too, and a code nobody knows.
    let (status, _) = h.send_photo_part(&token, 43, 30, "toast").await;
    assert_eq!(status, StatusCode::OK);
    let unknown = json!({"id": food_id(44), "eaten_at": "2026-11-17T14:00:00Z", "slot": "snack",
                         "code": "0628915423456", "grams": 175, "part_of": food_id(30)});
    let (_, home) = h.post("/v1/food/barcode-entries", Some(&token), Some(unknown)).await;

    let food = &home["food"];
    assert_eq!(food["entries"].as_array().unwrap().len(), 1);
    let meal = &food["entries"][0];
    assert_eq!(names(&meal["parts"]), ["Banana", "Protein bar", "Oats", "toast", "Barcode 0628915423456"]);
    assert!(meal["parts"].as_array().unwrap().iter().all(|part| part["slot"] == "breakfast"));
    // The photo is still with the model and the code has no label: both
    // unknown, the rest counted.
    assert_eq!((&meal["kcal"], &meal["figures"]), (&json!(107 + 210 + 303), &json!("estimating")));
    assert_eq!((&food["kcal"], &food["unknown"], &food["drafts"]), (&json!(620), &json!(2), &json!([])));
    assert_eq!(food["open_slots"], json!(["lunch", "dinner"]));

    // Typing the label fills that part in.
    let label = json!({"name": "Skyr cup", "kcal_per_100g": 63, "protein_per_100g": 11, "serving_g": 175});
    let (_, home) = h.put("/v1/food/products/0628915423456", Some(&token), label).await;
    let skyr = &home["food"]["entries"][0]["parts"][4];
    assert_eq!((&skyr["name"], &skyr["kcal"], &skyr["figures"]), (&json!("Skyr cup"), &json!(110), &json!("known")));
    assert_eq!(skyr["weighed"], json!({"grams": 175.0, "kcal_per_100g": 63.0, "protein_per_100g": 11.0}));

    // Only a logged built meal takes parts. A photo may go ahead of its
    // meal; anything else needs the meal to be there.
    h.save_meal(&token, 1, breakfast_recipe()).await;
    h.log_meal(&token, 11, 1, "2026-11-17T11:05:00Z").await;
    for part_of in [food_id(11), food_id(99)] {
        let stray = json!({"id": food_id(45), "eaten_at": "2026-11-17T14:00:00Z", "slot": "snack", "code": "96385074",
                           "grams": 60, "part_of": part_of});
        let (status, _) = h.post("/v1/food/barcode-entries", Some(&token), Some(stray)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        let stray = json!({"id": food_id(46), "eaten_at": "2026-11-17T14:00:00Z", "slot": "snack", "name": "Oats",
                           "kcal": 300, "protein_g": 10, "part_of": part_of});
        let (status, _) = h.post("/v1/food/typed-entries", Some(&token), Some(stray)).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }
    let (status, _) = h.send_photo_part(&token, 47, 11, "toast").await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // The last part taken out takes the meal with it.
    let mut home = Value::Null;
    for part in [32, 41, 42, 43, 44] {
        (_, home) = h.delete(&format!("/v1/food/entries/{}", food_id(part)), Some(&token)).await;
    }
    assert_eq!(names(&home["food"]["entries"]), ["Usual breakfast"]);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_typed_food_is_logged_as_measured(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;

    let coffee = json!({"id": food_id(51), "eaten_at": "2026-11-17T14:00:00Z", "slot": "snack",
                        "name": " Flat white ", "kcal": 120, "protein_g": 6, "carbs_g": 9, "fat_g": 6.5});
    let (status, _) = h.post("/v1/food/typed-entries", None, Some(coffee.clone())).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (status, home) = h.post("/v1/food/typed-entries", Some(&token), Some(coffee.clone())).await;
    assert_eq!(status, StatusCode::OK, "{home}");
    assert_eq!(
        home["food"]["entries"],
        json!([{"id": food_id(51), "slot": "snack", "name": "Flat white", "meal_id": null, "servings": 1.0,
                "kcal": 120, "protein_g": 6.0, "carbs_g": 9.0, "fat_g": 6.5, "source": "typed", "figures": "known", "estimated": false}])
    );
    assert_eq!((&home["food"]["kcal_measured"], &home["food"]["kcal_estimated"]), (&json!(120), &json!(0)));
    // Sent twice, logged once.
    h.post("/v1/food/typed-entries", Some(&token), Some(coffee)).await;
    assert_eq!(food_entry_count(&h.state.pool).await, 1);

    let typed = |fields: Value| {
        let mut body = json!({"id": food_id(52), "eaten_at": "2026-11-17T14:00:00Z", "slot": "snack"});
        body.as_object_mut().unwrap().extend(fields.as_object().unwrap().clone());
        body
    };
    for wrong in [
        json!({"name": "Oats"}),
        json!({"name": "Oats", "grams": 80}),
        // Both ways of saying it at once.
        json!({"name": "Oats", "grams": 80, "kcal_per_100g": 379, "protein_per_100g": 13.2, "kcal": 300, "protein_g": 10}),
        json!({"name": "", "kcal": 300, "protein_g": 10}),
        json!({"name": "Oats", "kcal": 30000, "protein_g": 10}),
        json!({"name": "Oats", "grams": 80, "kcal_per_100g": 3790, "protein_per_100g": 13.2}),
        json!({"name": "Oats", "grams": 0, "kcal_per_100g": 379, "protein_per_100g": 13.2}),
        json!({"name": "Oats", "grams": 80, "kcal_per_100g": 379, "protein_per_100g": 13.2, "fat_g": 90}),
    ] {
        let (status, body) = h.post("/v1/food/typed-entries", Some(&token), Some(typed(wrong.clone()))).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{wrong} {body}");
    }
    let mut elsewhen = typed(json!({"name": "Oats", "kcal": 300, "protein_g": 10}));
    elsewhen["slot"] = json!("brunch");
    let (status, _) = h.post("/v1/food/typed-entries", Some(&token), Some(elsewhen)).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(food_entry_count(&h.state.pool).await, 1);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_built_meal_that_makes_no_sense_is_refused(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    for parts in [
        json!([]),
        json!([{"id": food_id(31), "code": "963", "grams": 60}]),
        json!([{"id": food_id(31), "code": "96385074"}]),
        json!([{"id": food_id(31), "code": "96385074", "grams": 5000}]),
        json!([{"id": food_id(31), "name": "Banana", "grams": 120}]),
        // One bad part refuses the whole meal.
        json!([{"id": food_id(31), "name": "Banana", "kcal": 107, "protein_g": 1.3},
               {"id": food_id(32), "name": "Oats", "kcal": -1, "protein_g": 10}]),
    ] {
        let (status, body) = h.log_built(&token, 30, "", parts.clone()).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{parts} {body}");
    }
    let banana = json!([{"id": food_id(31), "name": "Banana", "kcal": 107, "protein_g": 1.3}]);
    let (status, _) = h.log_built(&token, 30, &"x".repeat(61), banana.clone()).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    let mut future = json!({"id": food_id(30), "eaten_at": "2026-11-19T11:30:00Z", "slot": "breakfast", "parts": banana});
    let (status, _) = h.post("/v1/food/built-entries", Some(&token), Some(future.clone())).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    future["eaten_at"] = json!("2026-11-17T11:30:00Z");
    future["slot"] = json!("brunch");
    let (status, _) = h.post("/v1/food/built-entries", Some(&token), Some(future)).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);
    assert_eq!(food_entry_count(&h.state.pool).await, 0);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_photo_for_a_meal_never_logged_counts_for_nothing(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    let model = Model::start(&h, 72).await;
    model.answers(STIR_FRY).await;

    h.send_photo_part(&token, 34, 30, "eggs on toast").await;
    model.estimate().await;
    // Thrown away with the meal it was for.
    let (_, home) = h.delete(&format!("/v1/food/entries/{}", food_id(34)), Some(&token)).await;
    assert_eq!((&home["food"]["drafts"], &home["food"]["entries"]), (&json!([]), &json!([])));

    // One the phone never came back for is dropped a week on, the next
    // time a photo is sent ahead.
    h.send_photo_part(&token, 35, 30, "toast").await;
    sqlx::query("update food_entries set received_at = now() - interval '8 days' where id = $1::uuid")
        .bind(food_id(35))
        .execute(&h.state.pool)
        .await
        .unwrap();
    let (_, home) = h.send_photo_part(&token, 36, 31, "pho").await;
    assert_eq!(names(&home["food"]["drafts"]), ["pho"]);
    assert_eq!(home["food"]["streak"]["state"], "not_started");
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_saved_meal_keeps_a_photos_estimate_as_an_estimate(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;

    // Saved from a meal that was built: yogurt scanned, a coffee typed
    // whole, and what a photo of eggs on toast was estimated at.
    let recipe = json!({
        "name": "Café breakfast", "slot": "breakfast", "portions": 1,
        "ingredients": [
            {"name": "Greek yogurt", "grams": 175, "kcal_per_100g": 63, "protein_per_100g": 11, "code": "0 64200 11589 6"},
            {"name": "Flat white", "kcal": 120, "protein_g": 6},
            {"name": "Eggs on toast", "kcal": 192.4, "protein_g": 23, "estimated": true},
        ],
    });
    let home = h.save_meal(&token, 3, recipe.clone()).await;
    let meal = &home["food"]["meals"][0];
    assert_eq!((&meal["kcal"], &meal["protein_g"], &meal["kcal_estimated"]), (&json!(423), &json!(48.3), &json!(192)));
    assert_eq!(
        meal["ingredients"],
        json!([
            {"name": "Greek yogurt", "grams": 175.0, "kcal_per_100g": 63.0, "protein_per_100g": 11.0, "code": "064200115896"},
            {"name": "Flat white", "kcal": 120.0, "protein_g": 6.0},
            {"name": "Eggs on toast", "kcal": 192.4, "protein_g": 23.0, "estimated": true},
        ])
    );

    // One tap, every time: the photo's part stays estimated.
    let home = h.log_meal(&token, 11, 3, "2026-11-17T11:05:00Z").await;
    let food = &home["food"];
    let logged = &food["entries"][0];
    assert_eq!((&logged["source"], &logged["kcal"], &logged["estimated"], &logged["kcal_estimated"]), (&json!("saved"), &json!(423), &json!(true), &json!(192)));
    assert_eq!((&logged["kcal_low"], &logged["kcal_high"]), (&json!(351), &json!(491)));
    assert_eq!((&food["kcal"], &food["kcal_measured"], &food["kcal_estimated"]), (&json!(423), &json!(231), &json!(192)));
    assert_eq!((&food["protein_measured_g"], &food["protein_estimated_g"]), (&json!(25.3), &json!(23.0)));

    // Saving it again replaces the recipe whole, estimate included.
    let mut weighed = recipe;
    weighed["ingredients"][2] = json!({"name": "Eggs on toast", "grams": 150, "kcal_per_100g": 130, "protein_per_100g": 15});
    let home = h.save_meal(&token, 3, weighed).await;
    let meal = &home["food"]["meals"][0];
    assert_eq!((&meal["kcal"], meal.get("kcal_estimated")), (&json!(425), None));
    // What was logged keeps the figures it was logged with.
    assert_eq!(home["food"]["kcal_estimated"], 192);

    for wrong in [
        json!({"name": "Flat white", "kcal": 120}),
        json!({"name": "Flat white", "grams": 200, "kcal": 120, "protein_g": 6}),
        json!({"name": "Flat white", "kcal": 120, "protein_g": 6, "code": "12"}),
    ] {
        let recipe = json!({"name": "Coffee", "slot": "snack", "portions": 1, "ingredients": [wrong]});
        let (status, _) = h.put(&format!("/v1/food/meals/{}", food_id(4)), Some(&token), recipe).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
    }
}

// --- Meal illustrations ---------------------------------------------------

/// The stand-in illustrator (`tests/illustrator_stand_in.py`), started the
/// way the Spark's is, on a machine with `free_gb` of memory free. What it
/// is asked is written to a file to look at afterwards.
struct Drawer {
    illustrator: lyfe_server::illustrator::Illustrator,
    log: PathBuf,
    _dir: tempdir::Dir,
}

impl Drawer {
    async fn start(h: &Harness, free_gb: u64, how: &[&str]) -> Drawer {
        let dir = tempdir::Dir::new();
        let meminfo = dir.0.join("meminfo");
        std::fs::write(&meminfo, format!("MemTotal: 128000000 kB\nMemAvailable: {} kB\n", free_gb * 1024 * 1024)).unwrap();
        let log = dir.0.join("asked.jsonl");
        let script = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/illustrator_stand_in.py");
        let mut program: Vec<String> = ["python3", "-I", script, "--log"].map(String::from).to_vec();
        program.push(log.to_string_lossy().into_owned());
        program.extend(how.iter().map(|arg| arg.to_string()));
        Drawer::with(h, Some(program), meminfo, log, dir)
    }

    fn with(h: &Harness, program: Option<Vec<String>>, meminfo: PathBuf, log: PathBuf, dir: tempdir::Dir) -> Drawer {
        let settings = lyfe_server::illustrator::IllustratorSettings {
            program,
            meminfo,
            // Let go as soon as nothing is waiting.
            keep_alive: std::time::Duration::ZERO,
            ..Default::default()
        };
        let illustrator =
            lyfe_server::illustrator::Illustrator::new(h.state.pool.clone(), settings, h.state.illustrator_wake.clone());
        Drawer { illustrator, log, _dir: dir }
    }

    async fn draw(&self) -> lyfe_server::illustrator::Outcome {
        self.illustrator.run_once().await.unwrap()
    }

    /// What the illustrator was asked to draw.
    fn asked(&self) -> Vec<Value> {
        std::fs::read_to_string(&self.log)
            .unwrap_or_default()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect()
    }
}

impl Harness {
    /// The illustration of meal number `entry`: its status and the bytes.
    async fn illustration(&self, token: Option<&str>, entry: u32) -> (StatusCode, Option<String>, Vec<u8>) {
        let mut request = Request::get(format!("/v1/food/entries/{}/illustration", food_id(entry)));
        if let Some(token) = token {
            request = request.header("Authorization", format!("Bearer {token}"));
        }
        let response = api::router(self.state.clone()).oneshot(request.body(Body::empty()).unwrap()).await.unwrap();
        let status = response.status();
        let kind = response.headers().get("content-type").map(|v| v.to_str().unwrap().to_string());
        let bytes = response.into_body().collect().await.unwrap().to_bytes().to_vec();
        (status, kind, bytes)
    }
}

/// Brings every illustration's next try forward to now.
async fn illustrations_due(pool: &PgPool) {
    sqlx::query("update food_photos set illustration_due_at = now() where illustration_due_at is not null")
        .execute(pool)
        .await
        .unwrap();
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_photo_meal_is_illustrated_after_its_estimate_without_holding_it_up(pool: PgPool) {
    use lyfe_server::illustrator::Outcome;
    let h = harness(pool).await;
    let token = h.signed_in().await;
    let model = Model::start(&h, 72).await;
    model.answers(STIR_FRY).await;
    let drawer = Drawer::start(&h, 72, &[]).await;

    // Logged and counted at once, with no illustration yet: the app shows
    // the photo.
    let home = h.log_photo(&token, 21, "2026-11-17T23:00:00Z", "dinner", "stir fry, rice, some oil").await;
    let dinner = &home["food"]["entries"][0];
    assert_eq!((&dinner["photo"]["has_photo"], &dinner["photo"]["illustrated"]), (&json!(true), &json!(false)));
    assert_eq!(dinner["photo"]["illustration_version"], Value::Null);
    assert_eq!(home["food"]["streak"]["state"], "kept");
    assert_eq!(h.illustration(Some(&token), 21).await.0, StatusCode::NOT_FOUND);

    // The illustrator was woken by the photo arriving...
    let woken = || tokio::time::timeout(std::time::Duration::from_millis(50), h.state.illustrator_wake.notified());
    assert!(woken().await.is_ok());
    // ...but the estimate comes first: the two models are not loaded for it
    // at once. It is woken again when the estimate is in.
    assert_eq!(drawer.draw().await, Outcome::Idle);
    assert!(drawer.asked().is_empty());
    assert!(woken().await.is_err());
    model.estimate().await;
    assert!(woken().await.is_ok());

    assert_eq!(drawer.draw().await, Outcome::Drew(1));
    assert_eq!(drawer.draw().await, Outcome::Idle);
    let asked = drawer.asked();
    assert_eq!(asked.len(), 1);
    assert_eq!(asked[0]["id"], food_id(21));
    assert_eq!(asked[0]["jpeg"], jpeg_base64());
    let prompt = asked[0]["prompt"].as_str().unwrap();
    assert!(prompt.starts_with("Redraw this photo of stir fry, rice, some oil as a bold flat graphic illustration"), "{prompt}");
    assert!(prompt.ends_with("Centred on a plain off-white background. No text."), "{prompt}");

    let (_, home) = h.get("/v1/home", Some(&token)).await;
    let dinner = &home["food"]["entries"][0];
    assert_eq!(dinner["photo"]["illustrated"], true);
    assert!(dinner["photo"]["illustration_version"].as_i64().unwrap() > 0);
    // Drawing it changed nothing that counts.
    assert_eq!((&dinner["kcal"], &home["food"]["kcal"]), (&json!(578), &json!(578)));

    let (status, kind, png) = h.illustration(Some(&token), 21).await;
    assert_eq!((status, kind.as_deref()), (StatusCode::OK, Some("image/png")));
    assert!(png.starts_with(b"\x89PNG\r\n\x1a\n"));
    assert_eq!(h.illustration(None, 21).await.0, StatusCode::UNAUTHORIZED);
    // The photo is still there to look at.
    assert_eq!(h.get(&format!("/v1/food/entries/{}/photo", food_id(21)), Some(&token)).await.0, StatusCode::OK);

    // A meal taken back is not shown, drawn or not.
    h.delete(&format!("/v1/food/entries/{}", food_id(21)), Some(&token)).await;
    assert_eq!(h.illustration(Some(&token), 21).await.0, StatusCode::NOT_FOUND);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn photos_logged_together_are_drawn_with_one_load_and_only_photos_are_drawn(pool: PgPool) {
    use lyfe_server::illustrator::Outcome;
    let h = harness(pool).await;
    let token = h.signed_in().await;
    let model = Model::start(&h, 72).await;
    model.answers(STIR_FRY).await;
    h.log_photo(&token, 21, "2026-11-17T16:00:00Z", "lunch", "pho").await;
    h.log_photo(&token, 22, "2026-11-17T23:00:00Z", "dinner", "").await;
    // Described in words only: there is nothing to draw from.
    let body = json!({"id": food_id(23), "eaten_at": "2026-11-17T20:00:00Z", "slot": "snack", "note": "an apple"});
    assert_eq!(h.post("/v1/food/photo-entries", Some(&token), Some(body)).await.0, StatusCode::OK);
    // One taken back before it was drawn.
    h.log_photo(&token, 24, "2026-11-17T21:00:00Z", "snack", "chips").await;
    h.delete(&format!("/v1/food/entries/{}", food_id(24)), Some(&token)).await;
    while model.estimate().await != lyfe_server::estimator::Outcome::Idle {}

    let drawer = Drawer::start(&h, 72, &[]).await;
    assert_eq!(drawer.draw().await, Outcome::Drew(2));
    let asked = drawer.asked();
    assert_eq!(asked.iter().map(|a| a["id"].as_str().unwrap()).collect::<Vec<_>>(), [food_id(21), food_id(22)]);
    // No line: the photo alone says what it is.
    assert!(asked[1]["prompt"].as_str().unwrap().starts_with("Redraw this photo of a meal as a bold flat"));
    let (_, home) = h.get("/v1/home", Some(&token)).await;
    let illustrated: Vec<_> = home["food"]["entries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| (e["name"].as_str().unwrap(), &e["photo"]["illustrated"]))
        .collect();
    assert_eq!(illustrated, [("pho", &json!(true)), ("Photo meal", &json!(true)), ("an apple", &json!(false))]);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_photo_sent_ahead_is_drawn_once_its_meal_is_logged(pool: PgPool) {
    use lyfe_server::illustrator::Outcome;
    let h = harness(pool).await;
    let token = h.signed_in().await;
    h.import_products().await;
    let model = Model::start(&h, 72).await;
    model.answers(STIR_FRY).await;
    let drawer = Drawer::start(&h, 72, &[]).await;

    // Still being put together on the phone: on no day, so not drawn; it
    // may yet be thrown away.
    h.send_photo_part(&token, 34, 30, "eggs on toast").await;
    model.estimate().await;
    assert_eq!(drawer.draw().await, Outcome::Idle);

    let (status, _) = h.log_built(&token, 30, "", breakfast_parts()).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(drawer.draw().await, Outcome::Drew(1));
    let (_, home) = h.get("/v1/home", Some(&token)).await;
    let parts = &home["food"]["entries"][0]["parts"];
    assert_eq!((&parts[3]["source"], &parts[3]["photo"]["illustrated"]), (&json!("photo"), &json!(true)));
    assert_eq!(h.illustration(Some(&token), 34).await.0, StatusCode::OK);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_busy_spark_or_a_missing_illustrator_puts_illustrations_off(pool: PgPool) {
    use lyfe_server::illustrator::Outcome;
    let h = harness(pool).await;
    let token = h.signed_in().await;
    let model = Model::start(&h, 72).await;
    model.answers(STIR_FRY).await;
    h.log_photo(&token, 21, "2026-11-17T16:00:00Z", "lunch", "pho").await;
    model.estimate().await;

    // 12 GB free: the program is not even started.
    let busy = Drawer::start(&h, 12, &[]).await;
    let Outcome::PutOff(why) = busy.draw().await else { panic!("not put off") };
    assert_eq!(why, "The Spark is busy: 12 GB free, and the illustrator needs 24.");
    assert!(busy.asked().is_empty());
    // Not due again for a while.
    assert_eq!(busy.draw().await, Outcome::Idle);

    // Not installed yet.
    illustrations_due(&h.state.pool).await;
    let dir = tempdir::Dir::new();
    let meminfo = dir.0.join("meminfo");
    std::fs::write(&meminfo, "MemAvailable: 75000000 kB\n").unwrap();
    let missing = Drawer::with(&h, Some(vec!["/no/such/lyfe-illustrate".into()]), meminfo, dir.0.join("log"), dir);
    let Outcome::PutOff(why) = missing.draw().await else { panic!("not put off") };
    assert_eq!(why, "The illustrator is not installed (/no/such/lyfe-illustrate).");

    // The model would not load.
    illustrations_due(&h.state.pool).await;
    let failing = Drawer::start(&h, 72, &["--fail-load"]).await;
    let Outcome::PutOff(why) = failing.draw().await else { panic!("not put off") };
    assert_eq!(why, "The illustrator could not load the model: CUDA out of memory (stand-in).");

    // None of that is the photo's fault: it is drawn once the Spark can.
    for _ in 0..5 {
        illustrations_due(&h.state.pool).await;
        assert!(matches!(busy.draw().await, Outcome::PutOff(_)));
    }
    illustrations_due(&h.state.pool).await;
    assert_eq!(Drawer::start(&h, 72, &[]).await.draw().await, Outcome::Drew(1));
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_photo_that_cannot_be_drawn_keeps_showing_the_photo(pool: PgPool) {
    use lyfe_server::illustrator::Outcome;
    let h = harness(pool).await;
    let token = h.signed_in().await;
    let model = Model::start(&h, 72).await;
    model.answers(STIR_FRY).await;
    h.log_photo(&token, 21, "2026-11-17T16:00:00Z", "lunch", "pho").await;
    model.estimate().await;

    // Answered with an error, then the program dying on it: each counts.
    let cannot = Drawer::start(&h, 72, &["--cannot-draw"]).await;
    assert_eq!(cannot.draw().await, Outcome::Drew(0));
    // Tried again a minute later, not at once.
    assert_eq!(cannot.draw().await, Outcome::Idle);
    illustrations_due(&h.state.pool).await;
    let dying = Drawer::start(&h, 72, &["--exit-on-draw"]).await;
    assert_eq!(dying.draw().await, Outcome::Drew(0));
    illustrations_due(&h.state.pool).await;
    assert_eq!(cannot.draw().await, Outcome::Drew(0));

    // Three times: given up on, and never tried again.
    illustrations_due(&h.state.pool).await;
    assert_eq!(Drawer::start(&h, 72, &[]).await.draw().await, Outcome::Idle);
    let (problem, tries): (Option<String>, i32) =
        sqlx::query_as("select illustration_problem, illustration_tries from food_photos").fetch_one(&h.state.pool).await.unwrap();
    assert_eq!(tries, 3);
    assert_eq!(problem.as_deref(), Some("The illustrator could not draw it: cannot identify image file (stand-in)."));

    let (_, home) = h.get("/v1/home", Some(&token)).await;
    let lunch = &home["food"]["entries"][0];
    assert_eq!((&lunch["photo"]["illustrated"], &lunch["kcal"]), (&json!(false), &json!(578)));
    assert_eq!(h.illustration(Some(&token), 21).await.0, StatusCode::NOT_FOUND);
    assert_eq!(h.get(&format!("/v1/food/entries/{}/photo", food_id(21)), Some(&token)).await.0, StatusCode::OK);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_photo_drawn_in_an_older_look_is_drawn_again(pool: PgPool) {
    use lyfe_server::illustrator::Outcome;
    let h = harness(pool).await;
    let token = h.signed_in().await;
    let model = Model::start(&h, 72).await;
    model.answers(STIR_FRY).await;
    h.log_photo(&token, 21, "2026-11-17T16:00:00Z", "lunch", "pho").await;
    h.log_photo(&token, 22, "2026-11-17T23:00:00Z", "dinner", "stir fry").await;
    while model.estimate().await != lyfe_server::estimator::Outcome::Idle {}
    let drawer = Drawer::start(&h, 72, &[]).await;
    assert_eq!(drawer.draw().await, Outcome::Drew(2));
    let version = |home: &Value, n: usize| home["food"]["entries"][n]["photo"]["illustration_version"].as_i64();
    let (_, home) = h.get("/v1/home", Some(&token)).await;
    let (lunch_first, dinner_first) = (version(&home, 0).unwrap(), version(&home, 1).unwrap());

    // Drawn in the look of now: nothing to do when the server starts.
    assert_eq!(db::redraw_older_looks(&h.state.pool).await.unwrap(), 0);
    assert_eq!(drawer.draw().await, Outcome::Idle);

    // The lunch as if drawn in the first look, some time ago.
    sqlx::query("update food_photos set illustration_look = 1, illustration = '\\x89504e470d0a1a0a6f6c64'::bytea, illustrated_at = illustrated_at - interval '1 day' where entry_id = $1::uuid")
        .bind(food_id(21))
        .execute(&h.state.pool)
        .await
        .unwrap();
    let (_, home) = h.get("/v1/home", Some(&token)).await;
    let lunch_old = version(&home, 0).unwrap();
    assert!(lunch_old < lunch_first);
    assert_eq!(db::redraw_older_looks(&h.state.pool).await.unwrap(), 1);
    assert_eq!(db::redraw_older_looks(&h.state.pool).await.unwrap(), 0);

    // Until it is drawn again, the old drawing is still the one shown.
    let (status, _, old) = h.illustration(Some(&token), 21).await;
    assert_eq!((status, old.ends_with(b"old")), (StatusCode::OK, true));
    // A try that fails leaves it there too.
    let cannot = Drawer::start(&h, 72, &["--cannot-draw"]).await;
    assert_eq!(cannot.draw().await, Outcome::Drew(0));
    assert!(h.illustration(Some(&token), 21).await.2.ends_with(b"old"));

    illustrations_due(&h.state.pool).await;
    assert_eq!(drawer.draw().await, Outcome::Drew(1));
    assert_eq!(drawer.asked().last().unwrap()["id"], food_id(21));
    let (_, _, new) = h.illustration(Some(&token), 21).await;
    assert!(!new.ends_with(b"old") && new.starts_with(b"\x89PNG"));
    // Its version moved on, so the phone fetches it again; the dinner's did not.
    let (_, home) = h.get("/v1/home", Some(&token)).await;
    assert!(version(&home, 0).unwrap() > lunch_old);
    assert_eq!(version(&home, 1), Some(dinner_first));
    let look: i32 = sqlx::query_scalar("select illustration_look from food_photos where entry_id = $1::uuid")
        .bind(food_id(21))
        .fetch_one(&h.state.pool)
        .await
        .unwrap();
    assert_eq!(look, lyfe_server::routines::illustration::LOOK);
}

// --- Money ---------------------------------------------------------------

use lyfe_server::money::sync::{ImportError, ImportReport, Importer};
use lyfe_server::money::{BridgeClient, BridgeError};

/// A harness whose importer asks `bridge` instead of SimpleFIN Bridge.
async fn banked(pool: PgPool) -> (Harness, MockServer) {
    let mut h = harness(pool.clone()).await;
    let bridge = MockServer::start().await;
    let access_file = h._key_dir.0.join("simplefin-access");
    let address = format!("{}/simplefin\n", bridge.uri().replace("http://", "http://lyfe:se%40cret@"));
    std::fs::write(&access_file, address).unwrap();
    let client = BridgeClient::new(access_file).unwrap();
    h.state.money = Arc::new(Importer::new(pool, Some(client), h.state.timezone, 180, 14));
    (h, bridge)
}

/// Serves `body` as the bridge's whole answer until replaced, to a caller
/// who gives the user name and password from the access address.
async fn bridge_answers(bridge: &MockServer, body: Value) {
    use base64::Engine;
    bridge.reset().await;
    let basic = base64::engine::general_purpose::STANDARD.encode("lyfe:se@cret");
    Mock::given(method("GET"))
        .and(path("/simplefin/accounts"))
        .and(header("Authorization", format!("Basic {basic}")))
        .and(query_param("version", "2"))
        .respond_with(ResponseTemplate::new(200).set_body_json(body))
        .mount(bridge)
        .await;
}

async fn bridge_fails(bridge: &MockServer, status: u16) {
    bridge.reset().await;
    Mock::given(method("GET")).respond_with(ResponseTemplate::new(status)).mount(bridge).await;
}

/// Banks give a date and no time, which arrives as noon UTC.
fn noon(day: &str) -> i64 {
    at(&format!("{day}T12:00:00Z")).timestamp()
}

fn posted(id: &str, day: &str, amount: &str, payee: &str) -> Value {
    json!({"id": id, "posted": noon(day), "transacted_at": noon(day), "amount": amount,
           "description": format!("POS {} 0031", payee.to_uppercase()), "payee": payee, "memo": ""})
}

fn bank_account(id: &str, name: &str, balance: &str, transactions: Vec<Value>) -> Value {
    json!({"id": id, "name": name, "conn_id": "CON-1", "currency": "CAD", "balance": balance,
           "balance-date": noon("2026-11-17"), "transactions": transactions})
}

fn bridge_answer(accounts: Vec<Value>, errlist: Value) -> Value {
    json!({
        "errlist": errlist,
        "connections": [{"conn_id": "CON-1", "name": "First Bank", "org_id": "ORG-1", "sfin_url": "https://bridge.invalid"}],
        "accounts": accounts,
    })
}

/// A chequing account and a card, with a card payment between them.
fn chequing_and_card() -> (Vec<Value>, Vec<Value>) {
    (
        vec![
            posted("T1", "2026-11-03", "-45.10", "Corner Grocer"),
            posted("T2", "2026-11-10", "-500.00", "Card payment"),
            posted("T3", "2026-11-14", "3000.00", "Employer"),
            posted("T4", "2026-10-20", "-900.00", "Landlord"),
        ],
        vec![
            posted("C1", "2026-11-02", "-80.00", "Noodle Bar"),
            posted("C2", "2026-11-12", "500.00", "Payment received"),
            posted("C3", "2026-11-05", "-39.90", "Corner Grocer #2"),
        ],
    )
}

fn two_accounts(chequing: Vec<Value>, card: Vec<Value>) -> Value {
    bridge_answer(
        vec![bank_account("ACT-1", "Chequing", "2500.00", chequing), bank_account("ACT-2", "Card", "-120.00", card)],
        json!([]),
    )
}

impl Harness {
    async fn import(&self) -> ImportReport {
        self.import_at((self.state.now)()).await.expect("import succeeds")
    }

    async fn import_at(&self, now: DateTime<Utc>) -> Result<ImportReport, ImportError> {
        self.state.money.import_once(now).await.expect("the bridge is configured")
    }

    async fn money(&self, token: &str) -> Value {
        let (status, body) = self.get("/v1/money", Some(token)).await;
        assert_eq!(status, StatusCode::OK, "{body}");
        body
    }

    /// Sorts the entry called `name` and answers with the month.
    async fn sort(&self, token: &str, name: &str, body: Value) -> (StatusCode, Value) {
        let money = self.money(token).await;
        let id = entry_named(&money, name)["id"].as_str().unwrap().to_string();
        self.post(&format!("/v1/money/entries/{id}/sort"), Some(token), Some(body)).await
    }
}

fn entry_named<'a>(money: &'a Value, name: &str) -> &'a Value {
    money["entries"]
        .as_array()
        .unwrap()
        .iter()
        .find(|entry| entry["name"] == name)
        .unwrap_or_else(|| panic!("no entry called {name} in {}", money["entries"]))
}

fn category(money: &Value, name: &str) -> Value {
    money["categories"].as_array().unwrap().iter().find(|c| c["name"] == name).cloned().unwrap_or(Value::Null)
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_month_of_spending_is_imported_and_a_card_payment_is_not_spent_twice(pool: PgPool) {
    let (h, bridge) = banked(pool).await;
    let token = h.signed_in().await;
    let (chequing, card) = chequing_and_card();
    bridge_answers(&bridge, two_accounts(chequing, card)).await;

    let report = h.import().await;
    assert_eq!((report.accounts, report.new, report.changed, report.unreadable), (2, 7, 0, 0));

    let (status, _) = h.get("/v1/money", None).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let money = h.money(&token).await;
    assert_eq!((&money["month"], &money["current"], &money["currency"]), (&json!("2026-11"), &json!(true), &json!("CAD")));
    // The groceries twice and the noodles; not the 500 that paid the card.
    assert_eq!(money["spent_minor"], 4510 + 8000 + 3990);
    assert_eq!(money["unsorted_minor"], 16500);
    assert_eq!(money["income_minor"], 300000);
    // Three things bought and the pay, which is waiting to be called income.
    assert_eq!(money["to_sort"], 4);
    assert_eq!(money["categories"], json!([]));
    assert_eq!(money["entries"].as_array().unwrap().len(), 6);
    for half in ["Card payment", "Payment received"] {
        let entry = entry_named(&money, half);
        assert_eq!((&entry["kind"], &entry["sorted_by"], &entry["to_sort"]), (&json!("transfer"), &json!("match"), &json!(false)));
    }
    assert_eq!(
        entry_named(&money, "Corner Grocer #2"),
        &json!({"id": entry_named(&money, "Corner Grocer #2")["id"], "day": "2026-11-05", "name": "Corner Grocer #2",
                "amount_minor": -3990, "currency": "CAD", "kind": "expense", "category": null, "sorted_by": "auto",
                "to_sort": true, "has_payee": true, "account": "Card"})
    );
    // What is in the bank less what is owed on the card.
    assert_eq!((&money["everyday_minor"], &money["set_aside_minor"]), (&json!(238000), &json!(0)));
    let accounts = money["accounts"].as_array().unwrap();
    assert_eq!(accounts.len(), 2);
    assert_eq!(
        (&accounts[0]["name"], &accounts[0]["connection"], &accounts[0]["balance_minor"], &accounts[0]["stale"]),
        (&json!("Card"), &json!("First Bank"), &json!(-12000), &json!(false))
    );
    assert_eq!(accounts[0]["balance_at"], "2026-11-17T12:00:00Z");
    assert_eq!((&money["problems"], &money["source"]["state"]), (&json!([]), &json!("ok")));
    // October is there to step back to, but it is a part month and is not compared.
    assert_eq!((&money["earlier"], &money["later"], &money["previous"]), (&json!("2026-10"), &json!(null), &json!(null)));
    assert_eq!(money["category_names"].as_array().unwrap().len(), 12);

    let (status, october) = h.get("/v1/money?month=2026-10", Some(&token)).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!((&october["spent_minor"], &october["current"], &october["later"]), (&json!(90000), &json!(false), &json!("2026-11")));
    let (status, _) = h.get("/v1/money?month=october", Some(&token)).await;
    assert_eq!(status, StatusCode::BAD_REQUEST);

    // Home carries the little it shows.
    let (_, home) = h.get("/v1/home", Some(&token)).await;
    assert_eq!(
        home["money"],
        json!({"month": "2026-11", "currency": "CAD", "spent_minor": 16500, "to_sort": 4, "problem": null,
               "last_success_at": home["money"]["last_success_at"]})
    );
    assert!(home["money"]["last_success_at"].is_string());
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_payee_is_sorted_once_and_stays_sorted(pool: PgPool) {
    let (h, bridge) = banked(pool).await;
    let token = h.signed_in().await;
    let (mut chequing, mut card) = chequing_and_card();
    bridge_answers(&bridge, two_accounts(chequing.clone(), card.clone())).await;
    h.import().await;

    let (status, _) = h.post(&format!("/v1/money/entries/{}/sort", food_id(1)), None, Some(json!({"to": "Fun"}))).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (status, _) = h.post(&format!("/v1/money/entries/{}/sort", food_id(1)), Some(&token), Some(json!({"to": "Fun"}))).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    for wrong in [json!({"to": "Nonsense"}), json!({"to": "groceries"}), json!({"to": "income"}), json!({"to": "Fun", "month": "soon"})] {
        let (status, body) = h.sort(&token, "Corner Grocer", wrong.clone()).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{wrong} {body}");
    }

    // Said once of the grocer, it holds for both of its entries, whichever account.
    let (status, money) = h.sort(&token, "Corner Grocer", json!({"to": "Groceries"})).await;
    assert_eq!(status, StatusCode::OK, "{money}");
    assert_eq!(category(&money, "Groceries"), json!({"name": "Groceries", "spent_minor": 8500, "entries": 2}));
    assert_eq!(entry_named(&money, "Corner Grocer #2")["sorted_by"], "rule");
    assert_eq!((&money["to_sort"], &money["unsorted_minor"], &money["spent_minor"]), (&json!(2), &json!(8000), &json!(16500)));
    let (_, money) = h.sort(&token, "Noodle Bar", json!({"to": "Eating out"})).await;
    let (_, money) = (money, h.sort(&token, "Employer", json!({"to": "income"})).await.1);
    assert_eq!((&money["to_sort"], &money["unsorted_minor"], &money["income_minor"]), (&json!(0), &json!(0), &json!(300000)));

    // One entry can be said to be something else than its payee usually is.
    let (_, money) = h.sort(&token, "Corner Grocer #2", json!({"to": "Other", "only_this": true})).await;
    assert_eq!(entry_named(&money, "Corner Grocer #2")["sorted_by"], "owner");
    assert_eq!(category(&money, "Groceries")["spent_minor"], 4510);
    assert_eq!(category(&money, "Other")["spent_minor"], 3990);

    // New entries from a payee already sorted need nothing, and money back
    // from it comes off its category.
    chequing.push(posted("T9", "2026-11-16", "-10.00", "Corner Grocer"));
    card.push(posted("C9", "2026-11-16", "5.00", "CORNER GROCER #7"));
    bridge_answers(&bridge, two_accounts(chequing.clone(), card.clone())).await;
    let report = h.import().await;
    assert_eq!((report.requests, report.new, report.changed), (1, 2, 0));
    let money = h.money(&token).await;
    assert_eq!(category(&money, "Groceries"), json!({"name": "Groceries", "spent_minor": 4510 + 1000 - 500, "entries": 3}));
    assert_eq!(entry_named(&money, "CORNER GROCER #7")["kind"], "refund");
    assert_eq!((&money["to_sort"], &money["spent_minor"]), (&json!(0), &json!(16500 + 1000 - 500)));

    // The same answer again adds nothing; an amount the bank corrected is
    // corrected here and keeps its category.
    assert_eq!(h.import().await.new, 0);
    chequing[0] = posted("T1", "2026-11-03", "-50.10", "Corner Grocer");
    bridge_answers(&bridge, two_accounts(chequing, card)).await;
    let report = h.import().await;
    assert_eq!((report.new, report.changed), (0, 1));
    let money = h.money(&token).await;
    assert_eq!(entry_named(&money, "Corner Grocer")["category"], "Groceries");
    assert_eq!(category(&money, "Groceries")["spent_minor"], 5010 + 1000 - 500);
    assert_eq!(money["entries"].as_array().unwrap().len(), 8);

    // Saying one half of a transfer is spending frees the other half, and
    // taking that back pairs them again.
    let (_, money) = h.sort(&token, "Card payment", json!({"to": "Other", "only_this": true})).await;
    assert_eq!((&entry_named(&money, "Card payment")["kind"], &entry_named(&money, "Payment received")["kind"]), (&json!("expense"), &json!("income")));
    assert_eq!(entry_named(&money, "Payment received")["to_sort"], true);
    let (_, money) = h.sort(&token, "Card payment", json!({"to": "unsorted", "only_this": true})).await;
    assert_eq!(entry_named(&money, "Card payment")["sorted_by"], "match");
    assert_eq!(entry_named(&money, "Payment received")["sorted_by"], "match");

    // Taking back what was said of a payee leaves all of it to sort again,
    // except the one entry sorted by itself.
    let (_, money) = h.sort(&token, "Corner Grocer", json!({"to": "unsorted"})).await;
    assert_eq!(category(&money, "Groceries"), Value::Null);
    assert_eq!(category(&money, "Other")["spent_minor"], 3990);
    assert_eq!(money["to_sort"], 3);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn nothing_in_an_account_set_aside_counts_as_spending(pool: PgPool) {
    let (h, bridge) = banked(pool).await;
    let token = h.signed_in().await;
    let chequing = vec![posted("T1", "2026-11-05", "-200.00", "To savings"), posted("T2", "2026-11-06", "-12.00", "Noodle Bar")];
    let savings = vec![
        posted("S1", "2026-11-06", "200.00", "Deposit"),
        posted("S2", "2026-11-10", "1.20", "Interest"),
        posted("S3", "2026-11-11", "-50.00", "Fund purchase"),
    ];
    let mut dollars = bank_account("ACT-3", "Dollars", "40.00", vec![posted("U1", "2026-11-07", "-9.00", "Bookshop")]);
    dollars["currency"] = json!("USD");
    // An account the bank lists holdings for is an investment account.
    let mut brokerage = bank_account("ACT-4", "Brokerage", "20000.00", vec![posted("B1", "2026-11-08", "-700.00", "Fund purchase")]);
    brokerage["holdings"] = json!([{"id": "H1", "symbol": "XYZ", "shares": "10"}]);
    bridge_answers(
        &bridge,
        bridge_answer(
            vec![
                bank_account("ACT-1", "Chequing", "1000.00", chequing),
                bank_account("ACT-2", "Savings", "9000.00", savings),
                dollars,
                brokerage,
            ],
            json!([]),
        ),
    )
    .await;
    h.import().await;

    // Until the owner says so, lyfe cannot know the savings from an everyday account.
    let money = h.money(&token).await;
    // The brokerage it can tell by its holdings, and sets aside from the start.
    assert_eq!((&money["spent_minor"], &money["to_sort"]), (&json!(1200 + 5000), &json!(4)));
    assert_eq!((&money["everyday_minor"], &money["set_aside_minor"]), (&json!(1000000), &json!(2000000)));
    let brokerage = money["accounts"].as_array().unwrap().iter().find(|a| a["name"] == "Brokerage").unwrap();
    assert_eq!(brokerage["set_aside"], true);
    // The account in another currency is listed and left out of every total.
    assert_eq!(money["currency"], "CAD");
    assert_eq!(entry_named(&money, "Bookshop")["currency"], "USD");

    let savings_id = money["accounts"].as_array().unwrap().iter().find(|a| a["name"] == "Savings").unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();
    let uri = format!("/v1/money/accounts/{savings_id}");
    let (status, _) = h.put(&uri, None, json!({"set_aside": true})).await;
    assert_eq!(status, StatusCode::UNAUTHORIZED);
    let (status, _) = h.put(&format!("/v1/money/accounts/{}", food_id(1)), Some(&token), json!({"set_aside": true})).await;
    assert_eq!(status, StatusCode::NOT_FOUND);
    let (status, money) = h.put(&uri, Some(&token), json!({"set_aside": true})).await;
    assert_eq!(status, StatusCode::OK, "{money}");
    assert_eq!((&money["spent_minor"], &money["income_minor"]), (&json!(1200), &json!(0)));
    // The noodles and the bookshop are left to sort; nothing in the savings is.
    assert_eq!(money["to_sort"], 2);
    assert_eq!((&money["everyday_minor"], &money["set_aside_minor"]), (&json!(100000), &json!(2900000)));
    assert_eq!(entry_named(&money, "Fund purchase")["kind"], "transfer");
    assert_eq!(money["accounts"].as_array().unwrap().last().unwrap()["name"], "Savings");

    // The owner can still say what something in it is.
    let (_, money) = h.sort(&token, "Interest", json!({"to": "income"})).await;
    assert_eq!(money["income_minor"], 120);
    let (_, money) = h.put(&uri, Some(&token), json!({"set_aside": false})).await;
    assert_eq!(money["spent_minor"], 1200 + 5000);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_bank_to_sign_in_to_again_is_shown_and_prompted_for_once(pool: PgPool) {
    let (h, bridge) = banked(pool).await;
    let token = h.signed_in().await;
    register_device(&h, &token).await;
    let apple = MockServer::start().await;
    apple_answers(&apple, "dev", 200, None).await;
    let notifier = notifier(&h, &apple);
    let (chequing, card) = chequing_and_card();
    let healthy = two_accounts(chequing, card);
    bridge_answers(&bridge, healthy.clone()).await;
    h.import().await;
    assert_eq!(notifier.money((h.state.now)()).await.unwrap(), lyfe_server::push::notifier::Outcome::NothingDue);

    let mut broken = healthy.clone();
    broken["errlist"] = json!([
        {"code": "con.auth", "msg": "Sign in\nagain to continue", "conn_id": "CON-1"},
        {"code": "act.missingdata", "msg": "Some transactions are missing", "account_id": "ACT-2"},
        {"code": "gen.api", "msg": "You are asking too often"},
    ]);
    bridge_answers(&bridge, broken.clone()).await;
    assert_eq!(h.import().await.troubles, 3);
    let money = h.money(&token).await;
    assert_eq!(
        money["problems"],
        json!([
            {"text": "First Bank: Sign in again to continue", "reconnect": true},
            {"text": "You are asking too often", "reconnect": false},
        ])
    );
    let card = money["accounts"].as_array().unwrap().iter().find(|a| a["name"] == "Card").unwrap();
    assert_eq!(card["problem"], "Some transactions are missing");
    // What was imported before is still there.
    assert_eq!(money["spent_minor"], 16500);
    let (_, home) = h.get("/v1/home", Some(&token)).await;
    assert_eq!(home["money"]["problem"], "First Bank: Sign in again to continue");
    // What the bridge says in passing is for Money, not for Home.
    let mut chatty = healthy.clone();
    chatty["errlist"] = json!([{"code": "gen.api", "msg": "You are asking too often"}]);
    bridge_answers(&bridge, chatty).await;
    h.import().await;
    assert_eq!(h.money(&token).await["problems"], json!([{"text": "You are asking too often", "reconnect": false}]));
    let (_, home) = h.get("/v1/home", Some(&token)).await;
    assert_eq!(home["money"]["problem"], Value::Null);
    bridge_answers(&bridge, broken.clone()).await;
    h.import().await;

    // 03:00 in San Juan is no time to say so; 11:00 is, once.
    use lyfe_server::push::notifier::Outcome as Told;
    assert_eq!(notifier.money(at("2026-11-17T07:00:00Z")).await.unwrap(), Told::Quiet);
    match notifier.money((h.state.now)()).await.unwrap() {
        Told::Sent { title, body, devices } => {
            assert_eq!((title.as_str(), devices), ("Sign in to a bank again", 1));
            assert!(body.starts_with("First Bank has stopped"), "{body}");
        }
        other => panic!("{other:?}"),
    }
    assert_eq!(notifier.money((h.state.now)()).await.unwrap(), Told::AlreadySent);
    // Still broken the next day: the same break, not a new one.
    h.import_at(at("2026-11-18T15:00:00Z")).await.unwrap();
    assert_eq!(notifier.money(at("2026-11-18T15:00:00Z")).await.unwrap(), Told::AlreadySent);

    // Mended, the problem goes; broken again later, it is said again.
    bridge_answers(&bridge, healthy).await;
    h.import_at(at("2026-11-19T15:00:00Z")).await.unwrap();
    assert_eq!(h.money(&token).await["problems"], json!([]));
    assert_eq!(notifier.money(at("2026-11-19T15:00:00Z")).await.unwrap(), Told::NothingDue);
    bridge_answers(&bridge, broken).await;
    h.import_at(at("2026-11-20T15:00:00Z")).await.unwrap();
    assert!(matches!(notifier.money(at("2026-11-20T15:00:00Z")).await.unwrap(), Told::Sent { .. }));
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_failed_import_is_reported_and_what_was_imported_stays(pool: PgPool) {
    let (h, bridge) = banked(pool).await;
    let token = h.signed_in().await;
    let (chequing, card) = chequing_and_card();
    bridge_answers(&bridge, two_accounts(chequing, card)).await;
    h.import().await;

    for (status, error) in [(403, BridgeError::AccessRejected), (402, BridgeError::PaymentDue), (503, BridgeError::Status(503))] {
        bridge_fails(&bridge, status).await;
        match h.import_at((h.state.now)()).await {
            Err(ImportError::Bridge(found)) => assert_eq!(found, error),
            other => panic!("{other:?}"),
        }
        let money = h.money(&token).await;
        assert_eq!(money["source"]["state"], "failing");
        assert_eq!(money["problems"][0], json!({"text": format!("The last import failed: {error}."), "reconnect": false}));
        assert_eq!(money["spent_minor"], 16500);
    }
    // An answer that is not what the bridge sends is refused whole.
    bridge_answers(&bridge, json!({"oops": true})).await;
    assert!(matches!(h.import_at((h.state.now)()).await, Err(ImportError::Bridge(BridgeError::BadResponse))));
    // Wrong credentials never reach an answer.
    bridge.reset().await;
    assert!(matches!(h.import_at((h.state.now)()).await, Err(ImportError::Bridge(BridgeError::Status(404)))));
    assert_eq!(h.money(&token).await["entries"].as_array().unwrap().len(), 6);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn the_bridge_is_asked_sparingly(pool: PgPool) {
    let (h, bridge) = banked(pool).await;
    let now = (h.state.now)();
    let every = std::time::Duration::from_secs(6 * 3600);
    let asked = |request: &wiremock::Request, name: &str| -> i64 {
        request.url.query_pairs().find(|(key, _)| key == name).unwrap().1.parse().unwrap()
    };

    // The first import reaches back a stretch at a time while there is anything older.
    let (chequing, card) = chequing_and_card();
    bridge_answers(&bridge, two_accounts(chequing, card)).await;
    let report = h.state.money.import_if_due(now, every).await.unwrap().unwrap();
    assert_eq!((report.requests, report.new), (4, 7));
    let requests = bridge.received_requests().await.unwrap();
    let day = 86400;
    assert_eq!(
        requests.iter().map(|r| (now.timestamp() - asked(r, "start-date")) / day).collect::<Vec<_>>(),
        vec![44, 89, 134, 179]
    );
    assert_eq!(asked(&requests[0], "end-date"), now.timestamp() + day);
    assert_eq!(asked(&requests[1], "end-date"), asked(&requests[0], "start-date"));
    // No stretch is longer than the bridge likes to answer for.
    assert!(requests.iter().all(|r| asked(r, "end-date") - asked(r, "start-date") <= 45 * day));

    // Asked again too soon, nothing goes out. (The attempt is stamped by
    // the database's clock, so it is put on this test's clock first.)
    sqlx::query("update source_sync set last_attempt_at = $1 where source = 'simplefin'")
        .bind(now)
        .execute(&h.state.pool)
        .await
        .unwrap();
    assert!(h.state.money.import_if_due(now + chrono::Duration::hours(5), every).await.is_none());
    assert_eq!(bridge.received_requests().await.unwrap().len(), 4);

    // When it is due, one request for the last two weeks.
    let later = now + chrono::Duration::hours(7);
    let report = h.state.money.import_if_due(later, every).await.unwrap().unwrap();
    assert_eq!((report.requests, report.new), (1, 0));
    let requests = bridge.received_requests().await.unwrap();
    assert_eq!((later.timestamp() - asked(&requests[4], "start-date")) / day, 14);
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn a_bank_with_nothing_older_is_not_asked_for_more(pool: PgPool) {
    let (h, bridge) = banked(pool).await;
    bridge_answers(&bridge, bridge_answer(vec![bank_account("ACT-1", "Chequing", "10.00", vec![])], json!([]))).await;
    let report = h.import().await;
    assert_eq!((report.requests, report.accounts, report.fetched), (1, 1, 0));
}

#[sqlx::test(migrator = "lyfe_server::db::MIGRATOR")]
async fn without_a_bank_the_server_still_answers(pool: PgPool) {
    let h = harness(pool).await;
    let token = h.signed_in().await;
    let (_, home) = h.get("/v1/home", Some(&token)).await;
    assert!(home.get("money").is_none());
    let money = h.money(&token).await;
    assert_eq!((&money["source"]["state"], &money["entries"], &money["accounts"]), (&json!("not_configured"), &json!([]), &json!([])));
    assert_eq!((&money["spent_minor"], &money["problems"]), (&json!(0), &json!([])));
    assert!(h.state.money.import_once((h.state.now)()).await.is_none());
}

#[tokio::test]
async fn a_setup_token_is_traded_once_for_the_access_address() {
    use base64::Engine;
    let bridge = MockServer::start().await;
    let token = base64::engine::general_purpose::STANDARD.encode(format!("{}/simplefin/claim/abc123", bridge.uri()));
    let access = format!("{}/simplefin", bridge.uri().replace("http://", "http://lyfe:secret@"));
    Mock::given(method("POST"))
        .and(path("/simplefin/claim/abc123"))
        .respond_with(ResponseTemplate::new(200).set_body_string(format!("{access}\n")))
        .up_to_n_times(1)
        .mount(&bridge)
        .await;
    // Pasted with a line break in it, as a long token often is.
    let (first, second) = token.split_at(20);
    assert_eq!(lyfe_server::money::claim(&format!(" {first}\n{second} ")).await.as_deref(), Ok(access.as_str()));
    assert!(lyfe_server::money::is_access_address(&access));

    // Used already: the bridge refuses it, and lyfe says to make a new one.
    Mock::given(method("POST")).respond_with(ResponseTemplate::new(403)).mount(&bridge).await;
    assert_eq!(lyfe_server::money::claim(&token).await, Err(BridgeError::TokenRejected));
    // An answer that is not an access address is not kept.
    bridge.reset().await;
    Mock::given(method("POST")).respond_with(ResponseTemplate::new(200).set_body_string("welcome")).mount(&bridge).await;
    assert_eq!(lyfe_server::money::claim(&token).await, Err(BridgeError::BadResponse));
}
