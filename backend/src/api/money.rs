//! Money as the apps see it: a month of spending by category, the entries
//! behind it, the accounts they came from, and the owner's say on what an
//! entry or a payee is.

use axum::extract::Query;

use super::*;
use crate::money::ledger::{self, Choice, Month, MonthView, Problem, SortedBy, Sorting};
use crate::money::sync::SOURCE as SIMPLEFIN;
use crate::money::Trouble;

#[derive(Serialize)]
pub(super) struct MoneyResponse {
    #[serde(flatten)]
    view: MonthView,
    /// What is wrong with where the figures come from, if anything: a bank
    /// to sign in to again, an import that failed.
    problems: Vec<Problem>,
    /// How many of them, from the front, stop the figures from being
    /// right: a failed import, a bank to sign in to again. The rest is
    /// what the bridge had to say in passing, which Money shows and Home
    /// does not.
    #[serde(skip)]
    pressing: usize,
    source: SourceStatus,
}

/// The little of it Home shows.
#[derive(Serialize)]
pub(super) struct Glance {
    month: Month,
    currency: String,
    spent_minor: i64,
    to_sort: u32,
    /// The first thing wrong that stops the figures from being right.
    problem: Option<String>,
    #[serde(serialize_with = "seconds::optional")]
    last_success_at: Option<DateTime<Utc>>,
}

async fn source_status(state: &AppState) -> Result<SourceStatus, ApiError> {
    let sync = db::source_sync(&state.pool, SIMPLEFIN).await?;
    let source_state = if !state.money.is_configured() {
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

/// The currency totals are in: the one set, or the one most accounts are in.
fn home_currency(state: &AppState, accounts: &[ledger::Account]) -> String {
    if let Some(currency) = &state.money_currency {
        return currency.clone();
    }
    let mut counts = std::collections::BTreeMap::<&str, usize>::new();
    for account in accounts {
        *counts.entry(account.currency.as_str()).or_default() += 1;
    }
    // The most common; of two as common, the first by name, so it is the same every time.
    counts
        .into_iter()
        .max_by(|a, b| a.1.cmp(&b.1).then_with(|| b.0.cmp(a.0)))
        .map_or_else(|| "USD".to_string(), |(currency, _)| currency.to_string())
}

async fn month_now(state: &AppState, month: Option<Month>) -> Result<MoneyResponse, ApiError> {
    let now = (state.now)();
    let today = now.with_timezone(&state.timezone).date_naive();
    let month = month.unwrap_or_else(|| Month::containing(today));
    let accounts = db::money_accounts(&state.pool).await?;
    let entries = db::money_entries_between(&state.pool, month.previous().first_day(), month.last_day()).await?;
    let history = db::money_history(&state.pool, month.first_day(), month.last_day()).await?;
    let currency = home_currency(state, &accounts);
    let view = ledger::month(ledger::MonthInput {
        month,
        today,
        now,
        currency: &currency,
        entries: &entries,
        accounts: &accounts,
        history,
    });

    let source = source_status(state).await?;
    // Ordered by how much they call for: what stops the figures first.
    let mut problems = Vec::new();
    if let Some(message) = &source.message {
        problems.push(Problem { text: format!("The last import failed: {message}."), reconnect: false });
    }
    for broken in db::broken_money_connections(&state.pool).await? {
        problems.push(Problem {
            text: format!("{}: {}", broken.name, broken.problem),
            reconnect: Trouble::needs_reconnecting(&broken.code),
        });
    }
    let pressing = problems.len();
    problems.extend(db::money_notes(&state.pool).await?.into_iter().map(|text| Problem { text, reconnect: false }));
    Ok(MoneyResponse { view, problems, pressing, source })
}

/// What Home shows of money, or nothing while no bank has ever been
/// imported and none is set up.
pub(super) async fn glance(state: &AppState) -> Result<Option<Glance>, ApiError> {
    if !state.money.is_configured() && !db::has_money(&state.pool).await? {
        return Ok(None);
    }
    let money = month_now(state, None).await?;
    Ok(Some(Glance {
        month: money.view.month,
        currency: money.view.currency,
        spent_minor: money.view.spent_minor,
        to_sort: money.view.to_sort,
        problem: money.problems[..money.pressing].first().map(|problem| problem.text.clone()),
        last_success_at: money.source.last_success_at,
    }))
}

fn parse_month(text: Option<&str>) -> Result<Option<Month>, ApiError> {
    text.map(|text| Month::parse(text).ok_or(ApiError::BadRequest("month must look like 2026-11"))).transpose()
}

#[derive(Deserialize)]
pub(super) struct MonthQuery {
    month: Option<String>,
}

pub(super) async fn month(
    State(state): State<AppState>,
    _device: Device,
    Query(query): Query<MonthQuery>,
) -> Result<Json<MoneyResponse>, ApiError> {
    Ok(Json(month_now(&state, parse_month(query.month.as_deref())?).await?))
}

#[derive(Deserialize)]
pub(super) struct SortRequest {
    /// A category by its name, or `income`, `transfer` or `unsorted`.
    to: String,
    /// True to say it of this one entry only. Otherwise it is said of the
    /// payee, and holds for every entry of theirs the owner has not
    /// sorted by itself.
    #[serde(default)]
    only_this: bool,
    /// The month to answer with; the current one when missing.
    month: Option<String>,
}

/// The owner says what an entry is.
pub(super) async fn sort(
    State(state): State<AppState>,
    _device: Device,
    Path(id): Path<Uuid>,
    Json(request): Json<SortRequest>,
) -> Result<Json<MoneyResponse>, ApiError> {
    let month = parse_month(request.month.as_deref())?;
    let choice = Choice::parse(&request.to)
        .ok_or(ApiError::BadRequest("to must be a category, income, transfer or unsorted"))?;
    let mut tx = state.pool.begin().await?;
    let entry = db::money_entry(&mut tx, id).await?.ok_or(ApiError::NotFound)?;
    // An entry with nothing to tell its payee by can only be sorted by itself.
    let only_this = request.only_this || entry.payee_key.is_empty();
    match choice {
        Choice::Unsorted => {
            db::unsort_money_entry(&mut tx, id).await?;
            if !only_this {
                db::set_money_rule(&mut tx, &entry.payee_key, None).await?;
            }
        }
        Choice::Rule(rule) => {
            let sorting = Sorting::from_rule(&rule, entry.amount_minor, SortedBy::Owner)
                .ok_or(ApiError::BadRequest("money going out is not income"))?;
            if only_this {
                db::sort_money_entry(&mut tx, id, &sorting).await?;
            } else {
                db::set_money_rule(&mut tx, &entry.payee_key, Some(&rule)).await?;
                // This entry follows its payee from now on.
                db::unsort_money_entry(&mut tx, id).await?;
            }
        }
    }
    db::resort_money(&mut tx).await?;
    tx.commit().await?;
    Ok(Json(month_now(&state, month).await?))
}

#[derive(Deserialize)]
pub(super) struct AccountRequest {
    /// True for savings and investments: the balance stays on show and
    /// nothing in the account counts as spending.
    set_aside: bool,
    month: Option<String>,
}

pub(super) async fn set_account(
    State(state): State<AppState>,
    _device: Device,
    Path(id): Path<Uuid>,
    Json(request): Json<AccountRequest>,
) -> Result<Json<MoneyResponse>, ApiError> {
    let month = parse_month(request.month.as_deref())?;
    let mut tx = state.pool.begin().await?;
    if !db::set_money_account_aside(&mut tx, id, request.set_aside).await? {
        return Err(ApiError::NotFound);
    }
    db::resort_money(&mut tx).await?;
    tx.commit().await?;
    Ok(Json(month_now(&state, month).await?))
}
