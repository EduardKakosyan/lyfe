//! How far off financial independence is. Pure rules: nothing here reads
//! the database or the bridge.
//!
//! What is measured: what came in and what was spent, a month at a time,
//! and so what was kept of it. Only months lyfe holds whole are counted,
//! the last twelve of them at most; the month still running is shown and
//! left out of every average.
//!
//! What is worked out from that and from what the owner assumes (ADR 0009):
//! the FI number is a year's spending divided by the withdrawal rate; the
//! years to it are how long what is set aside takes to grow there with a
//! year's keeping added each year; the coast number is what would grow
//! there by itself by a given age. The emergency fund is held back from
//! the savings set aside before any of that. Growth is counted above
//! inflation, so every figure is in today's money.

use std::collections::BTreeMap;

use chrono::{Datelike, NaiveDate};
use serde::Serialize;

use super::ledger::{Flow, Month};

/// The most months the averages are taken over.
pub const MONTHS_COUNTED: usize = 12;

/// Further off than this is not said as a number of years.
const MOST_YEARS: f64 = 99.0;

/// A savings rate below this is not a rate: next to nothing came in, and
/// what was spent is some huge multiple of it.
const LOWEST_RATE_PCT: f64 = -999.0;

/// The line into the years ahead is drawn at least and at most this far.
const DRAWN_YEARS: std::ops::RangeInclusive<u32> = 10..=60;

/// What the owner assumes. Rates are in hundredths of a percent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Plan {
    /// The share of what is set aside that can be spent each year for good.
    pub withdrawal_bp: u32,
    /// Growth a year above inflation.
    pub return_bp: u32,
    /// Only for saying an age; missing until the owner gives it.
    pub birth_year: Option<i32>,
    /// The age the coast number is worked out for.
    pub coast_age: u32,
    /// What the owner keeps in savings for the unexpected, in the currency
    /// totals are in. It is held back from what is set aside in the bank,
    /// never from what is invested.
    pub emergency_fund_minor: i64,
}

impl Default for Plan {
    /// Careful rather than hopeful (ADR 0009): a withdrawal rate that held
    /// over fifty years and more, and growth as planners assume it.
    fn default() -> Self {
        Plan { withdrawal_bp: 350, return_bp: 400, birth_year: None, coast_age: 65, emergency_fund_minor: 0 }
    }
}

impl Plan {
    pub const WITHDRAWAL_BP: std::ops::RangeInclusive<u32> = 200..=600;
    pub const RETURN_BP: std::ops::RangeInclusive<u32> = 0..=1000;
    pub const COAST_AGE: std::ops::RangeInclusive<u32> = 40..=80;
    pub const EMERGENCY_FUND_MINOR: std::ops::RangeInclusive<i64> = 0..=10_000_000;

    /// What is wrong with it, if anything, in words for whoever sent it.
    pub fn problem(&self, today: NaiveDate) -> Option<&'static str> {
        if !Self::WITHDRAWAL_BP.contains(&self.withdrawal_bp) {
            return Some("withdrawal_bp must be between 200 and 600");
        }
        if !Self::RETURN_BP.contains(&self.return_bp) {
            return Some("return_bp must be between 0 and 1000");
        }
        if !Self::COAST_AGE.contains(&self.coast_age) {
            return Some("coast_age must be between 40 and 80");
        }
        if self.birth_year.is_some_and(|year| !(1900..=today.year()).contains(&year)) {
            return Some("birth_year must be a year that has begun");
        }
        if !Self::EMERGENCY_FUND_MINOR.contains(&self.emergency_fund_minor) {
            return Some("emergency_fund_minor must be between 0 and 10000000");
        }
        None
    }

    fn withdrawal(&self) -> f64 {
        f64::from(self.withdrawal_bp) / 10_000.0
    }

    fn growth(&self) -> f64 {
        f64::from(self.return_bp) / 10_000.0
    }
}

/// One month of what came in and what was spent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct MonthFlow {
    pub month: Month,
    pub spent_minor: i64,
    pub income_minor: i64,
    /// False for the month still running, which no average counts.
    pub whole: bool,
}

/// What would grow to the FI number by itself by a given age.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct Coast {
    pub age: u32,
    /// Years from now until then.
    pub years: u32,
    pub number_minor: i64,
    /// What is set aside as a share of it, in percent.
    pub progress_pct: f64,
    /// True once what is set aside would get there with nothing added.
    pub reached: bool,
}

/// What is set aside in a year to come, in today's money.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Ahead {
    pub year: i32,
    pub age: Option<u32>,
    /// With a year's keeping added each year.
    pub kept_minor: i64,
    /// With nothing more added.
    pub coast_minor: i64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct FireView {
    pub currency: String,
    /// The whole months counted, oldest first, then the month running.
    pub months: Vec<MonthFlow>,
    /// How many whole months the averages are from: none, and there are
    /// no averages and nothing worked out from them.
    pub counted: u32,
    pub monthly_income_minor: Option<i64>,
    pub monthly_spent_minor: Option<i64>,
    /// What came in less what was spent, a month.
    pub monthly_kept_minor: Option<i64>,
    /// What was kept as a share of what came in, in percent. Missing while
    /// nothing came in, or next to nothing.
    pub savings_rate_pct: Option<f64>,
    pub yearly_spent_minor: Option<i64>,
    pub yearly_kept_minor: Option<i64>,
    /// What counts towards independence: every account set aside, less the
    /// emergency fund.
    pub set_aside_minor: i64,
    /// What was held back from it for the emergency fund: the fund, or
    /// what the savings set aside come to if that is less.
    pub emergency_fund_minor: i64,
    /// A year's spending divided by the withdrawal rate. Missing while
    /// there is no spending to work it from.
    pub fi_number_minor: Option<i64>,
    /// What is set aside as a share of it, in percent.
    pub progress_pct: Option<f64>,
    pub reached: bool,
    /// Missing when it is not reached at this rate, or cannot be told.
    pub years_to_fi: Option<f64>,
    pub fi_year: Option<i32>,
    pub fi_age: Option<u32>,
    pub age: Option<u32>,
    pub coast: Option<Coast>,
    /// What is in the bank less what is owed.
    pub on_hand_minor: i64,
    /// How many months of spending that covers.
    pub runway_months: Option<f64>,
    /// A point a year from this year on. Empty with nothing to work from.
    pub ahead: Vec<Ahead>,
    pub plan: Plan,
}

pub struct FireInput<'a> {
    pub today: NaiveDate,
    pub currency: &'a str,
    /// What came in and was spent, by month.
    pub flows: &'a BTreeMap<Month, Flow>,
    /// The day of the oldest entry stored: a month is whole only when the
    /// history reaches back to its first day.
    pub first: Option<NaiveDate>,
    /// Every account set aside, added up.
    pub set_aside_minor: i64,
    /// Of that, what is in the bank and not invested: the savings the
    /// emergency fund is kept in.
    pub set_aside_in_bank_minor: i64,
    pub on_hand_minor: i64,
    pub plan: Plan,
}

pub fn fire(input: FireInput<'_>) -> FireView {
    let FireInput { today, currency, flows, first, set_aside_minor, set_aside_in_bank_minor, on_hand_minor, plan } = input;
    // The emergency fund is kept in the savings set aside and is not on its
    // way to being invested, so it is held back from them; never from the
    // investments, and never more than the savings hold.
    let emergency_fund_minor = plan.emergency_fund_minor.clamp(0, set_aside_in_bank_minor.max(0));
    let set_aside_minor = set_aside_minor - emergency_fund_minor;
    let current = Month::containing(today);
    let flow = |month: Month, whole: bool| {
        let Flow { spent_minor, income_minor } = flows.get(&month).copied().unwrap_or_default();
        MonthFlow { month, spent_minor, income_minor, whole }
    };

    // The months lyfe holds whole, walking back from the last one finished.
    let mut months = Vec::new();
    let mut month = current.previous();
    while months.len() < MONTHS_COUNTED && first.is_some_and(|first| first <= month.first_day()) {
        months.push(flow(month, true));
        month = month.previous();
    }
    months.reverse();
    let counted = months.len() as i64;
    let spent: i64 = months.iter().map(|month| month.spent_minor).sum();
    let income: i64 = months.iter().map(|month| month.income_minor).sum();
    months.push(flow(current, false));

    let average = |sum: i64, over: i64| (counted > 0).then(|| rounded(sum as f64 / counted as f64 * over as f64));
    let yearly_spent_minor = average(spent, 12);
    let yearly_kept_minor = average(income - spent, 12);
    let monthly_spent_minor = average(spent, 1);

    let set_aside = set_aside_minor as f64;
    let growth = plan.growth();
    let fi_number = yearly_spent_minor.filter(|spent| *spent > 0).map(|spent| spent as f64 / plan.withdrawal());
    let reached = fi_number.is_some_and(|number| set_aside >= number);
    let years_to_fi = fi_number.zip(yearly_kept_minor).and_then(|(number, kept)| years_until(set_aside, kept as f64, number, growth));
    // Counted from today, not from the start of the year.
    let fi_year = years_to_fi.map(|years| (f64::from(today.year()) + f64::from(today.ordinal0()) / 365.25 + years).floor() as i32);
    let age = plan.birth_year.map(|born| (today.year() - born).max(0) as u32);

    let coast = fi_number.zip(age).filter(|(_, age)| *age < plan.coast_age).map(|(number, age)| {
        let years = plan.coast_age - age;
        let needed = number / (1.0 + growth).powi(years as i32);
        Coast {
            age: plan.coast_age,
            years,
            number_minor: rounded(needed),
            progress_pct: tenth(set_aside / needed * 100.0),
            reached: set_aside >= needed,
        }
    });

    let ahead = match (fi_number, yearly_kept_minor) {
        (Some(_), Some(kept)) => {
            let until = years_to_fi
                .map(|years| years.ceil() as u32 + 2)
                .or(coast.map(|coast| coast.years))
                .unwrap_or(*DRAWN_YEARS.start())
                .clamp(*DRAWN_YEARS.start(), *DRAWN_YEARS.end());
            (0..=until)
                .map(|years| Ahead {
                    year: today.year() + years as i32,
                    age: age.map(|age| age + years),
                    kept_minor: rounded(grown(set_aside, kept as f64, growth, years).max(0.0)),
                    coast_minor: rounded(grown(set_aside, 0.0, growth, years).max(0.0)),
                })
                .collect()
        }
        _ => Vec::new(),
    };

    FireView {
        currency: currency.to_string(),
        months,
        counted: counted as u32,
        monthly_income_minor: average(income, 1),
        monthly_spent_minor,
        monthly_kept_minor: average(income - spent, 1),
        savings_rate_pct: (counted > 0 && income > 0)
            .then(|| tenth((income - spent) as f64 / income as f64 * 100.0))
            .filter(|rate| *rate >= LOWEST_RATE_PCT),
        yearly_spent_minor,
        yearly_kept_minor,
        set_aside_minor,
        emergency_fund_minor,
        fi_number_minor: fi_number.map(rounded),
        progress_pct: fi_number.map(|number| tenth(set_aside / number * 100.0)),
        reached,
        years_to_fi: years_to_fi.map(tenth),
        fi_year,
        fi_age: fi_year.zip(plan.birth_year).map(|(year, born)| (year - born).max(0) as u32),
        age,
        coast,
        on_hand_minor,
        runway_months: monthly_spent_minor
            .filter(|spent| *spent > 0)
            .map(|spent| tenth((on_hand_minor.max(0)) as f64 / spent as f64)),
        ahead,
        plan,
    }
}

/// How many years until `set_aside`, growing at `growth` a year with `kept`
/// added at the end of each, comes to `number`. `None` when it never does,
/// or not within a lifetime.
pub fn years_until(set_aside: f64, kept: f64, number: f64, growth: f64) -> Option<f64> {
    if number <= 0.0 {
        return None;
    }
    if set_aside >= number {
        return Some(0.0);
    }
    let years = if growth <= 0.0 {
        if kept <= 0.0 {
            return None;
        }
        (number - set_aside) / kept
    } else {
        // set_aside·(1+g)^n + kept·((1+g)^n − 1)/g = number, solved for n.
        let level = set_aside + kept / growth;
        if level <= 0.0 {
            // More is spent than comes in, faster than what is set aside grows.
            return None;
        }
        ((number + kept / growth) / level).ln() / (1.0 + growth).ln()
    };
    (years.is_finite() && years <= MOST_YEARS).then_some(years)
}

/// What `set_aside` comes to after `years`, with `kept` added at the end
/// of each.
pub fn grown(set_aside: f64, kept: f64, growth: f64, years: u32) -> f64 {
    if growth <= 0.0 {
        return set_aside + kept * f64::from(years);
    }
    let factor = (1.0 + growth).powi(years as i32);
    set_aside * factor + kept * (factor - 1.0) / growth
}

fn rounded(value: f64) -> i64 {
    value.round() as i64
}

/// To one decimal, which is as fine as any of this is known.
fn tenth(value: f64) -> f64 {
    (value * 10.0).round() / 10.0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn day(text: &str) -> NaiveDate {
        text.parse().unwrap()
    }

    fn month(text: &str) -> Month {
        Month::parse(text).unwrap()
    }

    fn close(found: Option<f64>, wanted: f64) -> bool {
        found.is_some_and(|found| (found - wanted).abs() < 0.05)
    }

    /// Each month from `from` on spends and earns the same.
    fn steady(from: &str, months: u32, spent_minor: i64, income_minor: i64) -> BTreeMap<Month, Flow> {
        let mut flows = BTreeMap::new();
        let mut at = month(from);
        for _ in 0..months {
            flows.insert(at, Flow { spent_minor, income_minor });
            at = at.next();
        }
        flows
    }

    fn worked_out(flows: &BTreeMap<Month, Flow>, first: &str, set_aside_minor: i64, plan: Plan) -> FireView {
        fire(FireInput {
            today: day("2026-11-17"),
            currency: "CAD",
            flows,
            first: Some(day(first)),
            set_aside_minor,
            set_aside_in_bank_minor: 0,
            on_hand_minor: 1_200_000,
            plan,
        })
    }

    #[test]
    fn the_years_to_independence_follow_the_savings_rate() {
        // The table every write-up of this starts from: nothing set aside,
        // 5% growth, 4% drawn, and the share of income kept.
        for (rate, years) in [(10.0, 51.4), (25.0, 31.9), (50.0, 16.6), (60.0, 12.4), (75.0, 7.1), (90.0, 2.7)] {
            let (income, kept) = (100_000.0, 1_000.0 * rate);
            let number = (income - kept) / 0.04;
            assert!(close(years_until(0.0, kept, number, 0.05), years), "{rate}%");
        }
        // Something set aside already brings it nearer: half kept, and five
        // years' spending there to start with.
        assert!(close(years_until(200_000.0, 40_000.0, 1_000_000.0, 0.05), 12.05));
        assert!(close(years_until(20_000.0, 20_000.0, 1_000_000.0, 0.05), 24.68));
        // A smaller share drawn each year asks for more, and so for longer.
        assert!(close(years_until(20_000.0, 20_000.0, 40_000.0 / 0.035, 0.05), 26.67));
        assert_eq!(years_until(1_000_000.0, 0.0, 1_000_000.0, 0.05), Some(0.0));
    }

    #[test]
    fn independence_that_never_comes_is_not_given_a_date() {
        // Nothing kept and nothing set aside.
        assert_eq!(years_until(0.0, 0.0, 1_000_000.0, 0.04), None);
        // More spent than comes in, faster than what is set aside grows.
        assert_eq!(years_until(100_000.0, -10_000.0, 1_000_000.0, 0.04), None);
        // Spending a little of the growth still gets there.
        assert!(years_until(500_000.0, -10_000.0, 1_000_000.0, 0.04).is_some());
        // Nothing kept, but what is set aside grows by itself.
        assert!(close(years_until(500_000.0, 0.0, 1_000_000.0, 0.04), 17.67));
        // No growth at all: only the keeping counts.
        assert_eq!(years_until(0.0, 10_000.0, 100_000.0, 0.0), Some(10.0));
        assert_eq!(years_until(0.0, 0.0, 100_000.0, 0.0), None);
        // Further off than a lifetime is not a date.
        assert_eq!(years_until(0.0, 100.0, 10_000_000.0, 0.01), None);
        assert_eq!(years_until(0.0, 100.0, 0.0, 0.04), None);
    }

    #[test]
    fn what_is_set_aside_grows_with_what_is_added() {
        assert!((grown(1_000.0, 0.0, 0.07, 30) - 7_612.26).abs() < 0.01);
        assert!((grown(0.0, 1.0, 0.05, 41) - 127.84).abs() < 0.01);
        assert_eq!(grown(1_000.0, 100.0, 0.0, 5), 1_500.0);
        assert_eq!(grown(1_000.0, 100.0, 0.05, 0), 1_000.0);
    }

    #[test]
    fn a_year_of_whole_months_gives_every_figure() {
        // 3,000 in and 2,000 spent a month for a year and a half.
        let flows = steady("2025-05", 19, 200_000, 300_000);
        let born = Plan { birth_year: Some(1990), ..Plan::default() };
        let view = worked_out(&flows, "2025-05-01", 5_000_000, born);
        // The last twelve whole months, then the one running.
        assert_eq!(view.counted, 12);
        assert_eq!(view.months.len(), 13);
        assert_eq!((view.months[0].month, view.months[0].whole), (month("2025-11"), true));
        assert_eq!((view.months[12].month, view.months[12].whole), (month("2026-11"), false));
        assert_eq!(
            (view.monthly_income_minor, view.monthly_spent_minor, view.monthly_kept_minor),
            (Some(300_000), Some(200_000), Some(100_000))
        );
        assert_eq!(view.savings_rate_pct, Some(33.3));
        assert_eq!((view.yearly_spent_minor, view.yearly_kept_minor), (Some(2_400_000), Some(1_200_000)));
        // 24,000 a year at 3.5% drawn.
        assert_eq!(view.fi_number_minor, Some(68_571_429));
        assert_eq!(view.progress_pct, Some(7.3));
        assert!(!view.reached);
        // 50,000 growing at 4% with 12,000 added a year.
        assert_eq!(view.years_to_fi, Some(26.4));
        assert_eq!((view.fi_year, view.fi_age, view.age), (Some(2053), Some(63), Some(36)));
        let coast = view.coast.unwrap();
        assert_eq!((coast.age, coast.years, coast.reached), (65, 29, false));
        // 685,714.29 / 1.04^29.
        assert_eq!(coast.number_minor, 21_987_526);
        assert_eq!(coast.progress_pct, 22.7);
        assert_eq!(view.runway_months, Some(6.0));
        // Drawn a year at a time to two years past the day it is reached.
        assert_eq!(view.ahead.len(), 30);
        assert_eq!(view.ahead[0], Ahead { year: 2026, age: Some(36), kept_minor: 5_000_000, coast_minor: 5_000_000 });
        assert_eq!(view.ahead[1], Ahead { year: 2027, age: Some(37), kept_minor: 6_400_000, coast_minor: 5_200_000 });
        let there = view.ahead.iter().find(|year| year.kept_minor >= 68_571_429).unwrap();
        assert_eq!(there.year, 2053);
    }

    #[test]
    fn only_months_held_whole_are_counted() {
        // History starts mid June: June is not a month to count.
        let mut flows = steady("2026-06", 6, 250_000, 400_000);
        flows.insert(month("2026-06"), Flow { spent_minor: 40_000, income_minor: 0 });
        flows.insert(month("2026-11"), Flow { spent_minor: 90_000, income_minor: 400_000 });
        let view = worked_out(&flows, "2026-06-14", 0, Plan::default());
        assert_eq!(view.counted, 4);
        assert_eq!(view.months.iter().map(|m| m.month.to_string()).collect::<Vec<_>>(), ["2026-07", "2026-08", "2026-09", "2026-10", "2026-11"]);
        // The month running is shown as it stands and left out of the average.
        assert_eq!((view.months[4].spent_minor, view.months[4].whole), (90_000, false));
        assert_eq!(view.monthly_spent_minor, Some(250_000));
        assert_eq!(view.yearly_spent_minor, Some(3_000_000));
        assert_eq!(view.savings_rate_pct, Some(37.5));
        // No birth year: no age, and no coast number.
        assert_eq!((view.age, view.fi_age, view.coast), (None, None, None));
        assert!(view.ahead.iter().all(|year| year.age.is_none()));
        // A month with nothing in it still counts, as nothing.
        let mut gap = flows.clone();
        gap.remove(&month("2026-09"));
        assert_eq!(super::fire(FireInput {
            today: day("2026-11-17"),
            currency: "CAD",
            flows: &gap,
            first: Some(day("2026-06-14")),
            set_aside_minor: 0,
            set_aside_in_bank_minor: 0,
            on_hand_minor: 0,
            plan: Plan::default(),
        })
        .monthly_spent_minor, Some(187_500));
    }

    #[test]
    fn with_no_whole_month_nothing_is_worked_out() {
        let flows = steady("2026-11", 1, 90_000, 400_000);
        for first in [Some(day("2026-11-02")), Some(day("2026-10-02")), None] {
            let view = fire(FireInput {
                today: day("2026-11-17"),
                currency: "CAD",
                flows: &flows,
                first,
                set_aside_minor: 5_000_000,
                set_aside_in_bank_minor: 0,
                on_hand_minor: 100_000,
                plan: Plan { birth_year: Some(1990), ..Plan::default() },
            });
            assert_eq!((view.counted, view.months.len()), (0, 1));
            assert_eq!((view.savings_rate_pct, view.fi_number_minor, view.years_to_fi, view.runway_months), (None, None, None, None));
            assert_eq!((view.coast, view.ahead.len(), view.reached), (None, 0, false));
            // What is set aside and the age are known all the same.
            assert_eq!((view.set_aside_minor, view.age), (5_000_000, Some(36)));
        }
    }

    #[test]
    fn spending_more_than_comes_in_is_said_as_it_is() {
        let flows = steady("2026-05", 7, 300_000, 250_000);
        let view = worked_out(&flows, "2026-05-01", 1_000_000, Plan::default());
        assert_eq!(view.savings_rate_pct, Some(-20.0));
        assert_eq!(view.monthly_kept_minor, Some(-50_000));
        assert_eq!((view.years_to_fi, view.fi_year), (None, None));
        // The line ahead runs down, and stops at nothing.
        assert_eq!(view.ahead.len(), 11);
        assert!(view.ahead[1].kept_minor < view.ahead[0].kept_minor);
        assert_eq!(view.ahead.last().unwrap().kept_minor, 0);
        // Nothing came in at all, or next to nothing: there is no rate to give.
        let none = steady("2026-05", 7, 300_000, 0);
        assert_eq!(worked_out(&none, "2026-05-01", 0, Plan::default()).savings_rate_pct, None);
        let cents = steady("2026-05", 7, 300_000, 100);
        assert_eq!(worked_out(&cents, "2026-05-01", 0, Plan::default()).savings_rate_pct, None);
        let little = steady("2026-05", 7, 300_000, 100_000);
        assert_eq!(worked_out(&little, "2026-05-01", 0, Plan::default()).savings_rate_pct, Some(-200.0));
    }

    #[test]
    fn independence_reached_is_said_and_so_is_coasting() {
        let flows = steady("2026-05", 7, 200_000, 300_000);
        let plan = Plan { birth_year: Some(1990), withdrawal_bp: 400, return_bp: 500, coast_age: 60, ..Plan::default() };
        // 24,000 a year at 4% is 600,000.
        let there = worked_out(&flows, "2026-05-01", 60_000_000, plan);
        assert_eq!((there.fi_number_minor, there.reached, there.years_to_fi), (Some(60_000_000), true, Some(0.0)));
        assert_eq!((there.progress_pct, there.fi_year, there.fi_age), (Some(100.0), Some(2026), Some(36)));
        // 600,000 / 1.05^24 is about 186,041: with more than that set aside
        // it would get there by 60 with nothing added.
        let coasting = worked_out(&flows, "2026-05-01", 20_000_000, plan);
        let coast = coasting.coast.unwrap();
        assert_eq!((coast.years, coast.number_minor, coast.reached), (24, 18_604_075, true));
        assert!(!coasting.reached);
        // Past the age it is worked out for, there is no coast number.
        let older = Plan { birth_year: Some(1960), ..plan };
        assert_eq!(worked_out(&flows, "2026-05-01", 20_000_000, older).coast, None);
    }

    #[test]
    fn a_plan_is_held_to_what_makes_sense() {
        let today = day("2026-11-17");
        assert_eq!(Plan::default().problem(today), None);
        assert_eq!(Plan { birth_year: Some(1990), ..Plan::default() }.problem(today), None);
        for wrong in [
            Plan { withdrawal_bp: 199, ..Plan::default() },
            Plan { withdrawal_bp: 601, ..Plan::default() },
            Plan { return_bp: 1001, ..Plan::default() },
            Plan { coast_age: 39, ..Plan::default() },
            Plan { coast_age: 81, ..Plan::default() },
            Plan { birth_year: Some(1899), ..Plan::default() },
            Plan { birth_year: Some(2027), ..Plan::default() },
            Plan { emergency_fund_minor: -1, ..Plan::default() },
            Plan { emergency_fund_minor: 10_000_001, ..Plan::default() },
        ] {
            assert!(wrong.problem(today).is_some(), "{wrong:?}");
        }
        assert_eq!(Plan { emergency_fund_minor: 500_000, ..Plan::default() }.problem(today), None);
    }

    #[test]
    fn the_emergency_fund_is_held_back_from_the_savings_set_aside() {
        let flows = steady("2026-05", 7, 200_000, 300_000);
        let plan = Plan { withdrawal_bp: 400, return_bp: 500, emergency_fund_minor: 500_000, ..Plan::default() };
        let worked = |set_aside_minor: i64, set_aside_in_bank_minor: i64, plan: Plan| {
            let view = fire(FireInput {
                today: day("2026-11-17"),
                currency: "CAD",
                flows: &flows,
                first: Some(day("2026-05-01")),
                set_aside_minor,
                set_aside_in_bank_minor,
                on_hand_minor: 1_200_000,
                plan,
            });
            (view.set_aside_minor, view.emergency_fund_minor, view.progress_pct, view.on_hand_minor)
        };
        // 100,000 invested and 11,000 in savings: 5,000 of the savings is
        // the fund, and the rest is on its way to being invested. 24,000 a
        // year at 4% is 600,000, and 106,000 of it is set aside. The fund is
        // money on hand all the same.
        assert_eq!(worked(11_100_000, 1_100_000, plan), (10_600_000, 500_000, Some(17.7), 1_200_000));
        // Savings smaller than the fund are all of it; the investments are never held back.
        assert_eq!(worked(10_300_000, 300_000, plan), (10_000_000, 300_000, Some(16.7), 1_200_000));
        assert_eq!(worked(10_000_000, 0, plan), (10_000_000, 0, Some(16.7), 1_200_000));
        // With no fund, everything set aside counts.
        let no_fund = Plan { emergency_fund_minor: 0, ..plan };
        assert_eq!(worked(11_100_000, 1_100_000, no_fund), (11_100_000, 0, Some(18.5), 1_200_000));
    }
}
