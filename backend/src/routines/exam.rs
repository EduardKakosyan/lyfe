//! Exams: a result to get, such as a certification.
//!
//! Pure rules, no I/O. An exam has no percentage: it is passed or not, on
//! the day it is sat. What says whether the owner is ready is practice:
//! scores typed after each practice test, against the exam's own pass
//! mark, and the owner's own rule for being ready (so many in a row at
//! least so far over the pass mark). Where the exam is marked in parts,
//! each part's latest figure shows which one is weakest. Once passed, the
//! pass stays valid for as long as the exam's owner says.

use chrono::{Months, NaiveDate};
use serde::Serialize;
use uuid::Uuid;

/// Practice tests the apps are sent, the latest last.
pub const PRACTICE_SHOWN: usize = 10;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Domain {
    pub name: String,
    pub weight_pct: u32,
}

/// A practice test as typed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Practice {
    pub id: Uuid,
    pub taken_on: NaiveDate,
    pub score: u32,
    /// How each part went, by the part's name, where the test said.
    pub domains: Vec<(String, u32)>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    Passed,
    Failed,
}

impl Outcome {
    pub fn parse(text: &str) -> Option<Outcome> {
        match text {
            "passed" => Some(Outcome::Passed),
            "failed" => Some(Outcome::Failed),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Outcome::Passed => "passed",
            Outcome::Failed => "failed",
        }
    }
}

/// How the last sitting went.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Sitting {
    pub outcome: Outcome,
    pub on: NaiveDate,
    pub score: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Exam {
    pub name: String,
    /// The score it is marked out of.
    pub scale_max: u32,
    pub pass_mark: u32,
    /// Ready once practice is at least this far over the pass mark...
    pub ready_margin: u32,
    /// ...this many tests in a row.
    pub ready_runs: u32,
    /// How long a pass stays valid, when it expires.
    pub valid_months: Option<u32>,
    pub domains: Vec<Domain>,
    pub result: Option<Sitting>,
    /// Oldest first.
    pub practice: Vec<Practice>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PracticeView {
    pub id: Uuid,
    pub taken_on: NaiveDate,
    pub score: u32,
    /// At least the score that counts toward being ready.
    pub over_ready: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DomainView {
    pub name: String,
    pub weight_pct: u32,
    /// The latest practice figure for it, in percent.
    pub latest_pct: Option<u32>,
}

/// An exam as the apps show it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ExamView {
    pub name: String,
    pub scale_max: u32,
    pub pass_mark: u32,
    /// The practice score that counts toward being ready.
    pub ready_at: u32,
    pub ready_runs: u32,
    pub valid_months: Option<u32>,
    pub result: Option<Sitting>,
    /// When a pass stops being valid, once passed.
    pub expires_on: Option<NaiveDate>,
    /// The latest practice tests, oldest first.
    pub practice: Vec<PracticeView>,
    /// The latest practice tests in a row at the ready score, at most
    /// `ready_runs`.
    pub in_a_row: u32,
    pub ready: bool,
    pub domains: Vec<DomainView>,
    /// The part with the lowest latest figure, when any has one.
    pub weakest: Option<String>,
    /// Minutes of study on the exam's subject since the goal was set.
    pub minutes: u32,
}

pub fn view(exam: &Exam, minutes: u32) -> ExamView {
    let ready_at = exam.pass_mark + exam.ready_margin;
    let mut practice: Vec<&Practice> = exam.practice.iter().collect();
    practice.sort_by_key(|p| (p.taken_on, p.id));
    let in_a_row = practice.iter().rev().take_while(|p| p.score >= ready_at).count().min(exam.ready_runs as usize) as u32;
    let domains: Vec<DomainView> = exam
        .domains
        .iter()
        .map(|domain| DomainView {
            name: domain.name.clone(),
            weight_pct: domain.weight_pct,
            latest_pct: practice
                .iter()
                .rev()
                .find_map(|p| p.domains.iter().find(|(name, _)| name.eq_ignore_ascii_case(&domain.name)).map(|(_, pct)| *pct)),
        })
        .collect();
    let weakest = domains
        .iter()
        .filter_map(|d| d.latest_pct.map(|pct| (pct, d)))
        .min_by_key(|(pct, d)| (*pct, std::cmp::Reverse(d.weight_pct)))
        .map(|(_, d)| d.name.clone());
    let expires_on = match (exam.result, exam.valid_months) {
        (Some(Sitting { outcome: Outcome::Passed, on, .. }), Some(months)) => on.checked_add_months(Months::new(months)),
        _ => None,
    };
    let shown = practice.len().saturating_sub(PRACTICE_SHOWN);
    ExamView {
        name: exam.name.clone(),
        scale_max: exam.scale_max,
        pass_mark: exam.pass_mark,
        ready_at,
        ready_runs: exam.ready_runs,
        valid_months: exam.valid_months,
        result: exam.result,
        expires_on,
        practice: practice[shown..]
            .iter()
            .map(|p| PracticeView { id: p.id, taken_on: p.taken_on, score: p.score, over_ready: p.score >= ready_at })
            .collect(),
        in_a_row,
        ready: in_a_row >= exam.ready_runs,
        domains,
        weakest,
        minutes,
    }
}

/// Whether an exam's figures hang together: a pass mark on its scale with
/// room for the margin, parts that are named and carry a share.
pub fn check(exam: &Exam) -> Result<(), &'static str> {
    if exam.name.trim().is_empty() || exam.name.chars().count() > 80 {
        return Err("an exam's name is 1 to 80 characters");
    }
    if !(1..=10_000).contains(&exam.scale_max) || exam.pass_mark == 0 || exam.pass_mark + exam.ready_margin > exam.scale_max {
        return Err("the pass mark and margin fit within the scale");
    }
    if !(1..=10).contains(&exam.ready_runs) {
        return Err("ready_runs is 1 to 10");
    }
    if exam.valid_months.is_some_and(|months| !(1..=240).contains(&months)) {
        return Err("valid_months is 1 to 240");
    }
    if exam.domains.len() > 20 {
        return Err("at most 20 parts");
    }
    for domain in &exam.domains {
        if domain.name.trim().is_empty() || domain.name.chars().count() > 60 || !(1..=100).contains(&domain.weight_pct) {
            return Err("a part has a name and a share of 1 to 100");
        }
    }
    let mut names: Vec<String> = exam.domains.iter().map(|d| d.name.trim().to_lowercase()).collect();
    names.sort();
    if names.windows(2).any(|pair| pair[0] == pair[1]) {
        return Err("two parts have the same name");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn date(s: &str) -> NaiveDate {
        s.parse().unwrap()
    }

    fn exam(scores: &[u32]) -> Exam {
        Exam {
            name: "Solutions architect".into(),
            scale_max: 1000,
            pass_mark: 720,
            ready_margin: 30,
            ready_runs: 3,
            valid_months: Some(36),
            domains: vec![
                Domain { name: "Secure".into(), weight_pct: 30 },
                Domain { name: "Resilient".into(), weight_pct: 26 },
                Domain { name: "High-performing".into(), weight_pct: 24 },
                Domain { name: "Cost-optimized".into(), weight_pct: 20 },
            ],
            result: None,
            practice: scores
                .iter()
                .enumerate()
                .map(|(i, score)| Practice {
                    id: Uuid::from_u128(i as u128 + 1),
                    taken_on: date("2026-11-01") + chrono::Duration::days(i as i64 * 3),
                    score: *score,
                    domains: vec![],
                })
                .collect(),
        }
    }

    #[test]
    fn ready_means_the_latest_tests_in_a_row_over_the_owners_mark() {
        let early = view(&exam(&[640, 705, 745]), 2850);
        assert_eq!((early.ready_at, early.in_a_row, early.ready), (750, 0, false));
        assert!(!early.practice[2].over_ready);
        let close = view(&exam(&[640, 760, 755]), 0);
        assert_eq!((close.in_a_row, close.ready), (2, false));
        let ready = view(&exam(&[700, 760, 755, 790, 800]), 0);
        assert_eq!((ready.in_a_row, ready.ready), (3, true));
        // A slip after being ready starts the count again.
        let slipped = view(&exam(&[760, 755, 790, 730]), 0);
        assert_eq!((slipped.in_a_row, slipped.ready), (0, false));
        assert_eq!(view(&exam(&[]), 0).in_a_row, 0);
    }

    #[test]
    fn each_part_shows_its_latest_figure_and_the_weakest_is_named() {
        let mut exam = exam(&[700, 745]);
        exam.practice[0].domains = vec![("Secure".into(), 60), ("Resilient".into(), 50)];
        exam.practice[1].domains = vec![("secure".into(), 78), ("High-performing".into(), 64)];
        let view = view(&exam, 0);
        let latest: Vec<Option<u32>> = view.domains.iter().map(|d| d.latest_pct).collect();
        assert_eq!(latest, [Some(78), Some(50), Some(64), None]);
        assert_eq!(view.weakest.as_deref(), Some("Resilient"));
    }

    #[test]
    fn only_the_latest_ten_tests_are_sent_oldest_first() {
        let scores: Vec<u32> = (0..14).map(|i| 600 + i * 10).collect();
        let view = view(&exam(&scores), 0);
        assert_eq!(view.practice.len(), 10);
        assert_eq!((view.practice[0].score, view.practice[9].score), (640, 730));
    }

    #[test]
    fn a_pass_stays_valid_for_the_months_the_exam_gives() {
        let mut passed = exam(&[760]);
        passed.result = Some(Sitting { outcome: Outcome::Passed, on: date("2027-01-04"), score: Some(801) });
        assert_eq!(view(&passed, 0).expires_on, Some(date("2030-01-04")));
        passed.valid_months = None;
        assert_eq!(view(&passed, 0).expires_on, None);
        let mut failed = exam(&[700]);
        failed.result = Some(Sitting { outcome: Outcome::Failed, on: date("2027-01-04"), score: Some(690) });
        assert_eq!(view(&failed, 0).expires_on, None);
    }

    #[test]
    fn figures_that_do_not_hang_together_are_refused() {
        assert_eq!(check(&exam(&[])), Ok(()));
        let mut bad = exam(&[]);
        bad.pass_mark = 990;
        assert!(check(&bad).is_err());
        let mut bad = exam(&[]);
        bad.domains.push(Domain { name: " secure ".into(), weight_pct: 5 });
        assert_eq!(check(&bad), Err("two parts have the same name"));
        let mut bad = exam(&[]);
        bad.domains[0].weight_pct = 0;
        assert!(check(&bad).is_err());
        let mut bad = exam(&[]);
        bad.ready_runs = 0;
        assert!(check(&bad).is_err());
        let mut bad = exam(&[]);
        bad.name = "  ".into();
        assert!(check(&bad).is_err());
    }
}
