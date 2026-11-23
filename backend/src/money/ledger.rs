//! What an imported transaction is, and what a month comes to. Pure rules:
//! nothing here reads the database or the bridge.
//!
//! Every entry is one of four things. Money spent is an expense; money back
//! for something spent is a refund, and counts against its category; money
//! in is income; and money moved between the owner's own accounts is a
//! transfer, which is never spending. A card payment is a transfer: the
//! purchases it pays for were already counted when they were made.
//!
//! Who decides, strongest first: the owner, for one entry; a rule the owner
//! set for a payee; a match between the two halves of a transfer; and
//! otherwise the sign, which leaves the entry waiting to be sorted.

use std::collections::{BTreeMap, HashMap};

use chrono::{DateTime, Datelike, NaiveDate, Utc};
use serde::Serialize;
use uuid::Uuid;

/// The categories spending is sorted into, in the order they are offered.
pub const CATEGORIES: [&str; 12] = [
    "Groceries",
    "Eating out",
    "Fuel",
    "Transport",
    "Home",
    "Bills",
    "Subscriptions",
    "Health",
    "Shopping",
    "Fun",
    "Travel",
    "Other",
];

/// The two halves of a transfer can post this many days apart.
pub const MATCH_WITHIN_DAYS: i64 = 3;

/// A balance the bank has not refreshed for this many days is shown as old.
pub const STALE_AFTER_DAYS: i64 = 3;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    Expense,
    Refund,
    Income,
    Transfer,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Expense => "expense",
            Kind::Refund => "refund",
            Kind::Income => "income",
            Kind::Transfer => "transfer",
        }
    }

    pub fn parse(text: &str) -> Option<Kind> {
        [Kind::Expense, Kind::Refund, Kind::Income, Kind::Transfer].into_iter().find(|kind| kind.as_str() == text)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum SortedBy {
    /// Nobody yet: read from the sign alone.
    Auto,
    /// The other half of the transfer was found in another account.
    Match,
    /// The owner said what this payee is.
    Rule,
    /// The owner said what this one entry is.
    Owner,
}

impl SortedBy {
    pub fn as_str(self) -> &'static str {
        match self {
            SortedBy::Auto => "auto",
            SortedBy::Match => "match",
            SortedBy::Rule => "rule",
            SortedBy::Owner => "owner",
        }
    }

    pub fn parse(text: &str) -> Option<SortedBy> {
        [SortedBy::Auto, SortedBy::Match, SortedBy::Rule, SortedBy::Owner]
            .into_iter()
            .find(|by| by.as_str() == text)
    }
}

/// What the owner said a payee is.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Rule {
    /// Spending in this category; money back from the payee is a refund in it.
    Spending(String),
    Income,
    Transfer,
}

/// What the owner can sort an entry to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Choice {
    Rule(Rule),
    /// Back to waiting: the owner's word is taken away.
    Unsorted,
}

impl Choice {
    /// `text` is a category by its name, or `income`, `transfer` or
    /// `unsorted`.
    pub fn parse(text: &str) -> Option<Choice> {
        match text {
            "income" => Some(Choice::Rule(Rule::Income)),
            "transfer" => Some(Choice::Rule(Rule::Transfer)),
            "unsorted" => Some(Choice::Unsorted),
            _ => CATEGORIES
                .iter()
                .find(|name| **name == text)
                .map(|name| Choice::Rule(Rule::Spending(name.to_string()))),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Sorting {
    pub kind: Kind,
    pub category: Option<String>,
    pub sorted_by: SortedBy,
    /// The other half, for a matched transfer.
    pub peer_id: Option<Uuid>,
}

impl Sorting {
    /// What a rule makes of an amount, or `None` where it does not apply:
    /// money going out is never income.
    pub fn from_rule(rule: &Rule, amount_minor: i64, sorted_by: SortedBy) -> Option<Sorting> {
        let (kind, category) = match rule {
            Rule::Spending(category) if amount_minor < 0 => (Kind::Expense, Some(category.clone())),
            Rule::Spending(category) => (Kind::Refund, Some(category.clone())),
            Rule::Income if amount_minor > 0 => (Kind::Income, None),
            Rule::Income => return None,
            Rule::Transfer => (Kind::Transfer, None),
        };
        Some(Sorting { kind, category, sorted_by, peer_id: None })
    }

    /// Read from the sign alone. In an account that is set aside nothing is
    /// spending, so its movements are money moved.
    fn by_sign(amount_minor: i64, set_aside: bool) -> Sorting {
        let kind = match (set_aside, amount_minor < 0) {
            (true, _) => Kind::Transfer,
            (false, true) => Kind::Expense,
            (false, false) => Kind::Income,
        };
        Sorting { kind, category: None, sorted_by: SortedBy::Auto, peer_id: None }
    }
}

/// One stored entry, as far as sorting needs it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Row {
    pub id: Uuid,
    pub account_id: Uuid,
    pub set_aside: bool,
    pub currency: String,
    pub day: NaiveDate,
    pub amount_minor: i64,
    /// Empty when the bank gave nothing to tell the payee by.
    pub payee_key: String,
    pub sorting: Sorting,
}

/// Sorts every entry again from scratch, in the order given. The owner's
/// own word on an entry is kept; everything else is worked out afresh, so
/// a new rule, a new entry or the other half of a transfer arriving late
/// changes exactly what it should.
pub fn sort_all(rows: &[Row], rules: &HashMap<String, Rule>) -> Vec<Sorting> {
    let mut sorted: Vec<Option<Sorting>> = rows
        .iter()
        .map(|row| {
            if row.sorting.sorted_by == SortedBy::Owner {
                return Some(Sorting { peer_id: None, ..row.sorting.clone() });
            }
            rules
                .get(&row.payee_key)
                .filter(|_| !row.payee_key.is_empty())
                .and_then(|rule| Sorting::from_rule(rule, row.amount_minor, SortedBy::Rule))
        })
        .collect();

    // What is left may be half of a transfer: the same amount leaving one
    // account and arriving in another within a few days. Money out is
    // looked at oldest first, and takes the nearest arrival still free.
    let mut out: Vec<usize> = (0..rows.len()).filter(|&i| sorted[i].is_none() && rows[i].amount_minor < 0).collect();
    out.sort_by_key(|&i| (rows[i].day, rows[i].id));
    let mut arrivals: Vec<usize> = (0..rows.len()).filter(|&i| sorted[i].is_none() && rows[i].amount_minor > 0).collect();
    arrivals.sort_by_key(|&i| (rows[i].day, rows[i].id));
    let within = chrono::Duration::days(MATCH_WITHIN_DAYS);
    for i in out {
        let from = arrivals.partition_point(|&j| rows[j].day < rows[i].day - within);
        let arrival = arrivals[from..]
            .iter()
            .copied()
            .take_while(|&j| rows[j].day <= rows[i].day + within)
            .filter(|&j| {
                sorted[j].is_none()
                    && rows[j].amount_minor == -rows[i].amount_minor
                    && rows[j].account_id != rows[i].account_id
                    && rows[j].currency == rows[i].currency
            })
            .min_by_key(|&j| ((rows[j].day - rows[i].day).num_days().abs(), rows[j].day, rows[j].id));
        if let Some(j) = arrival {
            let half = |peer: Uuid| Sorting {
                kind: Kind::Transfer,
                category: None,
                sorted_by: SortedBy::Match,
                peer_id: Some(peer),
            };
            sorted[i] = Some(half(rows[j].id));
            sorted[j] = Some(half(rows[i].id));
        }
    }

    sorted
        .into_iter()
        .zip(rows)
        .map(|(sorting, row)| sorting.unwrap_or_else(|| Sorting::by_sign(row.amount_minor, row.set_aside)))
        .collect()
}

/// An amount as the bridge writes it (`"-12.34"`, `"1200"`, `"0.5"`), in
/// minor units. Anything past the second decimal is rounded half away
/// from zero. `None` for anything that is not a plain number.
pub fn minor_units(text: &str) -> Option<i64> {
    let text = text.trim();
    let (negative, digits) = match text.strip_prefix('-') {
        Some(rest) => (true, rest),
        None => (false, text.strip_prefix('+').unwrap_or(text)),
    };
    let (whole, fraction) = digits.split_once('.').unwrap_or((digits, ""));
    if whole.is_empty() && fraction.is_empty() {
        return None;
    }
    if !whole.chars().all(|c| c.is_ascii_digit()) || !fraction.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    let whole: i64 = if whole.is_empty() { 0 } else { whole.parse().ok()? };
    let mut places = fraction.bytes().map(|b| i64::from(b - b'0'));
    let cents = places.next().unwrap_or(0) * 10 + places.next().unwrap_or(0);
    let round_up = places.next().is_some_and(|third| third >= 5);
    let minor = whole.checked_mul(100)?.checked_add(cents + i64::from(round_up))?;
    Some(if negative { -minor } else { minor })
}

/// What a payee is told by, so the same shop is the same payee whatever
/// branch number or reference the bank put after its name: the letters of
/// the payee, or of the description when the bank named no payee, in
/// lower case.
pub fn payee_key(payee: &str, description: &str) -> String {
    let source = if payee.trim().is_empty() { description } else { payee };
    let letters: String = source
        .chars()
        .map(|c| if c.is_alphabetic() { c } else { ' ' })
        .flat_map(char::to_lowercase)
        .collect();
    let key = letters.split_whitespace().collect::<Vec<_>>().join(" ");
    key.chars().take(60).collect::<String>().trim_end().to_string()
}

/// Text from outside, made safe to show: one line, no control characters,
/// and not endless.
pub fn shown(text: &str, most: usize) -> String {
    let clean: String = text.chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
    let line = clean.split_whitespace().collect::<Vec<_>>().join(" ");
    line.chars().take(most).collect::<String>().trim_end().to_string()
}

// --- A month --------------------------------------------------------------

/// A calendar month.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Month {
    pub year: i32,
    pub month: u32,
}

impl Month {
    pub fn containing(day: NaiveDate) -> Month {
        Month { year: day.year(), month: day.month() }
    }

    /// Reads `2026-11`.
    pub fn parse(text: &str) -> Option<Month> {
        let (year, month) = text.split_once('-')?;
        if year.len() != 4 || month.len() != 2 {
            return None;
        }
        let month = Month { year: year.parse().ok()?, month: month.parse().ok()? };
        ((2000..=2100).contains(&month.year) && (1..=12).contains(&month.month)).then_some(month)
    }

    pub fn first_day(self) -> NaiveDate {
        NaiveDate::from_ymd_opt(self.year, self.month, 1).expect("a month has a first day")
    }

    pub fn last_day(self) -> NaiveDate {
        self.next().first_day().pred_opt().expect("a month has a last day")
    }

    pub fn previous(self) -> Month {
        if self.month == 1 { Month { year: self.year - 1, month: 12 } } else { Month { year: self.year, month: self.month - 1 } }
    }

    pub fn next(self) -> Month {
        if self.month == 12 { Month { year: self.year + 1, month: 1 } } else { Month { year: self.year, month: self.month + 1 } }
    }

    pub fn contains(self, day: NaiveDate) -> bool {
        Month::containing(day) == self
    }
}

impl std::fmt::Display for Month {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:04}-{:02}", self.year, self.month)
    }
}

impl Serialize for Month {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.collect_str(self)
    }
}

/// One entry as it is read back, with the account it is in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    pub id: Uuid,
    pub day: NaiveDate,
    pub amount_minor: i64,
    pub currency: String,
    pub payee: String,
    pub description: String,
    pub payee_key: String,
    pub account: String,
    pub set_aside: bool,
    pub sorting: Sorting,
}

impl Entry {
    /// Whether it is still waiting for the owner. Nothing in an account
    /// that is set aside waits: none of it is spending.
    pub fn to_sort(&self) -> bool {
        self.sorting.sorted_by == SortedBy::Auto && !self.set_aside
    }

    /// What it adds to spending: an expense adds, a refund takes away.
    fn spent_minor(&self) -> i64 {
        match self.sorting.kind {
            Kind::Expense | Kind::Refund => -self.amount_minor,
            Kind::Income | Kind::Transfer => 0,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Account {
    pub id: Uuid,
    pub name: String,
    pub connection: String,
    pub currency: String,
    pub balance_minor: i64,
    pub available_minor: Option<i64>,
    pub balance_at: DateTime<Utc>,
    pub set_aside: bool,
    pub problem: Option<String>,
}

/// Something wrong with where the figures come from, worded for the owner.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Problem {
    pub text: String,
    /// True when the owner has to sign in to the bank again at the bridge.
    pub reconnect: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct EntryView {
    pub id: Uuid,
    pub day: NaiveDate,
    /// The payee, or the bank's own line when it named none.
    pub name: String,
    pub amount_minor: i64,
    pub currency: String,
    pub kind: Kind,
    pub category: Option<String>,
    pub sorted_by: SortedBy,
    pub to_sort: bool,
    /// False when the bank gave nothing to tell the payee by, so sorting
    /// it can only be for this one entry.
    pub has_payee: bool,
    pub account: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct CategoryView {
    pub name: String,
    /// Expenses less refunds, which can come out below zero.
    pub spent_minor: i64,
    pub entries: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct AccountView {
    pub id: Uuid,
    pub name: String,
    pub connection: String,
    pub currency: String,
    pub balance_minor: i64,
    pub available_minor: Option<i64>,
    #[serde(serialize_with = "seconds")]
    pub balance_at: DateTime<Utc>,
    pub set_aside: bool,
    /// The bank has not refreshed the balance for some days.
    pub stale: bool,
    pub problem: Option<String>,
}

fn seconds<S: serde::Serializer>(at: &DateTime<Utc>, serializer: S) -> Result<S::Ok, S::Error> {
    serializer.serialize_str(&at.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
}

/// The month before, for comparison.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Previous {
    pub month: Month,
    pub spent_minor: i64,
    /// What had been spent by the same day of that month, given while the
    /// month shown is still running.
    pub by_now_minor: Option<i64>,
}

/// A month of money as the apps show it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct MonthView {
    pub month: Month,
    /// True for the month today is in.
    pub current: bool,
    /// The nearest months with anything in them, either way.
    pub earlier: Option<Month>,
    pub later: Option<Month>,
    /// The currency the totals are in. Entries and accounts in another
    /// are listed and left out of every total.
    pub currency: String,
    /// Expenses less refunds, sorted or not.
    pub spent_minor: i64,
    /// The part of it not sorted into a category yet.
    pub unsorted_minor: i64,
    /// Entries still waiting for the owner.
    pub to_sort: u32,
    pub income_minor: i64,
    /// Missing when the history does not reach back over the whole of the
    /// month before, so that a part month is never compared as a whole one.
    pub previous: Option<Previous>,
    /// Largest first.
    pub categories: Vec<CategoryView>,
    /// Newest first.
    pub entries: Vec<EntryView>,
    pub accounts: Vec<AccountView>,
    /// The balances of everyday accounts added up: what is in the bank
    /// less what is owed on cards.
    pub everyday_minor: i64,
    pub set_aside_minor: i64,
    pub category_names: Vec<&'static str>,
}

/// What a month is built from.
pub struct MonthInput<'a> {
    pub month: Month,
    pub today: NaiveDate,
    pub now: DateTime<Utc>,
    pub currency: &'a str,
    /// Entries of the month and of the month before, in any order.
    pub entries: &'a [Entry],
    pub accounts: &'a [Account],
    /// What is stored around the month, to know how far the history
    /// reaches and which months there are to step to.
    pub history: History,
}

/// Where the stored entries lie around a month.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct History {
    /// The day of the oldest entry stored.
    pub first: Option<NaiveDate>,
    /// The day of the last entry before the month.
    pub before: Option<NaiveDate>,
    /// The day of the first entry after the month.
    pub after: Option<NaiveDate>,
}

pub fn month(input: MonthInput<'_>) -> MonthView {
    let MonthInput { month, today, now, currency, entries, accounts, history } = input;
    let counted = |entry: &&Entry| entry.currency == currency;
    let in_month: Vec<&Entry> = entries.iter().filter(|entry| month.contains(entry.day)).collect();
    let spent_minor = in_month.iter().copied().filter(counted).map(Entry::spent_minor).sum();
    let unsorted_minor = in_month
        .iter()
        .copied()
        .filter(counted)
        .filter(|entry| entry.sorting.category.is_none())
        .map(Entry::spent_minor)
        .sum();
    let income_minor = in_month
        .iter()
        .copied()
        .filter(counted)
        .filter(|entry| entry.sorting.kind == Kind::Income)
        .map(|entry| entry.amount_minor)
        .sum();

    let mut by_category = BTreeMap::<&str, (i64, u32)>::new();
    for entry in in_month.iter().copied().filter(counted) {
        if let Some(category) = entry.sorting.category.as_deref() {
            let sum = by_category.entry(category).or_default();
            sum.0 += entry.spent_minor();
            sum.1 += 1;
        }
    }
    let mut categories: Vec<CategoryView> = by_category
        .into_iter()
        .map(|(name, (spent_minor, entries))| CategoryView { name: name.to_string(), spent_minor, entries })
        .collect();
    categories.sort_by(|a, b| b.spent_minor.cmp(&a.spent_minor).then_with(|| a.name.cmp(&b.name)));

    let current = month.contains(today);
    let before = month.previous();
    let previous = history.first.filter(|first| *first <= before.first_day()).map(|_| {
        let then: Vec<&Entry> = entries.iter().filter(|entry| before.contains(entry.day)).filter(counted).collect();
        Previous {
            month: before,
            spent_minor: then.iter().map(|entry| entry.spent_minor()).sum(),
            by_now_minor: current.then(|| {
                then.iter().filter(|entry| entry.day.day() <= today.day()).map(|entry| entry.spent_minor()).sum()
            }),
        }
    });

    let mut listed = in_month.clone();
    listed.sort_by(|a, b| b.day.cmp(&a.day).then_with(|| a.amount_minor.cmp(&b.amount_minor)).then_with(|| a.id.cmp(&b.id)));
    let entries_shown: Vec<EntryView> = listed
        .into_iter()
        .map(|entry| EntryView {
            id: entry.id,
            day: entry.day,
            name: shown(if entry.payee.trim().is_empty() { &entry.description } else { &entry.payee }, 60),
            amount_minor: entry.amount_minor,
            currency: entry.currency.clone(),
            kind: entry.sorting.kind,
            category: entry.sorting.category.clone(),
            sorted_by: entry.sorting.sorted_by,
            to_sort: entry.to_sort(),
            has_payee: !entry.payee_key.is_empty(),
            account: entry.account.clone(),
        })
        .collect();

    let total = |aside: bool| -> i64 {
        accounts
            .iter()
            .filter(|account| account.currency == currency && account.set_aside == aside)
            .map(|account| account.balance_minor)
            .sum()
    };
    MonthView {
        month,
        current,
        earlier: history.before.map(Month::containing),
        // Always a way back to the month today is in.
        later: history.after.map(Month::containing).or_else(|| (!current && month < Month::containing(today)).then(|| Month::containing(today))),
        currency: currency.to_string(),
        spent_minor,
        unsorted_minor,
        to_sort: in_month.iter().filter(|entry| entry.to_sort()).count() as u32,
        income_minor,
        previous,
        categories,
        entries: entries_shown,
        accounts: accounts
            .iter()
            .map(|account| AccountView {
                id: account.id,
                name: account.name.clone(),
                connection: account.connection.clone(),
                currency: account.currency.clone(),
                balance_minor: account.balance_minor,
                available_minor: account.available_minor,
                balance_at: account.balance_at,
                set_aside: account.set_aside,
                stale: (now - account.balance_at).num_days() >= STALE_AFTER_DAYS,
                problem: account.problem.clone(),
            })
            .collect(),
        everyday_minor: total(false),
        set_aside_minor: total(true),
        category_names: CATEGORIES.to_vec(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn day(text: &str) -> NaiveDate {
        text.parse().unwrap()
    }

    const CHEQUING: u128 = 1;
    const CARD: u128 = 2;
    const SAVINGS: u128 = 3;

    fn row(n: u128, account: u128, on: &str, amount_minor: i64, payee: &str) -> Row {
        Row {
            id: Uuid::from_u128(n),
            account_id: Uuid::from_u128(account),
            set_aside: account == SAVINGS,
            currency: "CAD".into(),
            day: day(on),
            amount_minor,
            payee_key: payee_key(payee, ""),
            sorting: Sorting::by_sign(amount_minor, account == SAVINGS),
        }
    }

    fn kinds(rows: &[Row], rules: &HashMap<String, Rule>) -> Vec<(Kind, Option<String>, SortedBy)> {
        sort_all(rows, rules).into_iter().map(|s| (s.kind, s.category, s.sorted_by)).collect()
    }

    #[test]
    fn amounts_are_read_exactly() {
        assert_eq!(minor_units("12.34"), Some(1234));
        assert_eq!(minor_units("-12.34"), Some(-1234));
        assert_eq!(minor_units("1200"), Some(120000));
        assert_eq!(minor_units("0.5"), Some(50));
        assert_eq!(minor_units(".5"), Some(50));
        assert_eq!(minor_units("-0.07"), Some(-7));
        assert_eq!(minor_units(" 33293.43 "), Some(3329343));
        // Past the cent it is rounded, half away from zero.
        assert_eq!(minor_units("1.005"), Some(101));
        assert_eq!(minor_units("-1.005"), Some(-101));
        assert_eq!(minor_units("1.0049"), Some(100));
        for wrong in ["", "-", ".", "1,234.00", "12.3.4", "1e3", "abc", "--1", "$5"] {
            assert_eq!(minor_units(wrong), None, "{wrong}");
        }
        assert_eq!(minor_units("99999999999999999999"), None);
    }

    #[test]
    fn a_payee_is_the_same_whatever_number_follows_its_name() {
        assert_eq!(payee_key("Corner Grocer #1234", ""), "corner grocer");
        assert_eq!(payee_key("CORNER GROCER  #88 TORONTO", ""), "corner grocer toronto");
        assert_eq!(payee_key("", "POS 4471 Corner Grocer 0031"), "pos corner grocer");
        assert_eq!(payee_key("  ", "  "), "");
        assert_eq!(payee_key("4471-0031", ""), "");
        assert_eq!(payee_key("Café Été", ""), "café été");
    }

    #[test]
    fn unsorted_entries_are_read_from_their_sign() {
        let rows = [row(1, CHEQUING, "2026-11-03", -2500, "Corner Grocer"), row(2, CHEQUING, "2026-11-14", 300000, "Employer")];
        assert_eq!(
            kinds(&rows, &HashMap::new()),
            vec![(Kind::Expense, None, SortedBy::Auto), (Kind::Income, None, SortedBy::Auto)]
        );
    }

    #[test]
    fn a_card_payment_is_a_transfer_and_not_spending_twice() {
        let rows = [
            row(1, CARD, "2026-11-02", -8000, "Corner Grocer"),
            row(2, CHEQUING, "2026-11-10", -50000, "Card payment"),
            row(3, CARD, "2026-11-12", 50000, "Payment thank you"),
        ];
        let sorted = sort_all(&rows, &HashMap::new());
        assert_eq!(sorted[0].kind, Kind::Expense);
        assert_eq!((sorted[1].kind, sorted[1].sorted_by, sorted[1].peer_id), (Kind::Transfer, SortedBy::Match, Some(rows[2].id)));
        assert_eq!((sorted[2].kind, sorted[2].sorted_by, sorted[2].peer_id), (Kind::Transfer, SortedBy::Match, Some(rows[1].id)));
    }

    #[test]
    fn the_two_halves_must_agree_and_be_close() {
        // The same account, another amount, another currency, or most of a week apart: no match.
        let mut usd = row(8, CARD, "2026-11-10", 50000, "x");
        usd.currency = "USD".into();
        let rows = [
            row(1, CHEQUING, "2026-11-10", -50000, "a"),
            row(2, CHEQUING, "2026-11-10", 50000, "b"),
            row(3, CARD, "2026-11-10", 49999, "c"),
            row(4, CARD, "2026-11-16", 50000, "d"),
            usd,
        ];
        assert!(sort_all(&rows, &HashMap::new()).iter().all(|s| s.sorted_by == SortedBy::Auto));
    }

    #[test]
    fn each_arrival_is_matched_once_and_to_the_nearest() {
        let rows = [
            row(1, CHEQUING, "2026-11-01", -10000, "a"),
            row(2, CHEQUING, "2026-11-04", -10000, "a"),
            row(3, CARD, "2026-11-04", 10000, "b"),
            row(4, CARD, "2026-11-02", 10000, "b"),
        ];
        let sorted = sort_all(&rows, &HashMap::new());
        assert_eq!(sorted[0].peer_id, Some(rows[3].id));
        assert_eq!(sorted[1].peer_id, Some(rows[2].id));
        // One arrival, two that left: the second stays an expense.
        let sorted = sort_all(&rows[..3], &HashMap::new());
        assert_eq!(sorted[0].peer_id, Some(rows[2].id));
        assert_eq!((sorted[1].kind, sorted[1].sorted_by), (Kind::Expense, SortedBy::Auto));
    }

    #[test]
    fn a_rule_holds_for_every_entry_of_its_payee() {
        let rules = HashMap::from([
            ("corner grocer".to_string(), Rule::Spending("Groceries".into())),
            ("employer".to_string(), Rule::Income),
            ("to savings".to_string(), Rule::Transfer),
        ]);
        let rows = [
            row(1, CARD, "2026-11-02", -8000, "Corner Grocer #12"),
            row(2, CARD, "2026-11-04", 1500, "CORNER GROCER #7"),
            row(3, CHEQUING, "2026-11-14", 300000, "Employer"),
            row(4, CHEQUING, "2026-11-15", -20000, "To savings"),
            // Money going out is never income, whatever the rule says.
            row(5, CHEQUING, "2026-11-16", -100, "Employer"),
        ];
        assert_eq!(
            kinds(&rows, &rules),
            vec![
                (Kind::Expense, Some("Groceries".into()), SortedBy::Rule),
                (Kind::Refund, Some("Groceries".into()), SortedBy::Rule),
                (Kind::Income, None, SortedBy::Rule),
                (Kind::Transfer, None, SortedBy::Rule),
                (Kind::Expense, None, SortedBy::Auto),
            ]
        );
    }

    #[test]
    fn a_known_shop_is_not_mistaken_for_half_a_transfer() {
        // A refund on the card and the same amount spent from chequing.
        let rules = HashMap::from([("corner grocer".to_string(), Rule::Spending("Groceries".into()))]);
        let rows = [row(1, CHEQUING, "2026-11-02", -2000, "Someone"), row(2, CARD, "2026-11-03", 2000, "Corner Grocer")];
        let sorted = sort_all(&rows, &rules);
        assert_eq!((sorted[0].kind, sorted[0].sorted_by), (Kind::Expense, SortedBy::Auto));
        assert_eq!((sorted[1].kind, sorted[1].sorted_by), (Kind::Refund, SortedBy::Rule));
    }

    #[test]
    fn the_owners_word_on_one_entry_beats_a_rule_and_a_match() {
        let rules = HashMap::from([("corner grocer".to_string(), Rule::Spending("Groceries".into()))]);
        let mut fuel = row(1, CARD, "2026-11-02", -6000, "Corner Grocer");
        fuel.sorting = Sorting { kind: Kind::Expense, category: Some("Fuel".into()), sorted_by: SortedBy::Owner, peer_id: None };
        // Looks like half a transfer, but the owner said it was spending.
        let mut gift = row(2, CHEQUING, "2026-11-10", -50000, "Someone");
        gift.sorting = Sorting { kind: Kind::Expense, category: Some("Other".into()), sorted_by: SortedBy::Owner, peer_id: None };
        let rows = [fuel, gift, row(3, CARD, "2026-11-11", 50000, "Payment")];
        assert_eq!(
            kinds(&rows, &rules),
            vec![
                (Kind::Expense, Some("Fuel".into()), SortedBy::Owner),
                (Kind::Expense, Some("Other".into()), SortedBy::Owner),
                (Kind::Income, None, SortedBy::Auto),
            ]
        );
    }

    #[test]
    fn nothing_in_an_account_set_aside_is_spending() {
        let rows = [
            row(1, SAVINGS, "2026-11-02", -8000, "Fund purchase"),
            row(2, SAVINGS, "2026-11-03", 120, "Interest"),
            row(3, CHEQUING, "2026-11-05", -20000, "To savings"),
            row(4, SAVINGS, "2026-11-06", 20000, "Deposit"),
        ];
        let sorted = sort_all(&rows, &HashMap::new());
        assert!(sorted.iter().all(|s| s.kind == Kind::Transfer));
        assert_eq!(sorted[0].sorted_by, SortedBy::Auto);
        assert_eq!(sorted[2].peer_id, Some(rows[3].id));
    }

    #[test]
    fn choices_are_a_category_or_one_of_three_words() {
        assert_eq!(Choice::parse("Groceries"), Some(Choice::Rule(Rule::Spending("Groceries".into()))));
        assert_eq!(Choice::parse("income"), Some(Choice::Rule(Rule::Income)));
        assert_eq!(Choice::parse("transfer"), Some(Choice::Rule(Rule::Transfer)));
        assert_eq!(Choice::parse("unsorted"), Some(Choice::Unsorted));
        assert_eq!(Choice::parse("groceries"), None);
        assert_eq!(Choice::parse(""), None);
    }

    fn entry(n: u128, on: &str, amount_minor: i64, kind: Kind, category: Option<&str>) -> Entry {
        Entry {
            id: Uuid::from_u128(n),
            day: day(on),
            amount_minor,
            currency: "CAD".into(),
            payee: format!("Payee {n}"),
            description: String::new(),
            payee_key: format!("payee {n}"),
            account: "Chequing".into(),
            set_aside: false,
            sorting: Sorting {
                kind,
                category: category.map(str::to_string),
                sorted_by: if category.is_some() || kind == Kind::Transfer { SortedBy::Rule } else { SortedBy::Auto },
                peer_id: None,
            },
        }
    }

    fn account(n: u128, currency: &str, balance_minor: i64, set_aside: bool, age_days: i64) -> Account {
        Account {
            id: Uuid::from_u128(n),
            name: format!("Account {n}"),
            connection: "First Bank".into(),
            currency: currency.into(),
            balance_minor,
            available_minor: None,
            balance_at: now() - chrono::Duration::days(age_days),
            set_aside,
            problem: None,
        }
    }

    fn now() -> DateTime<Utc> {
        "2026-11-17T15:00:00Z".parse().unwrap()
    }

    fn november(entries: &[Entry], accounts: &[Account], history_from: &str) -> MonthView {
        let first = day(history_from);
        month(MonthInput {
            month: Month { year: 2026, month: 11 },
            today: day("2026-11-17"),
            now: now(),
            currency: "CAD",
            entries,
            accounts,
            history: History { first: Some(first), before: Some(first).filter(|first| *first < day("2026-11-01")), after: None },
        })
    }

    #[test]
    fn a_month_is_expenses_less_refunds_and_never_transfers() {
        let mut usd = entry(7, "2026-11-09", -9900, Kind::Expense, Some("Travel"));
        usd.currency = "USD".into();
        let entries = [
            entry(1, "2026-11-02", -8000, Kind::Expense, Some("Groceries")),
            entry(2, "2026-11-04", 1500, Kind::Refund, Some("Groceries")),
            entry(3, "2026-11-05", -4200, Kind::Expense, Some("Eating out")),
            entry(4, "2026-11-06", -1300, Kind::Expense, None),
            entry(5, "2026-11-10", -50000, Kind::Transfer, None),
            entry(6, "2026-11-14", 300000, Kind::Income, None),
            usd,
            entry(8, "2026-10-20", -99900, Kind::Expense, Some("Home")),
        ];
        let view = november(&entries, &[], "2026-10-15");
        assert_eq!(view.spent_minor, 8000 - 1500 + 4200 + 1300);
        assert_eq!(view.unsorted_minor, 1300);
        assert_eq!(view.income_minor, 300000);
        // The pay is waiting to be called income, and the unsorted expense for a category.
        assert_eq!(view.to_sort, 2);
        assert_eq!(
            view.categories,
            vec![
                CategoryView { name: "Groceries".into(), spent_minor: 6500, entries: 2 },
                CategoryView { name: "Eating out".into(), spent_minor: 4200, entries: 1 },
            ]
        );
        // Newest first, the other currency listed with the rest, October left out.
        let listed: Vec<u128> = view.entries.iter().map(|e| e.id.as_u128()).collect();
        assert_eq!(listed, vec![6, 5, 7, 4, 3, 2, 1]);
        assert!(view.current);
        assert_eq!((view.earlier, view.later), (Some(Month { year: 2026, month: 10 }), None));
    }

    #[test]
    fn last_month_is_compared_only_when_all_of_it_is_known() {
        let entries = [
            entry(1, "2026-11-02", -8000, Kind::Expense, Some("Groceries")),
            entry(2, "2026-10-03", -10000, Kind::Expense, Some("Groceries")),
            entry(3, "2026-10-17", -2000, Kind::Expense, Some("Fun")),
            entry(4, "2026-10-28", -30000, Kind::Expense, Some("Home")),
        ];
        // History starts mid October: a part month is not a month to compare with.
        assert_eq!(november(&entries, &[], "2026-10-03").previous, None);
        let view = november(&entries, &[], "2026-09-28");
        assert_eq!(
            view.previous,
            Some(Previous { month: Month { year: 2026, month: 10 }, spent_minor: 42000, by_now_minor: Some(12000) })
        );
        // Looking back at October from November: a finished month has no "by now".
        let october = month(MonthInput {
            month: Month { year: 2026, month: 10 },
            today: day("2026-11-17"),
            now: now(),
            currency: "CAD",
            entries: &entries,
            accounts: &[],
            history: History { first: Some(day("2026-08-30")), before: Some(day("2026-08-30")), after: Some(day("2026-11-02")) },
        });
        assert!(!october.current);
        assert_eq!(october.spent_minor, 42000);
        assert_eq!(october.previous.unwrap().by_now_minor, None);
        assert_eq!((october.earlier, october.later), (Some(Month { year: 2026, month: 8 }), Some(Month { year: 2026, month: 11 })));
    }

    #[test]
    fn balances_add_up_by_what_the_account_is_for() {
        let accounts = [
            account(1, "CAD", 250000, false, 0),
            account(2, "CAD", -80000, false, 0),
            account(3, "CAD", 1000000, true, 4),
            account(4, "USD", 5000, false, 0),
        ];
        let view = november(&[], &accounts, "2026-11-01");
        assert_eq!((view.everyday_minor, view.set_aside_minor), (170000, 1000000));
        assert_eq!(view.accounts.iter().map(|a| a.stale).collect::<Vec<_>>(), vec![false, false, true, false]);
        assert_eq!((view.spent_minor, view.to_sort, view.previous), (0, 0, None));
    }

    #[test]
    fn months_are_read_and_stepped() {
        assert_eq!(Month::parse("2026-11"), Some(Month { year: 2026, month: 11 }));
        for wrong in ["2026-13", "2026-00", "26-11", "2026-1", "2026/11", "november"] {
            assert_eq!(Month::parse(wrong), None, "{wrong}");
        }
        let january = Month { year: 2027, month: 1 };
        assert_eq!(january.previous(), Month { year: 2026, month: 12 });
        assert_eq!(january.previous().next(), january);
        assert_eq!(Month { year: 2028, month: 2 }.last_day(), day("2028-02-29"));
        assert_eq!(january.to_string(), "2027-01");
    }

    #[test]
    fn text_from_outside_is_made_one_safe_line() {
        assert_eq!(shown("  Sign in\nagain\u{7} please  ", 100), "Sign in again please");
        assert_eq!(shown("abcdef", 3), "abc");
    }
}
