//! Breath training: what counts as a session, and the table lyfe sets next.
//!
//! Pure rules, no I/O. The method is fixed rounds: every round has the same
//! length and starts with a hold taken as far as it goes; what is left of
//! the round is the recovery. Longer holds leave less recovery, and once a
//! session's tightest recovery drops under a threshold the next table's
//! rounds get longer to make room.
//!
//! Two things are kept apart. The streak counts weeks with three sessions
//! and never looks at how long a hold was. Progression looks only at the
//! holds.

use chrono::{NaiveDate, NaiveDateTime};
use serde::Serialize;
use uuid::Uuid;

use super::weekly::{self, Week, WeekStreak, Wording};

/// Sessions needed for a week to count toward the breath streak.
pub const WEEKLY_TARGET: u32 = 3;

/// How breath training is named in a prompt.
pub const WORDING: Wording =
    Wording { key: "breath", name: "Breath", do_today: "Do a session today", target: WEEKLY_TARGET };

#[derive(Debug, Clone)]
pub struct BreathRules {
    /// Round length of the first table, before any session is recorded.
    pub start_round_s: u32,
    /// Rounds in a table.
    pub rounds: u32,
    /// The next table's rounds get longer once a session's tightest
    /// recovery is under this.
    pub advance_under_s: u32,
    /// How much longer.
    pub step_s: u32,
}

impl BreathRules {
    pub const DEFAULT_START_ROUND_SECONDS: u32 = 240;
    pub const DEFAULT_ROUNDS: u32 = 6;
    pub const DEFAULT_ADVANCE_UNDER_SECONDS: u32 = 45;
    pub const DEFAULT_STEP_SECONDS: u32 = 15;
}

impl Default for BreathRules {
    fn default() -> Self {
        BreathRules {
            start_round_s: Self::DEFAULT_START_ROUND_SECONDS,
            rounds: Self::DEFAULT_ROUNDS,
            advance_under_s: Self::DEFAULT_ADVANCE_UNDER_SECONDS,
            step_s: Self::DEFAULT_STEP_SECONDS,
        }
    }
}

/// One recorded hold: the round it opened and how long it lasted.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Hold {
    /// Counted from 1.
    pub round: u32,
    pub hold_ms: u32,
}

/// A session as captured on the phone.
#[derive(Debug, Clone, PartialEq)]
pub struct Session {
    /// Made on the phone, so sending a session twice stores it once.
    pub id: Uuid,
    /// When it started, in the owner's wall-clock time; decides which day
    /// and week it belongs to.
    pub started_local: NaiveDateTime,
    /// The table it was run with.
    pub round_s: u32,
    pub rounds: u32,
    /// A round the owner did not tap in has no hold.
    pub holds: Vec<Hold>,
}

impl Session {
    pub fn date(&self) -> NaiveDate {
        self.started_local.date()
    }

    /// A session counts toward the week once at least half its rounds have
    /// a recorded hold, so a session cut short still counts and a timer
    /// started by accident does not.
    pub fn counts(&self) -> bool {
        !self.holds.is_empty() && self.holds.len() as u32 * 2 >= self.rounds
    }

    pub fn best_ms(&self) -> Option<u32> {
        self.holds.iter().map(|h| h.hold_ms).max()
    }

    pub fn mean_ms(&self) -> Option<u32> {
        if self.holds.is_empty() {
            return None;
        }
        let total: u64 = self.holds.iter().map(|h| u64::from(h.hold_ms)).sum();
        Some((total as f64 / self.holds.len() as f64).round() as u32)
    }

    /// The least that was left of a round after its hold.
    pub fn tightest_recovery_ms(&self) -> Option<u32> {
        self.best_ms().map(|best| (self.round_s * 1000).saturating_sub(best))
    }

    /// The hold of each round in order, `None` where none was recorded.
    pub fn holds_by_round(&self, rounds: u32) -> Vec<Option<u32>> {
        (1..=rounds)
            .map(|round| self.holds.iter().find(|h| h.round == round).map(|h| h.hold_ms))
            .collect()
    }

    pub fn summary(&self) -> SessionSummary {
        SessionSummary {
            id: self.id,
            date: self.date(),
            round_s: self.round_s,
            rounds: self.rounds,
            holds_ms: self.holds_by_round(self.rounds),
            best_ms: self.best_ms(),
            mean_ms: self.mean_ms(),
            tightest_recovery_ms: self.tightest_recovery_ms(),
            counts: self.counts(),
        }
    }
}

/// A session as the apps show it.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct SessionSummary {
    pub id: Uuid,
    pub date: NaiveDate,
    pub round_s: u32,
    pub rounds: u32,
    /// One entry per round; null where no hold was recorded.
    pub holds_ms: Vec<Option<u32>>,
    pub best_ms: Option<u32>,
    pub mean_ms: Option<u32>,
    pub tightest_recovery_ms: Option<u32>,
    /// Whether it counts toward the week.
    pub counts: bool,
}

/// The table for the next session.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Table {
    pub round_s: u32,
    pub rounds: u32,
    /// The last session's round length, when this table moved on from it.
    pub changed_from_s: Option<u32>,
    /// The rounds get longer once a session's tightest recovery is under this.
    pub advance_under_s: u32,
    /// How much longer.
    pub step_s: u32,
    /// The last session's hold in each round of this table, to beat; null
    /// where it had none.
    pub last_holds_ms: Vec<Option<u32>>,
}

/// The most recent session that counts.
fn last_counted(sessions: &[Session]) -> Option<&Session> {
    sessions
        .iter()
        .filter(|s| s.counts())
        .max_by_key(|s| s.started_local)
}

/// The table lyfe sets from what has been recorded. The round length
/// follows the last session that counts: the same again while its recovery
/// had room, one step longer once it got tight. It never gets shorter.
pub fn next_table(rules: &BreathRules, sessions: &[Session]) -> Table {
    let Some(last) = last_counted(sessions) else {
        return Table {
            round_s: rules.start_round_s,
            rounds: rules.rounds,
            changed_from_s: None,
            advance_under_s: rules.advance_under_s,
            step_s: rules.step_s,
            last_holds_ms: vec![None; rules.rounds as usize],
        };
    };
    let tight = last
        .tightest_recovery_ms()
        .is_some_and(|recovery| recovery < rules.advance_under_s * 1000);
    let round_s = if tight { last.round_s + rules.step_s } else { last.round_s };
    Table {
        round_s,
        rounds: rules.rounds,
        changed_from_s: (round_s != last.round_s).then_some(last.round_s),
        advance_under_s: rules.advance_under_s,
        step_s: rules.step_s,
        last_holds_ms: last.holds_by_round(rules.rounds),
    }
}

/// The days with a session that counts, in no particular order. A day
/// counts once however many sessions it had.
pub fn session_days(sessions: &[Session]) -> Vec<NaiveDate> {
    sessions.iter().filter(|s| s.counts()).map(Session::date).collect()
}

/// Every session started in `week`, counted or not, oldest first.
pub fn sessions_in_week(week: Week, sessions: &[Session]) -> Vec<&Session> {
    let mut found: Vec<&Session> = sessions.iter().filter(|s| week.contains(s.date())).collect();
    found.sort_by_key(|s| s.started_local);
    found
}

/// The streak rules applied to the recorded sessions.
pub fn streak(today: NaiveDate, sessions: &[Session]) -> WeekStreak {
    weekly::streak(WEEKLY_TARGET, today, &session_days(sessions))
}

/// The longest hold ever recorded, in any session.
pub fn best_ever_ms(sessions: &[Session]) -> Option<u32> {
    sessions.iter().filter_map(Session::best_ms).max()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::routines::streak::State;

    fn date(s: &str) -> NaiveDate {
        s.parse().unwrap()
    }

    /// A session of 4:00 rounds started at `start`, with one hold per entry
    /// in seconds from round 1 on.
    fn session(n: u128, start: &str, round_s: u32, holds_s: &[u32]) -> Session {
        Session {
            id: Uuid::from_u128(n),
            started_local: NaiveDateTime::parse_from_str(start, "%Y-%m-%d %H:%M:%S").unwrap(),
            round_s,
            rounds: 6,
            holds: holds_s
                .iter()
                .enumerate()
                .map(|(index, s)| Hold { round: index as u32 + 1, hold_ms: s * 1000 })
                .collect(),
        }
    }

    fn rules() -> BreathRules {
        BreathRules::default()
    }

    #[test]
    fn a_session_counts_once_half_its_rounds_have_a_hold() {
        assert!(session(1, "2026-11-17 20:00:00", 240, &[100, 110, 105, 120, 118, 122]).counts());
        // Cut short after three of six rounds: still a session.
        assert!(session(2, "2026-11-17 20:00:00", 240, &[100, 110, 105]).counts());
        // Two rounds, or a timer started and abandoned: not one.
        assert!(!session(3, "2026-11-17 20:00:00", 240, &[100, 110]).counts());
        assert!(!session(4, "2026-11-17 20:00:00", 240, &[]).counts());
    }

    #[test]
    fn a_round_without_a_tap_has_no_hold() {
        let mut s = session(1, "2026-11-17 20:00:00", 240, &[100, 110, 105, 120]);
        // Rounds 1, 2, 4 and 6 were tapped; 3 and 5 were not.
        s.holds[2].round = 4;
        s.holds[3].round = 6;
        assert_eq!(
            s.holds_by_round(6),
            vec![Some(100_000), Some(110_000), None, Some(105_000), None, Some(120_000)]
        );
        assert!(s.counts());
    }

    #[test]
    fn a_session_is_summed_up_by_its_holds() {
        let s = session(1, "2026-11-17 20:00:00", 240, &[125, 132, 120, 118]);
        assert_eq!(s.best_ms(), Some(132_000));
        assert_eq!(s.mean_ms(), Some(123_750));
        // 4:00 rounds and a 2:12 hold leave 1:48.
        assert_eq!(s.tightest_recovery_ms(), Some(108_000));
        let empty = session(2, "2026-11-17 20:00:00", 240, &[]);
        assert_eq!((empty.best_ms(), empty.mean_ms(), empty.tightest_recovery_ms()), (None, None, None));
    }

    #[test]
    fn the_first_table_comes_from_the_settings() {
        let table = next_table(&rules(), &[]);
        assert_eq!((table.round_s, table.rounds, table.changed_from_s), (240, 6, None));
        assert_eq!((table.advance_under_s, table.step_s), (45, 15));
        assert_eq!(table.last_holds_ms, vec![None; 6]);
    }

    #[test]
    fn the_table_repeats_while_recovery_has_room() {
        // Best hold 2:12 in 4:00 rounds leaves 1:48.
        let sessions = [session(1, "2026-11-17 20:00:00", 240, &[125, 132, 120, 118, 121, 119])];
        let table = next_table(&rules(), &sessions);
        assert_eq!((table.round_s, table.changed_from_s), (240, None));
        assert_eq!(table.last_holds_ms[1], Some(132_000));
    }

    #[test]
    fn the_rounds_get_longer_once_recovery_is_tight() {
        // A 3:16 hold leaves 0:44 of a 4:00 round.
        let tight = [session(1, "2026-11-17 20:00:00", 240, &[180, 196, 170, 165, 160, 150])];
        let table = next_table(&rules(), &tight);
        assert_eq!((table.round_s, table.changed_from_s), (255, Some(240)));
        // Exactly 0:45 left is not under the threshold.
        let edge = [session(1, "2026-11-17 20:00:00", 240, &[180, 195, 170, 165, 160, 150])];
        assert_eq!(next_table(&rules(), &edge).round_s, 240);
    }

    #[test]
    fn the_table_follows_the_latest_session_that_counts() {
        let sessions = [
            session(1, "2026-11-13 20:00:00", 240, &[180, 200, 170]),
            session(2, "2026-11-15 20:00:00", 255, &[185, 190, 175, 170, 168, 160]),
            // Abandoned after one very long hold: says nothing about the table.
            session(3, "2026-11-17 20:00:00", 255, &[230]),
        ];
        let table = next_table(&rules(), &sessions);
        assert_eq!((table.round_s, table.changed_from_s), (255, None));
        assert_eq!(table.last_holds_ms[0], Some(185_000));
        // The order they are handed over in does not matter.
        let mut shuffled = sessions.to_vec();
        shuffled.reverse();
        assert_eq!(next_table(&rules(), &shuffled), table);
    }

    #[test]
    fn the_rounds_never_get_shorter() {
        let sessions = [
            session(1, "2026-11-13 20:00:00", 270, &[100, 90, 95, 80, 85, 70]),
        ];
        assert_eq!(next_table(&rules(), &sessions).round_s, 270);
    }

    #[test]
    fn holds_to_beat_line_up_with_the_tables_rounds() {
        let eight = BreathRules { rounds: 8, ..BreathRules::default() };
        let sessions = [session(1, "2026-11-17 20:00:00", 240, &[125, 132, 120, 118, 121, 119])];
        let table = next_table(&eight, &sessions);
        assert_eq!(table.rounds, 8);
        assert_eq!(table.last_holds_ms.len(), 8);
        assert_eq!(table.last_holds_ms[5], Some(119_000));
        assert_eq!(table.last_holds_ms[6..], [None, None]);
    }

    #[test]
    fn three_sessions_on_three_days_keep_a_week() {
        let good = &[120, 125, 118, 121, 119, 117];
        let mut sessions = vec![
            // Week 46, kept.
            session(1, "2026-11-09 20:00:00", 240, good),
            session(2, "2026-11-11 20:00:00", 240, good),
            session(3, "2026-11-14 20:00:00", 240, good),
            // Week 47, so far: Monday and Tuesday.
            session(4, "2026-11-16 20:00:00", 240, good),
            session(5, "2026-11-17 07:00:00", 240, good),
        ];
        let s = streak(date("2026-11-17"), &sessions);
        assert_eq!((s.weeks, s.state, s.remaining), (1, State::OnTrack, 1));

        // A second session the same day does not make the third.
        sessions.push(session(6, "2026-11-17 21:00:00", 240, good));
        assert_eq!(streak(date("2026-11-17"), &sessions).remaining, 1);
        // Nor does one that was abandoned.
        sessions.push(session(7, "2026-11-18 21:00:00", 240, &[90]));
        assert_eq!(streak(date("2026-11-18"), &sessions).remaining, 1);

        sessions.push(session(8, "2026-11-19 21:00:00", 240, good));
        let kept = streak(date("2026-11-19"), &sessions);
        assert_eq!((kept.weeks, kept.state, kept.remaining), (2, State::Kept, 0));
    }

    #[test]
    fn a_hard_session_never_breaks_the_week() {
        // Short holds and a session cut to half still count as showing up.
        let sessions = [
            session(1, "2026-11-16 20:00:00", 240, &[40, 35, 30]),
            session(2, "2026-11-17 20:00:00", 240, &[45, 30, 20, 25, 20, 15]),
            session(3, "2026-11-18 20:00:00", 240, &[50, 41, 38]),
        ];
        assert_eq!(streak(date("2026-11-18"), &sessions).state, State::Kept);
    }

    #[test]
    fn a_weeks_sessions_are_listed_oldest_first_counted_or_not() {
        let week = Week::containing(date("2026-11-17"));
        let sessions = [
            session(3, "2026-11-18 20:00:00", 240, &[90]),
            session(1, "2026-11-15 20:00:00", 240, &[100, 110, 105]), // Sunday before
            session(2, "2026-11-16 06:00:00", 240, &[100, 110, 105]),
        ];
        let ids: Vec<u128> = sessions_in_week(week, &sessions).iter().map(|s| s.id.as_u128()).collect();
        assert_eq!(ids, vec![2, 3]);
    }

    #[test]
    fn the_best_hold_ever_includes_sessions_that_did_not_count() {
        let sessions = [
            session(1, "2026-11-16 20:00:00", 240, &[100, 110, 105]),
            session(2, "2026-11-17 20:00:00", 240, &[140]),
        ];
        assert_eq!(best_ever_ms(&sessions), Some(140_000));
        assert_eq!(best_ever_ms(&[]), None);
    }
}
