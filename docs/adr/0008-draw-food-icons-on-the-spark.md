---
status: accepted
---

# Draw the catalogue's food icons on the Spark, not from stock photos

The ingredient catalogue showed each food by an emoji: its own for twenty staples, and one for its category for the 3,712 foods from the USDA database, so every vegetable was a lettuce. The owner wants a picture of the food itself, from stock images where they exist and drawn by the model on the Spark where they do not, and left the choice open if stock images did not work out. They do not: the USDA database carries no pictures, and the stock libraries that have them want an account and a key each, ask for a credit beside every photo, and would have the Spark send the name of each food the owner looks at to a service outside it, which nothing about food does today. Photos from many photographers would also sit on the Poster screens as a patchwork of backgrounds and lighting. lyfe will draw every icon with the model it already runs for meal illustrations, FLUX.2 klein 4B (ADR 0005), from the food's name alone, in one look: the food by itself in its own colours, with a thick ink outline and flat fills, on the app's paper. The look and the wording were chosen from six rounds drawn on the Spark, on the staples and on names taken from every category of the catalogue.

An icon is drawn the first time the phone asks for it, not ahead of time: the catalogue is large and most of it will never be looked at. The phone asks once a food has stayed on screen for a moment, shows the drawing of the food's category until its own arrives, and keeps what it fetches. A category's drawing is an icon like any other, asked for by a line saying what to draw.

## Consequences

- An icon takes about a second to draw, at 512 pixels, and is kept at 256 in at most 48 colours, 5 to 12 kB. The whole catalogue would be about 30 MB in the database and over an hour of the GPU; drawing on demand keeps both to what the owner browses.
- The first icons after the model has been let go wait about two minutes for it to load, as meal illustrations do. Until then, and with no connection, a food shows its category's drawing, and before that has ever been fetched, an empty frame.
- The model reads a name literally. "Beans, black turtle" was drawn as a turtle, a stewed rabbit with the rabbit looking out of the bowl, and a branded food as a jar with made-up lettering. Asking for "a serving of" the food is what stopped chicken cuts being drawn as hens. Telling the model what to leave out made things worse: a prompt that said meat should never be a live animal put meat on every plate. Some icons will still be wrong, and there is no way yet to ask for one again from the phone.
- Icons share the illustrator with meal photos and wait for them. They are drawn only when the Spark has the memory free, by the same rule.
- Each icon is stored with the look it was drawn in. When the look moves on, an icon is drawn again the next time it is asked for, not all at once, and the phone shows the one it has until the new one comes.
- Icons can be drawn again, so they are left out of the backup, like the downloaded food database.
- Nothing leaves the Spark, and no licence or credit is owed for a picture.
