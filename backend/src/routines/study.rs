//! Study: what counts as a session, and the week it adds up to.
//!
//! Pure rules, no I/O. A session is timed on the phone and counts once the
//! timer has passed a minimum; a longer target is shown but never needed.
//! Weeks with four days of study keep the streak, with the same recovery
//! rule as the gym. Building something counts as study for at most two
//! sessions a week, and only once the owner has said, without looking it
//! up, what was built and why.
//!
//! Two things are kept apart, as for breath training: the streak counts
//! days studied and never looks at what was studied or how it went; the
//! questions answered and right the first time are kept for whether the
//! hours are working.

use std::collections::BTreeMap;

use chrono::{NaiveDate, NaiveDateTime};
use serde::Serialize;
use uuid::Uuid;

use super::weekly::{self, Week, WeekStreak, Wording};

/// Days of study needed for a week to count toward the streak.
pub const WEEKLY_TARGET: u32 = 4;

/// How study is named in a prompt.
pub const WORDING: Wording = Wording { key: "study", name: "Study", do_today: "Study today", target: WEEKLY_TARGET };

/// A timer left running is ended by itself after this long on the clock,
/// and the owner is asked when they really stopped.
pub const STOP_AFTER_S: u32 = 3 * 3600;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StudyRules {
    /// A session counts once its timer has passed this.
    pub min_s: u32,
    /// What a session aims at; shown, never required.
    pub target_s: u32,
    /// Build sessions that can count in one week, the earliest first.
    pub builds_per_week: u32,
}

impl StudyRules {
    pub const DEFAULT_MIN_MINUTES: u32 = 45;
    pub const DEFAULT_TARGET_MINUTES: u32 = 90;
    pub const DEFAULT_BUILDS_PER_WEEK: u32 = 2;
}

impl Default for StudyRules {
    fn default() -> Self {
        StudyRules {
            min_s: Self::DEFAULT_MIN_MINUTES * 60,
            target_s: Self::DEFAULT_TARGET_MINUTES * 60,
            builds_per_week: Self::DEFAULT_BUILDS_PER_WEEK,
        }
    }
}

/// What a session was spent on.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    /// Answering questions or problems, from memory.
    Questions,
    Reading,
    /// Building something, which counts only with an explain-back.
    Build,
}

impl Kind {
    pub fn parse(text: &str) -> Option<Kind> {
        match text {
            "questions" => Some(Kind::Questions),
            "reading" => Some(Kind::Reading),
            "build" => Some(Kind::Build),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Questions => "questions",
            Kind::Reading => "reading",
            Kind::Build => "build",
        }
    }
}

/// A session as timed on the phone.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Session {
    /// Made on the phone, so sending a session twice stores it once.
    pub id: Uuid,
    /// When the timer started, in the owner's wall-clock time; decides the
    /// day and week it belongs to.
    pub started_local: NaiveDateTime,
    /// Time on the timer, less any pause.
    pub active_s: u32,
    pub subject_id: Uuid,
    pub subject: String,
    pub kind: Kind,
    pub answered: Option<u32>,
    pub right_first: Option<u32>,
    /// What was built and why, for a build session.
    pub explain_back: Option<String>,
}

/// Why a session does not count, when it does not.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum NotCounted {
    /// The timer stopped before the minimum.
    Short,
    /// A build session with nothing said about what was built.
    NotExplained,
    /// A build session in a week whose build sessions have all counted.
    BuildsUsed,
}

impl Session {
    pub fn date(&self) -> NaiveDate {
        self.started_local.date()
    }

    pub fn is_explained(&self) -> bool {
        self.kind != Kind::Build || self.explain_back.as_deref().is_some_and(|text| !text.trim().is_empty())
    }

    /// Why it would not count, leaving aside how many builds the week has.
    fn fault(&self, rules: &StudyRules) -> Option<NotCounted> {
        if self.active_s < rules.min_s {
            Some(NotCounted::Short)
        } else if !self.is_explained() {
            Some(NotCounted::NotExplained)
        } else {
            None
        }
    }
}

/// Whether each session counts, by id. Within a week, build sessions count
/// earliest first until the week's allowance is used.
pub fn judged(rules: &StudyRules, sessions: &[Session]) -> BTreeMap<Uuid, Option<NotCounted>> {
    let mut ordered: Vec<&Session> = sessions.iter().collect();
    ordered.sort_by_key(|s| (s.started_local, s.id));
    let mut builds: BTreeMap<NaiveDate, u32> = BTreeMap::new();
    ordered
        .into_iter()
        .map(|session| {
            let mut fault = session.fault(rules);
            if fault.is_none() && session.kind == Kind::Build {
                let used = builds.entry(Week::containing(session.date()).starts_on).or_default();
                if *used >= rules.builds_per_week {
                    fault = Some(NotCounted::BuildsUsed);
                } else {
                    *used += 1;
                }
            }
            (session.id, fault)
        })
        .collect()
}

/// The days with a session that counts, in no particular order. A day
/// counts once however many sessions it had.
pub fn session_days(rules: &StudyRules, sessions: &[Session]) -> Vec<NaiveDate> {
    let judged = judged(rules, sessions);
    sessions
        .iter()
        .filter(|s| judged.get(&s.id).is_some_and(Option::is_none))
        .map(Session::date)
        .collect()
}

/// The streak rules applied to the recorded sessions.
pub fn streak(rules: &StudyRules, today: NaiveDate, sessions: &[Session]) -> WeekStreak {
    weekly::streak(WEEKLY_TARGET, today, &session_days(rules, sessions))
}

/// A session as the apps show it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SessionSummary {
    pub id: Uuid,
    pub date: NaiveDate,
    pub minutes: u32,
    pub subject: String,
    pub kind: Kind,
    pub answered: Option<u32>,
    pub right_first: Option<u32>,
    /// Whether it counts toward the week.
    pub counts: bool,
    /// Why not, when it does not.
    pub not_counted: Option<NotCounted>,
}

/// A subject and the time given to it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SubjectSummary {
    pub id: Uuid,
    pub name: String,
    /// Every minute on the timer for it, counted or not.
    pub minutes: u32,
    pub sessions: u32,
    /// The day it was last studied.
    pub last: NaiveDate,
}

/// Study as the apps show it this week.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct StudyWeek {
    /// Days of study a week needs to count.
    pub target: u32,
    /// Days this week with a session that counts.
    pub done: u32,
    pub remaining: u32,
    /// Whether today already has a session that counts.
    pub done_today: bool,
    /// Minutes on the timer this week, counted or not.
    pub minutes: u32,
    /// Build sessions that counted this week, out of `rules.builds_per_week`.
    pub builds: u32,
    /// Every session started this week, oldest first.
    pub sessions: Vec<SessionSummary>,
    pub streak: WeekStreak,
    /// Most recently studied first.
    pub subjects: Vec<SubjectSummary>,
    pub rules: RulesView,
}

/// What the phone's timer needs to know.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct RulesView {
    pub min_minutes: u32,
    pub target_minutes: u32,
    pub builds_per_week: u32,
    pub stop_after_minutes: u32,
}

/// The week as of `today`.
pub fn week(rules: &StudyRules, today: NaiveDate, sessions: &[Session]) -> StudyWeek {
    let this_week = Week::containing(today);
    let judged = judged(rules, sessions);
    let counts = |s: &Session| judged.get(&s.id).is_some_and(Option::is_none);

    let mut in_week: Vec<&Session> = sessions.iter().filter(|s| this_week.contains(s.date())).collect();
    in_week.sort_by_key(|s| (s.started_local, s.id));
    let mut days: Vec<NaiveDate> = in_week.iter().filter(|s| counts(s)).map(|s| s.date()).collect();
    days.dedup();
    let done = days.len() as u32;

    let mut subjects: BTreeMap<Uuid, SubjectSummary> = BTreeMap::new();
    for session in sessions {
        let subject = subjects.entry(session.subject_id).or_insert_with(|| SubjectSummary {
            id: session.subject_id,
            name: session.subject.clone(),
            minutes: 0,
            sessions: 0,
            last: session.date(),
        });
        subject.minutes += session.active_s / 60;
        subject.sessions += 1;
        subject.last = subject.last.max(session.date());
    }
    let mut subjects: Vec<SubjectSummary> = subjects.into_values().collect();
    subjects.sort_by(|a, b| b.last.cmp(&a.last).then_with(|| a.name.cmp(&b.name)));

    StudyWeek {
        target: WEEKLY_TARGET,
        done,
        remaining: WEEKLY_TARGET.saturating_sub(done),
        done_today: days.contains(&today),
        minutes: in_week.iter().map(|s| s.active_s / 60).sum(),
        builds: in_week.iter().filter(|s| s.kind == Kind::Build && counts(s)).count() as u32,
        sessions: in_week
            .iter()
            .map(|s| {
                let not_counted = judged.get(&s.id).copied().flatten();
                SessionSummary {
                    id: s.id,
                    date: s.date(),
                    minutes: s.active_s / 60,
                    subject: s.subject.clone(),
                    kind: s.kind,
                    answered: s.answered,
                    right_first: s.right_first,
                    counts: not_counted.is_none(),
                    not_counted,
                }
            })
            .collect(),
        streak: streak(rules, today, sessions),
        subjects,
        rules: RulesView {
            min_minutes: rules.min_s / 60,
            target_minutes: rules.target_s / 60,
            builds_per_week: rules.builds_per_week,
            stop_after_minutes: STOP_AFTER_S / 60,
        },
    }
}

/// A subject's name as it is kept: trimmed, with runs of spaces made one.
/// `None` when nothing is left, it is too long, or it has control
/// characters.
pub fn subject_name(text: &str) -> Option<String> {
    let name = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let fits = !name.is_empty() && name.chars().count() <= 60 && !name.chars().any(char::is_control);
    fits.then_some(name)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::routines::streak::State;

    fn date(s: &str) -> NaiveDate {
        s.parse().unwrap()
    }

    const SYSTEM_DESIGN: Uuid = Uuid::from_u128(0xa);
    const MODELS: Uuid = Uuid::from_u128(0xb);

    fn session(n: u128, start: &str, minutes: u32, kind: Kind) -> Session {
        Session {
            id: Uuid::from_u128(n),
            started_local: NaiveDateTime::parse_from_str(start, "%Y-%m-%d %H:%M").unwrap(),
            active_s: minutes * 60,
            subject_id: SYSTEM_DESIGN,
            subject: "System design".into(),
            kind,
            answered: None,
            right_first: None,
            explain_back: (kind == Kind::Build).then(|| "A queue for the photo estimates, because...".into()),
        }
    }

    fn rules() -> StudyRules {
        StudyRules::default()
    }

    #[test]
    fn a_session_counts_once_the_timer_passes_the_minimum() {
        let sessions = [
            session(1, "2026-11-16 19:00", 44, Kind::Questions),
            session(2, "2026-11-17 19:00", 45, Kind::Questions),
            session(3, "2026-11-18 19:00", 90, Kind::Reading),
        ];
        let judged = judged(&rules(), &sessions);
        assert_eq!(judged[&Uuid::from_u128(1)], Some(NotCounted::Short));
        assert_eq!(judged[&Uuid::from_u128(2)], None);
        assert_eq!(judged[&Uuid::from_u128(3)], None);
        let mut days = session_days(&rules(), &sessions);
        days.sort();
        assert_eq!(days, vec![date("2026-11-17"), date("2026-11-18")]);
    }

    #[test]
    fn a_build_session_counts_only_with_its_explain_back() {
        let mut build = session(1, "2026-11-16 19:00", 120, Kind::Build);
        build.explain_back = Some("   ".into());
        assert_eq!(judged(&rules(), &[build.clone()])[&build.id], Some(NotCounted::NotExplained));
        build.explain_back = None;
        assert_eq!(judged(&rules(), &[build.clone()])[&build.id], Some(NotCounted::NotExplained));
        build.explain_back = Some("Moved the photo estimate off the request".into());
        assert_eq!(judged(&rules(), &[build.clone()])[&build.id], None);
        // A short build session is short first.
        build.active_s = 600;
        assert_eq!(judged(&rules(), &[build.clone()])[&build.id], Some(NotCounted::Short));
    }

    #[test]
    fn two_build_sessions_count_a_week_the_earliest_first() {
        let sessions = [
            session(3, "2026-11-18 19:00", 90, Kind::Build),
            session(1, "2026-11-16 19:00", 90, Kind::Build),
            session(2, "2026-11-17 19:00", 90, Kind::Build),
            session(4, "2026-11-19 19:00", 90, Kind::Questions),
            // The next week has its own two.
            session(5, "2026-11-23 19:00", 90, Kind::Build),
        ];
        let judged = judged(&rules(), &sessions);
        assert_eq!(judged[&Uuid::from_u128(1)], None);
        assert_eq!(judged[&Uuid::from_u128(2)], None);
        assert_eq!(judged[&Uuid::from_u128(3)], Some(NotCounted::BuildsUsed));
        assert_eq!(judged[&Uuid::from_u128(4)], None);
        assert_eq!(judged[&Uuid::from_u128(5)], None);
        // A build session too short to count does not use the allowance.
        let short_first = [
            session(1, "2026-11-16 19:00", 20, Kind::Build),
            session(2, "2026-11-17 19:00", 90, Kind::Build),
            session(3, "2026-11-18 19:00", 90, Kind::Build),
        ];
        let judged = super::judged(&rules(), &short_first);
        assert_eq!(judged[&Uuid::from_u128(3)], None);
    }

    #[test]
    fn a_day_counts_once_however_many_sessions_it_had() {
        let sessions = [
            session(1, "2026-11-16 07:00", 60, Kind::Questions),
            session(2, "2026-11-16 19:00", 60, Kind::Reading),
            session(3, "2026-11-17 19:00", 60, Kind::Questions),
        ];
        let week = week(&rules(), date("2026-11-17"), &sessions);
        assert_eq!((week.done, week.remaining, week.done_today), (2, 2, true));
        assert_eq!(week.minutes, 180);
    }

    #[test]
    fn four_days_keep_the_week_and_one_miss_is_recovered() {
        let mut sessions = Vec::new();
        let mut n = 0;
        // Weeks of 2 Nov and 9 Nov kept, 16 Nov missed, 23 Nov kept.
        for monday in ["2026-11-02", "2026-11-09", "2026-11-23"] {
            for day in 0..4 {
                n += 1;
                let date = date(monday) + chrono::Duration::days(day);
                sessions.push(session(n, &format!("{date} 19:00"), 50, Kind::Questions));
            }
        }
        let streak = streak(&rules(), date("2026-11-26"), &sessions);
        assert_eq!((streak.weeks, streak.state), (3, State::Kept));
        assert_eq!(streak.recent.last().unwrap().mark, crate::routines::streak::Mark::Recovered);
    }

    #[test]
    fn the_week_lists_its_sessions_and_says_why_one_did_not_count() {
        let mut questions = session(2, "2026-11-17 19:00", 92, Kind::Questions);
        questions.answered = Some(12);
        questions.right_first = Some(8);
        let sessions = [
            session(1, "2026-11-09 19:00", 90, Kind::Reading),
            session(3, "2026-11-18 06:30", 30, Kind::Reading),
            questions,
        ];
        let week = week(&rules(), date("2026-11-18"), &sessions);
        assert_eq!(week.sessions.len(), 2);
        assert_eq!(week.sessions[0].minutes, 92);
        assert_eq!((week.sessions[0].answered, week.sessions[0].right_first), (Some(12), Some(8)));
        assert!(week.sessions[0].counts);
        assert_eq!(week.sessions[1].not_counted, Some(NotCounted::Short));
        assert_eq!((week.done, week.done_today, week.minutes), (1, false, 122));
        assert_eq!(week.rules.min_minutes, 45);
        assert_eq!(week.rules.stop_after_minutes, 180);
    }

    #[test]
    fn subjects_add_up_every_minute_and_the_latest_comes_first() {
        let mut models = session(3, "2026-11-18 19:00", 50, Kind::Reading);
        models.subject_id = MODELS;
        models.subject = "Local models".into();
        let sessions = [
            session(1, "2026-11-09 19:00", 90, Kind::Reading),
            session(2, "2026-11-10 19:00", 20, Kind::Questions),
            models,
        ];
        let week = week(&rules(), date("2026-11-18"), &sessions);
        assert_eq!(week.subjects.len(), 2);
        assert_eq!(week.subjects[0].name, "Local models");
        assert_eq!((week.subjects[1].minutes, week.subjects[1].sessions), (110, 2));
        assert_eq!(week.subjects[1].last, date("2026-11-10"));
    }

    #[test]
    fn builds_this_week_are_counted_for_the_screen() {
        let sessions = [
            session(1, "2026-11-16 19:00", 90, Kind::Build),
            session(2, "2026-11-17 19:00", 90, Kind::Build),
            session(3, "2026-11-18 19:00", 90, Kind::Build),
        ];
        let week = week(&rules(), date("2026-11-18"), &sessions);
        assert_eq!((week.builds, week.done), (2, 2));
        assert_eq!(week.sessions[2].not_counted, Some(NotCounted::BuildsUsed));
    }

    #[test]
    fn subject_names_are_tidied_and_refused_when_empty_or_odd() {
        assert_eq!(subject_name("  System   design "), Some("System design".into()));
        assert_eq!(subject_name("   "), None);
        assert_eq!(subject_name(&"x".repeat(61)), None);
        assert_eq!(subject_name(&"é".repeat(60)), Some("é".repeat(60)));
        assert_eq!(subject_name("a\u{7}b"), None);
    }
}
