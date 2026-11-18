-- Step 3: breath sessions.

-- One row per session run on the phone. The id is made on the phone when
-- the session starts, so a session sent twice (a retry after a dropped
-- connection) is stored once.
create table breath_sessions (
    id uuid primary key,
    started_at timestamptz not null,
    ended_at timestamptz not null,
    -- The table it was run with.
    round_s integer not null check (round_s > 0),
    rounds integer not null check (rounds > 0),
    received_at timestamptz not null default now(),
    -- The device that sent it; kept when that device later signs out.
    device_session_id bigint references device_sessions (id)
);

create index breath_sessions_started_at_idx on breath_sessions (started_at);

-- Every hold. A round the owner did not tap in has no row.
create table breath_holds (
    session_id uuid not null references breath_sessions (id) on delete cascade,
    -- Counted from 1.
    round integer not null check (round > 0),
    hold_ms integer not null check (hold_ms >= 0),
    primary key (session_id, round)
);
