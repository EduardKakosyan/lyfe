//! lyfe's own sign-in. The tailnet decides who can reach the server; this
//! decides who may read the data, because the machine and the tailnet are
//! shared. One owner, one password, one revocable token per device.

use std::sync::Mutex;
use std::time::{Duration, Instant};

use argon2::password_hash::phc::PasswordHash;
use argon2::password_hash::{PasswordHasher, PasswordVerifier};
use argon2::Argon2;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use sha2::{Digest, Sha256};

pub const MIN_PASSWORD_CHARS: usize = 12;

pub fn hash_password(password: &str) -> anyhow::Result<String> {
    Argon2::default()
        .hash_password(password.as_bytes())
        .map(|h| h.to_string())
        .map_err(|e| anyhow::anyhow!("could not hash password: {e}"))
}

pub fn verify_password(password: &str, stored_hash: &str) -> bool {
    match PasswordHash::new(stored_hash) {
        Ok(parsed) => Argon2::default()
            .verify_password(password.as_bytes(), &parsed)
            .is_ok(),
        Err(_) => false,
    }
}

/// A new device token: 32 random bytes, shown to the device once.
pub fn new_token() -> anyhow::Result<String> {
    let mut bytes = [0u8; 32];
    getrandom::fill(&mut bytes).map_err(|e| anyhow::anyhow!("no randomness available: {e}"))?;
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}

/// What is stored in place of a token. Tokens are long and random, so a
/// plain hash is enough to make a database copy useless for signing in.
pub fn token_hash(token: &str) -> Vec<u8> {
    Sha256::digest(token.as_bytes()).to_vec()
}

/// Slows password guessing: after a few wrong attempts in a row, each
/// further failure doubles the wait before the next attempt is looked at.
/// There is one owner, so one shared counter is enough.
pub struct SignInThrottle {
    state: Mutex<ThrottleState>,
}

struct ThrottleState {
    failures: u32,
    blocked_until: Option<Instant>,
}

impl SignInThrottle {
    const FREE_ATTEMPTS: u32 = 5;
    const MAX_WAIT: Duration = Duration::from_secs(15 * 60);

    pub fn new() -> Self {
        Self {
            state: Mutex::new(ThrottleState { failures: 0, blocked_until: None }),
        }
    }

    /// Time the caller must still wait, if any.
    pub fn wait_remaining(&self, now: Instant) -> Option<Duration> {
        let state = self.state.lock().expect("throttle lock");
        state
            .blocked_until
            .and_then(|until| until.checked_duration_since(now))
            .filter(|d| !d.is_zero())
    }

    pub fn record_failure(&self, now: Instant) {
        let mut state = self.state.lock().expect("throttle lock");
        state.failures = state.failures.saturating_add(1);
        if state.failures >= Self::FREE_ATTEMPTS {
            let doublings = (state.failures - Self::FREE_ATTEMPTS).min(16);
            let wait = Duration::from_secs(1u64 << doublings).min(Self::MAX_WAIT);
            state.blocked_until = Some(now + wait);
        }
    }

    pub fn record_success(&self) {
        let mut state = self.state.lock().expect("throttle lock");
        state.failures = 0;
        state.blocked_until = None;
    }
}

impl Default for SignInThrottle {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn password_round_trip() {
        let hash = hash_password("correct horse battery").unwrap();
        assert!(hash.starts_with("$argon2id$"));
        assert!(verify_password("correct horse battery", &hash));
        assert!(!verify_password("correct horse batterx", &hash));
        assert!(!verify_password("anything", "not a hash"));
    }

    #[test]
    fn tokens_are_unique_and_hash_stably() {
        let a = new_token().unwrap();
        let b = new_token().unwrap();
        assert_ne!(a, b);
        assert_eq!(a.len(), 43);
        assert_eq!(token_hash(&a), token_hash(&a));
        assert_ne!(token_hash(&a), token_hash(&b));
        assert_eq!(token_hash(&a).len(), 32);
    }

    #[test]
    fn throttle_allows_a_few_mistakes_then_backs_off() {
        let throttle = SignInThrottle::new();
        let t0 = Instant::now();
        for _ in 0..4 {
            throttle.record_failure(t0);
            assert_eq!(throttle.wait_remaining(t0), None);
        }
        throttle.record_failure(t0);
        assert_eq!(throttle.wait_remaining(t0), Some(Duration::from_secs(1)));
        throttle.record_failure(t0);
        assert_eq!(throttle.wait_remaining(t0), Some(Duration::from_secs(2)));
        assert_eq!(throttle.wait_remaining(t0 + Duration::from_secs(3)), None);
        for _ in 0..40 {
            throttle.record_failure(t0);
        }
        assert_eq!(throttle.wait_remaining(t0), Some(SignInThrottle::MAX_WAIT));
        throttle.record_success();
        assert_eq!(throttle.wait_remaining(t0), None);
    }
}
