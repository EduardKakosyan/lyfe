//! The streak and recovery rules, shared by every routine.
//!
//! Pure rules, no I/O. A routine is judged period by period: weeks for the
//! gym and breath training, days for food logging. What "kept" means for a
//! period is the routine's business; this module only knows the sequence.
//!
//! - A streak counts the kept periods in a run.
//! - One missed period does not end the run. Keeping the very next period
//!   recovers it, and the missed one is then shown as recovered. Nothing
//!   has to be made up: the recovering period needs only its usual target.
//! - Two missed periods in a row end the run. The next kept period starts a
//!   new one, and the longest ended run stays visible as the previous best.
//!
//! A missed period never adds to the count, recovered or not.

use serde::Serialize;

/// How one finished period turned out, once what followed it is known.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Mark {
    Kept,
    /// Missed, with the run alive and the next period still to be decided.
    AwaitingRecovery,
    /// Missed, and the next period was kept, so the run continued.
    Recovered,
    /// Missed with no run alive, or one of the two misses that ended a run.
    Missed,
}

/// Where the streak stands with the period now in progress.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum State {
    /// No run is alive. Keeping the current period starts one.
    NotStarted,
    /// A run is alive and the current period is still open.
    OnTrack,
    /// The last period was missed. Keeping the current one recovers it;
    /// missing it too ends the run.
    Recovering,
    /// The current period has already been kept.
    Kept,
}

/// The period now in progress.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Current {
    /// Not yet kept.
    Open,
    /// Its target has already been met.
    Kept,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Standing {
    /// Kept periods in the run that is alive, counting the current period
    /// once it is kept. Zero when no run is alive.
    pub length: u32,
    pub state: State,
    /// The longest run that has ended. Zero when none has.
    pub previous_best: u32,
    /// One mark per finished period, in the order given.
    pub marks: Vec<Mark>,
}

/// Works out the streak from every finished period, oldest first (`true`
/// for kept), and the period in progress.
pub fn standing(finished: &[bool], current: Current) -> Standing {
    let mut length = 0u32;
    let mut previous_best = 0u32;
    // Index of a missed period the run is waiting to recover from.
    let mut awaiting: Option<usize> = None;
    let mut marks = Vec::with_capacity(finished.len());

    for (index, &kept) in finished.iter().enumerate() {
        if kept {
            if let Some(missed) = awaiting.take() {
                marks[missed] = Mark::Recovered;
            }
            length += 1;
            marks.push(Mark::Kept);
        } else if length == 0 {
            marks.push(Mark::Missed);
        } else if let Some(missed) = awaiting.take() {
            // The second miss in a row: the run is over.
            marks[missed] = Mark::Missed;
            marks.push(Mark::Missed);
            previous_best = previous_best.max(length);
            length = 0;
        } else {
            awaiting = Some(index);
            marks.push(Mark::AwaitingRecovery);
        }
    }

    let state = match (current, awaiting) {
        (Current::Kept, missed) => {
            if let Some(missed) = missed {
                marks[missed] = Mark::Recovered;
            }
            length += 1;
            State::Kept
        }
        (Current::Open, Some(_)) => State::Recovering,
        (Current::Open, None) if length > 0 => State::OnTrack,
        (Current::Open, None) => State::NotStarted,
    };
    Standing { length, state, previous_best, marks }
}

#[cfg(test)]
mod tests {
    use super::*;
    use Mark::{AwaitingRecovery as Awaiting, Kept as K, Missed as M, Recovered as R};

    /// "KKM" style shorthand: K kept, M missed.
    fn periods(text: &str) -> Vec<bool> {
        text.chars().map(|c| c == 'K').collect()
    }

    fn open(text: &str) -> Standing {
        standing(&periods(text), Current::Open)
    }

    fn kept(text: &str) -> Standing {
        standing(&periods(text), Current::Kept)
    }

    #[test]
    fn nothing_recorded_is_not_started() {
        let s = open("");
        assert_eq!((s.length, s.state, s.previous_best), (0, State::NotStarted, 0));
        assert!(s.marks.is_empty());
    }

    #[test]
    fn kept_periods_in_a_row_are_counted() {
        let s = open("KKK");
        assert_eq!((s.length, s.state, s.previous_best), (3, State::OnTrack, 0));
        assert_eq!(s.marks, vec![K, K, K]);
    }

    #[test]
    fn the_current_period_counts_as_soon_as_it_is_kept() {
        let s = kept("KKK");
        assert_eq!((s.length, s.state), (4, State::Kept));
        let first = kept("");
        assert_eq!((first.length, first.state), (1, State::Kept));
    }

    #[test]
    fn one_miss_opens_recovery_without_resetting_the_count() {
        let s = open("KKKM");
        assert_eq!((s.length, s.state, s.previous_best), (3, State::Recovering, 0));
        assert_eq!(s.marks, vec![K, K, K, Awaiting]);
    }

    #[test]
    fn keeping_the_next_period_recovers_the_miss() {
        let s = open("KKKMK");
        assert_eq!((s.length, s.state, s.previous_best), (4, State::OnTrack, 0));
        assert_eq!(s.marks, vec![K, K, K, R, K]);
    }

    #[test]
    fn the_current_period_recovers_a_miss_once_kept() {
        let s = kept("KKKM");
        assert_eq!((s.length, s.state), (4, State::Kept));
        assert_eq!(s.marks, vec![K, K, K, R]);
    }

    #[test]
    fn a_missed_period_never_adds_to_the_count() {
        // Five kept periods and two recovered misses.
        assert_eq!(open("KKMKKMK").length, 5);
    }

    #[test]
    fn recovery_can_be_used_again_after_a_kept_period() {
        let s = open("KMKMKMK");
        assert_eq!((s.length, s.state, s.previous_best), (4, State::OnTrack, 0));
        assert_eq!(s.marks, vec![K, R, K, R, K, R, K]);
    }

    #[test]
    fn two_misses_in_a_row_end_the_streak_and_keep_the_best() {
        let s = open("KKKMM");
        assert_eq!((s.length, s.state, s.previous_best), (0, State::NotStarted, 3));
        assert_eq!(s.marks, vec![K, K, K, M, M]);
    }

    #[test]
    fn a_new_streak_starts_after_one_has_ended() {
        let s = open("KKKMMKK");
        assert_eq!((s.length, s.state, s.previous_best), (2, State::OnTrack, 3));
        assert_eq!(s.marks, vec![K, K, K, M, M, K, K]);
    }

    #[test]
    fn the_previous_best_is_the_longest_ended_streak() {
        let s = open("KKMMKKKKMMKMM");
        assert_eq!((s.length, s.previous_best), (0, 4));
        // The streak that is alive is never its own previous best.
        let alive = open("KMMKKKKK");
        assert_eq!((alive.length, alive.previous_best), (5, 1));
    }

    #[test]
    fn misses_before_any_streak_are_plain_misses() {
        let s = open("MMMK");
        assert_eq!((s.length, s.state, s.previous_best), (1, State::OnTrack, 0));
        assert_eq!(s.marks, vec![M, M, M, K]);
    }

    #[test]
    fn a_single_miss_after_a_streak_ended_does_not_open_recovery() {
        // Nothing is alive after the two misses, so the third is a plain miss.
        let s = open("KKMMM");
        assert_eq!((s.length, s.state, s.previous_best), (0, State::NotStarted, 2));
        assert_eq!(s.marks, vec![K, K, M, M, M]);
    }

    #[test]
    fn a_one_period_streak_can_be_recovered_too() {
        let s = open("KM");
        assert_eq!((s.length, s.state), (1, State::Recovering));
        let ended = open("KMM");
        assert_eq!((ended.length, ended.state, ended.previous_best), (0, State::NotStarted, 1));
    }

    #[test]
    fn there_is_one_mark_per_finished_period() {
        for text in ["", "K", "M", "KMKMMKKM", "MMKKMKMMMK"] {
            assert_eq!(open(text).marks.len(), text.len());
            assert_eq!(kept(text).marks.len(), text.len());
        }
    }
}
