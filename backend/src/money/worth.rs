//! What everything comes to, and what the investments are in. Pure rules:
//! nothing here reads the database or the bridge.
//!
//! Net worth is every account's balance added up: what is in the bank and
//! what is invested, less what is owed. The bank gives only the balance
//! now, so lyfe keeps each account's balance once a day and the line over
//! time is drawn from those; it starts the day they started being kept.
//!
//! As everywhere in money, totals are in one currency and nothing is
//! converted: an account or a holding in another is listed and left out.

use std::collections::{BTreeMap, HashSet};

use chrono::NaiveDate;
use serde::Serialize;
use uuid::Uuid;

use super::ledger::{Account, AccountView};

/// Past this many days the line is drawn a week at a time.
const DAYS_DRAWN_WHOLE: usize = 400;

/// What a change is measured over, when the days kept reach back that far.
const CHANGE_OVER_DAYS: i64 = 30;

/// One holding as it is stored, with the account it is in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Holding {
    pub account_id: Uuid,
    pub symbol: String,
    pub name: String,
    pub currency: String,
    pub shares_micro: i64,
    pub value_minor: i64,
    pub cost_minor: Option<i64>,
}

/// What an account's balance was on a day.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Balance {
    pub account_id: Uuid,
    pub currency: String,
    pub day: NaiveDate,
    pub balance_minor: i64,
}

/// One thing the investments are in, across every account that holds it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct HoldingView {
    /// The ticker, or empty when the bank gives none.
    pub symbol: String,
    pub name: String,
    pub currency: String,
    /// In millionths; zero when the bank does not say for all of it.
    pub shares_micro: i64,
    pub value_minor: i64,
    /// What was paid for it, when the bank says so for all of it.
    pub cost_minor: Option<i64>,
    /// The accounts it is held in, by name.
    pub accounts: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Point {
    pub day: NaiveDate,
    pub worth_minor: i64,
}

/// How net worth moved since an earlier day.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Change {
    pub since: NaiveDate,
    pub minor: i64,
}

/// What the holdings are worth against what was paid for them, over the
/// ones the bank gives a cost for.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Paid {
    pub paid_minor: i64,
    /// What those same holdings are worth now.
    pub worth_minor: i64,
    /// How many holdings that covers.
    pub holdings: u32,
}

/// Net worth as the apps show it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct WorthView {
    /// The currency the totals are in.
    pub currency: String,
    /// Everything added up: in the bank and invested, less what is owed.
    pub worth_minor: i64,
    /// What is in accounts that hold no investments.
    pub banked_minor: i64,
    /// The balances of the accounts the bank lists holdings for.
    pub invested_minor: i64,
    /// What is owed, on cards mostly, as a figure above zero.
    pub owed_minor: i64,
    pub everyday_minor: i64,
    pub set_aside_minor: i64,
    /// The first day a balance was kept; the line starts there.
    pub recorded_since: Option<NaiveDate>,
    /// Net worth a day at a time, oldest first, today last.
    pub series: Vec<Point>,
    pub change: Option<Change>,
    /// Largest first.
    pub holdings: Vec<HoldingView>,
    /// The holdings added up.
    pub held_minor: i64,
    /// What sits in investment accounts and in no holding.
    pub loose_minor: i64,
    pub paid: Option<Paid>,
    pub accounts: Vec<AccountView>,
}

pub struct WorthInput<'a> {
    pub today: NaiveDate,
    pub now: chrono::DateTime<chrono::Utc>,
    pub currency: &'a str,
    /// The accounts the bridge still lists.
    pub accounts: &'a [Account],
    /// What those accounts hold.
    pub holdings: &'a [Holding],
    /// Every balance kept, of any account, in any order.
    pub balances: &'a [Balance],
}

pub fn worth(input: WorthInput<'_>) -> WorthView {
    let WorthInput { today, now, currency, accounts, holdings, balances } = input;
    let counted: Vec<&Account> = accounts.iter().filter(|account| account.currency == currency).collect();
    let sum = |of: &dyn Fn(&Account) -> bool| -> i64 {
        counted.iter().filter(|account| of(account)).map(|account| account.balance_minor).sum()
    };
    let invested_minor = sum(&|account| account.invested);
    let banked_minor = sum(&|account| !account.invested && account.balance_minor > 0);
    let owed_minor = -sum(&|account| !account.invested && account.balance_minor < 0);

    let held = merged(holdings, accounts);
    let in_totals = |holding: &&HoldingView| holding.currency == currency;
    let held_minor = held.iter().filter(in_totals).map(|holding| holding.value_minor).sum();
    let costed: Vec<&HoldingView> = held.iter().filter(in_totals).filter(|holding| holding.cost_minor.is_some()).collect();
    let paid = (!costed.is_empty()).then(|| Paid {
        paid_minor: costed.iter().filter_map(|holding| holding.cost_minor).sum(),
        worth_minor: costed.iter().map(|holding| holding.value_minor).sum(),
        holdings: costed.len() as u32,
    });

    // What an investment account has that is in no holding. Only where
    // every holding is in the account's own currency: otherwise what they
    // come to cannot be set against its balance.
    let loose_minor = counted
        .iter()
        .filter(|account| account.invested)
        .filter_map(|account| {
            let mine: Vec<&Holding> = holdings.iter().filter(|holding| holding.account_id == account.id).collect();
            let comparable = !mine.is_empty() && mine.iter().all(|holding| holding.currency == account.currency);
            comparable.then(|| account.balance_minor - mine.iter().map(|holding| holding.value_minor).sum::<i64>())
        })
        .filter(|loose| *loose > 0)
        .sum();

    let listed: HashSet<Uuid> = accounts.iter().map(|account| account.id).collect();
    let kept = Kept::new(balances, &listed, currency, today);
    let daily = kept.series();
    let change = kept.change(&daily);
    let total = |aside: bool| -> i64 {
        counted.iter().filter(|account| account.set_aside == aside).map(|account| account.balance_minor).sum()
    };

    WorthView {
        currency: currency.to_string(),
        worth_minor: banked_minor + invested_minor - owed_minor,
        banked_minor,
        invested_minor,
        owed_minor,
        everyday_minor: total(false),
        set_aside_minor: total(true),
        recorded_since: daily.first().map(|point| point.day),
        series: thinned(daily, today),
        change,
        holdings: held,
        held_minor,
        loose_minor,
        paid,
        accounts: accounts.iter().map(|account| AccountView::of(account, now)).collect(),
    }
}

/// The same fund held in two accounts is one holding: what the investments
/// are in is asked of all of them together. Largest first.
fn merged(holdings: &[Holding], accounts: &[Account]) -> Vec<HoldingView> {
    struct Sum {
        view: HoldingView,
        shares_known: bool,
    }
    let mut by_what = BTreeMap::<(String, String), Sum>::new();
    let mut nameless = 0;
    for holding in holdings {
        let Some(account) = accounts.iter().find(|account| account.id == holding.account_id) else { continue };
        // Told apart by the ticker, or by the name where there is none.
        // One with neither is nothing to tell another by, and stays its own.
        let what = match (holding.symbol.is_empty(), holding.name.is_empty()) {
            (false, _) => holding.symbol.to_uppercase(),
            (true, false) => holding.name.to_lowercase(),
            (true, true) => format!("\u{0}{nameless}"),
        };
        nameless += usize::from(holding.symbol.is_empty() && holding.name.is_empty());
        let sum = by_what.entry((what, holding.currency.clone())).or_insert_with(|| Sum {
            view: HoldingView {
                symbol: holding.symbol.clone(),
                name: holding.name.clone(),
                currency: holding.currency.clone(),
                shares_micro: 0,
                value_minor: 0,
                cost_minor: Some(0),
                accounts: Vec::new(),
            },
            shares_known: true,
        });
        sum.view.value_minor += holding.value_minor;
        sum.view.shares_micro += holding.shares_micro;
        sum.shares_known &= holding.shares_micro > 0;
        sum.view.cost_minor = sum.view.cost_minor.zip(holding.cost_minor).map(|(so_far, cost)| so_far + cost);
        if sum.view.name.is_empty() {
            sum.view.name = holding.name.clone();
        }
        if !sum.view.accounts.contains(&account.name) {
            sum.view.accounts.push(account.name.clone());
        }
    }
    let mut held: Vec<HoldingView> = by_what
        .into_values()
        .map(|mut sum| {
            sum.view.accounts.sort();
            HoldingView { shares_micro: if sum.shares_known { sum.view.shares_micro } else { 0 }, ..sum.view }
        })
        .collect();
    held.sort_by(|a, b| b.value_minor.cmp(&a.value_minor).then_with(|| a.symbol.cmp(&b.symbol)).then_with(|| a.name.cmp(&b.name)));
    held
}

/// The balances kept, an account at a time, oldest first.
struct Kept<'a> {
    by_account: BTreeMap<Uuid, Vec<(NaiveDate, i64)>>,
    listed: &'a HashSet<Uuid>,
    today: NaiveDate,
}

impl<'a> Kept<'a> {
    fn new(balances: &[Balance], listed: &'a HashSet<Uuid>, currency: &str, today: NaiveDate) -> Self {
        let mut by_account = BTreeMap::<Uuid, Vec<(NaiveDate, i64)>>::new();
        for balance in balances.iter().filter(|balance| balance.currency == currency && balance.day <= today) {
            by_account.entry(balance.account_id).or_default().push((balance.day, balance.balance_minor));
        }
        for days in by_account.values_mut() {
            days.sort();
        }
        Kept { by_account, listed, today }
    }

    /// What an account counted for on a day: the last balance kept on or
    /// before it. Nothing before its first; and nothing after its last
    /// once the bridge no longer lists it, since what was in it went
    /// somewhere else.
    fn on(&self, account: &Uuid, day: NaiveDate) -> Option<i64> {
        let days = self.by_account.get(account)?;
        let (last, _) = *days.last()?;
        if day > last && !self.listed.contains(account) {
            return None;
        }
        days.partition_point(|(kept, _)| *kept <= day).checked_sub(1).map(|at| days[at].1)
    }

    /// Net worth a day at a time, from the first balance kept to today. A
    /// day with no balance for an account takes the last one before it.
    fn series(&self) -> Vec<Point> {
        let Some(first) = self.by_account.values().filter_map(|days| days.first()).map(|(day, _)| *day).min() else {
            return Vec::new();
        };
        first
            .iter_days()
            .take_while(|day| *day <= self.today)
            .map(|day| Point { day, worth_minor: self.by_account.keys().filter_map(|account| self.on(account, day)).sum() })
            .collect()
    }

    /// How net worth moved over the last month, or since the first day
    /// kept when that is nearer. An account first seen since then is left
    /// out of it: lyfe learning of money is not money arriving. One closed
    /// since is not: what was in it left.
    fn change(&self, daily: &[Point]) -> Option<Change> {
        let latest = daily.last()?;
        let wanted = latest.day - chrono::Duration::days(CHANGE_OVER_DAYS);
        let from = daily.iter().rev().find(|point| point.day <= wanted).or(daily.first())?;
        if from.day >= latest.day {
            return None;
        }
        let minor = self
            .by_account
            .iter()
            .filter(|(_, days)| days.first().is_some_and(|(first, _)| *first <= from.day))
            .map(|(account, _)| self.on(account, latest.day).unwrap_or(0) - self.on(account, from.day).unwrap_or(0))
            .sum();
        Some(Change { since: from.day, minor })
    }
}

/// Net worth a day at a time, from the first balance kept to today. An
/// account the bridge no longer lists counts up to the last day it was
/// seen, and not after.
pub fn series(balances: &[Balance], listed: &HashSet<Uuid>, currency: &str, today: NaiveDate) -> Vec<Point> {
    Kept::new(balances, listed, currency, today).series()
}

/// The line as it is sent: every day while it is short, and a week at a
/// time, counted back from today, once it is long. The first day kept is
/// always there, since that is where the line says it starts.
pub fn thinned(daily: Vec<Point>, today: NaiveDate) -> Vec<Point> {
    if daily.len() <= DAYS_DRAWN_WHOLE {
        return daily;
    }
    daily
        .into_iter()
        .enumerate()
        .filter(|(index, point)| *index == 0 || (today - point.day).num_days() % 7 == 0)
        .map(|(_, point)| point)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn day(text: &str) -> NaiveDate {
        text.parse().unwrap()
    }

    fn now() -> chrono::DateTime<chrono::Utc> {
        "2026-11-17T15:00:00Z".parse().unwrap()
    }

    fn account(n: u128, name: &str, currency: &str, balance_minor: i64, set_aside: bool, invested: bool) -> Account {
        Account {
            id: Uuid::from_u128(n),
            name: name.into(),
            connection: "First Bank".into(),
            currency: currency.into(),
            balance_minor,
            available_minor: None,
            balance_at: now(),
            set_aside,
            invested,
            problem: None,
            bank_currency: None,
        }
    }

    fn holding(account: u128, symbol: &str, name: &str, shares_micro: i64, value_minor: i64, cost_minor: Option<i64>) -> Holding {
        Holding {
            account_id: Uuid::from_u128(account),
            symbol: symbol.into(),
            name: name.into(),
            currency: "CAD".into(),
            shares_micro,
            value_minor,
            cost_minor,
        }
    }

    fn kept(account: u128, on: &str, balance_minor: i64) -> Balance {
        Balance { account_id: Uuid::from_u128(account), currency: "CAD".into(), day: day(on), balance_minor }
    }

    fn view(accounts: &[Account], holdings: &[Holding], balances: &[Balance]) -> WorthView {
        worth(WorthInput { today: day("2026-11-17"), now: now(), currency: "CAD", accounts, holdings, balances })
    }

    #[test]
    fn net_worth_is_the_bank_and_the_investments_less_what_is_owed() {
        let accounts = [
            account(1, "Chequing", "CAD", 284_512, false, false),
            account(2, "Card", "CAD", -41_733, false, false),
            account(3, "Savings", "CAD", 1_250_000, true, false),
            account(4, "Brokerage", "CAD", 2_210_455, true, true),
            account(5, "Dollars", "USD", 31_000, false, false),
        ];
        let view = view(&accounts, &[], &[]);
        assert_eq!((view.banked_minor, view.invested_minor, view.owed_minor), (1_534_512, 2_210_455, 41_733));
        assert_eq!(view.worth_minor, 284_512 - 41_733 + 1_250_000 + 2_210_455);
        assert_eq!((view.everyday_minor, view.set_aside_minor), (242_779, 3_460_455));
        // The account in another currency is listed and left out.
        assert_eq!(view.accounts.len(), 5);
        assert_eq!((view.series.len(), view.recorded_since, view.change), (0, None, None));
        assert_eq!((view.holdings.len(), view.held_minor, view.loose_minor, view.paid), (0, 0, 0, None));
    }

    #[test]
    fn the_same_fund_in_two_accounts_is_one_holding() {
        let accounts = [
            account(1, "Brokerage", "CAD", 1_800_000, true, true),
            account(2, "Retirement", "CAD", 500_000, true, true),
        ];
        let mut dollars = holding(1, "BIG", "Big Tech Co", 4_000_000, 150_050, None);
        dollars.currency = "USD".into();
        let holdings = [
            holding(1, "WRLD", "Whole World Equity Fund", 300_000_000, 1_000_000, Some(800_000)),
            holding(2, "wrld", "", 150_000_000, 500_000, Some(450_000)),
            holding(1, "BOND", "Bond Fund", 0, 400_000, None),
            holding(1, "", "Savings Bond", 0, 60_000, Some(60_000)),
            dollars,
            // In an account the bridge no longer lists: not shown.
            holding(9, "GONE", "Gone", 1_000_000, 999, None),
        ];
        let view = view(&accounts, &holdings, &[]);
        assert_eq!(
            view.holdings,
            vec![
                HoldingView {
                    symbol: "WRLD".into(),
                    name: "Whole World Equity Fund".into(),
                    currency: "CAD".into(),
                    shares_micro: 450_000_000,
                    value_minor: 1_500_000,
                    cost_minor: Some(1_250_000),
                    accounts: vec!["Brokerage".into(), "Retirement".into()],
                },
                HoldingView {
                    symbol: "BOND".into(),
                    name: "Bond Fund".into(),
                    currency: "CAD".into(),
                    shares_micro: 0,
                    value_minor: 400_000,
                    cost_minor: None,
                    accounts: vec!["Brokerage".into()],
                },
                HoldingView {
                    symbol: "BIG".into(),
                    name: "Big Tech Co".into(),
                    currency: "USD".into(),
                    shares_micro: 4_000_000,
                    value_minor: 150_050,
                    cost_minor: None,
                    accounts: vec!["Brokerage".into()],
                },
                HoldingView {
                    symbol: String::new(),
                    name: "Savings Bond".into(),
                    currency: "CAD".into(),
                    shares_micro: 0,
                    value_minor: 60_000,
                    cost_minor: Some(60_000),
                    accounts: vec!["Brokerage".into()],
                },
            ]
        );
        // The holding in dollars is listed and left out of what they come to.
        assert_eq!(view.held_minor, 1_960_000);
        // Growth is said only of the holdings a cost is known for.
        assert_eq!(view.paid, Some(Paid { paid_minor: 1_310_000, worth_minor: 1_560_000, holdings: 2 }));
        // The brokerage holds something in dollars, so what is loose in it
        // cannot be told, whatever its balance; the retirement account's
        // holdings come to all of it.
        assert_eq!(view.loose_minor, 0);
    }

    #[test]
    fn holdings_with_nothing_to_tell_them_by_stay_apart() {
        let accounts = [account(1, "Brokerage", "CAD", 500_000, true, true)];
        let holdings = [holding(1, "", "", 0, 300_000, None), holding(1, "", "", 0, 200_000, None)];
        let view = view(&accounts, &holdings, &[]);
        assert_eq!(view.holdings.iter().map(|holding| holding.value_minor).collect::<Vec<_>>(), vec![300_000, 200_000]);
        assert_eq!(view.held_minor, 500_000);
    }

    #[test]
    fn what_is_in_an_investment_account_and_in_no_holding_is_loose() {
        let accounts = [account(1, "Brokerage", "CAD", 1_050_000, true, true), account(2, "Retirement", "CAD", 90_000, true, true)];
        let holdings = [
            holding(1, "WRLD", "Whole World", 1, 1_000_000, None),
            // Worth more than the bank's balance says: nothing is loose, and nothing is owed.
            holding(2, "BOND", "Bond Fund", 1, 100_000, None),
        ];
        assert_eq!(view(&accounts, &holdings, &[]).loose_minor, 50_000);
    }

    #[test]
    fn the_line_is_drawn_from_the_balances_kept_a_day_at_a_time() {
        let accounts = [account(1, "Chequing", "CAD", 120_000, false, false), account(2, "Brokerage", "CAD", 500_000, true, true)];
        let mut dollars = kept(3, "2026-11-13", 77_700);
        dollars.currency = "USD".into();
        let balances = [
            kept(1, "2026-11-13", 100_000),
            kept(2, "2026-11-14", 480_000),
            kept(1, "2026-11-15", 90_000),
            // Nothing kept on the 16th: the day before stands.
            kept(1, "2026-11-17", 120_000),
            kept(2, "2026-11-17", 500_000),
            dollars,
            // An account closed since: it counts while it was seen, and not after.
            kept(9, "2026-11-13", 5_000),
            kept(9, "2026-11-14", 5_000),
        ];
        let view = view(&accounts, &[], &balances);
        assert_eq!(
            view.series.iter().map(|point| (point.day.to_string(), point.worth_minor)).collect::<Vec<_>>(),
            vec![
                ("2026-11-13".to_string(), 105_000),
                ("2026-11-14".to_string(), 585_000),
                ("2026-11-15".to_string(), 570_000),
                ("2026-11-16".to_string(), 570_000),
                ("2026-11-17".to_string(), 620_000),
            ]
        );
        assert_eq!(view.recorded_since, Some(day("2026-11-13")));
        // Not a month kept yet: the change is since the first day. The
        // chequing account is up 200; the closed account's 50 left; and
        // the brokerage, first seen a day later, is no gain at all.
        assert_eq!(view.change, Some(Change { since: day("2026-11-13"), minor: 15_000 }));
    }

    #[test]
    fn an_account_connected_later_is_not_money_arriving() {
        let accounts = [account(1, "Chequing", "CAD", 110_000, false, false), account(2, "Brokerage", "CAD", 5_000_000, true, true)];
        let mut balances: Vec<Balance> = (0..48)
            .map(|n| Balance {
                account_id: Uuid::from_u128(1),
                currency: "CAD".into(),
                day: day("2026-10-01") + chrono::Duration::days(n),
                balance_minor: if n < 40 { 100_000 } else { 110_000 },
            })
            .collect();
        balances.push(kept(2, "2026-11-10", 5_000_000));
        balances.push(kept(2, "2026-11-17", 5_000_000));
        let view = view(&accounts, &[], &balances);
        // The line steps up the day the brokerage is first seen; the change does not.
        assert_eq!(view.series.last().map(|point| point.worth_minor), Some(5_110_000));
        assert_eq!(view.change, Some(Change { since: day("2026-10-18"), minor: 10_000 }));
    }

    #[test]
    fn a_day_the_import_failed_takes_the_balance_before_it() {
        let listed = HashSet::from([Uuid::from_u128(1)]);
        let balances = [kept(1, "2026-11-10", 100_000)];
        let points = series(&balances, &listed, "CAD", day("2026-11-12"));
        assert_eq!(points.iter().map(|point| point.worth_minor).collect::<Vec<_>>(), vec![100_000, 100_000, 100_000]);
        // A balance dated after today (a clock put back) is not drawn.
        assert_eq!(series(&balances, &listed, "CAD", day("2026-11-09")), vec![]);
    }

    #[test]
    fn the_change_is_over_a_month_once_a_month_is_kept() {
        let accounts = [account(1, "Chequing", "CAD", 0, false, false)];
        let balances: Vec<Balance> = (0..50)
            .map(|n| Balance {
                account_id: Uuid::from_u128(1),
                currency: "CAD".into(),
                day: day("2026-09-29") + chrono::Duration::days(n),
                balance_minor: 100_000 + n * 1_000,
            })
            .collect();
        let view = worth(WorthInput {
            today: day("2026-11-17"),
            now: now(),
            currency: "CAD",
            accounts: &accounts,
            holdings: &[],
            balances: &balances,
        });
        assert_eq!(view.series.len(), 50);
        assert_eq!(view.change, Some(Change { since: day("2026-10-18"), minor: 30_000 }));
        // One day kept is no change at all.
        let one = worth(WorthInput {
            today: day("2026-11-17"),
            now: now(),
            currency: "CAD",
            accounts: &accounts,
            holdings: &[],
            balances: &balances[49..],
        });
        assert_eq!((one.series.len(), one.change), (1, None));
    }

    #[test]
    fn years_of_days_are_drawn_a_week_at_a_time() {
        let listed = HashSet::from([Uuid::from_u128(1)]);
        let balances: Vec<Balance> = (0..800)
            .map(|n| Balance {
                account_id: Uuid::from_u128(1),
                currency: "CAD".into(),
                day: day("2024-09-09") + chrono::Duration::days(n),
                balance_minor: n,
            })
            .collect();
        let today = day("2024-09-09") + chrono::Duration::days(799);
        let daily = series(&balances, &listed, "CAD", today);
        assert_eq!(daily.len(), 800);
        let points = thinned(daily, today);
        // A week at a time counted back from today, and the first day kept besides.
        assert_eq!(points.len(), 116);
        assert_eq!(points.first().map(|point| point.day), Some(day("2024-09-09")));
        assert_eq!(points.last().map(|point| (point.day, point.worth_minor)), Some((today, 799)));
        assert!(points[1..].windows(2).all(|pair| (pair[1].day - pair[0].day).num_days() == 7));
        // A short line is sent whole.
        assert_eq!(thinned(points.clone(), today).len(), 116);

        // Where it starts and how it moved are read from every day, not from what is sent.
        let accounts = [account(1, "Chequing", "CAD", 799, false, false)];
        let view = worth(WorthInput { today, now: now(), currency: "CAD", accounts: &accounts, holdings: &[], balances: &balances });
        assert_eq!(view.recorded_since, Some(day("2024-09-09")));
        assert_eq!(view.change, Some(Change { since: today - chrono::Duration::days(30), minor: 30 }));
        assert_eq!(view.series.len(), 116);
    }
}
