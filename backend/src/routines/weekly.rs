//! Routines counted by the week: the gym and breath training.
//!
//! Pure rules, no I/O. A week runs Monday to Sunday in the owner's
//! wall-clock time. A routine hands over the days it had a session on and
//! its weekly target; this module turns them into weeks, applies the
//! streak rules, and says when the owner should be prompted.

use std::collections::BTreeSet;

use chrono::{Datelike, Duration, NaiveDate};
use serde::Serialize;

use super::streak::{self, Current, Mark, State};

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

/// A weekly routine's streak as of today.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct WeekStreak {
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

/// Every week from the first session up to today's, with the days that had
/// a session in each. A day counts once however often it is listed.
pub fn all_weeks_until(today: NaiveDate, session_days: &[NaiveDate]) -> Vec<(Week, u32)> {
    let this_week = Week::containing(today);
    let days: BTreeSet<NaiveDate> = session_days
        .iter()
        .copied()
        .filter(|day| *day <= this_week.ends_on)
        .collect();
    let Some(earliest) = days.first().copied() else {
        return vec![(this_week, 0)];
    };
    let mut weeks = Vec::new();
    let mut week = Week::containing(earliest.min(today));
    loop {
        let done = days.range(week.starts_on..=week.ends_on).count() as u32;
        weeks.push((week, done));
        if week == this_week {
            return weeks;
        }
        week = week.next();
    }
}

/// The same, starting at the first week that met the target. Weeks before
/// it say nothing about a streak and are left out.
pub fn weeks_until(target: u32, today: NaiveDate, session_days: &[NaiveDate]) -> Vec<(Week, u32)> {
    let all = all_weeks_until(today, session_days);
    let first_kept = all
        .iter()
        .position(|(_, done)| *done >= target)
        .unwrap_or(all.len() - 1);
    all[first_kept..].to_vec()
}

/// The streak rules applied to the days a routine had a session on.
pub fn streak(target: u32, today: NaiveDate, session_days: &[NaiveDate]) -> WeekStreak {
    let this_week = Week::containing(today);
    let weeks = weeks_until(target, today, session_days);
    let (finished, current) = weeks.split_at(weeks.len() - 1);
    let done = current[0].1;

    let kept: Vec<bool> = finished.iter().map(|(_, done)| *done >= target).collect();
    let now = if done >= target { Current::Kept } else { Current::Open };
    let standing = streak::standing(&kept, now);

    let open_days = today
        .iter_days()
        .take_while(|day| *day <= this_week.ends_on)
        .filter(|day| !session_days.contains(day))
        .count() as u32;
    let remaining = target.saturating_sub(done);

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

    WeekStreak {
        weeks: standing.length,
        state: standing.state,
        previous_best: standing.previous_best,
        remaining,
        open_days,
        reachable: remaining <= open_days,
        recent,
    }
}

/// How a routine is named in a prompt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Wording {
    /// Names the routine in the record of what was sent ("gym").
    pub key: &'static str,
    /// The routine as the owner reads it ("Gym").
    pub name: &'static str,
    /// What doing one session today is called ("Train today").
    pub do_today: &'static str,
    /// Sessions a week needs.
    pub target: u32,
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
    pub fn kind(&self, routine: &Wording) -> String {
        match self {
            Prompt::TrainToday { .. } => format!("{}_train_today", routine.key),
            Prompt::RecoveryOpen { .. } => format!("{}_recovery_open", routine.key),
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

    pub fn title(&self, routine: &Wording, today: NaiveDate) -> String {
        let name = routine.name;
        match self {
            Prompt::TrainToday { remaining: 1, .. } if today.weekday() == chrono::Weekday::Sun => {
                format!("{name}: 1 more today")
            }
            Prompt::TrainToday { remaining, .. } => format!("{name}: {remaining} more by Sunday"),
            Prompt::RecoveryOpen { .. } => format!("{name}: last week was missed"),
        }
    }

    pub fn body(&self, routine: &Wording) -> String {
        let streak = |weeks: u32| format!("{weeks}-week streak");
        match self {
            Prompt::TrainToday { remaining, weeks, recovering } => {
                let verb = if *recovering { "recover" } else { "keep" };
                let every_day = if *remaining > 1 { " It takes every day left this week." } else { "" };
                format!("{} to {verb} your {}.{every_day}", routine.do_today, streak(*weeks))
            }
            Prompt::RecoveryOpen { weeks } => format!(
                "{} sessions by Sunday recovers your {}. Nothing to make up.",
                routine.target,
                streak(*weeks)
            ),
        }
    }
}

/// The prompt today calls for, if any. `done_today` is whether today
/// already has a session.
pub fn prompt(streak: &WeekStreak, done_today: bool) -> Option<Prompt> {
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
    if !done_today && streak.remaining == streak.open_days {
        return Some(Prompt::TrainToday { remaining: streak.remaining, weeks: streak.weeks, recovering });
    }
    recovering.then_some(Prompt::RecoveryOpen { weeks: streak.weeks })
}

#[cfg(test)]
mod tests {
    use super::*;

    const GYM: Wording = Wording { key: "gym", name: "Gym", do_today: "Train today", target: 4 };
    const BREATH: Wording =
        Wording { key: "breath", name: "Breath", do_today: "Do a session today", target: 3 };

    fn date(s: &str) -> NaiveDate {
        s.parse().unwrap()
    }

    /// One session on each of the first `count` days of each week, starting
    /// Monday 5 October 2026 (ISO week 41), one count per week.
    fn history(counts: &[u32]) -> Vec<NaiveDate> {
        counts
            .iter()
            .enumerate()
            .flat_map(|(index, count)| {
                let monday = date("2026-10-05") + Duration::days(7 * index as i64);
                (0..*count).map(move |day| monday + Duration::days(day as i64))
            })
            .collect()
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
    fn the_target_decides_which_weeks_are_kept() {
        // Three sessions a week keeps a breath week and misses a gym week.
        let days = history(&[3, 3, 3, 1]);
        let breath = streak(3, date("2026-10-27"), &days);
        assert_eq!((breath.weeks, breath.state, breath.remaining), (3, State::OnTrack, 2));
        let gym = streak(4, date("2026-10-27"), &days);
        assert_eq!((gym.weeks, gym.state, gym.remaining), (0, State::NotStarted, 3));
    }

    #[test]
    fn a_day_listed_twice_counts_once() {
        let mut days = history(&[3, 2]);
        days.push(date("2026-10-13"));
        days.push(date("2026-10-13"));
        // Wednesday of week 42: Monday and Tuesday done, one more needed.
        let s = streak(3, date("2026-10-14"), &days);
        assert_eq!((s.weeks, s.remaining, s.open_days), (1, 1, 5));
    }

    #[test]
    fn days_after_this_week_are_ignored() {
        let mut days = history(&[3]);
        days.push(date("2026-10-20"));
        let s = streak(3, date("2026-10-07"), &days);
        assert_eq!((s.weeks, s.state), (1, State::Kept));
        assert!(s.recent.is_empty());
    }

    fn standing(state: State, weeks: u32, remaining: u32, open_days: u32) -> WeekStreak {
        WeekStreak {
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
        assert_eq!(keep.title(&GYM, friday), "Gym: 3 more by Sunday");
        assert_eq!(keep.body(&GYM), "Train today to keep your 6-week streak. It takes every day left this week.");
        let last = Prompt::TrainToday { remaining: 1, weeks: 1, recovering: true };
        assert_eq!(last.title(&GYM, sunday), "Gym: 1 more today");
        assert_eq!(last.body(&GYM), "Train today to recover your 1-week streak.");
        let open = Prompt::RecoveryOpen { weeks: 6 };
        assert_eq!(open.title(&GYM, friday), "Gym: last week was missed");
        assert_eq!(open.body(&GYM), "4 sessions by Sunday recovers your 6-week streak. Nothing to make up.");
    }

    #[test]
    fn each_routine_is_named_in_its_own_prompts() {
        let friday = date("2026-11-20");
        let keep = Prompt::TrainToday { remaining: 2, weeks: 5, recovering: false };
        assert_eq!(keep.title(&BREATH, friday), "Breath: 2 more by Sunday");
        assert_eq!(
            keep.body(&BREATH),
            "Do a session today to keep your 5-week streak. It takes every day left this week."
        );
        let open = Prompt::RecoveryOpen { weeks: 5 };
        assert_eq!(open.body(&BREATH), "3 sessions by Sunday recovers your 5-week streak. Nothing to make up.");
    }

    #[test]
    fn a_prompt_is_sent_once_per_day_or_once_per_week() {
        let friday = date("2026-11-20");
        let keep = Prompt::TrainToday { remaining: 3, weeks: 6, recovering: false };
        assert_eq!((keep.kind(&GYM).as_str(), keep.period(friday)), ("gym_train_today", friday));
        let open = Prompt::RecoveryOpen { weeks: 6 };
        assert_eq!((open.kind(&GYM).as_str(), open.period(friday)), ("gym_recovery_open", date("2026-11-16")));
        // The routines keep separate records, so one never silences the other.
        assert_eq!(keep.kind(&BREATH), "breath_train_today");
    }
}
