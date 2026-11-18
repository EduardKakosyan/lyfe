//! Client for the Garmin Connect Personal API: a long-lived key, read from
//! a file, is exchanged for a 24-hour access token, and activities are
//! pulled with it. Garmin pushes nothing, so lyfe polls.
//!
//! The key and token never appear in logs, errors or stored state.

pub mod sync;

use std::path::PathBuf;
use std::time::Duration;

use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use chrono::{DateTime, NaiveDate, TimeZone, Utc};
use serde_json::Value;
use tokio::sync::Mutex;

/// Errors are worded for the owner: they are stored and shown as the
/// reason a sync failed, and contain nothing secret.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum GarminError {
    #[error("the Garmin key file is missing or unreadable")]
    KeyUnreadable,
    #[error("Garmin rejected the API key; it may have expired or been deleted")]
    KeyRejected,
    #[error("Garmin answered with HTTP {0}")]
    Status(u16),
    #[error("Garmin could not be reached")]
    Unreachable,
    #[error("Garmin's answer could not be understood")]
    BadResponse,
}

struct CachedToken {
    value: String,
    refresh_after: DateTime<Utc>,
}

pub struct GarminClient {
    http: reqwest::Client,
    base_url: String,
    key_file: PathBuf,
    token: Mutex<Option<CachedToken>>,
}

const TOKEN_PATH: &str = "/personalapitoken-service/personal-api/personal-api-key/token";
const SEARCH_PATH: &str = "/activitylist-service/activities/search/activities";
const PAGE_SIZE: usize = 50;
/// Upper bound on pages per poll, so a misbehaving answer cannot loop forever.
const MAX_PAGES: usize = 60;

impl GarminClient {
    pub fn new(base_url: &str, key_file: PathBuf) -> anyhow::Result<Self> {
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(30))
            .user_agent("lyfe-server")
            .build()?;
        Ok(Self {
            http,
            base_url: base_url.trim_end_matches('/').to_string(),
            key_file,
            token: Mutex::new(None),
        })
    }

    /// All activities that started between the two dates, newest first as
    /// Garmin returns them, as raw JSON objects.
    pub async fn activities_between(
        &self,
        from: NaiveDate,
        to: NaiveDate,
    ) -> Result<Vec<Value>, GarminError> {
        let mut all = Vec::new();
        for page in 0..MAX_PAGES {
            let batch = self.search_page(from, to, page * PAGE_SIZE).await?;
            let count = batch.len();
            all.extend(batch);
            if count < PAGE_SIZE {
                return Ok(all);
            }
        }
        Err(GarminError::BadResponse)
    }

    async fn search_page(
        &self,
        from: NaiveDate,
        to: NaiveDate,
        start: usize,
    ) -> Result<Vec<Value>, GarminError> {
        let mut retried = false;
        loop {
            let token = self.access_token().await?;
            let response = self
                .http
                .get(format!("{}{}", self.base_url, SEARCH_PATH))
                .bearer_auth(&token)
                .header(reqwest::header::ACCEPT, "application/json")
                .query(&[
                    ("startDate", from.to_string()),
                    ("endDate", to.to_string()),
                    ("limit", PAGE_SIZE.to_string()),
                    ("start", start.to_string()),
                ])
                .send()
                .await
                .map_err(|_| GarminError::Unreachable)?;
            let status = response.status();
            if status == reqwest::StatusCode::UNAUTHORIZED && !retried {
                // The token may have been revoked early; ask for a fresh one once.
                *self.token.lock().await = None;
                retried = true;
                continue;
            }
            if !status.is_success() {
                return Err(GarminError::Status(status.as_u16()));
            }
            let body: Value = response.json().await.map_err(|_| GarminError::BadResponse)?;
            return match body {
                Value::Array(items) => Ok(items),
                _ => Err(GarminError::BadResponse),
            };
        }
    }

    async fn access_token(&self) -> Result<String, GarminError> {
        let mut cached = self.token.lock().await;
        if let Some(token) = cached.as_ref()
            && Utc::now() < token.refresh_after
        {
            return Ok(token.value.clone());
        }
        let key = tokio::fs::read_to_string(&self.key_file)
            .await
            .map_err(|_| GarminError::KeyUnreadable)?;
        let key = key.trim();
        if key.is_empty() {
            return Err(GarminError::KeyUnreadable);
        }
        let response = self
            .http
            .post(format!("{}{}", self.base_url, TOKEN_PATH))
            .header(reqwest::header::AUTHORIZATION, format!("ApiKey {key}"))
            .send()
            .await
            .map_err(|_| GarminError::Unreachable)?;
        let status = response.status();
        if status == reqwest::StatusCode::UNAUTHORIZED || status == reqwest::StatusCode::FORBIDDEN {
            return Err(GarminError::KeyRejected);
        }
        if !status.is_success() {
            return Err(GarminError::Status(status.as_u16()));
        }
        let body = response.text().await.map_err(|_| GarminError::BadResponse)?;
        let value = parse_token_body(&body).ok_or(GarminError::BadResponse)?;
        let now = Utc::now();
        let refresh_after = token_expiry(&value)
            .map(|expiry| expiry - chrono::Duration::minutes(10))
            .filter(|at| *at > now)
            .unwrap_or(now + chrono::Duration::hours(1));
        *cached = Some(CachedToken { value: value.clone(), refresh_after });
        Ok(value)
    }
}

/// Garmin answers with the bare token as plain text. A JSON wrapper is
/// accepted too in case that changes.
fn parse_token_body(body: &str) -> Option<String> {
    let body = body.trim();
    let token = match serde_json::from_str::<Value>(body) {
        Ok(Value::Object(fields)) => ["access_token", "accessToken", "token"]
            .iter()
            .find_map(|name| fields.get(*name).and_then(Value::as_str))?
            .to_string(),
        Ok(Value::String(token)) => token,
        _ => body.to_string(),
    };
    let plausible = !token.is_empty()
        && token.len() < 8192
        && token.chars().all(|c| c.is_ascii_graphic());
    plausible.then_some(token)
}

/// Reads the expiry out of a JWT without verifying it; it only decides
/// when to ask for the next token.
fn token_expiry(token: &str) -> Option<DateTime<Utc>> {
    let payload = token.split('.').nth(1)?;
    let bytes = URL_SAFE_NO_PAD.decode(payload.trim_end_matches('=')).ok()?;
    let claims: Value = serde_json::from_slice(&bytes).ok()?;
    let exp = claims.get("exp")?.as_i64()?;
    Utc.timestamp_opt(exp, 0).single()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn jwt_with_exp(exp: i64) -> String {
        let payload = URL_SAFE_NO_PAD.encode(format!(r#"{{"exp":{exp},"iss":"x"}}"#));
        format!("aGVhZGVy.{payload}.c2ln")
    }

    #[test]
    fn plain_text_token_is_accepted() {
        assert_eq!(parse_token_body(" abc.def.ghi \n").as_deref(), Some("abc.def.ghi"));
    }

    #[test]
    fn json_wrapped_token_is_accepted() {
        assert_eq!(parse_token_body(r#"{"access_token":"abc.def.ghi"}"#).as_deref(), Some("abc.def.ghi"));
        assert_eq!(parse_token_body(r#""abc.def.ghi""#).as_deref(), Some("abc.def.ghi"));
    }

    #[test]
    fn nonsense_token_bodies_are_rejected() {
        assert_eq!(parse_token_body(""), None);
        assert_eq!(parse_token_body("<html>try again later</html>"), None);
        assert_eq!(parse_token_body(r#"{"error":"nope"}"#), None);
    }

    #[test]
    fn expiry_is_read_from_the_jwt() {
        let expiry = token_expiry(&jwt_with_exp(1_800_000_000)).unwrap();
        assert_eq!(expiry.timestamp(), 1_800_000_000);
        assert_eq!(token_expiry("opaque-token"), None);
    }
}
