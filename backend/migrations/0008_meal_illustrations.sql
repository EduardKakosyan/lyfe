-- Step 7: a pictogram drawn from each meal photo, in the Poster colours.

-- The illustration is kept with the photo it was drawn from, so reading
-- the day reads neither. It only ever adds to a meal: the meal counts
-- without it, and the photo is shown until it comes or if it never does.
--   illustration:         a PNG once drawn; null until then.
--   illustration_due_at:  when to try drawing it next; null once drawn or
--                         given up on.
--   illustration_tries:   pictures the model failed to draw, which give up
--                         after a few; a busy Spark does not count.
--   illustration_problem: why the last try drew nothing, for the log and
--                         the check command.
alter table food_photos
    add column illustration bytea,
    add column illustrated_at timestamptz,
    add column illustration_tries integer not null default 0,
    add column illustration_due_at timestamptz,
    add column illustration_problem text;

-- Photos already logged are drawn too, oldest first.
update food_photos set illustration_due_at = received_at;
alter table food_photos alter column illustration_due_at set default now();

create index food_photos_illustration_due_idx on food_photos (illustration_due_at)
    where illustration_due_at is not null;
