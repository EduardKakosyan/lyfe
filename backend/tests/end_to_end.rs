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
