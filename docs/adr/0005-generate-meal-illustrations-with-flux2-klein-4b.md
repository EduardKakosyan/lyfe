---
status: accepted
---

# Generate meal illustrations with FLUX.2 klein 4B on Spark

The owner wants each logged meal to get a generated illustration in the app's Poster style, in the first version, rather than a filter applied to the photo. lyfe will generate these on Spark with FLUX.2 klein 4B, using the meal photo as the edit input and the meal's one-line description in a fixed "pictogram on off-white" prompt, then snap the result to the five Poster colours with dithering off. The larger FLUX.2 klein 9B was the first candidate from research, but it is gated behind a non-commercial licence that the owner would have to accept and read; the 4B model is Apache-licensed, ungated, and in a test on the owner's Spark with four stock photos it produced results the owner judged good, at about seven seconds per image and 17 GB of GPU memory.

## Consequences

- Generation never blocks logging: the meal is saved first, the illustration is attached afterwards, and the plain photo is shown if generation fails or Spark has too little free memory.
- The model takes about two minutes to load from disk, so jobs should be batched or the worker kept warm briefly; it must check available memory before loading because the machine is shared.
- A strict five-colour palette recolours food unnaturally and mixed dishes become abstract; this is accepted as part of the look.
- The test was eight images per round on stock photos. Consistency across many of the owner's own meals is unproven; a fixed style reference, a tuned style or the 9B model are the fallbacks if the look drifts.
- This does not authorize deploying a service on Spark; the test files left there are a prototype.
