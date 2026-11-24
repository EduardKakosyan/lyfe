-- Study sessions: timed on the phone, counted by the week like the gym.
-- (0017 is taken by holdings and net worth.)

-- What a session was about, named by the owner. A subject is found again
-- by its name whatever the case, so a name typed on the phone without a
-- connection joins the subject already kept.
create table study_subjects (
    id uuid primary key default gen_random_uuid(),
    name text not null check (trim(name) <> '' and length(name) <= 60),
    created_at timestamptz not null default now()
);
create unique index study_subjects_name on study_subjects (lower(name));

-- One row per session timed on the phone. The id is made on the phone when
-- the timer starts, so a session sent twice is stored once.
create table study_sessions (
    id uuid primary key,
    started_at timestamptz not null,
    ended_at timestamptz not null,
    -- Time on the timer: from start to end less any pause.
    active_s integer not null check (active_s >= 0),
    subject_id uuid not null references study_subjects (id),
    -- Answering questions, reading, or building something.
    kind text not null check (kind in ('questions', 'reading', 'build')),
    -- Questions answered in it, and how many of them were right the first
    -- time; either may be left out.
    answered integer check (answered between 0 and 1000),
    right_first integer check (right_first >= 0),
    -- For a build session: what was built and why, in the owner's words,
    -- without looking it up.
    explain_back text check (explain_back is null or (trim(explain_back) <> '' and length(explain_back) <= 4000)),
    received_at timestamptz not null default now(),
    -- The device that sent it; kept when that device later signs out.
    device_session_id bigint references device_sessions (id),
    check (ended_at >= started_at),
    check (right_first is null or (answered is not null and right_first <= answered))
);

create index study_sessions_started_at_idx on study_sessions (started_at);
