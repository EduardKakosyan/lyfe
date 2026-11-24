//! Weigh-ins: the day's weight and the seven-day average.
//!
//! Pure rules, no I/O. The scale is not connected, so the owner types the
//! number, normally into the morning prompt. A day's weight is the last one
//! typed that day, so typing it again corrects it. The seven-day average
//! smooths out the water and food that move one morning's reading; it is
//! the trend the calorie targets are later checked against.
//!
//! The weigh-in is not a streak. A missed morning costs nothing: the
//! average is taken over the days that have a weigh-in, and is left out
//! when too few of them do to say anything.

use std::collections::BTreeMap;

use chrono::{Duration, NaiveDate, NaiveDateTime, NaiveTime};
use serde::Serialize;
use uuid::Uuid;

/// Days the average looks back over, today included.
pub const AVERAGE_DAYS: i64 = 7;

/// Weigh-ins the seven days need before their average is given.
pub const MIN_DAYS_FOR_AVERAGE: usize = 3;

/// Days of history the apps are given: the eight weeks on Progress.
pub const HISTORY_DAYS: i64 = 56;

/// The lightest and heaviest weights taken, in grams. Anything outside is
/// a typing slip, not a weight.
pub const PLAUSIBLE_GRAMS: std::ops::RangeInclusive<u32> = 20_000..=400_000;

/// How long after its time the morning prompt can still go out, when the
/// server was not running at that time. Past this it is no longer a
/// morning weigh-in, and nothing is sent that day.
pub const PROMPT_WINDOW: Duration = Duration::hours(3);

/// The prompt's category. The app registers a reply field under the same
/// name, which is what lets the weight be typed into the notification.
pub const PROMPT_CATEGORY: &str = "WEIGH_IN";

/// The unit weights are typed and shown in. Stored weights are grams
/// whatever the unit, so changing it changes only what is shown.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Unit {
    Kg,
    Lb,
}

impl Unit {
    const GRAMS_PER_LB: f64 = 453.592_37;

    pub fn parse(text: &str) -> Option<Unit> {
        match text.trim().to_ascii_lowercase().as_str() {
            "kg" => Some(Unit::Kg),
            "lb" | "lbs" => Some(Unit::Lb),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Unit::Kg => "kg",
            Unit::Lb => "lb",
        }
    }

    fn grams_per_unit(self) -> f64 {
        match self {
            Unit::Kg => 1000.0,
            Unit::Lb => Self::GRAMS_PER_LB,
        }
    }

    /// A typed weight in grams, or `None` when it is not a weight anyone
    /// could be.
    pub fn to_grams(self, value: f64) -> Option<u32> {
        if !value.is_finite() {
            return None;
        }
        let grams = (value * self.grams_per_unit()).round();
        (grams >= 0.0 && grams <= f64::from(u32::MAX))
            .then_some(grams as u32)
            .filter(|grams| PLAUSIBLE_GRAMS.contains(grams))
    }

    /// Grams in this unit, to two decimals: finer than any scale reads.
    pub fn from_grams(self, grams: f64) -> f64 {
        (grams / self.grams_per_unit() * 100.0).round() / 100.0
    }
}

/// How weigh-ins are set up on this server.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct WeightSettings {
    pub unit: Unit,
    /// When the morning prompt goes out, in the owner's time zone; `None`
    /// sends none.
    pub prompt_at: Option<NaiveTime>,
}

impl Default for WeightSettings {
    fn default() -> Self {
        WeightSettings { unit: Unit::Lb, prompt_at: NaiveTime::from_hms_opt(6, 30, 0) }
    }
}

/// One weight as the owner typed it.
#[derive(Debug, Clone, PartialEq)]
pub struct WeighIn {
    /// Made on the phone, so a weight sent twice is stored once.
    pub id: Uuid,
    /// When it was typed, in the owner's wall-clock time; decides its day.
    pub measured_local: NaiveDateTime,
    pub grams: u32,
}

/// Each day's weight: the last one typed that day.
pub fn daily(weigh_ins: &[WeighIn]) -> BTreeMap<NaiveDate, u32> {
    let mut sorted: Vec<&WeighIn> = weigh_ins.iter().collect();
    sorted.sort_by_key(|w| (w.measured_local, w.id));
    sorted.into_iter().map(|w| (w.measured_local.date(), w.grams)).collect()
}

/// The average of the seven days ending `on`, in grams, with the number of
/// days it rests on. `None` while fewer than three of them have a weight.
pub fn average_on(daily: &BTreeMap<NaiveDate, u32>, on: NaiveDate) -> Option<(f64, usize)> {
    let from = on - Duration::days(AVERAGE_DAYS - 1);
    let weights: Vec<u32> = daily.range(from..=on).map(|(_, grams)| *grams).collect();
    if weights.len() < MIN_DAYS_FOR_AVERAGE {
        return None;
    }
    let total: u64 = weights.iter().map(|g| u64::from(*g)).sum();
    Some((total as f64 / weights.len() as f64, weights.len()))
}

/// Weigh-ins in the seven days ending `on`.
pub fn days_in_window(daily: &BTreeMap<NaiveDate, u32>, on: NaiveDate) -> usize {
    daily.range(on - Duration::days(AVERAGE_DAYS - 1)..=on).count()
}

/// A day's weight as the apps show it.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Reading {
    pub date: NaiveDate,
    pub value: f64,
}

/// One day on the Progress line.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Day {
    pub date: NaiveDate,
    /// The weight typed that day; null when none was.
    pub value: Option<f64>,
    /// The seven-day average as of that day; null when too few days had one.
    pub average: Option<f64>,
}

/// Weight as the apps show it, every figure in `unit`.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct WeightTrend {
    pub unit: Unit,
    /// When the morning prompt goes out ("06:30"); null when it is off.
    pub prompt_at: Option<String>,
    /// The most recent day with a weight.
    pub latest: Option<Reading>,
    /// The seven-day average as of today.
    pub average: Option<f64>,
    /// Days of the last seven, today included, with a weight.
    pub days_weighed: u32,
    /// The average now minus the average a week ago.
    pub change: Option<f64>,
    /// The same as a percentage of a week ago, to two decimals.
    pub change_pct: Option<f64>,
    /// The last eight weeks, oldest first: every day that has a weight or
    /// an average.
    pub days: Vec<Day>,
}

/// Everything the apps show about weight, as of `today`.
pub fn trend(settings: &WeightSettings, today: NaiveDate, weigh_ins: &[WeighIn]) -> WeightTrend {
    let unit = settings.unit;
    let daily = daily(weigh_ins);
    let up_to_today: BTreeMap<NaiveDate, u32> = daily.range(..=today).map(|(d, g)| (*d, *g)).collect();
    let now = average_on(&up_to_today, today).map(|(grams, _)| grams);
    let week_ago = average_on(&up_to_today, today - Duration::days(7)).map(|(grams, _)| grams);
    let change = now.zip(week_ago);
    let days = (0..HISTORY_DAYS)
        .rev()
        .map(|back| today - Duration::days(back))
        .filter_map(|date| {
            let value = up_to_today.get(&date).map(|grams| unit.from_grams(f64::from(*grams)));
            let average = average_on(&up_to_today, date).map(|(grams, _)| unit.from_grams(grams));
            (value.is_some() || average.is_some()).then_some(Day { date, value, average })
        })
        .collect();
    WeightTrend {
        unit,
        prompt_at: settings.prompt_at.map(|at| at.format("%H:%M").to_string()),
        latest: up_to_today
            .last_key_value()
            .map(|(date, grams)| Reading { date: *date, value: unit.from_grams(f64::from(*grams)) }),
        average: now.map(|grams| unit.from_grams(grams)),
        days_weighed: days_in_window(&up_to_today, today) as u32,
        change: change.map(|(now, then)| unit.from_grams(now - then)),
        change_pct: change.map(|(now, then)| ((now - then) / then * 10_000.0).round() / 100.0),
        days,
    }
}

/// Whether today already has a weight, which makes the prompt pointless.
pub fn weighed_on(weigh_ins: &[WeighIn], day: NaiveDate) -> bool {
    weigh_ins.iter().any(|w| w.measured_local.date() == day)
}

/// The prompt's words.
pub fn prompt_title() -> &'static str {
    "Morning weigh-in"
}

pub fn prompt_body(unit: Unit) -> String {
    format!("Hold this and type your weight in {}. No need to open lyfe.", unit.as_str())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn date(text: &str) -> NaiveDate {
        text.parse().unwrap()
    }

    fn weigh_in(n: u128, at: &str, kg: f64) -> WeighIn {
        WeighIn {
            id: Uuid::from_u128(n),
            measured_local: NaiveDateTime::parse_from_str(at, "%Y-%m-%d %H:%M").unwrap(),
            grams: (kg * 1000.0).round() as u32,
        }
    }

    fn kg() -> WeightSettings {
        WeightSettings { unit: Unit::Kg, prompt_at: NaiveTime::from_hms_opt(6, 30, 0) }
    }

    #[test]
    fn the_last_weight_typed_on_a_day_is_that_days_weight() {
        let weigh_ins = [
            weigh_in(2, "2026-11-17 06:41", 82.0),
            weigh_in(1, "2026-11-17 06:40", 28.0), // a slip, corrected a minute later
            weigh_in(3, "2026-11-16 06:35", 82.6),
        ];
        let days = daily(&weigh_ins);
        assert_eq!(days.len(), 2);
        assert_eq!(days[&date("2026-11-17")], 82_000);
        assert_eq!(days[&date("2026-11-16")], 82_600);
    }

    #[test]
    fn the_average_needs_three_of_the_last_seven_days() {
        let mut weigh_ins = vec![
            weigh_in(1, "2026-11-10 06:30", 90.0), // eight days back: outside
            weigh_in(2, "2026-11-12 06:30", 83.0),
            weigh_in(3, "2026-11-15 06:30", 82.0),
        ];
        let t = trend(&kg(), date("2026-11-18"), &weigh_ins);
        assert_eq!((t.average, t.days_weighed), (None, 2));

        weigh_ins.push(weigh_in(4, "2026-11-18 06:30", 81.0));
        let t = trend(&kg(), date("2026-11-18"), &weigh_ins);
        assert_eq!((t.average, t.days_weighed), (Some(82.0), 3));
        assert_eq!(t.latest, Some(Reading { date: date("2026-11-18"), value: 81.0 }));
    }

    #[test]
    fn missed_mornings_cost_nothing() {
        // Three weigh-ins in a week give the same average as seven of the
        // same weights would.
        let sparse = [
            weigh_in(1, "2026-11-12 06:30", 82.0),
            weigh_in(2, "2026-11-15 06:30", 82.0),
            weigh_in(3, "2026-11-18 06:30", 82.0),
        ];
        assert_eq!(trend(&kg(), date("2026-11-18"), &sparse).average, Some(82.0));
    }

    #[test]
    fn the_change_compares_this_weeks_average_with_last_weeks() {
        let mut weigh_ins = Vec::new();
        for day in 0..14u32 {
            // From 84.0 down by 0.1 a day.
            let kg = 84.0 - f64::from(day) * 0.1;
            weigh_ins.push(weigh_in(u128::from(day), &format!("2026-11-{:02} 06:30", 5 + day), kg));
        }
        let t = trend(&kg(), date("2026-11-18"), &weigh_ins);
        // This week 83.3 down to 82.7, mean 83.0; last week 84.0 down to
        // 83.4, mean 83.7.
        assert_eq!(t.average, Some(83.0));
        assert_eq!(t.change, Some(-0.7));
        assert_eq!(t.change_pct, Some(-0.84));
        assert_eq!(t.days_weighed, 7);
    }

    #[test]
    fn no_change_without_an_average_a_week_ago() {
        let weigh_ins = [
            weigh_in(1, "2026-11-16 06:30", 82.0),
            weigh_in(2, "2026-11-17 06:30", 82.0),
            weigh_in(3, "2026-11-18 06:30", 82.0),
        ];
        let t = trend(&kg(), date("2026-11-18"), &weigh_ins);
        assert_eq!((t.average, t.change, t.change_pct), (Some(82.0), None, None));
    }

    #[test]
    fn the_line_covers_eight_weeks_and_only_days_with_something_to_draw() {
        let weigh_ins = [
            weigh_in(1, "2026-09-01 06:30", 85.0), // long before the eight weeks
            weigh_in(2, "2026-11-12 06:30", 83.0),
            weigh_in(3, "2026-11-14 06:30", 82.5),
            weigh_in(4, "2026-11-16 06:30", 82.0),
        ];
        let t = trend(&kg(), date("2026-11-18"), &weigh_ins);
        let drawn: Vec<(String, Option<f64>, Option<f64>)> =
            t.days.iter().map(|d| (d.date.to_string(), d.value, d.average)).collect();
        assert_eq!(
            drawn,
            vec![
                ("2026-11-12".into(), Some(83.0), None),
                ("2026-11-14".into(), Some(82.5), None),
                ("2026-11-16".into(), Some(82.0), Some(82.5)),
                // No weight typed, but the average still stands.
                ("2026-11-17".into(), None, Some(82.5)),
                ("2026-11-18".into(), None, Some(82.5)),
            ]
        );
    }

    #[test]
    fn a_weight_typed_after_today_is_ignored() {
        // The phone's clock ran ahead; it does not count until its day.
        let weigh_ins = [weigh_in(1, "2026-11-19 06:30", 82.0)];
        let t = trend(&kg(), date("2026-11-18"), &weigh_ins);
        assert_eq!((t.latest, t.days.len()), (None, 0));
    }

    #[test]
    fn pounds_are_stored_as_grams_and_shown_back_as_pounds() {
        let grams = Unit::Lb.to_grams(181.4).unwrap();
        assert_eq!(grams, 82_282);
        assert_eq!(Unit::Lb.from_grams(f64::from(grams)), 181.4);
        let weigh_ins = [WeighIn { id: Uuid::from_u128(1), measured_local: date("2026-11-18").and_hms_opt(6, 30, 0).unwrap(), grams }];
        let lb = WeightSettings { unit: Unit::Lb, prompt_at: None };
        let t = trend(&lb, date("2026-11-18"), &weigh_ins);
        assert_eq!(t.latest.unwrap().value, 181.4);
        assert_eq!(t.prompt_at, None);
        // The same weight shown in kilograms.
        assert_eq!(trend(&kg(), date("2026-11-18"), &weigh_ins).latest.unwrap().value, 82.28);
    }

    #[test]
    fn slips_are_not_weights() {
        assert_eq!(Unit::Kg.to_grams(82.4), Some(82_400));
        for slip in [8.24, 824.0, 0.0, -82.0, f64::NAN, f64::INFINITY] {
            assert_eq!(Unit::Kg.to_grams(slip), None, "{slip}");
        }
        assert_eq!(Unit::Lb.to_grams(30.0), None);
        assert_eq!(Unit::parse(" LBS "), Some(Unit::Lb));
        assert_eq!(Unit::parse("stone"), None);
    }

    #[test]
    fn the_prompt_time_is_sent_as_hours_and_minutes() {
        let t = trend(&kg(), date("2026-11-18"), &[]);
        assert_eq!(t.prompt_at.as_deref(), Some("06:30"));
        assert_eq!((t.latest, t.average, t.days_weighed), (None, None, 0));
    }

    #[test]
    fn today_is_weighed_once_any_weight_is_typed() {
        let weigh_ins = [weigh_in(1, "2026-11-18 05:58", 82.0)];
        assert!(weighed_on(&weigh_ins, date("2026-11-18")));
        assert!(!weighed_on(&weigh_ins, date("2026-11-19")));
    }
}
