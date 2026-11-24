-- Step 4: weigh-ins.

-- One row per weight the owner typed, normally into the morning prompt.
-- The id is made on the phone, so a weight sent twice (a retry after a
-- dropped connection) is stored once. A day's weight is the last one typed
-- that day; earlier ones are kept, not overwritten.
create table weigh_ins (
    id uuid primary key,
    measured_at timestamptz not null,
    grams integer not null check (grams between 20000 and 400000),
    -- The unit it was typed in ("kg" or "lb"), for the record. Figures are
    -- worked out from the grams.
    unit text not null check (unit in ('kg', 'lb')),
    received_at timestamptz not null default now(),
    -- The device that sent it; kept when that device later signs out.
    device_session_id bigint references device_sessions (id)
);

create index weigh_ins_measured_at_idx on weigh_ins (measured_at);
