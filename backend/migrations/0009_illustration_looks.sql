-- Illustrations can be drawn again when their look changes.

-- The look a photo was drawn in (`routines::illustration::LOOK` at the
-- time); null while it has not been drawn. The first look was a pictogram
-- in the five Poster colours, which lost the meal; from the second on, the
-- meal keeps its own colours. When the look moves on, the server marks
-- photos drawn in an older one to be drawn again as it starts, and each
-- keeps its old drawing until the new one replaces it.
alter table food_photos add column illustration_look integer;
update food_photos set illustration_look = 1 where illustration is not null;
