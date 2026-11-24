//! A client for the Apple Push Notification service.
//!
//! Apple identifies the sender by a short-lived token signed with a key
//! from the developer account (a `.p8` file). The key is read from a file
//! on every signing and never appears in settings or logs.

use std::path::{Path, PathBuf};
use std::time::Duration;

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use chrono::{DateTime, Utc};
use p256::ecdsa::signature::Signer;
use p256::ecdsa::{Signature, SigningKey};
use p256::pkcs8::DecodePrivateKey;
use serde_json::json;

/// Apple runs one service for apps installed from Xcode and one for apps
/// from TestFlight or the App Store. A device token works on only one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Environment {
    Development,
    Production,
}

impl Environment {
    pub fn as_str(self) -> &'static str {
        match self {
            Environment::Development => "development",
            Environment::Production => "production",
        }
    }

    pub fn parse(text: &str) -> Option<Environment> {
        match text {
            "development" => Some(Environment::Development),
            "production" => Some(Environment::Production),
            _ => None,
        }
    }

    pub fn other(self) -> Environment {
        match self {
            Environment::Development => Environment::Production,
            Environment::Production => Environment::Development,
        }
    }
}

/// One notification as the owner sees it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Alert {
    pub title: String,
    pub body: String,
    /// A later alert with the same id replaces this one on the phone.
    pub collapse_id: String,
    /// Apple stops trying to deliver after this.
    pub expires_at: DateTime<Utc>,
    /// The kind of notification, as the app registered it: decides which
    /// actions it offers, such as a field to type a reply into.
    pub category: Option<String>,
}

#[derive(Debug, thiserror::Error)]
pub enum PushError {
    /// The token belongs to the other Apple service, or to no device.
    #[error("Apple does not know this device token here")]
    BadDeviceToken,
    /// The app was removed from the device or stopped accepting notifications.
    #[error("the device is no longer registered")]
    Unregistered,
    #[error("Apple refused the notification ({status}: {reason})")]
    Rejected { status: u16, reason: String },
    #[error("could not reach Apple")]
    Transport(#[from] reqwest::Error),
    #[error("could not read the Apple key file {path}")]
    KeyFile { path: PathBuf, #[source] source: std::io::Error },
    #[error("the Apple key file is not a private key Apple issues (.p8)")]
    KeyFormat,
}

/// A sender token is reused for this long; Apple accepts one for an hour
/// and refuses senders that mint a new one too often.
const TOKEN_LIFETIME: Duration = Duration::from_secs(40 * 60);

pub struct ApnsClient {
    http: reqwest::Client,
    key_file: PathBuf,
    key_id: String,
    team_id: String,
    /// The app's bundle identifier.
    topic: String,
    development_url: String,
    production_url: String,
    token: tokio::sync::Mutex<Option<(String, DateTime<Utc>)>>,
}

impl ApnsClient {
    pub fn new(key_file: PathBuf, key_id: String, team_id: String, topic: String) -> anyhow::Result<Self> {
        Self::with_urls(
            key_file,
            key_id,
            team_id,
            topic,
            "https://api.sandbox.push.apple.com",
            "https://api.push.apple.com",
        )
    }

    pub fn with_urls(
        key_file: PathBuf,
        key_id: String,
        team_id: String,
        topic: String,
        development_url: &str,
        production_url: &str,
    ) -> anyhow::Result<Self> {
        let http = reqwest::Client::builder()
            .timeout(Duration::from_secs(20))
            .connect_timeout(Duration::from_secs(10))
            .build()?;
        Ok(Self {
            http,
            key_file,
            key_id,
            team_id,
            topic,
            development_url: development_url.trim_end_matches('/').to_string(),
            production_url: production_url.trim_end_matches('/').to_string(),
            token: tokio::sync::Mutex::new(None),
        })
    }

    /// Apple names the downloaded key `AuthKey_<key id>.p8`.
    pub fn key_id_from_file_name(key_file: &Path) -> Option<String> {
        let stem = key_file.file_stem()?.to_str()?;
        let id = stem.strip_prefix("AuthKey_")?;
        (!id.is_empty() && id.chars().all(|c| c.is_ascii_alphanumeric())).then(|| id.to_string())
    }

    /// Checks the key file can be read and signs, without contacting Apple.
    pub async fn check_key(&self, now: DateTime<Utc>) -> Result<(), PushError> {
        self.sender_token(now).await.map(|_| ())
    }

    pub async fn send(
        &self,
        environment: Environment,
        device_token: &str,
        alert: &Alert,
        now: DateTime<Utc>,
    ) -> Result<(), PushError> {
        let base = match environment {
            Environment::Development => &self.development_url,
            Environment::Production => &self.production_url,
        };
        let mut payload = json!({
            "aps": {
                "alert": { "title": alert.title, "body": alert.body },
                "sound": "default",
            }
        });
        if let Some(category) = &alert.category {
            payload["aps"]["category"] = json!(category);
        }
        let response = self
            .http
            .post(format!("{base}/3/device/{device_token}"))
            .bearer_auth(self.sender_token(now).await?)
            .header("apns-topic", &self.topic)
            .header("apns-push-type", "alert")
            .header("apns-priority", "10")
            .header("apns-expiration", alert.expires_at.timestamp().max(0).to_string())
            .header("apns-collapse-id", &alert.collapse_id)
            .json(&payload)
            .send()
            .await?;

        let status = response.status().as_u16();
        if status == 200 {
            return Ok(());
        }
        let reason = response
            .json::<serde_json::Value>()
            .await
            .ok()
            .and_then(|body| body.get("reason").and_then(|r| r.as_str()).map(str::to_string))
            .unwrap_or_else(|| "no reason given".to_string());
        if status == 403 {
            // The sender token was refused; mint a new one next time.
            *self.token.lock().await = None;
        }
        Err(match (status, reason.as_str()) {
            (400, "BadDeviceToken") | (400, "DeviceTokenNotForTopic") => PushError::BadDeviceToken,
            (410, _) => PushError::Unregistered,
            _ => PushError::Rejected { status, reason },
        })
    }

    async fn sender_token(&self, now: DateTime<Utc>) -> Result<String, PushError> {
        let mut cached = self.token.lock().await;
        if let Some((token, minted_at)) = cached.as_ref() {
            let age = now.signed_duration_since(*minted_at);
            if age >= chrono::Duration::zero() && age.to_std().is_ok_and(|age| age < TOKEN_LIFETIME) {
                return Ok(token.clone());
            }
        }
        let pem = tokio::fs::read_to_string(&self.key_file)
            .await
            .map_err(|source| PushError::KeyFile { path: self.key_file.clone(), source })?;
        let token = sign_sender_token(&pem, &self.key_id, &self.team_id, now)?;
        *cached = Some((token.clone(), now));
        Ok(token)
    }
}

/// The token Apple expects: a JWT signed with ES256, naming the key and
/// the developer team.
pub fn sign_sender_token(pem: &str, key_id: &str, team_id: &str, now: DateTime<Utc>) -> Result<String, PushError> {
    let key = SigningKey::from_pkcs8_pem(pem.trim()).map_err(|_| PushError::KeyFormat)?;
    let header = URL_SAFE_NO_PAD.encode(json!({ "alg": "ES256", "kid": key_id }).to_string());
    let claims = URL_SAFE_NO_PAD.encode(json!({ "iss": team_id, "iat": now.timestamp() }).to_string());
    let signed = format!("{header}.{claims}");
    let signature: Signature = key.sign(signed.as_bytes());
    Ok(format!("{signed}.{}", URL_SAFE_NO_PAD.encode(signature.to_bytes())))
}

#[cfg(test)]
mod tests {
    use super::*;
    use p256::ecdsa::signature::Verifier;
    use p256::ecdsa::VerifyingKey;
    use p256::pkcs8::{EncodePrivateKey, LineEnding};

    /// A key made for one test, in the form Apple issues them, with its
    /// public half. No key is kept in the repository.
    fn throwaway_key() -> (String, VerifyingKey) {
        loop {
            let mut bytes = [0u8; 32];
            getrandom::fill(&mut bytes).expect("the system can supply random bytes");
            if let Ok(key) = SigningKey::from_slice(&bytes) {
                let pem = key.to_pkcs8_pem(LineEnding::LF).expect("a key can be written out");
                return (pem.to_string(), *key.verifying_key());
            }
        }
    }

    fn at(time: &str) -> DateTime<Utc> {
        time.parse().unwrap()
    }

    #[test]
    fn the_sender_token_names_the_key_and_team_and_verifies() {
        let (key, public) = throwaway_key();
        let token = sign_sender_token(&key, "KEY1234567", "TEAM123456", at("2026-11-18T12:00:00Z")).unwrap();
        let parts: Vec<&str> = token.split('.').collect();
        assert_eq!(parts.len(), 3);
        let decode = |part: &str| -> serde_json::Value {
            serde_json::from_slice(&URL_SAFE_NO_PAD.decode(part).unwrap()).unwrap()
        };
        assert_eq!(decode(parts[0]), json!({ "alg": "ES256", "kid": "KEY1234567" }));
        assert_eq!(decode(parts[1]), json!({ "iss": "TEAM123456", "iat": 1795003200 }));

        let signature = Signature::from_slice(&URL_SAFE_NO_PAD.decode(parts[2]).unwrap()).unwrap();
        public
            .verify(format!("{}.{}", parts[0], parts[1]).as_bytes(), &signature)
            .expect("the signature matches the key");
    }

    #[test]
    fn a_file_that_is_not_a_key_is_refused() {
        let error = sign_sender_token("not a key", "K", "T", at("2026-11-18T12:00:00Z")).unwrap_err();
        assert!(matches!(error, PushError::KeyFormat));
    }

    #[test]
    fn the_key_id_is_read_from_apples_file_name() {
        let id = |name: &str| ApnsClient::key_id_from_file_name(Path::new(name));
        assert_eq!(id("/home/lyfe/.config/lyfe/AuthKey_ABC123DEFG.p8").as_deref(), Some("ABC123DEFG"));
        assert_eq!(id("apns-key.p8"), None);
        assert_eq!(id("AuthKey_.p8"), None);
    }

    #[test]
    fn environments_round_trip() {
        for environment in [Environment::Development, Environment::Production] {
            assert_eq!(Environment::parse(environment.as_str()), Some(environment));
            assert_eq!(environment.other().other(), environment);
        }
        assert_eq!(Environment::parse("sandbox"), None);
    }
}
