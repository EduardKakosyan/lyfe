//! Goals: set on a reading, changed with their history kept, parked and
//! ended; and exams, with their practice scores and result. Where each
//! stands is worked out from what is stored, in `routines::goals` and
//! `routines::exam`.

use super::*;
use crate::routines::exam::{self, Exam, Outcome, Practice, Sitting};
use crate::routines::goals::{self, Change, Goal, GoalsView, Reading, Readings, Status};
use crate::routines::weight;

/// What lyfe reads now for every goal, and the study sessions behind it.
async fn readings(state: &AppState, today: NaiveDate) -> Result<(Option<f64>, Option<f64>, Option<f64>, Vec<study::Session>), ApiError> {
    let weigh_ins = db::weigh_ins(&state.pool, state.timezone).await?;
    let weight_g = weight::average_on(&weight::daily(&weigh_ins), today).map(|(grams, _)| grams);
    let body_fat = db::latest_body_fat(&mut *state.pool.acquire().await?, today).await?;
    let best_hold_s = breath::best_ever_ms(&db::breath_sessions(&state.pool, state.timezone).await?)
        .map(|ms| f64::from(ms) / 1000.0);
    let study = db::study_sessions(&state.pool, state.timezone).await?;
    Ok((weight_g, body_fat, best_hold_s, study))
}

/// Every goal as the apps show it, as of `today`.
pub(super) async fn snapshot(state: &AppState, today: NaiveDate) -> Result<GoalsView, ApiError> {
    let (weight_g, body_fat, best_hold_s, study) = readings(state, today).await?;
    let all = db::goals(&mut *state.pool.acquire().await?).await?;
    Ok(goals::view(&all, &Readings { weight_g, body_fat, best_hold_s, study: &study }, today))
}

#[derive(Deserialize)]
pub(super) struct GoalRequest {
    /// Left out to keep the one it has, or to name a new goal after what
    /// it reads.
    title: Option<String>,
    /// What a new goal reads; a goal already set keeps its own.
    reading: Option<String>,
    /// For a study goal, the subject by name; none for every subject.
    subject: Option<String>,
    /// In the reading's own unit: seconds, grams, percent or minutes. An
    /// exam's is its pass mark, given with the exam.
    target_value: Option<f64>,
    /// For an exam, the day it is sat.
    due_on: NaiveDate,
    /// For an exam: what it is held to.
    exam: Option<ExamRequest>,
}

#[derive(Deserialize)]
pub(super) struct ExamRequest {
    name: String,
    scale_max: u32,
    pass_mark: u32,
    #[serde(default)]
    ready_margin: u32,
    #[serde(default = "three")]
    ready_runs: u32,
    valid_months: Option<u32>,
    #[serde(default)]
    domains: Vec<DomainRequest>,
}

fn three() -> u32 {
    3
}

#[derive(Deserialize)]
pub(super) struct DomainRequest {
    name: String,
    weight_pct: u32,
}

impl ExamRequest {
    /// The exam as it would be kept, its practice and result taken from
    /// `kept`.
    fn exam(self, kept: Option<&Exam>) -> Result<Exam, ApiError> {
        let tidy = |text: &str| text.split_whitespace().collect::<Vec<_>>().join(" ");
        let exam = Exam {
            name: tidy(&self.name),
            scale_max: self.scale_max,
            pass_mark: self.pass_mark,
            ready_margin: self.ready_margin,
            ready_runs: self.ready_runs,
            valid_months: self.valid_months,
            domains: self
                .domains
                .into_iter()
                .map(|d| exam::Domain { name: tidy(&d.name), weight_pct: d.weight_pct })
                .collect(),
            result: kept.and_then(|exam| exam.result),
            practice: kept.map(|exam| exam.practice.clone()).unwrap_or_default(),
        };
        exam::check(&exam).map_err(ApiError::BadRequest)?;
        Ok(exam)
    }
}

fn named(reading: Reading, subject: Option<&str>) -> String {
    match (reading, subject) {
        (Reading::BreathHold, _) => "Breath hold".into(),
        (Reading::Weight, _) => "Weight".into(),
        (Reading::BodyFat, _) => "Body fat".into(),
        (Reading::StudyMinutes, Some(subject)) => format!("Study · {subject}"),
        (Reading::StudyMinutes, None) => "Study".into(),
        (Reading::Exam, _) => "Exam".into(),
    }
}

fn shown(value: f64) -> String {
    format!("{}", (value * 100.0).round() / 100.0)
}

/// Sets a goal, or changes the title, figure or date of one already set.
/// A new goal starts where its reading stands today, and is active unless
/// three already are. A change is recorded, not written over.
pub(super) async fn set(
    State(state): State<AppState>,
    _device: Device,
    Path(id): Path<Uuid>,
    Json(request): Json<GoalRequest>,
) -> Result<Json<HomeResponse>, ApiError> {
    let today = (state.now)().with_timezone(&state.timezone).date_naive();
    if request.due_on <= today || (request.due_on - today).num_days() > goals::LONGEST_DAYS {
        return Err(ApiError::BadRequest("due_on is after today and within ten years"));
    }
    if request.target_value.is_some_and(|value| !value.is_finite()) {
        return Err(ApiError::BadRequest("target_value is a number"));
    }
    let title = match request.title.as_deref() {
        Some(text) => Some(goals::title(text).ok_or(ApiError::BadRequest("a title is 1 to 80 characters"))?),
        None => None,
    };

    let (weight_g, body_fat, best_hold_s, study) = readings(&state, today).await?;
    let readings = Readings { weight_g, body_fat, best_hold_s, study: &study };
    let mut tx = state.pool.begin().await?;
    db::lock_goals(&mut tx).await?;
    let existing = db::goals(&mut tx).await?.into_iter().find(|goal| goal.id == id);
    match existing {
        Some(mut goal) => {
            if request.reading.as_deref().is_some_and(|reading| reading != goal.reading.as_str()) {
                return Err(ApiError::BadRequest("a goal keeps what it reads; set a new one instead"));
            }
            let target_value = match (goal.reading, request.exam) {
                (Reading::Exam, Some(asked)) => {
                    let exam = asked.exam(goal.exam.as_ref())?;
                    db::save_exam(&mut tx, goal.id, &exam).await?;
                    let pass_mark = f64::from(exam.pass_mark);
                    goal.exam = Some(exam);
                    pass_mark
                }
                (Reading::Exam, None) => goal.target_value,
                (_, Some(_)) => return Err(ApiError::BadRequest("only an exam goal has an exam")),
                (_, None) => request.target_value.ok_or(ApiError::BadRequest("target_value is needed"))?,
            };
            if !goal.reading.sensible().contains(&target_value) || target_value == goal.start_value {
                return Err(ApiError::BadRequest("target_value makes no sense for what it reads"));
            }
            let mut changes = Vec::new();
            let mut note = |what: &str, was: String, now: String| {
                if was != now {
                    changes.push(Change { on: today, what: what.into(), was, now });
                }
            };
            if let Some(title) = title {
                note("title", goal.title.clone(), title.clone());
                goal.title = title;
            }
            note("target", shown(goal.target_value), shown(target_value));
            note("due", goal.due_on.to_string(), request.due_on.to_string());
            goal.target_value = target_value;
            goal.due_on = request.due_on;
            db::update_goal(&mut tx, &goal, &changes).await?;
        }
        None => {
            let reading = request
                .reading
                .as_deref()
                .and_then(Reading::parse)
                .ok_or(ApiError::BadRequest("reading is breath_hold, weight, body_fat, study_minutes or exam"))?;
            let subject = match (reading, request.subject.as_deref()) {
                (Reading::StudyMinutes | Reading::Exam, Some(name)) => {
                    let name = study::subject_name(name).ok_or(ApiError::BadRequest("a subject is 1 to 60 characters"))?;
                    Some((db::study_subject(&mut tx, &name).await?, name))
                }
                (_, Some(_)) => return Err(ApiError::BadRequest("only a study or exam goal has a subject")),
                (_, None) => None,
            };
            let Some(start_value) = readings.start(reading) else {
                return Err(ApiError::BadRequest("lyfe has no reading of that yet"));
            };
            let exam = match (reading, request.exam) {
                (Reading::Exam, Some(asked)) => Some(asked.exam(None)?),
                (Reading::Exam, None) => return Err(ApiError::BadRequest("an exam goal needs its exam")),
                (_, Some(_)) => return Err(ApiError::BadRequest("only an exam goal has an exam")),
                (_, None) => None,
            };
            let target_value = match &exam {
                Some(exam) => f64::from(exam.pass_mark),
                None => request.target_value.ok_or(ApiError::BadRequest("target_value is needed"))?,
            };
            if !reading.sensible().contains(&target_value) || target_value == start_value {
                return Err(ApiError::BadRequest("target_value makes no sense for what it reads"));
            }
            let status = if db::active_goals(&mut tx, id).await? < goals::ACTIVE_LIMIT as i64 {
                Status::Active
            } else {
                Status::Parked
            };
            let goal = Goal {
                id,
                title: title.unwrap_or_else(|| match &exam {
                    Some(exam) => exam.name.clone(),
                    None => named(reading, subject.as_ref().map(|(_, name)| name.as_str())),
                }),
                reading,
                subject_id: subject.map(|(id, _)| id),
                subject: None,
                start_on: today,
                start_value,
                target_value,
                due_on: request.due_on,
                status,
                ended_on: None,
                note: None,
                changes: vec![],
                exam,
            };
            db::insert_goal(&mut tx, &goal).await?;
            if let Some(exam) = &goal.exam {
                db::save_exam(&mut tx, goal.id, exam).await?;
            }
            tracing::info!(id = %goal.id, reading = reading.as_str(), status = status.as_str(), "goal set");
        }
    }
    tx.commit().await?;
    Ok(Json(home_now(&state).await?))
}

#[derive(Deserialize)]
pub(super) struct StatusRequest {
    /// `active`, `parked`, `reached` or `dropped`.
    status: String,
    /// Why, in a line, for a goal that ends.
    note: Option<String>,
}

/// Makes a goal active, parks it, or ends it as reached or dropped. Only
/// three are active at once. An ended goal can be taken up again.
pub(super) async fn set_status(
    State(state): State<AppState>,
    _device: Device,
    Path(id): Path<Uuid>,
    Json(request): Json<StatusRequest>,
) -> Result<Json<HomeResponse>, ApiError> {
    let today = (state.now)().with_timezone(&state.timezone).date_naive();
    let status = Status::parse(&request.status).ok_or(ApiError::BadRequest("status is active, parked, reached or dropped"))?;
    let note = request.note.as_deref().map(str::trim).filter(|text| !text.is_empty()).map(str::to_string);
    if note.as_ref().is_some_and(|text| text.chars().count() > 500) {
        return Err(ApiError::BadRequest("a note is at most 500 characters"));
    }
    let mut tx = state.pool.begin().await?;
    db::lock_goals(&mut tx).await?;
    let mut goal = db::goals(&mut tx).await?.into_iter().find(|goal| goal.id == id).ok_or(ApiError::NotFound)?;
    if goal.status == status {
        return Ok(Json(home_now(&state).await?));
    }
    if status == Status::Active && db::active_goals(&mut tx, id).await? >= goals::ACTIVE_LIMIT as i64 {
        return Err(ApiError::BadRequest("three goals are active; park one first"));
    }
    let change = Change { on: today, what: "status".into(), was: goal.status.as_str().into(), now: status.as_str().into() };
    goal.status = status;
    goal.ended_on = status.ended().then_some(today);
    if status.ended() {
        goal.note = note;
    }
    db::update_goal(&mut tx, &goal, &[change]).await?;
    tx.commit().await?;
    Ok(Json(home_now(&state).await?))
}

#[derive(Deserialize)]
pub(super) struct PracticeRequest {
    /// Made on the phone, so a score sent twice is kept once.
    id: Uuid,
    taken_on: NaiveDate,
    score: u32,
    /// How each part went, in percent, by the part's name.
    #[serde(default)]
    domains: Vec<PracticeDomainRequest>,
}

#[derive(Deserialize)]
pub(super) struct PracticeDomainRequest {
    name: String,
    pct: u32,
}

/// Keeps a practice test's score for an exam.
pub(super) async fn record_practice(
    State(state): State<AppState>,
    _device: Device,
    Path(id): Path<Uuid>,
    Json(request): Json<PracticeRequest>,
) -> Result<Json<HomeResponse>, ApiError> {
    let today = (state.now)().with_timezone(&state.timezone).date_naive();
    if request.taken_on > today {
        return Err(ApiError::BadRequest("taken_on is not after today"));
    }
    let mut tx = state.pool.begin().await?;
    let goal = db::goals(&mut tx).await?.into_iter().find(|goal| goal.id == id).ok_or(ApiError::NotFound)?;
    let Some(exam) = goal.exam else {
        return Err(ApiError::BadRequest("only an exam has practice scores"));
    };
    if request.score > exam.scale_max {
        return Err(ApiError::BadRequest("the score is more than the exam is marked out of"));
    }
    let mut domains = Vec::new();
    for part in request.domains {
        let Some(domain) = exam.domains.iter().find(|d| d.name.eq_ignore_ascii_case(part.name.trim())) else {
            return Err(ApiError::BadRequest("a part the exam does not have"));
        };
        if part.pct > 100 || domains.iter().any(|(name, _): &(String, u32)| name == &domain.name) {
            return Err(ApiError::BadRequest("each part once, in percent"));
        }
        domains.push((domain.name.clone(), part.pct));
    }
    let practice = Practice { id: request.id, taken_on: request.taken_on, score: request.score, domains };
    if db::insert_practice(&mut tx, id, &practice).await? {
        tracing::info!(goal = %id, "practice score kept");
    }
    tx.commit().await?;
    Ok(Json(home_now(&state).await?))
}

#[derive(Deserialize)]
pub(super) struct ResultRequest {
    /// `passed` or `failed`.
    outcome: String,
    on: NaiveDate,
    score: Option<u32>,
}

/// Keeps how an exam went. A pass ends its goal as reached; a fail leaves
/// it active, for its date to be moved to the next sitting.
pub(super) async fn record_result(
    State(state): State<AppState>,
    _device: Device,
    Path(id): Path<Uuid>,
    Json(request): Json<ResultRequest>,
) -> Result<Json<HomeResponse>, ApiError> {
    let today = (state.now)().with_timezone(&state.timezone).date_naive();
    let outcome = Outcome::parse(&request.outcome).ok_or(ApiError::BadRequest("outcome is passed or failed"))?;
    if request.on > today {
        return Err(ApiError::BadRequest("on is not after today"));
    }
    let mut tx = state.pool.begin().await?;
    db::lock_goals(&mut tx).await?;
    let mut goal = db::goals(&mut tx).await?.into_iter().find(|goal| goal.id == id).ok_or(ApiError::NotFound)?;
    let Some(exam) = &goal.exam else {
        return Err(ApiError::BadRequest("only an exam has a result"));
    };
    if request.score.is_some_and(|score| score > exam.scale_max) {
        return Err(ApiError::BadRequest("the score is more than the exam is marked out of"));
    }
    db::set_exam_result(&mut tx, id, &Sitting { outcome, on: request.on, score: request.score }).await?;
    let was = goal.status;
    match outcome {
        Outcome::Passed => {
            goal.status = Status::Reached;
            goal.ended_on = Some(request.on);
        }
        Outcome::Failed if was.ended() => {
            goal.status = Status::Parked;
            goal.ended_on = None;
        }
        Outcome::Failed => {}
    }
    let changes: Vec<Change> = (was != goal.status)
        .then(|| Change { on: today, what: "status".into(), was: was.as_str().into(), now: goal.status.as_str().into() })
        .into_iter()
        .collect();
    db::update_goal(&mut tx, &goal, &changes).await?;
    tx.commit().await?;
    Ok(Json(home_now(&state).await?))
}
