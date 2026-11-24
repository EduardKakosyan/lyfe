-- Step 5: saved meals, the food log, and its targets.

-- A meal the owner eats repeatedly, defined once from weighed ingredients:
-- the usual breakfast, a batch lunch. The id is made on the phone, so
-- saving the same meal twice stores it once, and saving it again replaces
-- the recipe. A meal that is removed is archived, not deleted, because
-- logged entries point at it.
create table saved_meals (
    id uuid primary key,
    name text not null,
    -- The part of the day it is logged under.
    slot text not null check (slot in ('breakfast', 'lunch', 'dinner', 'snack')),
    -- How many portions the weighed recipe makes: 1 for a single meal,
    -- more for a batch.
    portions integer not null check (portions between 1 and 50),
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    archived_at timestamptz
);

-- What went into the recipe, as weighed, with the figures from the label.
create table saved_meal_ingredients (
    meal_id uuid not null references saved_meals (id) on delete cascade,
    -- Counted from 1, in the order typed.
    position integer not null check (position > 0),
    name text not null,
    grams double precision not null check (grams > 0),
    kcal_per_100g double precision not null check (kcal_per_100g >= 0),
    protein_per_100g double precision not null check (protein_per_100g >= 0),
    primary key (meal_id, position)
);

-- One row per meal logged. The id is made on the phone when the meal is
-- tapped, so an entry sent twice (a retry after a dropped connection) is
-- stored once. The name and figures are copied from the recipe as it stood
-- when the entry arrived, so changing a recipe later does not rewrite the
-- days already logged. An entry taken back is marked, not deleted, so a
-- late retry cannot bring it back.
create table food_entries (
    id uuid primary key,
    -- When it was logged on the phone; decides which day it belongs to.
    eaten_at timestamptz not null,
    slot text not null check (slot in ('breakfast', 'lunch', 'dinner', 'snack')),
    meal_id uuid references saved_meals (id),
    name text not null,
    servings double precision not null check (servings > 0),
    kcal integer not null check (kcal >= 0),
    -- Protein in tenths of a gram, so a day's rows add up exactly.
    protein_dg integer not null check (protein_dg >= 0),
    received_at timestamptz not null default now(),
    -- The device that sent it; kept when that device later signs out.
    device_session_id bigint references device_sessions (id),
    removed_at timestamptz
);

create index food_entries_eaten_at_idx on food_entries (eaten_at);

-- The calorie and protein targets, by the day each took effect. A day is
-- held to the latest target set on or before it, so changing the target
-- does not change how earlier days read.
create table food_targets (
    effective_on date primary key,
    kcal integer not null check (kcal > 0),
    protein_g integer not null check (protein_g > 0),
    set_at timestamptz not null default now()
);
