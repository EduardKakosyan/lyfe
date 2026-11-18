# lyfe first version: build plan

Status: written 2026-11-17, updated 2026-11-18. Steps 1 and 2 are built and running on the Spark and the phone, with notifications switched on (the Apple push key is on the Spark; see the README). Step 3 is built and installed on the Spark and the phone. It was tested on this Mac, in the simulator against a local backend; its check on the real phone (a session in airplane mode, counted once after reconnecting) and the locked-screen behaviour are still to do. Step 4 is built and tested on this Mac, in the simulator against a local backend: the prompt reaches the lock screen with its reply field, tapping it opens the weight entry, and a weight typed in the app is stored and drawn on Progress. With it came a Face ID lock on opening lyfe, tried in the simulator with a simulated face. It is installed on the Spark and the phone; its check (typing the weight into the prompt on the phone's lock screen, which the simulator cannot do) and Face ID on the real phone are still to do. Step 5 is built and tested on this Mac, in the simulator against a local backend: two saved meals were logged through the app with one tap each, the day showed against its targets, and a missed day was recovered. It is installed on the Spark and the phone. Its check on the real phone (a full weekday logged in three taps), typing a recipe into the meal editor by hand, and the logging prompt are still to do. The backup destination is decided: a private bucket in Supabase Storage, sent to nightly and encrypted on the Spark before it leaves. The job is written and was tried on Ubuntu 24.04 against a local Supabase (backed up, fetched, restored, and the restored database compared); it is set up on the Spark and runs nightly. The first backups were taken on 2026-11-18, one of them before step 5 was installed, and one was fetched back, restored into a scratch database on the Spark and matched the live one. Step 6 is built and tested on this Mac, in the simulator against a local backend with a stand-in model: a photo meal was logged, shown as being estimated, filled in when the estimate arrived and corrected, and a barcode the database did not have was logged and its label typed. gemma4:31b on the Spark estimated one real plate through the new check command in about 20 seconds, holding about 26 GB with its context capped, and the importer read the start of the real Open Food Facts export. It is not yet installed on the Spark or the phone; the food database is not downloaded there yet; and its check on the real phone (the daily total showing measured and estimated separately after a photo, a scan and a saved meal), the camera and the barcode reader are still to do. Steps 7 to 9 are not started. It turns the decisions in `discovery.md` and ADRs 0001 to 0005 into an order of work.

## What the first version is

An iPhone app in the Poster style that keeps three routines going: gym, breath training and food logging. It shows streaks with a recovery rule, pushes breath-hold progression, holds you to calorie and protein targets, and takes as little typing as possible. The backend runs on the Spark and is reached over Tailscale.

Not in the first version: study sessions, automatic bank sync, a watch app.

## How the work is cut

Each step below works end to end, from capture to a screen you can look at, before the next one starts. After any step you have something usable, and you can stop or reorder.

| # | When this step is done, you can… | Depends on |
|---|---|---|
| 1 | Record a strength session on your watch and see a filled square on the Home screen | Where lyfe runs on the Spark (see below) |
| 2 | See gym streak weeks, the recovery state, and get a prompt when the streak needs sessions | 1 |
| 3 | Run a breath session in the app, tap to end each hold, and see the next table lyfe sets | 1 |
| 4 | Answer a morning notification with your weight and see the 7-day trend | 1 |
| 5 | Log your weighed breakfast and lunch with one tap and see target against actual | 1 |
| 6 | Log any other meal with a photo and one line, or a barcode | 5 |
| 7 | See a pictogram illustration appear on each photo meal | 6 |
| 8 | Approve target changes, enter pool distance and tape measurements, and see the full Progress screen | 3, 4, 5 |
| 9 | Use the same data from the Mac, and let an AI assistant read and act through MCP | 1 to 8 |

## The steps

**1. Watch to Home screen.** The thinnest slice that proves the whole chain. Backend: a Rust service and PostgreSQL on the Spark, reachable only over Tailscale, with lyfe's own sign-in; a job that polls the Garmin Personal API and stores activities. App: a Swift shell with sign-in and the Home screen showing this week's gym squares. Check: do a strength session, sync the watch, and the square fills without touching lyfe.

**2. Streaks and recovery.** Backend: the streak rules as one tested module (weeks with four sessions, one miss recovered by completing the next week, two misses end the streak, previous best kept). Push notifications through Apple for "streak needs N sessions by Sunday", sent only when there is something to act on. App: the full gym band with numeral, squares and the striped recovery state. Check: replay your real Garmin history through the rules and confirm the weeks come out as you would count them.

**3. Breath session.** App: the full-screen timer, running fixed rounds with the screen locked, one tap to end a hold, working offline. Backend: stores every hold, counts weeks with three sessions, and sets the next table from the last session using your fixed-round method. App: the after-session screen. Check: run a session in airplane mode, reconnect, and see it counted once.

**4. Weigh-in.** A single morning notification answered by typing the number. Backend computes the 7-day average. App shows the weight line on Progress. Check: reply from the lock screen without opening the app.

**5. Saved meals and targets.** You define the usual breakfast and a batch lunch from weighed ingredients. App: the Food screen with target against actual, one-tap logging, the daily logging streak with recovery. Check: a full weekday logged in three taps.

**6. Photo and barcode meals.** Photo plus one line goes to gemma4:31b on the Spark, which returns items, grams, calories and protein. App shows the estimate with a range of about ±35%, lets you correct a portion, and asks about oil only for fried, sauced or restaurant meals. Barcode lookup against a downloaded food database. Captured offline, estimated on reconnect. Check: the daily total shows measured and estimated separately.

**7. Meal illustrations.** A worker on the Spark runs FLUX.2 klein 4B on the photo and description with the pictogram prompt, snaps the result to the five colours, and attaches it to the meal. It loads only when memory is free and falls back to the photo. Check: log a meal, and the illustration appears later without having delayed the log.

**8. Targets, pool, tape, Progress.** lyfe proposes a calorie target change only when weigh-ins are sufficient, the trend has been off for two weeks and logs are complete, and you approve it. One-number pool entry. Tape measurement every two weeks with a body-fat estimate. Progress screen with holds, gym weeks and weight.

**9. Mac and MCP.** A Mac app sharing the Swift code, and an MCP server exposing the same operations the apps use, with the same permission checks. This delivers the "usable by me and by an AI" boundary from discovery.

## Rules that apply to every step

- The backend decides streaks, progression and targets. The phone captures and displays.
- Every capture has a unique ID, so retries cannot double-count.
- Models on the Spark load on demand, check free memory first, cap their context and unload afterwards.
- No keys or tokens in the repository or in these notes.
- The repository is public. Nothing personal goes into it: no account or bank names, health figures, employer, location, or machine and device names. Research and discovery notes are kept outside it.
- The streak and progression rules get automated tests before any screen depends on them.

## To settle before or during the build

| Open item | Needed by | Recommendation |
|---|---|---|
| How lyfe runs on the Spark | Step 1 | Decided 2026-11-17: a dedicated `lyfe` account on the Spark running the backend and PostgreSQL as its own services, separate from the shared model servers. Creating the account needs administrator rights on the Spark. |
| Backup destination | Before the app holds data you would mind losing, at the latest step 5 | Decided 2026-11-18: a private bucket in Supabase Storage, encrypted before it leaves the Spark (see the README). It goes in a project of its own, which holds nothing else. |
| Garmin's terms on storing data and AI processing | Step 1 | Read them once in Garmin Connect |
| Garmin key expiry | Ongoing | lyfe reminds you before the key expires, since renewal is manual |
| Screens not yet drawn: pool entry, tape measure, Mac app, where illustrations appear | Steps 7 to 9 | Draw each when its step starts |
| Evening brightness of the breath screen | Step 3 | Test on the phone in a dark room |

## Known risks

- The Garmin Personal API is new, has no published rate limits or cost, and could change.
- Photo estimates were about 35% off in the test; accuracy rests on the weighed meals and the weight trend.
- Illustration quality was judged on eight stock images; your own meals may behave differently.
- The Spark is shared, and nothing guarantees memory will be free when a model is needed.
