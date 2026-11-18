//! What counts as a gym session, and which week it belongs to.
//!
//! Pure rules, no I/O. A gym week runs Monday to Sunday in the wall-clock
//! time the activity was recorded in. A day counts at most once, however
//! many activities were recorded on it, so a warm-up saved separately from
//! the main session does not fill two squares.

use chrono::{Datelike, Duration, NaiveDate, NaiveDateTime};
use serde::Serialize;

use super::streak::{self, Current, Mark, State};

/// Sessions needed for a week to count toward the gym streak.
pub const WEEKLY_TARGET: u32 = 4;

#[derive(Debug, Clone)]
pub struct GymRules {
    /// Garmin activity type keys that count as a gym session.
    pub counted_types: Vec<String>,
    /// Activities shorter than this are ignored (accidental starts).
    pub min_duration_s: f64,
}

impl GymRules {
    pub const DEFAULT_TYPES: &'static str = "strength_training,indoor_cardio,hiit,lap_swimming,\
        open_water_swimming,running,treadmill_running,cycling,indoor_cycling,elliptical,\
        stair_climbing,indoor_rowing";
    pub const DEFAULT_MIN_MINUTES: u32 = 15;

    pub fn counts(&self, activity: &Activity) -> bool {
        activity.duration_s >= self.min_duration_s
            && self.counted_types.iter().any(|t| t == &activity.type_key)
    }
}

/// The part of a recorded activity the gym rules look at.
#[derive(Debug, Clone, PartialEq)]
pub struct Activity {
    pub activity_id: i64,
    pub type_key: String,
    pub name: Option<String>,
    pub start_local: NaiveDateTime,
    pub duration_s: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Week {
    pub iso_year: i32,
    pub iso_week: u32,
    /// Monday.
    pub starts_on: NaiveDate,
    /// Sunday.
    pub ends_on: NaiveDate,
}

impl Week {
    pub fn containing(date: NaiveDate) -> Week {
        let iso = date.iso_week();
        let starts_on = date - Duration::days(date.weekday().num_days_from_monday() as i64);
        Week {
            iso_year: iso.year(),
            iso_week: iso.week(),
            starts_on,
            ends_on: starts_on + Duration::days(6),
        }
    }

    pub fn contains(&self, date: NaiveDate) -> bool {
        date >= self.starts_on && date <= self.ends_on
    }

    pub fn next(&self) -> Week {
        Week::containing(self.starts_on + Duration::days(7))
    }
}

/// A day on which a gym session happened.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct GymSession {
    pub date: NaiveDate,
    pub activity_id: i64,
    pub activity_type: String,
    pub name: Option<String>,
    pub duration_min: u32,
}

/// The gym sessions of one week: at most one per day, in date order. When
/// several qualifying activities share a day, the longest represents it.
pub fn sessions_in_week(rules: &GymRules, week: Week, activities: &[Activity]) -> Vec<GymSession> {
    let mut best_per_day: Vec<&Activity> = Vec::new();
    for activity in activities {
        let date = activity.start_local.date();
        if !week.contains(date) || !rules.counts(activity) {
            continue;
        }
        match best_per_day
            .iter_mut()
            .find(|a| a.start_local.date() == date)
        {
            Some(existing) => {
                if activity.duration_s > existing.duration_s {
                    *existing = activity;
                }
            }
            None => best_per_day.push(activity),
        }
    }
    best_per_day.sort_by_key(|a| a.start_local);
    best_per_day
        .into_iter()
        .map(|a| GymSession {
            date: a.start_local.date(),
            activity_id: a.activity_id,
            activity_type: a.type_key.clone(),
            name: a.name.clone(),
            duration_min: (a.duration_s / 60.0).round() as u32,
        })
        .collect()
}

/// How many finished weeks the Home screen is given.
pub const RECENT_WEEKS: usize = 12;

/// A finished week and how it turned out.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct PastWeek {
    pub iso_year: i32,
    pub iso_week: u32,
    pub starts_on: NaiveDate,
    /// Days that week with a session.
    pub done: u32,
    pub mark: Mark,
}

/// The gym streak as of today.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct GymStreak {
    /// Weeks in a row with the target met, counting this week once it is.
    pub weeks: u32,
    pub state: State,
    /// The longest streak that has ended. Zero when none has.
    pub previous_best: u32,
    /// Sessions this week still needs.
    pub remaining: u32,
    /// Days from today to Sunday that have no session yet. A day counts
    /// once, so this is the most sessions the week can still gain.
    pub open_days: u32,
    /// False once the week can no longer reach the target.
    pub reachable: bool,
    /// The most recent finished weeks, oldest first.
    pub recent: Vec<PastWeek>,
}

/// Every week from the first one that met the target up to today's, with
/// the days that had a session in each. Weeks before the first kept week
/// say nothing about a streak and are left out.
pub fn weeks_until(rules: &GymRules, today: NaiveDate, activities: &[Activity]) -> Vec<(Week, u32)> {
    let all = all_weeks_until(rules, today, activities);
    let first_kept = all
        .iter()
        .position(|(_, done)| *done >= WEEKLY_TARGET)
        .unwrap_or(all.len() - 1);
    all[first_kept..].to_vec()
}

/// Every week from the first recorded session up to today's, with the days
/// that had a session in each.
pub fn all_weeks_until(rules: &GymRules, today: NaiveDate, activities: &[Activity]) -> Vec<(Week, u32)> {
    let this_week = Week::containing(today);
    let Some(earliest) = activities
        .iter()
        .filter(|a| rules.counts(a))
        .map(|a| a.start_local.date())
        .min()
    else {
        return vec![(this_week, 0)];
    };
    let mut weeks = Vec::new();
    let mut week = Week::containing(earliest.min(today));
    loop {
        weeks.push((week, sessions_in_week(rules, week, activities).len() as u32));
        if week == this_week {
            return weeks;
        }
        week = week.next();
    }
}

/// The streak rules applied to the recorded activities.
pub fn streak(rules: &GymRules, today: NaiveDate, activities: &[Activity]) -> GymStreak {
    let this_week = Week::containing(today);
    let weeks = weeks_until(rules, today, activities);
    let (finished, current) = weeks.split_at(weeks.len() - 1);
    let done = current[0].1;

    let kept: Vec<bool> = finished.iter().map(|(_, done)| *done >= WEEKLY_TARGET).collect();
    let now = if done >= WEEKLY_TARGET { Current::Kept } else { Current::Open };
    let standing = streak::standing(&kept, now);

    let session_days: Vec<NaiveDate> = sessions_in_week(rules, this_week, activities)
        .iter()
        .map(|s| s.date)
        .collect();
    let open_days = today
        .iter_days()
        .take_while(|day| *day <= this_week.ends_on)
        .filter(|day| !session_days.contains(day))
        .count() as u32;
    let remaining = WEEKLY_TARGET.saturating_sub(done);

    let skip = finished.len().saturating_sub(RECENT_WEEKS);
    let recent = finished
        .iter()
        .zip(&standing.marks)
        .skip(skip)
        .map(|((week, done), mark)| PastWeek {
            iso_year: week.iso_year,
            iso_week: week.iso_week,
            starts_on: week.starts_on,
            done: *done,
            mark: *mark,
        })
        .collect();

    GymStreak {
        weeks: standing.length,
        state: standing.state,
        previous_best: standing.previous_best,
        remaining,
        open_days,
        reachable: remaining <= open_days,
        recent,
    }
}

/// Something worth interrupting the owner for. Prompts exist only when a
/// streak is at stake and today is a day to act on it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Prompt {
    /// Every day left this week is needed, starting today.
    TrainToday { remaining: u32, weeks: u32, recovering: bool },
    /// Last week was missed and this week recovers it.
    RecoveryOpen { weeks: u32 },
}

impl Prompt {
    /// Names the prompt in the record of what was sent.
    pub fn kind(&self) -> &'static str {
        match self {
            Prompt::TrainToday { .. } => "gym_train_today",
            Prompt::RecoveryOpen { .. } => "gym_recovery_open",
        }
    }

    /// The period a prompt is sent at most once in: the day for "train
    /// today", the week (its Monday) for "recovery open".
    pub fn period(&self, today: NaiveDate) -> NaiveDate {
        match self {
            Prompt::TrainToday { .. } => today,
            Prompt::RecoveryOpen { .. } => Week::containing(today).starts_on,
        }
    }

    pub fn title(&self, today: NaiveDate) -> String {
        match self {
            Prompt::TrainToday { remaining: 1, .. } if today.weekday() == chrono::Weekday::Sun => {
                "Gym: 1 more today".to_string()
            }
            Prompt::TrainToday { remaining, .. } => format!("Gym: {remaining} more by Sunday"),
            Prompt::RecoveryOpen { .. } => "Gym: last week was missed".to_string(),
        }
    }

    pub fn body(&self) -> String {
        let streak = |weeks: u32| format!("{weeks}-week streak");
        match self {
            Prompt::TrainToday { remaining, weeks, recovering } => {
                let verb = if *recovering { "recover" } else { "keep" };
                let every_day = if *remaining > 1 { " It takes every day left this week." } else { "" };
                format!("Train today to {verb} your {}.{every_day}", streak(*weeks))
            }
            Prompt::RecoveryOpen { weeks } => format!(
                "{WEEKLY_TARGET} sessions by Sunday recovers your {}. Nothing to make up.",
                streak(*weeks)
            ),
        }
    }
}

/// The prompt today calls for, if any. `trained_today` is whether today
/// already has a session.
pub fn prompt(streak: &GymStreak, trained_today: bool) -> Option<Prompt> {
    let recovering = match streak.state {
        State::OnTrack => false,
        State::Recovering => true,
        // Nothing at stake, or nothing left to do.
        State::NotStarted | State::Kept => return None,
    };
    if !streak.reachable {
        // Out of reach this week: there is nothing to do about it today.
        return None;
    }
    if !trained_today && streak.remaining == streak.open_days {
        return Some(Prompt::TrainToday { remaining: streak.remaining, weeks: streak.weeks, recovering });
    }
    recovering.then_some(Prompt::RecoveryOpen { weeks: streak.weeks })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rules() -> GymRules {
        GymRules {
            counted_types: vec!["strength_training".into(), "lap_swimming".into(), "indoor_cycling".into()],
            min_duration_s: 15.0 * 60.0,
        }
    }

    fn activity(id: i64, type_key: &str, start: &str, minutes: f64) -> Activity {
        Activity {
            activity_id: id,
            type_key: type_key.into(),
            name: None,
            start_local: NaiveDateTime::parse_from_str(start, "%Y-%m-%d %H:%M:%S").unwrap(),
            duration_s: minutes * 60.0,
        }
    }

    fn date(s: &str) -> NaiveDate {
        s.parse().unwrap()
    }

    #[test]
    fn week_runs_monday_to_sunday() {
        // Tuesday 17 November 2026 is in ISO week 47.
        let week = Week::containing(date("2026-11-17"));
        assert_eq!(week.iso_week, 47);
        assert_eq!(week.iso_year, 2026);
        assert_eq!(week.starts_on, date("2026-11-16"));
        assert_eq!(week.ends_on, date("2026-11-22"));
        assert_eq!(Week::containing(date("2026-11-16")), week);
        assert_eq!(Week::containing(date("2026-11-22")), week);
        assert_ne!(Week::containing(date("2026-11-23")), week);
    }

    #[test]
    fn week_at_year_boundary_uses_iso_year() {
        // Friday 1 January 2027 belongs to ISO week 53 of 2026.
        let week = Week::containing(date("2027-01-01"));
        assert_eq!((week.iso_year, week.iso_week), (2026, 53));
        assert_eq!(week.starts_on, date("2026-12-28"));
        assert_eq!(week.ends_on, date("2027-01-03"));
    }

    #[test]
    fn counts_qualifying_sessions_in_date_order() {
        let week = Week::containing(date("2026-11-17"));
        let activities = vec![
            activity(3, "lap_swimming", "2026-11-19 18:00:00", 40.0),
            activity(1, "strength_training", "2026-11-16 06:10:00", 58.0),
            activity(2, "strength_training", "2026-11-17 06:05:00", 61.0),
        ];
        let sessions = sessions_in_week(&rules(), week, &activities);
        assert_eq!(sessions.iter().map(|s| s.activity_id).collect::<Vec<_>>(), vec![1, 2, 3]);
        assert_eq!(sessions[0].duration_min, 58);
        assert_eq!(sessions[2].activity_type, "lap_swimming");
    }

    #[test]
    fn a_day_counts_once_and_keeps_the_longest_activity() {
        let week = Week::containing(date("2026-11-17"));
        let activities = vec![
            activity(1, "indoor_cycling", "2026-11-17 06:00:00", 16.0),
            activity(2, "strength_training", "2026-11-17 06:20:00", 55.0),
        ];
        let sessions = sessions_in_week(&rules(), week, &activities);
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].activity_id, 2);
    }

    #[test]
    fn ignores_other_types_short_activities_and_other_weeks() {
        let week = Week::containing(date("2026-11-17"));
        let activities = vec![
            activity(1, "walking", "2026-11-16 12:00:00", 45.0),
            activity(2, "strength_training", "2026-11-17 06:00:00", 3.0),
            activity(3, "strength_training", "2026-11-15 06:00:00", 60.0), // Sunday before
            activity(4, "strength_training", "2026-11-23 06:00:00", 60.0), // Monday after
        ];
        assert!(sessions_in_week(&rules(), week, &activities).is_empty());
    }

    #[test]
    fn late_sunday_session_belongs_to_that_week() {
        let week = Week::containing(date("2026-11-17"));
        let activities = vec![activity(1, "strength_training", "2026-11-22 23:30:00", 45.0)];
        assert_eq!(sessions_in_week(&rules(), week, &activities).len(), 1);
    }

    #[test]
    fn more_than_target_sessions_are_all_reported() {
        let week = Week::containing(date("2026-11-17"));
        let activities: Vec<_> = (16..=21)
            .map(|d| activity(d, "strength_training", &format!("2026-11-{d} 06:00:00"), 50.0))
            .collect();
        assert_eq!(sessions_in_week(&rules(), week, &activities).len(), 6);
    }

    /// One strength session on each of the first `count` days of the week
    /// that starts on `monday`.
    fn week_of_sessions(monday: &str, count: u32) -> Vec<Activity> {
        let monday = date(monday);
        (0..count)
            .map(|day| {
                let on = monday + Duration::days(day as i64);
                activity(on.num_days_from_ce() as i64, "strength_training", &format!("{on} 06:30:00"), 50.0)
            })
            .collect()
    }

    /// Weeks of sessions starting Monday 5 October 2026 (ISO week 41), one
    /// count per week.
    fn history(counts: &[u32]) -> Vec<Activity> {
        counts
            .iter()
            .enumerate()
            .flat_map(|(index, count)| {
                let monday = date("2026-10-05") + Duration::days(7 * index as i64);
                week_of_sessions(&monday.to_string(), *count)
            })
            .collect()
    }

    #[test]
    fn no_history_is_one_open_week_and_no_streak() {
        let s = streak(&rules(), date("2026-11-18"), &[]);
        assert_eq!((s.weeks, s.state, s.previous_best), (0, State::NotStarted, 0));
        assert_eq!((s.remaining, s.open_days, s.reachable), (4, 5, true));
        assert!(s.recent.is_empty());
    }

    #[test]
    fn weeks_with_four_sessions_build_the_streak() {
        // Weeks 41 to 46 kept; today is Wednesday of week 47 with one session.
        let s = streak(&rules(), date("2026-11-18"), &history(&[4, 5, 4, 4, 6, 4, 1]));
        assert_eq!((s.weeks, s.state, s.previous_best), (6, State::OnTrack, 0));
        assert_eq!((s.remaining, s.open_days, s.reachable), (3, 5, true));
        assert_eq!(s.recent.len(), 6);
        assert_eq!(s.recent[0].iso_week, 41);
        assert_eq!(s.recent[4].done, 6);
        assert!(s.recent.iter().all(|w| w.mark == Mark::Kept));
    }

    #[test]
    fn the_fourth_session_counts_the_week_at_once() {
        let s = streak(&rules(), date("2026-11-19"), &history(&[4, 4, 4, 4, 4, 4, 4]));
        assert_eq!((s.weeks, s.state, s.remaining), (7, State::Kept, 0));
    }

    #[test]
    fn a_missed_week_opens_recovery_and_the_next_week_closes_it() {
        // Week 46 had three sessions.
        let recovering = streak(&rules(), date("2026-11-16"), &history(&[4, 4, 4, 4, 4, 3]));
        assert_eq!((recovering.weeks, recovering.state), (5, State::Recovering));
        assert_eq!(recovering.recent.last().unwrap().mark, Mark::AwaitingRecovery);
        assert_eq!(recovering.recent.last().unwrap().done, 3);

        let recovered = streak(&rules(), date("2026-11-19"), &history(&[4, 4, 4, 4, 4, 3, 4]));
        assert_eq!((recovered.weeks, recovered.state), (6, State::Kept));
        assert_eq!(recovered.recent.last().unwrap().mark, Mark::Recovered);
    }

    #[test]
    fn two_missed_weeks_end_the_streak_and_keep_the_best() {
        let s = streak(&rules(), date("2026-11-16"), &history(&[4, 4, 4, 4, 2, 0]));
        assert_eq!((s.weeks, s.state, s.previous_best), (0, State::NotStarted, 4));
        let marks: Vec<Mark> = s.recent.iter().map(|w| w.mark).collect();
        assert_eq!(marks[4..], [Mark::Missed, Mark::Missed]);
    }

    #[test]
    fn a_week_with_no_activities_at_all_is_a_missed_week() {
        // Weeks 41 and 42 kept, 43 empty, 44 kept: the gap is recovered.
        let s = streak(&rules(), date("2026-11-02"), &history(&[4, 4, 0, 4]));
        assert_eq!((s.weeks, s.state), (3, State::OnTrack));
        assert_eq!(s.recent[2].mark, Mark::Recovered);
        assert_eq!(s.recent[2].done, 0);
    }

    #[test]
    fn weeks_before_the_first_kept_week_are_left_out() {
        // Two thin weeks, as when the import starts mid-history.
        let s = streak(&rules(), date("2026-11-02"), &history(&[1, 2, 4, 4]));
        assert_eq!(s.weeks, 2);
        assert_eq!(s.recent.iter().map(|w| w.iso_week).collect::<Vec<_>>(), vec![43, 44]);
    }

    #[test]
    fn only_the_latest_weeks_are_listed() {
        let s = streak(&rules(), date("2027-03-01"), &history(&[4; 21]));
        assert_eq!(s.weeks, 21);
        assert_eq!(s.recent.len(), RECENT_WEEKS);
        assert_eq!(s.recent.last().unwrap().starts_on, date("2027-02-22"));
    }

    #[test]
    fn a_week_stops_being_reachable_when_days_run_out() {
        let past = history(&[4, 4, 4, 4, 4, 4]);
        // Friday with one session so far: three more needed, three days left.
        let mut friday = past.clone();
        friday.push(activity(1, "strength_training", "2026-11-16 06:30:00", 50.0));
        let tight = streak(&rules(), date("2026-11-20"), &friday);
        assert_eq!((tight.remaining, tight.open_days, tight.reachable), (3, 3, true));
        // Saturday without having trained on Friday: out of reach.
        let lost = streak(&rules(), date("2026-11-21"), &friday);
        assert_eq!((lost.remaining, lost.open_days, lost.reachable), (3, 2, false));
        assert_eq!(lost.state, State::OnTrack);
    }

    #[test]
    fn a_day_already_trained_is_not_an_open_day() {
        let mut activities = history(&[4, 4]);
        activities.push(activity(1, "strength_training", "2026-10-22 06:30:00", 50.0));
        // Thursday 22 October, trained this morning: Fri, Sat, Sun remain.
        let s = streak(&rules(), date("2026-10-22"), &activities);
        assert_eq!((s.remaining, s.open_days, s.reachable), (3, 3, true));
    }

    fn standing(state: State, weeks: u32, remaining: u32, open_days: u32) -> GymStreak {
        GymStreak {
            weeks,
            state,
            previous_best: 0,
            remaining,
            open_days,
            reachable: remaining <= open_days,
            recent: Vec::new(),
        }
    }

    #[test]
    fn no_prompt_while_there_is_slack_in_the_week() {
        assert_eq!(prompt(&standing(State::OnTrack, 6, 3, 5), false), None);
        assert_eq!(prompt(&standing(State::OnTrack, 6, 1, 2), false), None);
    }

    #[test]
    fn a_prompt_when_every_day_left_is_needed() {
        assert_eq!(
            prompt(&standing(State::OnTrack, 6, 2, 2), false),
            Some(Prompt::TrainToday { remaining: 2, weeks: 6, recovering: false })
        );
        assert_eq!(
            prompt(&standing(State::Recovering, 6, 1, 1), false),
            Some(Prompt::TrainToday { remaining: 1, weeks: 6, recovering: true })
        );
    }

    #[test]
    fn no_prompt_once_today_is_done_or_the_week_is() {
        // Trained today; the remaining days are all needed, but not today.
        assert_eq!(prompt(&standing(State::OnTrack, 6, 2, 2), true), None);
        assert_eq!(prompt(&standing(State::Kept, 7, 0, 3), false), None);
    }

    #[test]
    fn no_prompt_without_a_streak_or_when_the_week_is_out_of_reach() {
        assert_eq!(prompt(&standing(State::NotStarted, 0, 2, 2), false), None);
        assert_eq!(prompt(&standing(State::OnTrack, 6, 3, 2), false), None);
        assert_eq!(prompt(&standing(State::Recovering, 6, 3, 2), false), None);
    }

    #[test]
    fn a_missed_week_prompts_recovery_until_the_tight_day_takes_over() {
        assert_eq!(
            prompt(&standing(State::Recovering, 6, 4, 7), false),
            Some(Prompt::RecoveryOpen { weeks: 6 })
        );
        assert_eq!(
            prompt(&standing(State::Recovering, 6, 4, 4), false),
            Some(Prompt::TrainToday { remaining: 4, weeks: 6, recovering: true })
        );
    }

    #[test]
    fn prompts_are_worded_for_the_day_and_the_state() {
        let friday = date("2026-11-20");
        let sunday = date("2026-11-22");
        let keep = Prompt::TrainToday { remaining: 3, weeks: 6, recovering: false };
        assert_eq!(keep.title(friday), "Gym: 3 more by Sunday");
        assert_eq!(keep.body(), "Train today to keep your 6-week streak. It takes every day left this week.");
        let last = Prompt::TrainToday { remaining: 1, weeks: 1, recovering: true };
        assert_eq!(last.title(sunday), "Gym: 1 more today");
        assert_eq!(last.body(), "Train today to recover your 1-week streak.");
        let open = Prompt::RecoveryOpen { weeks: 6 };
        assert_eq!(open.title(friday), "Gym: last week was missed");
        assert_eq!(open.body(), "4 sessions by Sunday recovers your 6-week streak. Nothing to make up.");
    }

    #[test]
    fn a_prompt_is_sent_once_per_day_or_once_per_week() {
        let friday = date("2026-11-20");
        let keep = Prompt::TrainToday { remaining: 3, weeks: 6, recovering: false };
        assert_eq!((keep.kind(), keep.period(friday)), ("gym_train_today", friday));
        let open = Prompt::RecoveryOpen { weeks: 6 };
        assert_eq!((open.kind(), open.period(friday)), ("gym_recovery_open", date("2026-11-16")));
    }
}
