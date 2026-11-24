-- Goals: where the owner means to get by a date, on a figure lyfe already
-- reads, or an exam to pass. Nothing about a figure goal is typed after it
-- is set; its reading moves it. An exam is moved by practice scores typed
-- after each test, and ended by its result. A goal is never deleted: it is
-- parked, reached or dropped.
create table goals (
    -- Made on the phone, so a goal sent twice is set once.
    id uuid primary key,
    title text not null check (trim(title) <> '' and length(title) <= 80),
    -- What it reads: the best breath hold (seconds), the seven-day average
    -- weight (grams), the body-fat estimate (percent), minutes of study
    -- since it was set, or an exam (its practice scores; see exams).
    reading text not null check (reading in ('breath_hold', 'weight', 'body_fat', 'study_minutes', 'exam')),
    -- For study: the subject it is on, or every subject when null. For an
    -- exam: the subject its study is on.
    subject_id uuid references study_subjects (id),
    start_on date not null,
    -- Where the reading stood when it was set; zero for study and exams.
    -- For an exam the target is its pass mark and the due date the day it
    -- is sat.
    start_value float8 not null,
    target_value float8 not null,
    due_on date not null,
    status text not null default 'active' check (status in ('active', 'parked', 'reached', 'dropped')),
    ended_on date,
    note text check (note is null or length(note) <= 500),
    created_at timestamptz not null default now(),
    check (due_on > start_on),
    check (target_value <> start_value),
    check ((status in ('reached', 'dropped')) = (ended_on is not null)),
    constraint goals_subject_check check (subject_id is null or reading in ('study_minutes', 'exam'))
);

-- Every change to a goal's title, figure, date or status, so a goal moved
-- keeps where it was.
create table goal_changes (
    id bigserial primary key,
    goal_id uuid not null references goals (id) on delete cascade,
    changed_on date not null,
    what text not null check (what in ('title', 'target', 'due', 'status')),
    was text not null,
    became text not null
);
create index goal_changes_goal on goal_changes (goal_id, id);

-- What an exam goal is held to, as the exam's owner publishes it: the
-- score it is marked out of, the pass mark, how long a pass stays valid;
-- and the owner's own rule for being ready to sit it: this many practice
-- tests in a row at least this far over the pass mark. `result` is the
-- last sitting's, once there has been one.
create table exams (
    goal_id uuid primary key references goals (id) on delete cascade,
    name text not null check (trim(name) <> '' and length(name) <= 80),
    scale_max integer not null check (scale_max between 1 and 10000),
    pass_mark integer not null check (pass_mark >= 1),
    ready_margin integer not null default 0 check (ready_margin >= 0),
    ready_runs integer not null default 3 check (ready_runs between 1 and 10),
    valid_months integer check (valid_months between 1 and 240),
    result text check (result in ('passed', 'failed')),
    result_on date,
    result_score integer check (result_score >= 0),
    check (pass_mark + ready_margin <= scale_max),
    check ((result is null) = (result_on is null))
);

-- The parts the exam is marked in, with the share each carries, in the
-- order its owner lists them.
create table exam_domains (
    goal_id uuid not null references exams (goal_id) on delete cascade,
    position integer not null check (position >= 1),
    name text not null check (trim(name) <> '' and length(name) <= 60),
    weight_pct integer not null check (weight_pct between 1 and 100),
    primary key (goal_id, position)
);

-- A practice test, typed after it was taken. The id is made on the phone,
-- so a score sent twice is kept once.
create table practice_scores (
    id uuid primary key,
    goal_id uuid not null references exams (goal_id) on delete cascade,
    taken_on date not null,
    score integer not null check (score >= 0),
    received_at timestamptz not null default now()
);
create index practice_scores_goal on practice_scores (goal_id, taken_on);

-- How a practice test went in each part, by the part's name, where the
-- test said.
create table practice_domain_scores (
    score_id uuid not null references practice_scores (id) on delete cascade,
    domain text not null,
    pct integer not null check (pct between 0 and 100),
    primary key (score_id, domain)
);
