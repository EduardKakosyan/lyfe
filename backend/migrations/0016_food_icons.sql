-- A small drawing for a food in the ingredient catalogue, in place of an
-- emoji: drawn on the Spark from the food's name alone, the first time the
-- phone asks for it, and kept so it is drawn once.

-- An icon only ever adds to the catalogue: the phone shows a drawing of
-- the food's category until its own comes, and if it never does.
--   key:      the food's name as icons are kept by: on one line, in lower
--             case (`routines::illustration::icon_key`).
--   id:       what the illustrator is asked for it by, and answers with.
--   name:     the name as the phone gave it, which the model is asked for.
--   png:      the icon once drawn; null until then.
--   look:     the look it was last drawn in, or given up on in
--             (`routines::illustration::ICON_LOOK` at the time). One from
--             an older look is drawn again when it is next asked for, and
--             keeps the drawing it has until then.
--   due_at:   when to try drawing it next; null once drawn or given up on.
--   tries:    times the model failed to draw it, which give up after a
--             few; a busy Spark does not count.
--   problem:  why the last try drew nothing, for the log.
--   asked_at: when the phone last asked. The one asked for latest is drawn
--             first: it is the one being looked at.
create table food_icons (
    key text primary key,
    id uuid not null unique default gen_random_uuid(),
    name text not null,
    png bytea,
    look integer,
    drawn_at timestamptz,
    due_at timestamptz default now(),
    tries integer not null default 0,
    problem text,
    asked_at timestamptz not null default now()
);

create index food_icons_due_idx on food_icons (due_at) where due_at is not null;
