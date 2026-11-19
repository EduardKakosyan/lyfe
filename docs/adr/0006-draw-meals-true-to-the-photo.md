---
status: accepted
---

# Draw meal illustrations true to the photo, with the dish in a Poster colour

ADR 0005 chose a look for meal illustrations: a pictogram reduced to a few bold shapes, snapped to the five Poster colours. On the owner's own meals it lost the meal: a flat white came out as three coloured blobs, because the prompt asked for abstraction and the snap then recoloured whatever was left. The owner wants the drawing much closer to the real thing, with the app's style added on top. lyfe will draw each meal as it is in the photo: the food and drink in their own colours, thick black ink outlines, flat fills, only the cup, plate or bowl in one Poster colour (cobalt blue, red-orange or yellow), and nothing else from the photo. The five-colour snap is dropped; the background alone is set to the app's paper. The owner chose this from two rounds of side-by-side drawings on the Spark, on their own photo and four stock plates, over a version with every dish in cobalt blue, which was more consistent, and one with no Poster colour at all, which was more faithful.

The model, where it runs and how it is started stay as ADR 0005 decided. Only the look changes.

## Consequences

- The dish's colour is the model's choice, so it varies from meal to meal, and on some plates it is loud against the food. A fixed cobalt dish is the fallback if the day stops reading as one set.
- A glass or anything without a dish of its own gets one invented around it: a glass cup became a red cup on a blue disc. Drinks may need wording of their own.
- The model does not always leave out what is around the plate, and may redraw a neighbouring object as something else. The prompt names what to leave out; it is a request, not a guarantee.
- Drawings are no longer five flat colours, so they are larger: 768 pixels square in at most 64 colours, about 100 kB each where the pictograms were about 10 kB. They are still in the database and the backup.
- A drawing can now be made again. Each is stored with the look it was drawn in; when the look moves on, the server marks older ones to be drawn again as it starts, and the phone, which keeps drawings by version, fetches the new one.
- The look was judged on five photos. It is still unproven across many of the owner's meals, as ADR 0005 already said of its own.
