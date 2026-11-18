//! Food: saved meals, the day's log against its targets, and the logging
//! streak.
//!
//! Pure rules, no I/O. A saved meal is defined once from weighed
//! ingredients and the figures on their labels, so logging it is one tap
//! and its numbers are measured, not guessed. A batch recipe says how many
//! portions it makes, and one portion is what a tap logs.
//!
//! The day is held to a calorie and a protein target, shown as target
//! against actual. What is not logged is unknown, never zero: a main meal
//! with nothing logged is reported as open, and the day's total is only
//! what was logged.
//!
//! Meals that are not saved meals come from a photo and one line, which a
//! model estimates, or from a barcode and the label's figures. The day
//! keeps what was measured (saved meals, labels) apart from what was
//! estimated (photos), and a meal whose figures are not known yet (a photo
//! still being estimated, a barcode not in the database) is logged but
//! left out of the total: unknown, not zero.
//!
//! The streak is on logging, by the day, with the same recovery rule as
//! every routine: a day counts once anything is logged on it, whatever the
//! numbers were, so a day over target does not break it.

use std::cmp::Reverse;
use std::collections::BTreeSet;
use std::ops::RangeInclusive;

use chrono::{Duration, NaiveDate, NaiveDateTime, NaiveTime};
use serde::Serialize;
use uuid::Uuid;

use super::photo::{self, Oil};
use super::product::Product;
use super::streak::{self, Current, Mark, State};

/// The longest name a meal or an ingredient can have.
pub const MAX_NAME_CHARS: usize = 60;
/// The most portions a batch recipe can make.
pub const MAX_PORTIONS: u32 = 50;
pub const MAX_INGREDIENTS: usize = 40;
/// The heaviest single ingredient taken, in grams: a big batch pot.
pub const MAX_GRAMS: f64 = 20_000.0;
/// Pure fat is 900 kcal per 100 g; nothing has more.
pub const MAX_KCAL_PER_100G: f64 = 900.0;
pub const MAX_PROTEIN_PER_100G: f64 = 100.0;
/// The most portions one tap can log.
pub const MAX_SERVINGS: f64 = 10.0;
/// Daily targets taken. Anything outside is a typing slip, not a target.
pub const KCAL_TARGETS: RangeInclusive<u32> = 800..=10_000;
pub const PROTEIN_TARGETS: RangeInclusive<u32> = 20..=500;

/// Days the apps are shown, today last.
pub const DAYS_SHOWN: i64 = 7;

/// What a logging prompt is recorded as, once sent for a day.
pub const PROMPT_KIND: &str = "food_log_today";

/// The prompt's category. The app knows it by this name, so tapping the
/// prompt opens the Food screen.
pub const PROMPT_CATEGORY: &str = "FOOD_LOG";

/// The part of the day a meal is logged under.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Slot {
    Breakfast,
    Lunch,
    Dinner,
    Snack,
}

impl Slot {
    /// The meals a day is expected to have. Snacks are extra: a day with
    /// none is not missing anything.
    pub const MAIN: [Slot; 3] = [Slot::Breakfast, Slot::Lunch, Slot::Dinner];

    pub fn parse(text: &str) -> Option<Slot> {
        match text.trim().to_ascii_lowercase().as_str() {
            "breakfast" => Some(Slot::Breakfast),
            "lunch" => Some(Slot::Lunch),
            "dinner" => Some(Slot::Dinner),
            "snack" => Some(Slot::Snack),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Slot::Breakfast => "breakfast",
            Slot::Lunch => "lunch",
            Slot::Dinner => "dinner",
            Slot::Snack => "snack",
        }
    }
}

/// When the logging prompt goes out.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FoodSettings {
    /// From this time of the owner's day a streak with nothing logged yet
    /// is prompted for; `None` sends none.
    pub prompt_at: Option<NaiveTime>,
}

impl Default for FoodSettings {
    fn default() -> Self {
        FoodSettings { prompt_at: NaiveTime::from_hms_opt(12, 0, 0) }
    }
}

/// One thing that went into a recipe: its weight, and the figures from
/// its label.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Ingredient {
    pub name: String,
    pub grams: f64,
    pub kcal_per_100g: f64,
    pub protein_per_100g: f64,
}

/// Calories and protein of something eaten. Protein is in tenths of a
/// gram, so a day's rows add up to its total exactly.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Amount {
    pub kcal: u32,
    pub protein_dg: u32,
}

impl Amount {
    pub fn protein_g(self) -> f64 {
        f64::from(self.protein_dg) / 10.0
    }

    fn plus(self, other: Amount) -> Amount {
        Amount { kcal: self.kcal + other.kcal, protein_dg: self.protein_dg + other.protein_dg }
    }
}

/// Where a logged meal's figures came from.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Source {
    /// A saved meal, weighed once. Measured.
    Saved,
    /// A photo and one line, estimated by a model. Estimated.
    Photo,
    /// A packaged food's label and the grams eaten. Measured.
    Barcode,
}

impl Source {
    pub fn as_str(self) -> &'static str {
        match self {
            Source::Saved => "saved",
            Source::Photo => "photo",
            Source::Barcode => "barcode",
        }
    }

    pub fn is_estimated(self) -> bool {
        self == Source::Photo
    }
}

/// Whether a logged meal's figures are known yet.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Figures {
    Known,
    /// A photo the model has not answered for yet.
    Estimating,
    /// The model could not estimate it; the owner can type the figures.
    Failed,
    /// A barcode the food database does not have; the owner types the label.
    NeedsLabel,
}

impl Figures {
    pub fn parse(text: &str) -> Option<Figures> {
        match text {
            "known" => Some(Figures::Known),
            "estimating" => Some(Figures::Estimating),
            "failed" => Some(Figures::Failed),
            "needs_label" => Some(Figures::NeedsLabel),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Figures::Known => "known",
            Figures::Estimating => "estimating",
            Figures::Failed => "failed",
            Figures::NeedsLabel => "needs_label",
        }
    }
}

/// What a photo meal carries besides its figures.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct PhotoDetail {
    /// The one line typed with it.
    pub note: String,
    /// False for a meal described without a photo.
    pub has_photo: bool,
    /// What the model saw; empty until it has answered.
    pub items: Vec<photo::Item>,
    /// Whether the model judged it fried, sauced or from a restaurant.
    pub oil_asked: bool,
    pub oil: Option<Oil>,
    /// The owner typed the figures instead of the model's.
    pub typed: bool,
    /// Why there is no estimate yet, in words the owner can act on.
    pub problem: Option<String>,
}

/// What a logged meal carries, by where it came from.
#[derive(Debug, Clone, PartialEq, Default)]
pub enum Detail {
    #[default]
    Saved,
    Photo(PhotoDetail),
    Barcode { code: String, grams: f64 },
}

impl Detail {
    pub fn source(&self) -> Source {
        match self {
            Detail::Saved => Source::Saved,
            Detail::Photo(_) => Source::Photo,
            Detail::Barcode { .. } => Source::Barcode,
        }
    }
}

/// A meal the owner eats repeatedly, weighed once.
#[derive(Debug, Clone, PartialEq)]
pub struct SavedMeal {
    /// Made on the phone, so saving a meal twice stores it once.
    pub id: Uuid,
    pub name: String,
    pub slot: Slot,
    /// Portions the weighed recipe makes.
    pub portions: u32,
    pub ingredients: Vec<Ingredient>,
}

/// A name as it is kept: trimmed, and neither empty nor too long.
fn clean_name(text: &str) -> Option<String> {
    let name = text.trim();
    (!name.is_empty() && name.chars().count() <= MAX_NAME_CHARS).then(|| name.to_string())
}

fn within(value: f64, low: f64, high: f64) -> bool {
    value.is_finite() && value >= low && value <= high
}

impl SavedMeal {
    /// A meal as the owner typed it, or what is wrong with it.
    pub fn new(
        id: Uuid,
        name: &str,
        slot: Slot,
        portions: u32,
        ingredients: Vec<Ingredient>,
    ) -> Result<SavedMeal, &'static str> {
        let name = clean_name(name).ok_or("the meal's name must be 1 to 60 characters")?;
        if !(1..=MAX_PORTIONS).contains(&portions) {
            return Err("portions must be 1 to 50");
        }
        if ingredients.is_empty() || ingredients.len() > MAX_INGREDIENTS {
            return Err("a meal has 1 to 40 ingredients");
        }
        let mut cleaned = Vec::with_capacity(ingredients.len());
        for ingredient in ingredients {
            let name = clean_name(&ingredient.name).ok_or("an ingredient's name must be 1 to 60 characters")?;
            if !(ingredient.grams.is_finite() && ingredient.grams > 0.0 && ingredient.grams <= MAX_GRAMS) {
                return Err("an ingredient's weight must be above 0 and at most 20000 g");
            }
            if !within(ingredient.kcal_per_100g, 0.0, MAX_KCAL_PER_100G) {
                return Err("kcal per 100 g must be 0 to 900");
            }
            if !within(ingredient.protein_per_100g, 0.0, MAX_PROTEIN_PER_100G) {
                return Err("protein per 100 g must be 0 to 100");
            }
            cleaned.push(Ingredient { name, ..ingredient });
        }
        Ok(SavedMeal { id, name, slot, portions, ingredients: cleaned })
    }

    /// What `servings` portions of the recipe come to.
    pub fn amount(&self, servings: f64) -> Amount {
        let (kcal, protein_g) = self.ingredients.iter().fold((0.0, 0.0), |(kcal, protein), i| {
            (kcal + i.grams * i.kcal_per_100g / 100.0, protein + i.grams * i.protein_per_100g / 100.0)
        });
        let share = servings / f64::from(self.portions);
        Amount { kcal: (kcal * share).round() as u32, protein_dg: (protein_g * share * 10.0).round() as u32 }
    }
}

/// Whether one tap can log this many portions.
pub fn servings_make_sense(servings: f64) -> bool {
    servings.is_finite() && servings > 0.0 && servings <= MAX_SERVINGS
}

/// One meal logged.
#[derive(Debug, Clone, PartialEq)]
pub struct Entry {
    /// Made on the phone, so an entry sent twice is stored once.
    pub id: Uuid,
    /// When it was logged, in the owner's wall-clock time; decides its day.
    pub eaten_local: NaiveDateTime,
    pub slot: Slot,
    pub meal_id: Option<Uuid>,
    pub name: String,
    pub servings: f64,
    /// Zero while `figures` is not known.
    pub amount: Amount,
    pub figures: Figures,
    pub detail: Detail,
}

/// The calorie and protein targets in force from a day on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Target {
    /// The day it took effect.
    pub since: NaiveDate,
    pub kcal: u32,
    pub protein_g: u32,
}

impl Target {
    /// A target as the owner typed it, or what is wrong with it.
    pub fn new(since: NaiveDate, kcal: u32, protein_g: u32) -> Result<Target, &'static str> {
        if !KCAL_TARGETS.contains(&kcal) {
            return Err("the calorie target must be 800 to 10000 kcal");
        }
        if !PROTEIN_TARGETS.contains(&protein_g) {
            return Err("the protein target must be 20 to 500 g");
        }
        Ok(Target { since, kcal, protein_g })
    }
}

/// The target a day is held to: the latest one set on or before it.
pub fn target_on(targets: &[Target], day: NaiveDate) -> Option<Target> {
    targets.iter().filter(|target| target.since <= day).max_by_key(|target| target.since).copied()
}

// --- The logging streak --------------------------------------------------

/// How one of the days shown turned out.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum DayState {
    /// Something was logged.
    Kept,
    /// Nothing was logged, and the next day recovered it.
    Recovered,
    /// Yesterday, with nothing logged; today decides whether it is recovered.
    AwaitingRecovery,
    /// Nothing was logged, and no streak was kept alive across it.
    Missed,
    /// Today, with nothing logged yet.
    Open,
    /// Before the first meal was ever logged.
    Before,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct DayMark {
    pub date: NaiveDate,
    pub state: DayState,
}

/// The logging streak as of today.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DayStreak {
    /// Days in a row with something logged, counting today once it has.
    pub days: u32,
    pub state: State,
    /// The longest streak that has ended. Zero when none has.
    pub previous_best: u32,
    pub logged_today: bool,
    /// The last seven days, oldest first, today last.
    pub last_days: Vec<DayMark>,
}

/// The days something was logged on.
pub fn logged_days(entries: &[Entry]) -> BTreeSet<NaiveDate> {
    entries.iter().map(|entry| entry.eaten_local.date()).collect()
}

/// The streak rules applied to the days something was logged on. Days
/// before the first log say nothing about a streak and are left out.
pub fn streak(today: NaiveDate, logged: &BTreeSet<NaiveDate>) -> DayStreak {
    let first = logged.first().copied().filter(|day| *day <= today);
    let logged_today = logged.contains(&today);
    let finished: Vec<bool> = first
        .map(|first| first.iter_days().take_while(|day| *day < today).map(|day| logged.contains(&day)).collect())
        .unwrap_or_default();
    let standing = streak::standing(&finished, if logged_today { Current::Kept } else { Current::Open });

    let last_days = (0..DAYS_SHOWN)
        .rev()
        .map(|back| today - Duration::days(back))
        .map(|date| {
            let state = match first {
                _ if date == today && logged_today => DayState::Kept,
                _ if date == today => DayState::Open,
                Some(first) if date >= first => match standing.marks[(date - first).num_days() as usize] {
                    Mark::Kept => DayState::Kept,
                    Mark::Recovered => DayState::Recovered,
                    Mark::AwaitingRecovery => DayState::AwaitingRecovery,
                    Mark::Missed => DayState::Missed,
                },
                _ => DayState::Before,
            };
            DayMark { date, state }
        })
        .collect();

    DayStreak {
        days: standing.length,
        state: standing.state,
        previous_best: standing.previous_best,
        logged_today,
        last_days,
    }
}

/// Something worth interrupting the owner for: a streak is alive and
/// today has nothing logged yet.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Prompt {
    pub days: u32,
    /// Yesterday was missed, so today is the last day that keeps the streak.
    pub recovering: bool,
}

/// The prompt today calls for, if any.
pub fn prompt(streak: &DayStreak) -> Option<Prompt> {
    match streak.state {
        State::OnTrack => Some(Prompt { days: streak.days, recovering: false }),
        State::Recovering => Some(Prompt { days: streak.days, recovering: true }),
        // Nothing at stake, or today is already logged.
        State::NotStarted | State::Kept => None,
    }
}

impl Prompt {
    pub fn title(&self) -> String {
        if self.recovering { "Fuel: yesterday was missed".into() } else { "Fuel: nothing logged today".into() }
    }

    pub fn body(&self) -> String {
        let streak = format!("{}-day streak", self.days);
        if self.recovering {
            format!("One meal logged today recovers your {streak}. Nothing to make up.")
        } else {
            format!("Log one meal to keep your {streak}.")
        }
    }
}

// --- The day as the apps show it -----------------------------------------

/// One logged meal.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct EntryView {
    pub id: Uuid,
    pub slot: Slot,
    pub name: String,
    /// The saved meal it was logged from.
    pub meal_id: Option<Uuid>,
    pub servings: f64,
    /// Zero while `figures` is not known.
    pub kcal: u32,
    pub protein_g: f64,
    pub source: Source,
    pub figures: Figures,
    /// True for a photo meal, whose figures are a model's estimate.
    pub estimated: bool,
    /// How far either way an estimate may be. Only for a photo meal with
    /// known figures the owner did not type.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kcal_low: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub kcal_high: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub photo: Option<PhotoView>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub barcode: Option<BarcodeView>,
}

/// A photo meal's line, what the model saw, and the oil question.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct PhotoView {
    pub note: String,
    pub has_photo: bool,
    pub items: Vec<ItemView>,
    /// Whether to ask how much oil or sauce went in.
    pub oil_asked: bool,
    /// The owner's answer; null until answered.
    pub oil: Option<Oil>,
    /// The oil the figures include: the answer, or "some" until there is one.
    pub oil_counted: Oil,
    pub oil_kcal: u32,
    pub typed: bool,
    pub problem: Option<String>,
}

/// One food the model saw, at the grams that count.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ItemView {
    pub name: String,
    pub grams: f64,
    /// The model's grams, before any correction.
    pub grams_seen: f64,
    pub kcal: u32,
    pub protein_g: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct BarcodeView {
    pub code: String,
    pub grams: f64,
}

/// A saved meal, with what one portion comes to.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct MealView {
    pub id: Uuid,
    pub name: String,
    pub slot: Slot,
    pub portions: u32,
    /// One portion.
    pub kcal: u32,
    pub protein_g: f64,
    pub ingredients: Vec<Ingredient>,
}

/// Food as the apps show it, as of `day`.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct FoodDay {
    pub day: NaiveDate,
    /// What the day is held to; null until the owner has set targets.
    pub target: Option<Target>,
    /// Everything logged today whose figures are known. Not the day's
    /// intake unless every meal was logged and known: see `open_slots` and
    /// `unknown`.
    pub kcal: u32,
    pub protein_g: f64,
    /// The part of it that was measured: saved meals and labels.
    pub kcal_measured: u32,
    pub protein_measured_g: f64,
    /// The part of it that was estimated from photos.
    pub kcal_estimated: u32,
    pub protein_estimated_g: f64,
    /// How far either way the estimated part may take the total.
    pub kcal_low: u32,
    pub kcal_high: u32,
    /// Meals logged today whose figures are not known yet: left out of
    /// the total, not counted as zero.
    pub unknown: u32,
    /// How far either way a photo estimate may be, in percent.
    pub estimate_range_pct: u32,
    /// The target minus what is logged; negative once over. Null without
    /// a target.
    pub kcal_left: Option<i64>,
    pub protein_left_g: Option<f64>,
    /// Main meals (breakfast, lunch, dinner) with nothing logged: unknown,
    /// not zero.
    pub open_slots: Vec<Slot>,
    /// Today's entries, by slot and then in the order logged.
    pub entries: Vec<EntryView>,
    /// The saved meals, by slot, the one logged most recently first.
    pub meals: Vec<MealView>,
    /// Packaged food logged lately, most recent first, so a code scanned
    /// again can be looked up without a connection.
    pub products: Vec<Product>,
    pub streak: DayStreak,
}

/// An entry as the apps show it.
fn entry_view(entry: &Entry, range_pct: u32) -> EntryView {
    let source = entry.detail.source();
    let known = entry.figures == Figures::Known;
    let ranged = match &entry.detail {
        Detail::Photo(detail) => known && !detail.typed,
        _ => false,
    };
    let range = ranged.then(|| photo::range(entry.amount.kcal, range_pct));
    EntryView {
        id: entry.id,
        slot: entry.slot,
        name: entry.name.clone(),
        meal_id: entry.meal_id,
        servings: entry.servings,
        kcal: entry.amount.kcal,
        protein_g: entry.amount.protein_g(),
        source,
        figures: entry.figures,
        estimated: source.is_estimated(),
        kcal_low: range.map(|(low, _)| low),
        kcal_high: range.map(|(_, high)| high),
        photo: match &entry.detail {
            Detail::Photo(detail) => {
                let oil_counted = photo::oil_counted(detail.oil_asked, detail.oil);
                Some(PhotoView {
                    note: detail.note.clone(),
                    has_photo: detail.has_photo,
                    items: detail
                        .items
                        .iter()
                        .map(|item| ItemView {
                            name: item.name.clone(),
                            grams: item.grams,
                            grams_seen: item.grams_seen,
                            kcal: item.kcal(),
                            protein_g: item.protein_g(),
                        })
                        .collect(),
                    oil_asked: detail.oil_asked,
                    oil: detail.oil,
                    oil_counted,
                    oil_kcal: if detail.typed { 0 } else { oil_counted.kcal() },
                    typed: detail.typed,
                    problem: detail.problem.clone(),
                })
            }
            _ => None,
        },
        barcode: match &entry.detail {
            Detail::Barcode { code, grams } => Some(BarcodeView { code: code.clone(), grams: *grams }),
            _ => None,
        },
    }
}

/// Everything the apps show about food, as of `today`. `meals` are the
/// saved meals still in use; `entries` every entry not taken back.
/// `range_pct` is how far either way a photo estimate may be.
pub fn day(today: NaiveDate, meals: &[SavedMeal], entries: &[Entry], targets: &[Target], range_pct: u32) -> FoodDay {
    let mut todays: Vec<&Entry> = entries.iter().filter(|entry| entry.eaten_local.date() == today).collect();
    todays.sort_by_key(|entry| (entry.slot, entry.eaten_local, entry.id));
    let known = || todays.iter().filter(|entry| entry.figures == Figures::Known);
    let sum = |estimated: bool| {
        known()
            .filter(|entry| entry.detail.source().is_estimated() == estimated)
            .fold(Amount::default(), |sum, entry| sum.plus(entry.amount))
    };
    let (measured, estimated) = (sum(false), sum(true));
    let eaten = measured.plus(estimated);
    let estimated_range = photo::range(estimated.kcal, range_pct);
    let target = target_on(targets, today);

    let last_logged = |meal: &SavedMeal| {
        entries.iter().filter(|entry| entry.meal_id == Some(meal.id)).map(|entry| entry.eaten_local).max()
    };
    let mut ordered: Vec<&SavedMeal> = meals.iter().collect();
    ordered.sort_by_cached_key(|meal| (meal.slot, Reverse(last_logged(meal)), meal.name.to_lowercase(), meal.id));

    FoodDay {
        day: today,
        target,
        kcal: eaten.kcal,
        protein_g: eaten.protein_g(),
        kcal_measured: measured.kcal,
        protein_measured_g: measured.protein_g(),
        kcal_estimated: estimated.kcal,
        protein_estimated_g: estimated.protein_g(),
        kcal_low: measured.kcal + estimated_range.0,
        kcal_high: measured.kcal + estimated_range.1,
        unknown: todays.iter().filter(|entry| entry.figures != Figures::Known).count() as u32,
        estimate_range_pct: range_pct,
        kcal_left: target.map(|target| i64::from(target.kcal) - i64::from(eaten.kcal)),
        protein_left_g: target
            .map(|target| (f64::from(target.protein_g) * 10.0 - f64::from(eaten.protein_dg)) / 10.0),
        open_slots: Slot::MAIN.into_iter().filter(|slot| !todays.iter().any(|entry| entry.slot == *slot)).collect(),
        entries: todays.iter().map(|entry| entry_view(entry, range_pct)).collect(),
        meals: ordered
            .into_iter()
            .map(|meal| {
                let portion = meal.amount(1.0);
                MealView {
                    id: meal.id,
                    name: meal.name.clone(),
                    slot: meal.slot,
                    portions: meal.portions,
                    kcal: portion.kcal,
                    protein_g: portion.protein_g(),
                    ingredients: meal.ingredients.clone(),
                }
            })
            .collect(),
        products: Vec::new(),
        streak: streak(today, &logged_days(entries)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use DayState::{AwaitingRecovery as Awaiting, Before, Kept, Missed, Open, Recovered};

    fn date(text: &str) -> NaiveDate {
        text.parse().unwrap()
    }

    fn ingredient(name: &str, grams: f64, kcal: f64, protein: f64) -> Ingredient {
        Ingredient { name: name.into(), grams, kcal_per_100g: kcal, protein_per_100g: protein }
    }

    /// Oats, milk and whey: 303.2 + 126 + 113.1 kcal and 10.6 + 8.5 + 24 g.
    fn breakfast() -> SavedMeal {
        SavedMeal::new(
            Uuid::from_u128(1),
            " Usual breakfast ",
            Slot::Breakfast,
            1,
            vec![
                ingredient("Oats", 80.0, 379.0, 13.2),
                ingredient("Milk 2%", 250.0, 50.4, 3.4),
                ingredient("Whey", 30.0, 377.0, 80.0),
            ],
        )
        .unwrap()
    }

    /// A pot that makes five lunches: 2805.6 kcal and 245 g in all.
    fn lunch() -> SavedMeal {
        SavedMeal::new(
            Uuid::from_u128(2),
            "Batch lunch",
            Slot::Lunch,
            5,
            vec![
                ingredient("Chicken thigh", 900.0, 177.0, 24.0),
                ingredient("Rice, dry", 300.0, 360.0, 7.0),
                ingredient("Olive oil", 15.0, 884.0, 0.0),
                ingredient("Frozen vegetables", 400.0, 0.0, 2.0),
            ],
        )
        .unwrap()
    }

    fn entry(n: u128, at: &str, meal: &SavedMeal, servings: f64) -> Entry {
        Entry {
            id: Uuid::from_u128(n),
            eaten_local: NaiveDateTime::parse_from_str(at, "%Y-%m-%d %H:%M").unwrap(),
            slot: meal.slot,
            meal_id: Some(meal.id),
            name: meal.name.clone(),
            servings,
            amount: meal.amount(servings),
            figures: Figures::Known,
            detail: Detail::Saved,
        }
    }

    fn logged(days: &[&str]) -> BTreeSet<NaiveDate> {
        days.iter().map(|day| date(day)).collect()
    }

    /// The states of the seven days shown, oldest first.
    fn shown(streak: &DayStreak) -> Vec<DayState> {
        streak.last_days.iter().map(|day| day.state).collect()
    }

    // --- Saved meals ---

    #[test]
    fn a_meal_is_the_sum_of_its_weighed_ingredients() {
        let meal = breakfast();
        assert_eq!(meal.name, "Usual breakfast");
        assert_eq!(meal.amount(1.0), Amount { kcal: 542, protein_dg: 431 });
        assert_eq!(meal.amount(1.0).protein_g(), 43.1);
    }

    #[test]
    fn a_batch_is_shared_between_its_portions() {
        let meal = lunch();
        assert_eq!(meal.amount(1.0), Amount { kcal: 561, protein_dg: 490 });
        // The whole pot.
        assert_eq!(meal.amount(5.0), Amount { kcal: 2806, protein_dg: 2450 });
    }

    #[test]
    fn a_portion_and_a_half_is_one_and_a_half_times_the_numbers() {
        let meal = lunch();
        assert_eq!(meal.amount(1.5), Amount { kcal: 842, protein_dg: 735 });
        assert_eq!(meal.amount(0.5), Amount { kcal: 281, protein_dg: 245 });
    }

    #[test]
    fn a_meal_that_makes_no_sense_is_refused() {
        let ok = || vec![ingredient("Oats", 80.0, 379.0, 13.2)];
        let meal = |name: &str, portions: u32, ingredients: Vec<Ingredient>| {
            SavedMeal::new(Uuid::from_u128(9), name, Slot::Breakfast, portions, ingredients)
        };
        assert!(meal("Oats", 1, ok()).is_ok());
        assert!(meal("  ", 1, ok()).is_err());
        assert!(meal(&"x".repeat(61), 1, ok()).is_err());
        assert!(meal("Oats", 0, ok()).is_err());
        assert!(meal("Oats", 51, ok()).is_err());
        assert!(meal("Oats", 1, vec![]).is_err());
        assert!(meal("Oats", 1, vec![ingredient("", 80.0, 379.0, 13.2)]).is_err());
        assert!(meal("Oats", 1, vec![ingredient("Oats", 0.0, 379.0, 13.2)]).is_err());
        assert!(meal("Oats", 1, vec![ingredient("Oats", f64::NAN, 379.0, 13.2)]).is_err());
        // A decimal point that slipped: no food has 3790 kcal in 100 g.
        assert!(meal("Oats", 1, vec![ingredient("Oats", 80.0, 3790.0, 13.2)]).is_err());
        assert!(meal("Oats", 1, vec![ingredient("Oats", 80.0, 379.0, 132.0)]).is_err());
        assert!(meal("Oats", 1, vec![ingredient("Oats", 80.0, -1.0, 13.2)]).is_err());
    }

    #[test]
    fn a_tap_logs_a_sensible_number_of_portions() {
        assert!(servings_make_sense(1.0));
        assert!(servings_make_sense(0.5));
        assert!(servings_make_sense(10.0));
        assert!(!servings_make_sense(0.0));
        assert!(!servings_make_sense(-1.0));
        assert!(!servings_make_sense(10.5));
        assert!(!servings_make_sense(f64::INFINITY));
    }

    // --- Targets ---

    #[test]
    fn a_day_is_held_to_the_latest_target_set_on_or_before_it() {
        let targets = [
            Target::new(date("2026-11-02"), 2500, 170).unwrap(),
            Target::new(date("2026-11-16"), 2300, 175).unwrap(),
        ];
        assert_eq!(target_on(&targets, date("2026-11-01")), None);
        assert_eq!(target_on(&targets, date("2026-11-02")).unwrap().kcal, 2500);
        assert_eq!(target_on(&targets, date("2026-11-15")).unwrap().kcal, 2500);
        assert_eq!(target_on(&targets, date("2026-11-16")).unwrap().kcal, 2300);
        assert_eq!(target_on(&targets, date("2026-12-25")).unwrap().protein_g, 175);
    }

    #[test]
    fn a_target_that_is_a_typing_slip_is_refused() {
        let day = date("2026-11-17");
        assert!(Target::new(day, 2500, 170).is_ok());
        assert!(Target::new(day, 250, 170).is_err());
        assert!(Target::new(day, 25_000, 170).is_err());
        assert!(Target::new(day, 2500, 17).is_err());
        assert!(Target::new(day, 2500, 1700).is_err());
    }

    // --- The day ---

    #[test]
    fn the_day_shows_what_was_logged_against_the_target() {
        let (b, l) = (breakfast(), lunch());
        let entries = [
            // Yesterday's lunch is not today's.
            entry(1, "2026-11-16 12:30", &l, 1.0),
            entry(2, "2026-11-17 12:40", &l, 1.0),
            entry(3, "2026-11-17 07:05", &b, 1.0),
        ];
        let targets = [Target::new(date("2026-11-02"), 2500, 170).unwrap()];
        let day = day(date("2026-11-17"), &[l.clone(), b.clone()], &entries, &targets, 35);

        assert_eq!((day.kcal, day.protein_g), (1103, 92.1));
        assert_eq!((day.kcal_left, day.protein_left_g), (Some(1397), Some(77.9)));
        assert_eq!(day.target.unwrap().since, date("2026-11-02"));
        // Dinner is unknown, not zero.
        assert_eq!(day.open_slots, vec![Slot::Dinner]);
        let rows: Vec<(&str, u32, f64)> = day.entries.iter().map(|e| (e.name.as_str(), e.kcal, e.protein_g)).collect();
        assert_eq!(rows, vec![("Usual breakfast", 542, 43.1), ("Batch lunch", 561, 49.0)]);
        let meals: Vec<(&str, u32, f64, u32)> =
            day.meals.iter().map(|m| (m.name.as_str(), m.kcal, m.protein_g, m.portions)).collect();
        assert_eq!(meals, vec![("Usual breakfast", 542, 43.1, 1), ("Batch lunch", 561, 49.0, 5)]);
        assert_eq!(day.meals[0].ingredients.len(), 3);
    }

    #[test]
    fn going_over_the_target_shows_as_a_negative_amount_left() {
        let l = lunch();
        let entries = [entry(1, "2026-11-17 12:40", &l, 5.0)];
        let targets = [Target::new(date("2026-11-02"), 2500, 170).unwrap()];
        let day = day(date("2026-11-17"), std::slice::from_ref(&l), &entries, &targets, 35);
        assert_eq!((day.kcal_left, day.protein_left_g), (Some(-306), Some(-75.0)));
    }

    #[test]
    fn without_a_target_nothing_is_left_or_over() {
        let b = breakfast();
        let day = day(date("2026-11-17"), std::slice::from_ref(&b), &[entry(1, "2026-11-17 07:05", &b, 1.0)], &[], 35);
        assert_eq!((day.target, day.kcal_left, day.protein_left_g), (None, None, None));
        assert_eq!(day.kcal, 542);
    }

    #[test]
    fn a_day_with_nothing_logged_has_every_main_meal_open() {
        let day = day(date("2026-11-17"), &[], &[], &[], 35);
        assert_eq!((day.kcal, day.protein_g), (0, 0.0));
        assert_eq!(day.open_slots, Slot::MAIN.to_vec());
        assert!(day.entries.is_empty());
        assert_eq!(day.streak.state, State::NotStarted);
    }

    #[test]
    fn two_meals_in_one_slot_both_count_and_a_snack_is_extra() {
        let (b, l) = (breakfast(), lunch());
        let bar = SavedMeal::new(Uuid::from_u128(3), "Protein bar", Slot::Snack, 1, vec![ingredient("Bar", 60.0, 350.0, 33.0)])
            .unwrap();
        let entries = [
            entry(1, "2026-11-17 07:05", &b, 1.0),
            entry(2, "2026-11-17 09:30", &b, 0.5),
            entry(3, "2026-11-17 15:00", &bar, 1.0),
        ];
        let day = day(date("2026-11-17"), &[b.clone(), l, bar], &entries, &[], 35);
        assert_eq!(day.kcal, 542 + 271 + 210);
        assert_eq!(day.entries.iter().map(|e| e.slot).collect::<Vec<_>>(), vec![Slot::Breakfast, Slot::Breakfast, Slot::Snack]);
        // The snack does not stand in for lunch or dinner.
        assert_eq!(day.open_slots, vec![Slot::Lunch, Slot::Dinner]);
    }

    #[test]
    fn the_meal_logged_most_recently_leads_its_slot() {
        let usual = breakfast();
        let eggs = SavedMeal::new(Uuid::from_u128(4), "Eggs on toast", Slot::Breakfast, 1, vec![ingredient("Eggs", 110.0, 143.0, 12.6)])
            .unwrap();
        let names = |entries: &[Entry]| -> Vec<String> {
            day(date("2026-11-17"), &[usual.clone(), eggs.clone(), lunch()], entries, &[], 35)
                .meals
                .into_iter()
                .map(|meal| meal.name)
                .collect()
        };
        // Never logged: by name.
        assert_eq!(names(&[]), ["Eggs on toast", "Usual breakfast", "Batch lunch"]);
        assert_eq!(
            names(&[entry(1, "2026-11-15 07:00", &eggs, 1.0), entry(2, "2026-11-16 07:00", &usual, 1.0)]),
            ["Usual breakfast", "Eggs on toast", "Batch lunch"]
        );
    }

    fn photo_entry(n: u128, at: &str, slot: Slot, figures: Figures, items: Vec<photo::Item>, oil_asked: bool) -> Entry {
        let amount = if figures == Figures::Known { photo::amount(&items, oil_asked, None) } else { Amount::default() };
        Entry {
            id: Uuid::from_u128(n),
            eaten_local: NaiveDateTime::parse_from_str(at, "%Y-%m-%d %H:%M").unwrap(),
            slot,
            meal_id: None,
            name: "stir fry, rice".into(),
            servings: 1.0,
            amount,
            figures,
            detail: Detail::Photo(PhotoDetail {
                note: "stir fry, rice".into(),
                has_photo: true,
                items,
                oil_asked,
                ..Default::default()
            }),
        }
    }

    fn rice_and_chicken() -> Vec<photo::Item> {
        let item = |name: &str, grams: f64, kcal: f64, protein: f64| photo::Item {
            name: name.into(),
            grams_seen: grams,
            kcal_seen: kcal,
            protein_g_seen: protein,
            grams,
        };
        vec![item("Rice", 200.0, 260.0, 5.4), item("Chicken", 120.0, 198.0, 27.6)]
    }

    #[test]
    fn the_day_keeps_measured_and_estimated_apart() {
        let b = breakfast();
        let bar = Entry {
            id: Uuid::from_u128(3),
            eaten_local: NaiveDateTime::parse_from_str("2026-11-17 15:00", "%Y-%m-%d %H:%M").unwrap(),
            slot: Slot::Snack,
            meal_id: None,
            name: "Protein bar".into(),
            servings: 1.0,
            amount: Amount { kcal: 210, protein_dg: 198 },
            figures: Figures::Known,
            detail: Detail::Barcode { code: "96385074".into(), grams: 60.0 },
        };
        let entries = [
            entry(1, "2026-11-17 07:05", &b, 1.0),
            photo_entry(2, "2026-11-17 19:00", Slot::Dinner, Figures::Known, rice_and_chicken(), true),
            bar,
        ];
        let targets = [Target::new(date("2026-11-02"), 2500, 170).unwrap()];
        let day = day(date("2026-11-17"), std::slice::from_ref(&b), &entries, &targets, 35);

        // Breakfast and the bar are measured; dinner, with some oil
        // counted until the owner answers, is estimated.
        assert_eq!((day.kcal_measured, day.protein_measured_g), (542 + 210, 62.9));
        assert_eq!((day.kcal_estimated, day.protein_estimated_g), (578, 33.0));
        assert_eq!((day.kcal, day.protein_g), (1330, 95.9));
        assert_eq!(day.kcal_left, Some(2500 - 1330));
        // Only the estimated part widens the day.
        assert_eq!((day.kcal_low, day.kcal_high), (752 + 380, 752 + 780));
        assert_eq!(day.unknown, 0);
        assert_eq!(day.open_slots, vec![Slot::Lunch]);

        let dinner = &day.entries[1];
        assert_eq!((dinner.source, dinner.figures, dinner.estimated), (Source::Photo, Figures::Known, true));
        assert_eq!((dinner.kcal, dinner.kcal_low, dinner.kcal_high), (578, Some(380), Some(780)));
        let photo = dinner.photo.as_ref().unwrap();
        assert_eq!((photo.oil_asked, photo.oil, photo.oil_counted, photo.oil_kcal), (true, None, Oil::Some, 120));
        assert_eq!(photo.items[1].name, "Chicken");
        assert_eq!((photo.items[1].kcal, photo.items[1].protein_g), (198, 27.6));
        let bar = &day.entries[2];
        assert_eq!((bar.source, bar.estimated, bar.kcal_low), (Source::Barcode, false, None));
        assert_eq!(bar.barcode, Some(BarcodeView { code: "96385074".into(), grams: 60.0 }));
        assert_eq!((day.entries[0].source, day.entries[0].photo.is_none()), (Source::Saved, true));
    }

    #[test]
    fn a_meal_still_being_estimated_is_logged_but_unknown_not_zero() {
        let entries = [photo_entry(1, "2026-11-17 12:30", Slot::Lunch, Figures::Estimating, vec![], false)];
        let day = day(date("2026-11-17"), &[], &entries, &[], 35);
        assert_eq!((day.kcal, day.unknown), (0, 1));
        // Lunch was logged: it is not open, and the day counts for the streak.
        assert_eq!(day.open_slots, vec![Slot::Breakfast, Slot::Dinner]);
        assert_eq!((day.streak.state, day.streak.logged_today), (State::Kept, true));
        let lunch = &day.entries[0];
        assert_eq!((lunch.figures, lunch.kcal_low), (Figures::Estimating, None));
    }

    #[test]
    fn typed_figures_have_no_range() {
        let mut typed = photo_entry(1, "2026-11-17 19:00", Slot::Dinner, Figures::Known, rice_and_chicken(), true);
        typed.amount = Amount { kcal: 650, protein_dg: 400 };
        if let Detail::Photo(detail) = &mut typed.detail {
            detail.typed = true;
        }
        let day = day(date("2026-11-17"), &[], &[typed], &[], 35);
        assert_eq!((day.entries[0].kcal, day.entries[0].kcal_low), (650, None));
        assert_eq!(day.entries[0].photo.as_ref().unwrap().oil_kcal, 0);
        // Still estimated: typed from a menu or a guess, not weighed.
        assert_eq!(day.kcal_estimated, 650);
    }

    // --- The logging streak ---

    #[test]
    fn days_logged_in_a_row_are_counted_and_today_counts_once_logged() {
        let s = streak(date("2026-11-17"), &logged(&["2026-11-14", "2026-11-15", "2026-11-16"]));
        assert_eq!((s.days, s.state, s.logged_today), (3, State::OnTrack, false));
        assert_eq!(shown(&s), vec![Before, Before, Before, Kept, Kept, Kept, Open]);
        assert_eq!(s.last_days[0].date, date("2026-11-11"));
        assert_eq!(s.last_days[6].date, date("2026-11-17"));

        let s = streak(date("2026-11-17"), &logged(&["2026-11-14", "2026-11-15", "2026-11-16", "2026-11-17"]));
        assert_eq!((s.days, s.state, s.logged_today), (4, State::Kept, true));
        assert_eq!(shown(&s)[6], Kept);
    }

    #[test]
    fn the_first_day_ever_logged_starts_a_streak() {
        let none = streak(date("2026-11-17"), &logged(&[]));
        assert_eq!((none.days, none.state, none.previous_best), (0, State::NotStarted, 0));
        assert_eq!(shown(&none), vec![Before, Before, Before, Before, Before, Before, Open]);

        let first = streak(date("2026-11-17"), &logged(&["2026-11-17"]));
        assert_eq!((first.days, first.state), (1, State::Kept));
    }

    #[test]
    fn one_missed_day_is_recovered_by_logging_the_next() {
        let days = ["2026-11-13", "2026-11-14", "2026-11-15"];
        // Monday the 16th was missed; it is now Tuesday.
        let open = streak(date("2026-11-17"), &logged(&days));
        assert_eq!((open.days, open.state), (3, State::Recovering));
        assert_eq!(shown(&open), vec![Before, Before, Kept, Kept, Kept, Awaiting, Open]);

        let mut with_today = days.to_vec();
        with_today.push("2026-11-17");
        let recovered = streak(date("2026-11-17"), &logged(&with_today));
        // The missed day never adds to the count.
        assert_eq!((recovered.days, recovered.state), (4, State::Kept));
        assert_eq!(shown(&recovered), vec![Before, Before, Kept, Kept, Kept, Recovered, Kept]);
    }

    #[test]
    fn two_missed_days_in_a_row_end_the_streak_and_keep_the_best() {
        let s = streak(date("2026-11-17"), &logged(&["2026-11-11", "2026-11-12", "2026-11-13", "2026-11-14"]));
        assert_eq!((s.days, s.state, s.previous_best), (0, State::NotStarted, 4));
        assert_eq!(shown(&s), vec![Kept, Kept, Kept, Kept, Missed, Missed, Open]);

        // Logging again starts a new one.
        let again =
            streak(date("2026-11-17"), &logged(&["2026-11-11", "2026-11-12", "2026-11-13", "2026-11-14", "2026-11-17"]));
        assert_eq!((again.days, again.state, again.previous_best), (1, State::Kept, 4));
    }

    #[test]
    fn a_long_streak_shows_only_its_last_seven_days() {
        let all: BTreeSet<NaiveDate> = date("2026-09-01").iter_days().take_while(|day| *day <= date("2026-11-17")).collect();
        let s = streak(date("2026-11-17"), &all);
        assert_eq!((s.days, s.state), (78, State::Kept));
        assert_eq!(shown(&s), vec![Kept; 7]);
    }

    #[test]
    fn a_meal_dated_ahead_of_today_does_not_count_yet() {
        // A phone whose clock is a day ahead.
        let s = streak(date("2026-11-17"), &logged(&["2026-11-18"]));
        assert_eq!((s.days, s.state, s.logged_today), (0, State::NotStarted, false));
    }

    // --- Prompts ---

    #[test]
    fn a_live_streak_with_nothing_logged_today_is_prompted_for() {
        let on_track = streak(date("2026-11-17"), &logged(&["2026-11-14", "2026-11-15", "2026-11-16"]));
        let p = prompt(&on_track).unwrap();
        assert_eq!(p, Prompt { days: 3, recovering: false });
        assert_eq!(p.title(), "Fuel: nothing logged today");
        assert_eq!(p.body(), "Log one meal to keep your 3-day streak.");

        let recovering = streak(date("2026-11-17"), &logged(&["2026-11-14", "2026-11-15"]));
        let p = prompt(&recovering).unwrap();
        assert_eq!(p.title(), "Fuel: yesterday was missed");
        assert_eq!(p.body(), "One meal logged today recovers your 2-day streak. Nothing to make up.");
    }

    #[test]
    fn nothing_is_prompted_once_today_is_logged_or_with_no_streak_alive() {
        let done = streak(date("2026-11-17"), &logged(&["2026-11-16", "2026-11-17"]));
        assert_eq!(prompt(&done), None);
        let ended = streak(date("2026-11-17"), &logged(&["2026-11-13", "2026-11-14"]));
        assert_eq!(prompt(&ended), None);
        assert_eq!(prompt(&streak(date("2026-11-17"), &logged(&[]))), None);
    }
}
