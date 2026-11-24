//! Goals: where the owner means to get, by a date, on a figure lyfe
//! already reads.
//!
//! Pure rules, no I/O. A goal is a destination and a date put on a
//! reading lyfe keeps anyway, so it needs nothing typed to move: a figure
//! to reach (the best breath hold, the weight trend, the body-fat
//! estimate) or a total to build up (minutes of study, on one subject or
//! all); or a result to get, an exam (see `exam`), which has no pace and no
//! percentage. A figure or a total is shown against its pace, the straight line from where it
//! started to its figure on its date. Being behind is an amount, with
//! what would now be needed; there is no failed state. Three goals are
//! active at once; the rest are parked, and none is ever deleted.

use chrono::NaiveDate;
use serde::Serialize;
use uuid::Uuid;

use super::exam::{self, Exam, ExamView};
use super::study;

/// Goals that can be active at once.
pub const ACTIVE_LIMIT: usize = 3;

/// The longest a goal can run, from today.
pub const LONGEST_DAYS: i64 = 10 * 366;

/// What shape a goal is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Shape {
    /// A figure to reach, up or down.
    Reach,
    /// A total to build up from nothing.
    Total,
    /// A result to get: an exam, passed or not.
    Result,
}

/// What a goal reads.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Reading {
    /// The longest breath hold ever recorded, in seconds.
    BreathHold,
    /// The seven-day average weight, in grams.
    Weight,
    /// The latest tape-measure estimate of body fat, in percent.
    BodyFat,
    /// Minutes of study since the goal was set, on one subject or all.
    StudyMinutes,
    /// An exam: its practice scores, and in the end its result.
    Exam,
}

impl Reading {
    pub fn parse(text: &str) -> Option<Reading> {
        match text {
            "breath_hold" => Some(Reading::BreathHold),
            "weight" => Some(Reading::Weight),
            "body_fat" => Some(Reading::BodyFat),
            "study_minutes" => Some(Reading::StudyMinutes),
            "exam" => Some(Reading::Exam),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Reading::BreathHold => "breath_hold",
            Reading::Weight => "weight",
            Reading::BodyFat => "body_fat",
            Reading::StudyMinutes => "study_minutes",
            Reading::Exam => "exam",
        }
    }

    pub fn shape(self) -> Shape {
        match self {
            Reading::StudyMinutes => Shape::Total,
            Reading::Exam => Shape::Result,
            _ => Shape::Reach,
        }
    }

    /// The routine that moves it, as the apps name it.
    pub fn moved_by(self) -> &'static str {
        match self {
            Reading::BreathHold => "breath",
            Reading::Weight | Reading::BodyFat => "gym_and_food",
            Reading::StudyMinutes | Reading::Exam => "study",
        }
    }

    /// The figures a goal on it can be set to, in its own unit.
    pub fn sensible(self) -> std::ops::RangeInclusive<f64> {
        match self {
            Reading::BreathHold => 10.0..=1200.0,
            Reading::Weight => 20_000.0..=400_000.0,
            Reading::BodyFat => 3.0..=60.0,
            Reading::StudyMinutes => 60.0..=200_000.0,
            Reading::Exam => 1.0..=10_000.0,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Active,
    Parked,
    Reached,
    Dropped,
}

impl Status {
    pub fn parse(text: &str) -> Option<Status> {
        match text {
            "active" => Some(Status::Active),
            "parked" => Some(Status::Parked),
            "reached" => Some(Status::Reached),
            "dropped" => Some(Status::Dropped),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Status::Active => "active",
            Status::Parked => "parked",
            Status::Reached => "reached",
            Status::Dropped => "dropped",
        }
    }

    /// Whether a goal in it has ended.
    pub fn ended(self) -> bool {
        matches!(self, Status::Reached | Status::Dropped)
    }
}

/// A change to a goal, as recorded.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Change {
    pub on: NaiveDate,
    /// `target`, `due`, `title` or `status`.
    pub what: String,
    pub was: String,
    pub now: String,
}

/// A goal as stored.
#[derive(Debug, Clone, PartialEq)]
pub struct Goal {
    pub id: Uuid,
    pub title: String,
    pub reading: Reading,
    /// For study: the subject it is on, or every subject when none.
    pub subject_id: Option<Uuid>,
    pub subject: Option<String>,
    pub start_on: NaiveDate,
    /// Where the reading stood when it was set; zero for a total.
    pub start_value: f64,
    pub target_value: f64,
    pub due_on: NaiveDate,
    pub status: Status,
    pub ended_on: Option<NaiveDate>,
    pub note: Option<String>,
    /// Oldest first.
    pub changes: Vec<Change>,
    /// For an exam: what it is held to, its practice and its result.
    pub exam: Option<Exam>,
}

/// What lyfe reads now, for every goal at once.
pub struct Readings<'a> {
    pub weight_g: Option<f64>,
    pub body_fat: Option<f64>,
    pub best_hold_s: Option<f64>,
    pub study: &'a [study::Session],
}

impl Readings<'_> {
    /// Where a goal's reading stands now; `None` when lyfe has none.
    pub fn current(&self, goal: &Goal) -> Option<f64> {
        match goal.reading {
            Reading::Weight => self.weight_g,
            Reading::BodyFat => self.body_fat,
            Reading::BreathHold => self.best_hold_s,
            Reading::StudyMinutes => Some(self.study_minutes(goal)),
            // An exam has no figure to stand against a line.
            Reading::Exam => None,
        }
    }

    /// Minutes of study since a goal was set, on its subject or all.
    pub fn study_minutes(&self, goal: &Goal) -> f64 {
        self.study
            .iter()
            .filter(|s| s.date() >= goal.start_on)
            .filter(|s| goal.subject_id.is_none_or(|subject| s.subject_id == subject))
            .map(|s| f64::from(s.active_s) / 60.0)
            .sum::<f64>()
            .floor()
    }

    /// Where a new goal on `reading` would start from today.
    pub fn start(&self, reading: Reading) -> Option<f64> {
        match reading {
            Reading::Weight => self.weight_g,
            Reading::BodyFat => self.body_fat,
            Reading::BreathHold => Some(self.best_hold_s.unwrap_or(0.0)),
            Reading::StudyMinutes | Reading::Exam => Some(0.0),
        }
    }
}

/// Where a goal stands against its pace.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct Standing {
    pub current: f64,
    /// The share of the way from start to figure, 0 to 1.
    pub progress: f64,
    /// Where the straight line from start to figure stands today.
    pub pace_value: f64,
    /// How far ahead of the line, in the reading's unit; below zero is
    /// behind.
    pub ahead_by: f64,
    /// What would now be needed each week to get there by the date, in the
    /// reading's unit; missing once reached or past the date.
    pub needed_per_week: Option<f64>,
    /// What the line asks for each week, from start to date.
    pub pace_per_week: f64,
    pub reached: bool,
}

/// Where a goal stands with its reading at `current` on `today`.
pub fn standing(goal: &Goal, current: f64, today: NaiveDate) -> Standing {
    let span = goal.target_value - goal.start_value;
    let direction = if span < 0.0 { -1.0 } else { 1.0 };
    let total_days = (goal.due_on - goal.start_on).num_days().max(1) as f64;
    let elapsed = ((today - goal.start_on).num_days() as f64).clamp(0.0, total_days);
    let pace_value = goal.start_value + span * elapsed / total_days;
    let reached = (current - goal.target_value) * direction >= 0.0;
    let days_left = (goal.due_on - today).num_days();
    let progress = if span == 0.0 { 1.0 } else { ((current - goal.start_value) / span).clamp(0.0, 1.0) };
    Standing {
        current,
        progress,
        pace_value,
        ahead_by: (current - pace_value) * direction,
        needed_per_week: (!reached && days_left > 0)
            .then(|| (goal.target_value - current) * direction / days_left as f64 * 7.0),
        pace_per_week: span.abs() / total_days * 7.0,
        reached,
    }
}

/// A goal as the apps show it.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct GoalView {
    pub id: Uuid,
    pub title: String,
    pub shape: Shape,
    pub reading: Reading,
    pub subject_id: Option<Uuid>,
    pub subject: Option<String>,
    pub start_on: NaiveDate,
    pub start_value: f64,
    pub target_value: f64,
    pub due_on: NaiveDate,
    pub status: Status,
    pub ended_on: Option<NaiveDate>,
    pub note: Option<String>,
    /// Days from today to the date; below zero once past it.
    pub days_left: i64,
    pub moved_by: &'static str,
    /// Missing while lyfe has no reading for it, and for an exam.
    pub standing: Option<Standing>,
    pub changes: Vec<Change>,
    /// For an exam.
    pub exam: Option<ExamView>,
}

/// Every goal as the apps show it.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct GoalsView {
    /// Goals that can be active at once.
    pub limit: usize,
    /// Active goals by date, then parked ones by date, then ended ones,
    /// the most recent first.
    pub goals: Vec<GoalView>,
}

pub fn view(goals: &[Goal], readings: &Readings, today: NaiveDate) -> GoalsView {
    let mut views: Vec<GoalView> = goals
        .iter()
        .map(|goal| GoalView {
            id: goal.id,
            title: goal.title.clone(),
            shape: goal.reading.shape(),
            reading: goal.reading,
            subject_id: goal.subject_id,
            subject: goal.subject.clone(),
            start_on: goal.start_on,
            start_value: goal.start_value,
            target_value: goal.target_value,
            due_on: goal.due_on,
            status: goal.status,
            ended_on: goal.ended_on,
            note: goal.note.clone(),
            days_left: (goal.due_on - today).num_days(),
            moved_by: goal.reading.moved_by(),
            standing: readings.current(goal).map(|current| standing(goal, current, today)),
            changes: goal.changes.clone(),
            exam: goal.exam.as_ref().map(|exam| {
                // Only the exam's own subject counts toward it.
                let minutes = if goal.subject_id.is_some() { readings.study_minutes(goal) } else { 0.0 };
                exam::view(exam, minutes as u32)
            }),
        })
        .collect();
    let rank = |status: Status| match status {
        Status::Active => 0,
        Status::Parked => 1,
        Status::Reached | Status::Dropped => 2,
    };
    views.sort_by(|a, b| {
        rank(a.status).cmp(&rank(b.status)).then_with(|| {
            if a.status.ended() {
                b.ended_on.cmp(&a.ended_on)
            } else {
                a.due_on.cmp(&b.due_on)
            }
        })
    });
    GoalsView { limit: ACTIVE_LIMIT, goals: views }
}

/// A goal's title as it is kept: trimmed, runs of spaces made one. `None`
/// when nothing is left, it is too long, or it has control characters.
pub fn title(text: &str) -> Option<String> {
    let title = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let fits = !title.is_empty() && title.chars().count() <= 80 && !title.chars().any(char::is_control);
    fits.then_some(title)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::NaiveDateTime;

    fn date(s: &str) -> NaiveDate {
        s.parse().unwrap()
    }

    fn goal(reading: Reading, start: f64, target: f64, from: &str, due: &str) -> Goal {
        Goal {
            id: Uuid::from_u128(1),
            title: "A goal".into(),
            reading,
            subject_id: None,
            subject: None,
            start_on: date(from),
            start_value: start,
            target_value: target,
            due_on: date(due),
            status: Status::Active,
            ended_on: None,
            note: None,
            changes: vec![],
            exam: None,
        }
    }

    #[test]
    fn a_figure_to_reach_is_set_against_the_straight_line_to_it() {
        // From a 2:20 hold to 3:00 over 40 weeks: 1 s a week.
        let hold = goal(Reading::BreathHold, 140.0, 180.0, "2026-11-02", "2027-08-09");
        let ten_weeks = date("2027-01-11");
        let behind = standing(&hold, 146.0, ten_weeks);
        assert_eq!(behind.pace_value, 150.0);
        assert_eq!(behind.ahead_by, -4.0);
        assert_eq!(behind.progress, 0.15);
        assert_eq!(behind.pace_per_week, 1.0);
        // 34 s to go in 30 weeks.
        assert!((behind.needed_per_week.unwrap() - 34.0 / 30.0).abs() < 1e-9);
        assert!(!behind.reached);
        let ahead = standing(&hold, 155.0, ten_weeks);
        assert_eq!(ahead.ahead_by, 5.0);
        let there = standing(&hold, 181.0, ten_weeks);
        assert!(there.reached);
        assert_eq!((there.progress, there.needed_per_week), (1.0, None));
    }

    #[test]
    fn a_figure_to_bring_down_counts_ahead_as_lower() {
        let fat = goal(Reading::BodyFat, 21.0, 17.0, "2026-11-02", "2027-05-03");
        let halfway = date("2027-02-01");
        let s = standing(&fat, 19.5, halfway);
        assert!((s.pace_value - 19.0).abs() < 0.03);
        assert!(s.ahead_by < 0.0, "{s:?}");
        assert!((s.progress - 0.375).abs() < 1e-9);
        assert!(standing(&fat, 16.9, halfway).reached);
        assert!(!standing(&fat, 17.1, halfway).reached);
    }

    #[test]
    fn past_its_date_the_line_stays_at_the_figure_and_nothing_is_asked_per_week() {
        let hold = goal(Reading::BreathHold, 140.0, 180.0, "2026-11-02", "2027-08-09");
        let after = standing(&hold, 170.0, date("2027-09-01"));
        assert_eq!(after.pace_value, 180.0);
        assert_eq!(after.ahead_by, -10.0);
        assert_eq!(after.needed_per_week, None);
        // Before it starts, the line is where it started.
        assert_eq!(standing(&hold, 140.0, date("2026-10-01")).pace_value, 140.0);
    }

    fn session(n: u128, day: &str, minutes: u32, subject: u128) -> study::Session {
        study::Session {
            id: Uuid::from_u128(n),
            started_local: NaiveDateTime::parse_from_str(&format!("{day} 19:00"), "%Y-%m-%d %H:%M").unwrap(),
            active_s: minutes * 60,
            subject_id: Uuid::from_u128(subject),
            subject: "Subject".into(),
            kind: study::Kind::Questions,
            answered: None,
            right_first: None,
            explain_back: None,
        }
    }

    #[test]
    fn a_total_adds_up_study_since_it_was_set_on_its_subject_or_all() {
        let sessions = [
            session(1, "2026-11-01", 90, 7),
            session(2, "2026-11-02", 90, 7),
            session(3, "2026-11-03", 50, 8),
            // A short one still adds its minutes.
            session(4, "2026-11-04", 20, 7),
        ];
        let readings = Readings { weight_g: None, body_fat: None, best_hold_s: None, study: &sessions };
        let mut hours = goal(Reading::StudyMinutes, 0.0, 80.0 * 60.0, "2026-11-02", "2027-01-04");
        assert_eq!(readings.current(&hours), Some(160.0));
        hours.subject_id = Some(Uuid::from_u128(7));
        assert_eq!(readings.current(&hours), Some(110.0));
        assert_eq!(readings.start(Reading::StudyMinutes), Some(0.0));
        assert_eq!(readings.start(Reading::Weight), None);
        assert_eq!(readings.start(Reading::BreathHold), Some(0.0));
    }

    #[test]
    fn goals_come_active_then_parked_then_ended_with_their_standing() {
        let readings = Readings { weight_g: Some(81_000.0), body_fat: None, best_hold_s: Some(140.0), study: &[] };
        let mut parked = goal(Reading::BreathHold, 120.0, 180.0, "2026-11-02", "2027-01-04");
        parked.id = Uuid::from_u128(2);
        parked.status = Status::Parked;
        let mut later = goal(Reading::Weight, 84_000.0, 78_000.0, "2026-11-02", "2027-06-07");
        later.id = Uuid::from_u128(3);
        let sooner = goal(Reading::BodyFat, 21.0, 17.0, "2026-11-02", "2027-03-01");
        let mut ended = goal(Reading::BreathHold, 100.0, 120.0, "2026-09-07", "2026-11-02");
        ended.id = Uuid::from_u128(4);
        ended.status = Status::Reached;
        ended.ended_on = Some(date("2026-10-20"));
        let view = view(&[parked, ended, later, sooner], &readings, date("2026-11-24"));
        assert_eq!(view.limit, 3);
        let order: Vec<u128> = view.goals.iter().map(|g| g.id.as_u128()).collect();
        assert_eq!(order, [1, 3, 2, 4]);
        // No tape measurement yet: no standing, not zero.
        assert_eq!(view.goals[0].standing, None);
        assert_eq!(view.goals[1].standing.unwrap().current, 81_000.0);
        assert_eq!(view.goals[1].moved_by, "gym_and_food");
        assert_eq!(view.goals[1].days_left, 195);
    }

    #[test]
    fn titles_are_tidied_and_refused_when_empty_or_odd() {
        assert_eq!(title("  Three-minute   hold "), Some("Three-minute hold".into()));
        assert_eq!(title(" "), None);
        assert_eq!(title(&"x".repeat(81)), None);
        assert_eq!(title("a\u{0}b"), None);
    }
}
