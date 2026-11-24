//! Brings accounts, posted transactions and what the investment accounts
//! hold from the bridge into the database. Safe to run as often as the
//! bridge allows: a transaction is stored under the bank's own id, so
//! importing the same days again refreshes it instead of adding it, and
//! whatever the owner has sorted stays sorted. Each import also keeps
//! every account's balance for the day, which is what net worth over time
//! is drawn from.

use std::sync::Arc;
use std::time::Duration;

use chrono::{DateTime, NaiveDate, NaiveTime, Utc};
use sqlx::PgPool;

use super::{AccountSet, BridgeClient, BridgeError, Trouble, MAX_RANGE_DAYS};
use crate::db::{self, Stored};

pub const SOURCE: &str = "simplefin";

/// On the first import the bridge is asked for at most this many stretches
/// of history, newest first, and no further back once one comes up empty.
const MAX_BACKFILL_REQUESTS: i64 = 4;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ImportReport {
    /// How many times the bridge was asked.
    pub requests: usize,
    pub accounts: usize,
    /// Posted transactions the bridge returned.
    pub fetched: usize,
    /// Of those, how many were not stored before.
    pub new: usize,
    /// And how many the bank had changed since.
    pub changed: usize,
    /// What the investment accounts hold, as the bank lists it now.
    pub holdings: usize,
    /// Accounts, transactions and holdings that could not be read and were
    /// left out.
    pub unreadable: usize,
    /// Things the bridge said were wrong.
    pub troubles: usize,
    /// Entries whose sorting changed as a result: transfers found, rules applied.
    pub resorted: u64,
}

#[derive(Debug, thiserror::Error)]
pub enum ImportError {
    #[error(transparent)]
    Bridge(#[from] BridgeError),
    #[error("the database refused the update")]
    Database(#[from] sqlx::Error),
}

pub struct Importer {
    pool: PgPool,
    client: Option<BridgeClient>,
    timezone: chrono_tz::Tz,
    backfill_days: i64,
    window_days: i64,
    /// One import at a time.
    running: tokio::sync::Mutex<()>,
}

impl Importer {
    pub fn new(
        pool: PgPool,
        client: Option<BridgeClient>,
        timezone: chrono_tz::Tz,
        backfill_days: i64,
        window_days: i64,
    ) -> Self {
        Self {
            pool,
            client,
            timezone,
            backfill_days: backfill_days.max(1),
            window_days: window_days.clamp(1, MAX_RANGE_DAYS - 1),
            running: tokio::sync::Mutex::new(()),
        }
    }

    pub fn is_configured(&self) -> bool {
        self.client.is_some()
    }

    /// Imports once and records the outcome as the source's freshness.
    /// Returns `None` when no access file is configured.
    pub async fn import_once(&self, now: DateTime<Utc>) -> Option<Result<ImportReport, ImportError>> {
        let client = self.client.as_ref()?;
        let _guard = self.running.lock().await;
        let result = self.import(client, now).await;
        let recorded = match &result {
            Ok(_) => db::record_sync_success(&self.pool, SOURCE).await,
            Err(error) => db::record_sync_failure(&self.pool, SOURCE, &error.to_string()).await,
        };
        if let Err(error) = recorded {
            tracing::error!(%error, "could not record the money import's outcome");
        }
        Some(result)
    }

    /// Imports unless the bridge was already asked within `every`, whether
    /// that worked or not. This is what keeps lyfe inside what the bridge
    /// allows, also across restarts.
    pub async fn import_if_due(&self, now: DateTime<Utc>, every: Duration) -> Option<Result<ImportReport, ImportError>> {
        if !self.is_configured() {
            return None;
        }
        let recent = match db::source_sync(&self.pool, SOURCE).await {
            // An attempt stamped after now (a clock put back) counts as recent too.
            Ok(sync) => sync.last_attempt_at.is_some_and(|at| (now - at).to_std().is_ok_and(|age| age < every) || at > now),
            // Not knowing is no reason to ask the bridge again.
            Err(_) => true,
        };
        if recent {
            return None;
        }
        self.import_once(now).await
    }

    /// Background loop: look every few minutes whether an import is due.
    /// Nothing about an account or a payee is ever logged, only counts.
    pub async fn run_forever(self: Arc<Self>, every: Duration) {
        if !self.is_configured() {
            return;
        }
        let mut ticker = tokio::time::interval(Duration::from_secs(600));
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            ticker.tick().await;
            match self.import_if_due(Utc::now(), every).await {
                Some(Ok(report)) => tracing::info!(
                    requests = report.requests,
                    accounts = report.accounts,
                    fetched = report.fetched,
                    new = report.new,
                    changed = report.changed,
                    unreadable = report.unreadable,
                    troubles = report.troubles,
                    resorted = report.resorted,
                    holdings = report.holdings,
                    "money import finished"
                ),
                Some(Err(error)) => tracing::warn!(%error, "money import failed"),
                None => {}
            }
        }
    }

    async fn import(&self, client: &BridgeClient, now: DateTime<Utc>) -> Result<ImportReport, ImportError> {
        let today = now.with_timezone(&self.timezone).date_naive();
        // A day past now: a bank's clock can run ahead of this one.
        let until = now + chrono::Duration::days(1);
        let mut report = ImportReport::default();

        if db::has_money(&self.pool).await? {
            let from = now - chrono::Duration::days(self.window_days);
            let set = client.accounts(from, until).await?;
            report.requests = 1;
            self.store(&set, today, true, &mut report).await?;
            return Ok(report);
        }

        // The first import reaches back a stretch at a time, newest first,
        // and stops where the bank has nothing older to give.
        let stretch = chrono::Duration::days(MAX_RANGE_DAYS - 1);
        let oldest = now - chrono::Duration::days(self.backfill_days);
        let mut until = until;
        let mut from = (now - stretch).max(oldest);
        for request in 0..MAX_BACKFILL_REQUESTS {
            let set = client.accounts(from, until).await?;
            report.requests += 1;
            let before = report.fetched;
            self.store(&set, today, request == 0, &mut report).await?;
            if report.fetched == before || from <= oldest {
                break;
            }
            until = from;
            from = (from - chrono::Duration::days(MAX_RANGE_DAYS)).max(oldest);
        }
        Ok(report)
    }

    /// Writes one answer. `latest` is the answer for the newest days, whose
    /// troubles describe the connections as they are now.
    async fn store(
        &self,
        set: &AccountSet,
        today: NaiveDate,
        latest: bool,
        report: &mut ImportReport,
    ) -> Result<(), sqlx::Error> {
        let mut tx = self.pool.begin().await?;
        if latest {
            report.troubles = set.troubles.len();
            for connection in &set.connections {
                let trouble = set
                    .troubles
                    .iter()
                    .find(|trouble| trouble.connection_id.as_deref() == Some(connection.id.as_str()) && trouble.account_id.is_none());
                db::upsert_money_connection(
                    &mut tx,
                    connection,
                    trouble.map(|trouble| (trouble.code.as_str(), trouble.text.as_str())),
                    today,
                )
                .await?;
            }
            let notes: Vec<String> =
                set.troubles.iter().filter(|trouble| is_general(trouble, set)).map(|trouble| trouble.text.clone()).collect();
            db::set_money_notes(&mut tx, &notes).await?;
        }
        report.accounts = report.accounts.max(set.accounts.len());
        report.unreadable += set.unreadable_accounts;
        for account in &set.accounts {
            let trouble = set.troubles.iter().find(|trouble| trouble.account_id.as_deref() == Some(account.id.as_str()));
            let account_id = db::upsert_money_account(&mut tx, account, trouble.map(|trouble| trouble.text.as_str())).await?;
            // The balance and the holdings are the account as it is now,
            // whatever days were asked for: kept once, from the newest answer.
            if latest {
                db::keep_money_balance(&mut tx, account_id, today, account.balance_minor).await?;
                if let Some(holdings) = &account.holdings {
                    db::replace_money_holdings(&mut tx, account_id, holdings).await?;
                    report.holdings += holdings.len();
                }
                report.unreadable += account.unreadable_holdings;
            }
            report.unreadable += account.unreadable;
            report.fetched += account.transactions.len();
            for transaction in &account.transactions {
                let at = transaction.transacted_at.unwrap_or(transaction.posted_at);
                match db::upsert_money_entry(&mut tx, account_id, transaction, counted_on(at, self.timezone)).await? {
                    Stored::New => report.new += 1,
                    Stored::Changed => report.changed += 1,
                    Stored::Same => {}
                }
            }
        }
        report.resorted += db::resort_money(&mut tx).await?;
        tx.commit().await
    }
}

/// A trouble that is about no connection or account lyfe knows, and so
/// about the import as a whole.
fn is_general(trouble: &Trouble, set: &AccountSet) -> bool {
    let about_connection =
        trouble.connection_id.as_ref().is_some_and(|id| set.connections.iter().any(|connection| &connection.id == id));
    let about_account = trouble.account_id.as_ref().is_some_and(|id| set.accounts.iter().any(|account| &account.id == id));
    !about_connection && !about_account
}

/// The day a transaction counts on. Banks mostly give a date and no time,
/// which the bridge writes as noon or midnight UTC: that date is the day.
/// A real time of day is read in the owner's time zone.
pub fn counted_on(at: DateTime<Utc>, timezone: chrono_tz::Tz) -> NaiveDate {
    let time = at.time();
    let noon = NaiveTime::from_hms_opt(12, 0, 0).expect("noon is a time");
    if time == NaiveTime::MIN || time == noon { at.date_naive() } else { at.with_timezone(&timezone).date_naive() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_date_without_a_time_is_its_own_day_anywhere() {
        let at = |text: &str| text.parse::<DateTime<Utc>>().unwrap();
        let day = |text: &str| text.parse::<NaiveDate>().unwrap();
        let (west, east) = (chrono_tz::America::Vancouver, chrono_tz::Pacific::Auckland);
        // Noon and midnight UTC are how a bare date arrives.
        assert_eq!(counted_on(at("2026-11-05T12:00:00Z"), east), day("2026-11-05"));
        assert_eq!(counted_on(at("2026-11-05T00:00:00Z"), west), day("2026-11-05"));
        // A real time of day is the owner's day.
        assert_eq!(counted_on(at("2026-11-05T03:30:00Z"), west), day("2026-11-04"));
        assert_eq!(counted_on(at("2026-11-05T13:30:00Z"), east), day("2026-11-06"));
    }
}
