-- Meals built from parts: scanned labels, typed foods and photos, added up.

-- A logged meal can now be several things eaten together. The meal is a
-- row with source 'built' and no figures of its own; each part is a row of
-- its own pointing at it. So a part is estimated, corrected, or waits for
-- its label exactly as a meal of one thing does.
--   source 'typed': a food the owner typed: its grams and the label's
--                   figures per 100 g, or just what it came to. Measured.
--   source 'built': a meal made of parts. Its figures are its parts'.
alter table food_entries
    drop constraint food_entries_source_check,
    add constraint food_entries_source_check check (source in ('saved', 'photo', 'barcode', 'typed', 'built')),
    -- The built meal this is a part of. Not a reference: a photo is sent to
    -- be estimated while its meal is still being put together on the phone,
    -- so it arrives before the meal does. Until the meal arrives, such a
    -- part is on no day and counts for nothing.
    add column part_of uuid,
    -- Where the part stands in its meal, in the order added.
    add column position integer not null default 0,
    -- Barcode and typed: the label's figures, kept with what was logged.
    add column kcal_per_100g double precision check (kcal_per_100g >= 0),
    add column protein_per_100g double precision check (protein_per_100g >= 0),
    -- Saved: the part of kcal and protein_dg that came from estimated
    -- ingredients, so a saved meal with a photo in it still shows as
    -- partly estimated each time it is logged.
    add column kcal_estimated integer not null default 0 check (kcal_estimated >= 0),
    add column protein_dg_estimated integer not null default 0 check (protein_dg_estimated >= 0);

create index food_entries_part_of_idx on food_entries (part_of) where part_of is not null;

-- What goes into a saved meal is no longer only weighed ingredients. It is
-- either weighed, with the label's figures per 100 g (typed, or scanned,
-- and then with its barcode), or just what it comes to: a menu's figures
-- typed whole, or a photo's estimate, which stays marked as estimated.
alter table saved_meal_ingredients
    alter column grams drop not null,
    alter column kcal_per_100g drop not null,
    alter column protein_per_100g drop not null,
    add column kcal double precision check (kcal >= 0),
    add column protein_g double precision check (protein_g >= 0),
    add column estimated boolean not null default false,
    add column barcode text,
    add constraint saved_meal_ingredients_figures_check check (
        (grams is not null and kcal_per_100g is not null and protein_per_100g is not null
            and kcal is null and protein_g is null)
        or (grams is null and kcal_per_100g is null and protein_per_100g is null
            and kcal is not null and protein_g is not null)
    );
