-- Grams in the recorded quantity, not grams per 100 g. NULL means not recorded.
alter table saved_meal_ingredients
    add column carbs_g double precision check (carbs_g >= 0),
    add column fat_g double precision check (fat_g >= 0);
alter table food_entries
    add column carbs_g double precision check (carbs_g >= 0),
    add column fat_g double precision check (fat_g >= 0);
