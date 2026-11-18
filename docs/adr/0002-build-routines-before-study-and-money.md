---
status: accepted
---

# Build routines first, then study, then money

The first version of lyfe starts with routines and streaks (gym sessions from Garmin, the breath-training timer, the food log and the morning weigh-in), adds study sessions second and money third. An earlier attempt launched every area at once and did not last, so the first version is deliberately narrow. Routines come first because nothing in them waits on an outside company beyond a Garmin Personal API key the owner creates; study reuses the same streak and progression machinery; automatic bank sync depends on a data provider approving the app and on accounts connecting, which cannot be scheduled.

## Consequences

- Provider evaluation for automatic spending sync can start in parallel, but nothing in the first version may depend on its outcome.
- Money being third is an ordering forced by external gates, not a statement that it matters less; if provider access is confirmed early, the order can be revisited.
- Everything else is outside the first three steps and remains to be designed.
- This fixes an order of work, not a client framework, database or schedule, and it does not authorize implementation to begin.
