-- Step 1: sign-in, Garmin activities, and per-source sync state.

-- lyfe has exactly one owner; the row holds their password hash.
create table owner (
    id boolean primary key default true check (id),
    password_hash text not null,
    updated_at timestamptz not null default now()
);

-- One row per signed-in device. Only a hash of the token is stored.
create table device_sessions (
    id bigint generated always as identity primary key,
    token_hash bytea not null unique,
    device_name text not null,
    created_at timestamptz not null default now(),
    last_used_at timestamptz not null default now(),
    revoked_at timestamptz
);

-- Activities as reported by the Garmin Connect Personal API. Garmin's
-- activity id is the unique capture id, so polling the same activity twice
-- can never count it twice.
create table garmin_activities (
    activity_id bigint primary key,
    type_key text not null,
    name text,
    -- Wall-clock time where the activity was recorded; decides which day
    -- and week a session belongs to.
    start_local timestamp not null,
    start_gmt timestamptz not null,
    duration_s double precision not null,
    raw jsonb not null,
    first_seen_at timestamptz not null default now(),
    last_seen_at timestamptz not null default now(),
    -- Set when a poll that covered this activity's date no longer returned
    -- it (deleted in Garmin Connect). Cleared if it reappears.
    gone_at timestamptz
);

create index garmin_activities_start_local_idx on garmin_activities (start_local);

-- Freshness of each outside data source, shown to the owner as "synced N ago".
create table source_sync (
    source text primary key,
    last_attempt_at timestamptz,
    last_success_at timestamptz,
    last_error text
);
