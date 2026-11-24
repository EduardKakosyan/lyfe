-- Step 6: meals logged from a photo and one line, or from a barcode.

-- Where a logged meal's figures came from, and whether they are known yet.
--   source 'saved':   a saved meal, weighed once. Measured.
--   source 'barcode': a packaged food, from its label and the grams eaten.
--                     Measured.
--   source 'photo':   a photo and one line, estimated by a model on the
--                     Spark. Estimated.
--   figures 'known':       kcal and protein_dg hold the meal.
--   figures 'estimating':  a photo the model has not answered for yet.
--   figures 'failed':      the model could not estimate it; the owner can
--                          type the figures instead.
--   figures 'needs_label': a barcode not in the food database; the owner
--                          types its label once.
-- Until the figures are known, kcal and protein_dg are 0 and the meal is
-- left out of the day's total: unknown, not zero. It still counts for the
-- logging streak, because it was logged.
alter table food_entries
    add column source text not null default 'saved' check (source in ('saved', 'photo', 'barcode')),
    add column figures text not null default 'known'
        check (figures in ('known', 'estimating', 'failed', 'needs_label')),
    -- Photo: the one line typed with it.
    add column note text,
    -- Photo: whether the model judged the meal fried, sauced or from a
    -- restaurant, so the owner is asked about oil.
    add column oil_asked boolean not null default false,
    -- Photo: the owner's answer. Null until answered.
    add column oil text check (oil in ('none', 'some', 'a_lot')),
    -- Photo: figures the owner typed instead of the model's.
    add column typed boolean not null default false,
    -- Photo: tries at asking the model, when the next is due, and why the
    -- last one did not give an estimate.
    add column estimate_tries integer not null default 0,
    add column estimate_due_at timestamptz,
    add column estimate_problem text,
    add column estimated_at timestamptz,
    -- Barcode: the code scanned and the grams eaten.
    add column barcode text,
    add column grams double precision check (grams > 0);

create index food_entries_estimating_idx on food_entries (estimate_due_at) where figures = 'estimating';

-- The photo itself, as the phone sent it (a JPEG). Kept apart so reading
-- the day does not read the pictures.
create table food_photos (
    entry_id uuid primary key references food_entries (id),
    jpeg bytea not null,
    received_at timestamptz not null default now()
);

-- What the model saw in a photo: each item with the grams it judged and
-- the figures for those grams. `grams` starts as the model's and is what
-- the owner corrects; the item's figures scale with it.
create table food_estimate_items (
    entry_id uuid not null references food_entries (id),
    position integer not null check (position > 0),
    name text not null,
    grams_seen double precision not null check (grams_seen > 0),
    kcal_seen double precision not null check (kcal_seen >= 0),
    protein_g_seen double precision not null check (protein_g_seen >= 0),
    grams double precision not null check (grams >= 0),
    primary key (entry_id, position)
);

-- Packaged food from the downloaded food database (Open Food Facts),
-- replaced whole on each import. It can be downloaded again, so the
-- nightly backup leaves its rows out.
create table barcode_products (
    code text primary key,
    name text not null,
    kcal_per_100g double precision not null check (kcal_per_100g >= 0),
    protein_per_100g double precision not null check (protein_per_100g >= 0),
    serving_g double precision check (serving_g > 0)
);

-- Labels the owner typed for codes the database did not have, or had
-- wrong. They win over the database's.
create table owner_products (
    code text primary key,
    name text not null,
    kcal_per_100g double precision not null check (kcal_per_100g >= 0),
    protein_per_100g double precision not null check (protein_per_100g >= 0),
    serving_g double precision check (serving_g > 0),
    set_at timestamptz not null default now()
);
