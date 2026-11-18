//! What counts as a gym session, and which week it belongs to.
//!
//! Pure rules, no I/O. A gym week runs Monday to Sunday in the wall-clock
//! time the activity was recorded in. A day counts at most once, however
//! many activities were recorded on it, so a warm-up saved separately from
//! the main session does not fill two squares.

use chrono::{NaiveDate, NaiveDateTime};
use serde::Serialize;

use super::weekly::{self, Wording};
pub use super::weekly::{PastWeek, Prompt, Week, WeekStreak as GymStreak, RECENT_WEEKS};

/// Sessions needed for a week to count toward the gym streak.
pub const WEEKLY_TARGET: u32 = 4;

/// How the gym is named in a prompt.
pub const WORDING: Wording =
    Wording { key: "gym", name: "Gym", do_today: "Train today", target: WEEKLY_TARGET };

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

/// The days with a gym session, in no particular order.
pub fn session_days(rules: &GymRules, activities: &[Activity]) -> Vec<NaiveDate> {
    activities
        .iter()
        .filter(|a| rules.counts(a))
        .map(|a| a.start_local.date())
        .collect()
}

/// Every week from the first recorded session up to today's, with the days
/// that had a session in each.
pub fn all_weeks_until(rules: &GymRules, today: NaiveDate, activities: &[Activity]) -> Vec<(Week, u32)> {
    weekly::all_weeks_until(today, &session_days(rules, activities))
}

/// The streak rules applied to the recorded activities.
pub fn streak(rules: &GymRules, today: NaiveDate, activities: &[Activity]) -> GymStreak {
    weekly::streak(WEEKLY_TARGET, today, &session_days(rules, activities))
}

/// The prompt today calls for, if any. `trained_today` is whether today
/// already has a session.
pub fn prompt(streak: &GymStreak, trained_today: bool) -> Option<Prompt> {
    weekly::prompt(streak, trained_today)
}

#[cfg(test)]
mod tests {
    use chrono::{Datelike, Duration};

    use super::*;
    use crate::routines::streak::{Mark, State};

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
}
