create table pool_entries (id uuid primary key, day date not null, metres float8 not null check (metres > 0 and metres <= 10000));
create table tape_entries (id uuid primary key, day date not null, height_cm float8 not null, waist_cm float8 not null, neck_cm float8 not null, hip_cm float8, estimate float8 not null check (estimate between 1 and 75));
create table confirmed_food_days (day date primary key);
create table trend_goal (singleton boolean primary key check (singleton), weekly_pct float8 not null check (weekly_pct between -1 and 1), since date not null);
