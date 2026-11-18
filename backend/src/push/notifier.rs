//! Decides when the owner is prompted, and sends the prompt.
//!
//! A prompt goes out only when a streak is at stake and today is a day to
//! act on it (see `routines::weekly::prompt`), only inside the daytime
//! window, and at most once for its period. Each weekly routine, the gym
//! and breath training, is looked at on its own. Garmin is checked again
//! just before a gym prompt, so a session recorded this morning is not
//! nagged about.
//!
//! The morning weigh-in is separate: one prompt at the owner's set time,
//! whose reply field takes the weight. It is not a streak, so it never
//! comes twice in a day and never comes once a weight is in.
//!
//! Food logging is a streak by the day, so its prompt is by the day too:
//! once, from a set time on, when a streak is alive and nothing has been
//! logged yet today.

use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, NaiveDate, NaiveDateTime, TimeZone, Timelike, Utc};
use sqlx::PgPool;

use super::apns::{Alert, ApnsClient, Environment, PushError};
use crate::db::{self, PushTarget};
use crate::garmin::sync::Syncer;
use crate::routines::breath;
use crate::routines::food::{self, FoodSettings};
use crate::routines::gym::{self, GymRules};
use crate::routines::weekly::{self, Prompt, Week, Wording};
use crate::routines::weight::{self, WeightSettings};

/// What a weigh-in prompt is recorded as, once sent for a day.
const WEIGH_IN_KIND: &str = "weigh_in";

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
    /// When the weigh-in prompt goes out, and the unit it asks for.
    pub weight: WeightSettings,
    /// From when in the day an unlogged day is prompted for.
    pub food: FoodSettings,
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
    /// Looks at the clock once and sends at most one prompt. When both
    /// routines call for one, the second goes out on the next look.
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
        let (mut routine, mut prompt) = match self.next_unsent(today).await? {
            Ok(due) => due,
            Err(outcome) => return Ok(outcome),
        };
        if routine.key == gym::WORDING.key {
            // Look again with fresh data before interrupting anyone.
            self.syncer.poll_if_stale(now, FRESH_ENOUGH).await;
            (routine, prompt) = match self.next_unsent(today).await? {
                Ok(due) => due,
                Err(outcome) => return Ok(outcome),
            };
        }

        let (kind, period) = (prompt.kind(&routine), prompt.period(today));
        let alert = Alert {
            title: prompt.title(&routine, today),
            body: prompt.body(&routine),
            collapse_id: kind.clone(),
            expires_at: self.window_end(today, now),
            category: None,
        };
        let devices = self.deliver(&targets, &alert, now).await;
        if devices == 0 {
            return Ok(Outcome::Undelivered);
        }
        db::record_notification(&self.pool, &kind, period, &alert.title, &alert.body).await?;
        Ok(Outcome::Sent { title: alert.title, body: alert.body, devices })
    }

    /// Sends the morning weigh-in prompt, once a day, from its set time
    /// until a few hours after, unless a weight is already in for today.
    /// Not held to the daytime window: it has its own time.
    pub async fn weigh_in(&self, now: DateTime<Utc>) -> sqlx::Result<Outcome> {
        let Some(at) = self.weight.prompt_at else {
            return Ok(Outcome::Quiet);
        };
        let local = now.with_timezone(&self.timezone);
        let today = local.date_naive();
        let opens = today.and_time(at);
        let closes = opens + weight::PROMPT_WINDOW;
        if local.naive_local() < opens || local.naive_local() >= closes {
            return Ok(Outcome::Quiet);
        }
        let targets = db::push_targets(&self.pool).await?;
        if targets.is_empty() {
            return Ok(Outcome::NoDevices);
        }
        let weigh_ins = db::weigh_ins(&self.pool, self.timezone).await?;
        if weight::weighed_on(&weigh_ins, today) {
            return Ok(Outcome::NothingDue);
        }
        if db::notification_sent(&self.pool, WEIGH_IN_KIND, today).await? {
            return Ok(Outcome::AlreadySent);
        }
        let alert = Alert {
            title: weight::prompt_title().to_string(),
            body: weight::prompt_body(self.weight.unit),
            collapse_id: WEIGH_IN_KIND.to_string(),
            expires_at: self.local_to_utc(closes).filter(|end| *end > now).unwrap_or(now + chrono::Duration::hours(1)),
            category: Some(weight::PROMPT_CATEGORY.to_string()),
        };
        let devices = self.deliver(&targets, &alert, now).await;
        if devices == 0 {
            return Ok(Outcome::Undelivered);
        }
        db::record_notification(&self.pool, WEIGH_IN_KIND, today, &alert.title, &alert.body).await?;
        Ok(Outcome::Sent { title: alert.title, body: alert.body, devices })
    }

    /// Sends the food-logging prompt: once a day, from its set time until
    /// the daytime window closes, when a logging streak is alive and today
    /// has nothing logged. A meal still waiting on the phone to be sent is
    /// not known here, so it can be prompted for.
    pub async fn food(&self, now: DateTime<Utc>) -> sqlx::Result<Outcome> {
        let Some(at) = self.food.prompt_at else {
            return Ok(Outcome::Quiet);
        };
        let local = now.with_timezone(&self.timezone);
        if local.hour() < self.from_hour || local.hour() >= self.until_hour || local.time() < at {
            return Ok(Outcome::Quiet);
        }
        let targets = db::push_targets(&self.pool).await?;
        if targets.is_empty() {
            return Ok(Outcome::NoDevices);
        }
        let today = local.date_naive();
        // Only which days have a meal matters here, not what a photo showed.
        let entries = db::food_entries(&self.pool, self.timezone, now).await?;
        let Some(prompt) = food::prompt(&food::streak(today, &food::logged_days(&entries))) else {
            return Ok(Outcome::NothingDue);
        };
        if db::notification_sent(&self.pool, food::PROMPT_KIND, today).await? {
            return Ok(Outcome::AlreadySent);
        }
        let alert = Alert {
            title: prompt.title(),
            body: prompt.body(),
            collapse_id: food::PROMPT_KIND.to_string(),
            expires_at: self.window_end(today, now),
            category: Some(food::PROMPT_CATEGORY.to_string()),
        };
        let devices = self.deliver(&targets, &alert, now).await;
        if devices == 0 {
            return Ok(Outcome::Undelivered);
        }
        db::record_notification(&self.pool, food::PROMPT_KIND, today, &alert.title, &alert.body).await?;
        Ok(Outcome::Sent { title: alert.title, body: alert.body, devices })
    }

    fn local_to_utc(&self, local: NaiveDateTime) -> Option<DateTime<Utc>> {
        self.timezone.from_local_datetime(&local).earliest().map(|at| at.with_timezone(&Utc))
    }

    /// The first prompt today calls for that has not gone out yet, or why
    /// there is none.
    async fn next_unsent(&self, today: NaiveDate) -> sqlx::Result<Result<(Wording, Prompt), Outcome>> {
        let due = self.due(today).await?;
        if due.is_empty() {
            return Ok(Err(Outcome::NothingDue));
        }
        for (routine, prompt) in due {
            if !db::notification_sent(&self.pool, &prompt.kind(&routine), prompt.period(today)).await? {
                return Ok(Ok((routine, prompt)));
            }
        }
        Ok(Err(Outcome::AlreadySent))
    }

    /// The prompts today calls for, from what is stored now: at most one
    /// per routine.
    async fn due(&self, today: NaiveDate) -> sqlx::Result<Vec<(Wording, Prompt)>> {
        let mut due = Vec::new();

        let week = Week::containing(today);
        let activities = db::activities_until(&self.pool, week.ends_on).await?;
        let streak = gym::streak(&self.gym_rules, today, &activities);
        let trained_today = gym::sessions_in_week(&self.gym_rules, week, &activities)
            .iter()
            .any(|session| session.date == today);
        due.extend(gym::prompt(&streak, trained_today).map(|prompt| (gym::WORDING, prompt)));

        let sessions = db::breath_sessions(&self.pool, self.timezone).await?;
        let streak = breath::streak(today, &sessions);
        let done_today = breath::session_days(&sessions).contains(&today);
        due.extend(weekly::prompt(&streak, done_today).map(|prompt| (breath::WORDING, prompt)));

        Ok(due)
    }

    /// When today's window closes; a prompt not delivered by then is
    /// dropped rather than arriving at night.
    fn window_end(&self, today: NaiveDate, now: DateTime<Utc>) -> DateTime<Utc> {
        today
            .and_hms_opt(self.until_hour.min(23), 0, 0)
            .and_then(|end| self.local_to_utc(end))
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
            let now = Utc::now();
            match self.weigh_in(now).await {
                Ok(Outcome::Sent { devices, .. }) => tracing::info!(devices, "weigh-in prompt sent"),
                Ok(Outcome::Undelivered) => tracing::warn!("the weigh-in prompt was due but reached no device"),
                Ok(_) => {}
                Err(error) => tracing::error!(%error, "could not check for the weigh-in prompt"),
            }
            match self.food(now).await {
                Ok(Outcome::Sent { devices, .. }) => tracing::info!(devices, "food-logging prompt sent"),
                Ok(Outcome::Undelivered) => tracing::warn!("the food-logging prompt was due but reached no device"),
                Ok(_) => {}
                Err(error) => tracing::error!(%error, "could not check for the food-logging prompt"),
            }
            match self.tick(now).await {
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
