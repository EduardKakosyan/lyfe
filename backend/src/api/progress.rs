use super::*;
use chrono::Duration as Days;

#[derive(Serialize, sqlx::FromRow)]
struct Point {
    day: NaiveDate,
    value: f64,
}

#[derive(Serialize)]
pub(super) struct Progress {
    pools: Vec<Point>,
    swims: Vec<Point>,
    tapes: Vec<Point>,
    tape_due: bool,
    holds: Vec<Point>,
    goal: Option<f64>,
    confirmed: bool,
    proposed_kcal: Option<i32>,
}

fn adjustment(av: [f64; 3], goal: f64) -> Option<i32> {
    let diff: Vec<_> = av
        .windows(2)
        .map(|w| (w[1] / w[0] - 1.) * 100. - goal)
        .collect();
    if diff.iter().all(|d| *d > 0.25) {
        Some(-100)
    } else if diff.iter().all(|d| *d < -0.25) {
        Some(100)
    } else {
        None
    }
}

async fn proposal(
    state: &AppState,
    today: NaiveDate,
    conn: &mut sqlx::PgConnection,
) -> Result<Option<i32>, ApiError> {
    let base:Option<(i32,f64)>=sqlx::query_as("select kcal,weekly_pct from food_targets cross join trend_goal where effective_on<=$1 and since<=$1::date-14 order by effective_on desc limit 1").bind(today).fetch_optional(&mut *conn).await?;
    let Some((kcal, goal)) = base else {
        return Ok(None);
    };
    let ready: bool = sqlx::query_scalar(
        "with logged as (
            select (coalesce(parent.eaten_at,e.eaten_at) at time zone $2)::date as day,e.kcal,e.figures
            from food_entries e left join food_entries parent on parent.id=e.part_of
            where e.removed_at is null and e.source<>'built' and
                (e.part_of is null or (parent.id is not null and parent.removed_at is null))
         ), complete as (
            select l.day from logged l join confirmed_food_days d using(day)
            where l.day >= $1::date-14 and l.day < $1 group by l.day
            having sum(kcal)>0 and bool_and(figures='known')
         ) select (select count(*) from complete)=14 and not exists
            (select from food_targets where effective_on > $1::date-14 and effective_on <= $1)"
    ).bind(today).bind(state.timezone.name()).fetch_one(&mut *conn).await?;
    if !ready {
        return Ok(None);
    }
    let averages:Vec<f64>=sqlx::query_scalar("with daily as (select distinct on (day) (measured_at at time zone $2)::date as day,grams from weigh_ins order by day,measured_at desc,id desc) select avg(grams)::float8 from daily where day >= $1::date-21 and day < $1 group by (($1::date-day-1)/7) having count(*)>=3 order by (($1::date-day-1)/7) desc").bind(today).bind(state.timezone.name()).fetch_all(conn).await?;
    Ok(averages
        .try_into()
        .ok()
        .and_then(|av| adjustment(av, goal))
        .map(|d| kcal + d)
        .filter(|k| (800..=10000).contains(k)))
}

pub(super) async fn snapshot(state: &AppState, today: NaiveDate) -> Result<Progress, ApiError> {
    let p = &state.pool;
    let pools=sqlx::query_as("select day,metres as value from pool_entries where day between $1::date-55 and $1 order by day desc,id").bind(today).fetch_all(p).await?;
    let swims=sqlx::query_as("select start_local::date as day,(raw->>'distance')::float8 as value from garmin_activities where type_key='lap_swimming' and gone_at is null and jsonb_typeof(raw->'distance')='number' and start_local::date between $1::date-55 and $1 order by start_local desc").bind(today).fetch_all(p).await?;
    let tapes:Vec<Point>=sqlx::query_as("select day,estimate as value from tape_entries where day between $1::date-55 and $1 order by day desc,id").bind(today).fetch_all(p).await?;
    let tape_due = tapes
        .first()
        .is_none_or(|x| today - x.day >= Days::days(14));
    let holds = db::breath_sessions(p, state.timezone)
        .await?
        .iter()
        .rev()
        .filter(|s| (today - Days::days(55)..=today).contains(&s.date()))
        .filter_map(|s| {
            Some(Point {
                day: s.date(),
                value: f64::from(s.best_ms()?) / 1000.,
            })
        })
        .collect();
    let goal = sqlx::query_scalar("select weekly_pct from trend_goal")
        .fetch_optional(p)
        .await?;
    let confirmed =
        sqlx::query_scalar("select exists(select from confirmed_food_days where day=$1)")
            .bind(today)
            .fetch_one(p)
            .await?;
    let proposed_kcal = proposal(state, today, &mut *p.acquire().await?).await?;
    Ok(Progress {
        pools,
        swims,
        tapes,
        tape_due,
        holds,
        goal,
        confirmed,
        proposed_kcal,
    })
}

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub(super) enum Capture {
    Pool {
        id: Uuid,
        day: NaiveDate,
        metres: f64,
    },
    Tape {
        id: Uuid,
        day: NaiveDate,
        height: f64,
        waist: f64,
        neck: f64,
        hip: Option<f64>,
    },
    Goal {
        pct: f64,
    },
    Confirm {
        day: NaiveDate,
    },
    Approve {
        day: NaiveDate,
        kcal: i32,
    },
}

fn estimate(height: f64, waist: f64, neck: f64, hip: Option<f64>) -> Option<f64> {
    if !(80.0..=250.).contains(&height)
        || !(20.0..=250.).contains(&waist)
        || !(15.0..=80.).contains(&neck)
        || hip.is_some_and(|v| !(30.0..=250.).contains(&v))
    {
        return None;
    }
    // The circumference equations take inches; the phone takes centimetres.
    let h = (height / 2.54).log10();
    let pct = match hip {
        None => 86.010 * ((waist - neck) / 2.54).log10() - 70.041 * h + 36.76,
        Some(hip) => 163.205 * ((waist + hip - neck) / 2.54).log10() - 97.684 * h - 78.387,
    };
    (1.0..=75.).contains(&pct).then_some(pct)
}

pub(super) async fn record(
    State(state): State<AppState>,
    _: Device,
    Json(input): Json<Capture>,
) -> Result<Json<HomeResponse>, ApiError> {
    let today = (state.now)().with_timezone(&state.timezone).date_naive();
    let bad = ApiError::BadRequest("invalid progress entry");
    let mut tx = state.pool.begin().await?;
    match input {
        Capture::Pool { id, day, metres } if day <= today && metres > 0. && metres <= 10000. => {
            sqlx::query("insert into pool_entries values($1,$2,$3) on conflict(id) do nothing")
                .bind(id)
                .bind(day)
                .bind(metres)
                .execute(&mut *tx)
                .await?;
        }
        Capture::Tape {
            id,
            day,
            height,
            waist,
            neck,
            hip,
        } if day <= today => {
            let pct = estimate(height, waist, neck, hip).ok_or(bad)?;
            sqlx::query(
                "insert into tape_entries values($1,$2,$3,$4,$5,$6,$7) on conflict(id) do nothing",
            )
            .bind(id)
            .bind(day)
            .bind(height)
            .bind(waist)
            .bind(neck)
            .bind(hip)
            .bind(pct)
            .execute(&mut *tx)
            .await?;
        }
        Capture::Goal { pct } if (-1.0..=1.).contains(&pct) => {
            sqlx::query("insert into trend_goal values(true,$1,$2) on conflict(singleton) do update set weekly_pct=excluded.weekly_pct,since=excluded.since where trend_goal.weekly_pct<>excluded.weekly_pct").bind(pct).bind(today).execute(&mut *tx).await?;
        }
        Capture::Confirm { day } if day == today => {
            sqlx::query("insert into confirmed_food_days values($1) on conflict do nothing")
                .bind(day)
                .execute(&mut *tx)
                .await?;
        }
        Capture::Approve { day, kcal } if day == today => {
            sqlx::query("lock table food_targets,trend_goal in share row exclusive mode")
                .execute(&mut *tx)
                .await?;
            if proposal(&state, today, &mut tx).await? != Some(kcal) {
                return Err(ApiError::BadRequest("proposal no longer current"));
            }
            sqlx::query("insert into food_targets(effective_on,kcal,protein_g) select $1,$2,protein_g from food_targets where effective_on<=$1 order by effective_on desc limit 1").bind(today).bind(kcal).execute(&mut *tx).await?;
        }
        _ => return Err(bad),
    }
    tx.commit().await?;
    Ok(Json(home_now(&state).await?))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn both_weeks_miss_on_same_side() {
        assert_eq!(adjustment([100., 101., 102.], 0.), Some(-100));
        assert_eq!(adjustment([100., 99., 98.], 0.), Some(100));
        assert_eq!(adjustment([100., 99., 100.], 0.), None);
        assert_eq!(adjustment([100., 100., 100.], 0.), None);
    }
    #[test]
    fn circumference_units() {
        assert!((estimate(180., 90., 40., None).unwrap() - 18.5).abs() < 0.5);
        assert_eq!(estimate(180., 35., 40., None), None);
        assert!(estimate(170., 75., 34., Some(96.)).is_some());
    }
}
