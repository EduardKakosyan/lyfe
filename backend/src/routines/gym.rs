//! What counts as a gym session, and which week it belongs to.
//!
//! Pure rules, no I/O. A gym week runs Monday to Sunday in the wall-clock
//! time the activity was recorded in. A day counts at most once, however
//! many activities were recorded on it, so a warm-up saved separately from
//! the main session does not fill two squares.

use chrono::{Datelike, Duration, NaiveDate, NaiveDateTime};
use serde::Serialize;

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
}
