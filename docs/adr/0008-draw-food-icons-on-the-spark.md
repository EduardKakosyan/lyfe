---
status: accepted
---

# Draw the catalogue's food icons on the Spark, not from stock photos

The ingredient catalogue showed each food by an emoji: its own for twenty staples, and one for its category for the 3,712 foods from the USDA database, so every vegetable was a lettuce. The owner wants a picture of the food itself, from stock images where they exist and drawn by the model on the Spark where they do not, and left the choice open if stock images did not work out. They do not: the USDA database carries no pictures, and the stock libraries that have them want an account and a key each, ask for a credit beside every photo, and would have the Spark send the name of each food the owner looks at to a service outside it, which nothing about food does today. Photos from many photographers would also sit on the Poster screens as a patchwork of backgrounds and lighting. lyfe will draw every icon with the model it already runs for meal illustrations, FLUX.2 klein 4B (ADR 0005), from the food's name alone, in one look: the food by itself in its own colours, with a thick ink outline and flat fills, on the app's paper. The look and the wording were chosen from six rounds drawn on the Spark, on the staples and on names taken from every category of the catalogue.

Every icon is drawn ahead of time: a script lists the catalogue's names and the Spark draws them in the background, once. The first version drew an icon only when the phone first asked for it, to spare a shared machine drawing foods nobody would look at; but the whole catalogue is a little over an hour of the GPU and about 30 MB, and what that saved was paid for on the phone, in a two-minute wait for the model to load before the first icon of a sitting. The owner asked why they were not simply drawn, and they now are. Asking for an icon still gets it drawn, for a food added since, and such an icon goes ahead of the queue. A food not drawn yet shows the drawing of its category, which is an icon like any other, asked for by a line saying what to draw.

## Consequences

- An icon takes about a second to draw, at 512 pixels, and is kept at 256 in at most 48 colours, 5 to 12 kB. The catalogue's 3,748 are a little over an hour of the GPU on a shared machine, once, and again whenever the look changes.
- The script has to be run: after the first install, and after the catalogue or the look changes. Until it has, icons are drawn as they are asked for, with the wait that has.
- The phone still fetches each icon the first time its food is on screen, so it needs a connection for a food it has not shown before. Putting the icons in the app would have made them instant with none, at 30 MB more in the app and the repository and a new build for every look.
- The model reads a name literally. "Beans, black turtle" was drawn as a turtle, a stewed rabbit with the rabbit looking out of the bowl, and a branded food as a jar with made-up lettering. Asking for "a serving of" the food is what stopped chicken cuts being drawn as hens. Telling the model what to leave out made things worse: a prompt that said meat should never be a live animal put meat on every plate. Some icons will still be wrong, and there is no way yet to ask for one again from the phone.
- Icons share the illustrator with meal photos and wait for them. They are drawn only when the Spark has the memory free, by the same rule.
- Each icon is stored with the look it was drawn in. When the look moves on, the script queues them all again, and the phone shows the one it has until the new one comes.
- Icons can be drawn again, so they are left out of the backup, like the downloaded food database.
- Nothing leaves the Spark, and no licence or credit is owed for a picture.
