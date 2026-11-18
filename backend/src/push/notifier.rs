//! Decides when the owner is prompted, and sends the prompt.
//!
//! A prompt goes out only when a streak is at stake and today is a day to
//! act on it (see `routines::gym::prompt`), only inside the daytime
//! window, and at most once for its period. Garmin is checked again just
//! before sending, so a session recorded this morning is not nagged about.

use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, NaiveDate, TimeZone, Timelike, Utc};
use sqlx::PgPool;

use super::apns::{Alert, ApnsClient, Environment, PushError};
use crate::db::{self, PushTarget};
use crate::garmin::sync::Syncer;
use crate::routines::gym::{self, GymRules, Prompt, Week};

/// How fresh the Garmin data must be for a prompt to be trusted.
const FRESH_ENOUGH: Duration = Duration::from_secs(120);

pub struct Notifier {
    pub pool: PgPool,
    pub syncer: Arc<Syncer>,
    pub apns: ApnsClient,
    /// The Apple service tried first for a device that has not been
    /// reached before.
    pub default_environment: Environment,
    pub timezone: chrono_tz::Tz,
    pub gym_rules: Arc<GymRules>,
    /// Prompts are sent from this hour of the owner's day...
    pub from_hour: u32,
    /// ...until this hour, and never outside it.
    pub until_hour: u32,
}

/// What one look at the clock led to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// Outside the daytime window.
    Quiet,
    /// No signed-in device accepts notifications.
    NoDevices,
    /// Nothing to act on today.
    NothingDue,
    /// Today's prompt has already gone out.
    AlreadySent,
    Sent { title: String, body: String, devices: usize },
    /// A prompt was due but no device could be reached; tried again later.
    Undelivered,
}

impl Notifier {
    /// Looks at the clock once and sends at most one prompt.
    pub async fn tick(&self, now: DateTime<Utc>) -> sqlx::Result<Outcome> {
        let local = now.with_timezone(&self.timezone);
        if local.hour() < self.from_hour || local.hour() >= self.until_hour {
            return Ok(Outcome::Quiet);
        }
        let targets = db::push_targets(&self.pool).await?;
        if targets.is_empty() {
            return Ok(Outcome::NoDevices);
        }
        let today = local.date_naive();
        let Some(due) = self.due(today).await? else {
            return Ok(Outcome::NothingDue);
        };
        if db::notification_sent(&self.pool, due.kind(), due.period(today)).await? {
            return Ok(Outcome::AlreadySent);
        }

        // Look again with fresh data before interrupting anyone.
        self.syncer.poll_if_stale(now, FRESH_ENOUGH).await;
        let Some(prompt) = self.due(today).await? else {
            return Ok(Outcome::NothingDue);
        };
        let (kind, period) = (prompt.kind(), prompt.period(today));
        if db::notification_sent(&self.pool, kind, period).await? {
            return Ok(Outcome::AlreadySent);
        }

        let alert = Alert {
            title: prompt.title(today),
            body: prompt.body(),
            collapse_id: kind.to_string(),
            expires_at: self.window_end(today, now),
        };
        let devices = self.deliver(&targets, &alert, now).await;
        if devices == 0 {
            return Ok(Outcome::Undelivered);
        }
        db::record_notification(&self.pool, kind, period, &alert.title, &alert.body).await?;
        Ok(Outcome::Sent { title: alert.title, body: alert.body, devices })
    }

    /// The prompt today calls for, from what is stored now.
    async fn due(&self, today: NaiveDate) -> sqlx::Result<Option<Prompt>> {
        let week = Week::containing(today);
        let activities = db::activities_until(&self.pool, week.ends_on).await?;
        let streak = gym::streak(&self.gym_rules, today, &activities);
        let trained_today = gym::sessions_in_week(&self.gym_rules, week, &activities)
            .iter()
            .any(|session| session.date == today);
        Ok(gym::prompt(&streak, trained_today))
    }

    /// When today's window closes; a prompt not delivered by then is
    /// dropped rather than arriving at night.
    fn window_end(&self, today: NaiveDate, now: DateTime<Utc>) -> DateTime<Utc> {
        today
            .and_hms_opt(self.until_hour.min(23), 0, 0)
            .and_then(|end| self.timezone.from_local_datetime(&end).earliest())
            .map(|end| end.with_timezone(&Utc))
            .filter(|end| *end > now)
            .unwrap_or(now + chrono::Duration::hours(1))
    }

    /// Sends one alert to every device and returns how many Apple accepted
    /// it for. A device's token works on only one of Apple's two services,
    /// so the other is tried when the first does not know the token.
    pub async fn deliver(&self, targets: &[PushTarget], alert: &Alert, now: DateTime<Utc>) -> usize {
        let mut delivered = 0;
        for target in targets {
            let known = target.apns_environment.as_deref().and_then(Environment::parse);
            let first = known.unwrap_or(self.default_environment);
            let mut accepted = None;
            let mut unknown_everywhere = true;
            for environment in [first, first.other()] {
                match self.apns.send(environment, &target.apns_token, alert, now).await {
                    Ok(()) => {
                        accepted = Some(environment);
                        break;
                    }
                    Err(PushError::BadDeviceToken) => continue,
                    Err(PushError::Unregistered) => break,
                    Err(error) => {
                        unknown_everywhere = false;
                        tracing::warn!(device = ?target.device_name, %error, "notification not delivered");
                        break;
                    }
                }
            }
            let stored = match accepted {
                Some(environment) => {
                    delivered += 1;
                    if known == Some(environment) {
                        Ok(())
                    } else {
                        db::set_push_environment(&self.pool, target.session_id, environment.as_str()).await
                    }
                }
                None if unknown_everywhere => {
                    tracing::info!(device = ?target.device_name, "Apple no longer knows this device; forgetting its token");
                    db::clear_push_token(&self.pool, target.session_id).await
                }
                None => Ok(()),
            };
            if let Err(error) = stored {
                tracing::error!(%error, "could not update a device's notification state");
            }
        }
        delivered
    }

    /// Background loop: look at the clock every few minutes.
    pub async fn run_forever(self: Arc<Self>, every: Duration) {
        let mut ticker = tokio::time::interval(every.max(Duration::from_secs(30)));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            ticker.tick().await;
            match self.tick(Utc::now()).await {
                Ok(Outcome::Sent { title, devices, .. }) => {
                    tracing::info!(%title, devices, "notification sent")
                }
                Ok(Outcome::Undelivered) => tracing::warn!("a notification was due but reached no device"),
                Ok(_) => {}
                Err(error) => tracing::error!(%error, "could not check for notifications"),
            }
        }
    }
}
