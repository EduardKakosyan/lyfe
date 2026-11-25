# How lyfe decides

What lyfe counts and shows, area by area. The backend decides all of it; the phone records what happened and shows what the backend worked out. File paths are from the repository's root. The words are defined in [CONTEXT.md](../CONTEXT.md), and running it is in [operations.md](operations.md).

## What counts as a gym session

Decided by the backend (`backend/src/routines/gym.rs`):

- A Garmin activity of a counted type that lasted at least 15 minutes.
- Counted types by default: strength training, indoor cardio, HIIT, pool and open-water swimming, running, treadmill, cycling, indoor cycling, elliptical, stair climbing, indoor rowing. Walking does not count.
- A day counts once, however many activities were recorded on it.
- The week runs Monday to Sunday in the time zone set on the server.

The types and the minimum are settings (`LYFE_GYM_ACTIVITY_TYPES`, `LYFE_GYM_MIN_MINUTES`).

## Streaks and recovery

The rules are one module shared by every routine (`backend/src/routines/streak.rs`). The gym, breath training and study apply them to weeks (`weekly.rs`): four days with a session keep a gym week, three keep a breath week, four days of study keep a study week. Food logging applies them to days ([Food](#food)).

- A week that reaches its count is kept, and the streak counts kept weeks in a row. The current week counts as soon as it reaches its count.
- One missed week does not end the streak. Keeping the very next week recovers it, and the missed week is then shown as recovered (striped). Nothing has to be made up, and a missed week never adds to the count.
- Two missed weeks in a row end the streak. The next kept week starts a new one, and the longest ended streak stays visible as the best.
- Weeks before the first kept week are not part of any streak and are not shown.

To see every recorded gym week as the rules count it, on the Spark as `lyfe`:

```sh
set -a; . ~/.config/lyfe/lyfe.env; set +a; ~/bin/lyfe-server gym-weeks
```

## Breath sessions

The method is fixed rounds: every round has the same length and starts with a hold taken as far as it goes, and what is left of the round is the recovery. The phone runs the session and records each hold; the backend decides the rest (`backend/src/routines/breath.rs`).

- **On the phone.** The Home screen's breath band opens the table lyfe set. After START there is a ten-second lead-in, then each round begins on time with a tone; tap anywhere to end the hold. The hold screen shifts from yellow to red as the hold nears the same round's hold last session, and flashes and turns blue once it passes it. A round with no tap records no hold. The last tap ends the session.
- **Screen locked.** The screen stays on during a session. If the phone is locked anyway, the rounds and tones carry on, because every tone is lined up against the clock when the session starts; ending a hold still needs the screen.
- **Offline.** A session needs no connection: it runs on the last table the backend sent, is written to the phone after every tap, and is sent when the backend can next be reached. Each session carries an id made on the phone, so sending it twice counts it once.
- **What counts.** A session counts toward the week once at least half its rounds have a hold, so one cut short still counts and a timer started by accident does not. A day counts once. How long the holds were never affects the streak.
- **The next table.** The round length follows the last session that counts: the same again while the longest hold left at least 0:45 of the round, 0:15 longer once it left less. It never gets shorter.

The first table and the two thresholds are settings (`LYFE_BREATH_START_ROUND_SECONDS`, `LYFE_BREATH_ROUNDS`, `LYFE_BREATH_ADVANCE_UNDER_SECONDS`, `LYFE_BREATH_STEP_SECONDS`); the defaults are six rounds of 4:00.

## Study sessions

Study toward better-paid work, timed in the app and counted by the week like the gym. A session counts once its timer passes a minimum; how it went is kept apart from whether it counted. The rules are `backend/src/routines/study.rs`; the phone's timer is `apps/LyfeKit/Sources/LyfeKit/Study/Study.swift`.

- **On the phone.** Home's study row opens the study screen. Pick a subject, or name a new one, say what the session is (questions, reading or build), and START. The clock shows the time on it, a line to the 90-minute target with the 45-minute minimum marked, and the black bar ends it. After END SESSION, say what it was: for questions, how many were answered and how many were right the first time, both optional; for a build, what was built and why, typed from memory.
- **What counts.** A session counts once its timer passed 45 minutes; 90 is shown as the target and never needed. A day counts once, however many sessions it had, and a week with four days of study keeps the streak, with the same recovery as the gym. Building something counts for at most two of the four, the earliest two in the week, and only with its explain-back; a build without one is kept and does not count.
- **The timer.** Worked out from the clock, never counted up, so locking the phone, leaving lyfe or closing it does not stop it; ← HOME leaves it running and Home's row shows its time. PAUSE stops the clock until RESUME. STARTED EARLIER? moves the start back, up to two hours in all, for a timer started late. A timer left running stops itself at three hours on the clock (or three hours into a pause), and the screen then asks when the owner really stopped. A session started by mistake can be thrown away.
- **Subjects.** Named by the owner, and found again by name whatever the case, so a subject typed without a connection joins the one already kept. Each adds up every minute given to it, counted or not; a goal on study hours reads them ([Goals](#goals)).
- **Offline.** A session is written to the phone when it starts and whenever it changes, with an id made there, and sent when DONE is tapped or when the server can next be reached. Sending it twice stores it once.

The minimum, the target and how many builds can count are settings (`LYFE_STUDY_MIN_MINUTES`, `LYFE_STUDY_TARGET_MINUTES`, `LYFE_STUDY_BUILDS_PER_WEEK`); the defaults are 45, 90 and 2.

## Goals

Where the owner means to get by a date, on a figure lyfe already reads, so a goal needs nothing typed to move (ADR 0010). The rules are `backend/src/routines/goals.rs` and `exam.rs`; the screens are the Goals tab (`apps/LyfeKit/Sources/LyfeKit/Views/GoalsScreen.swift`, `ExamViews.swift`).

- **Three shapes.** A figure to reach, up or down: the best breath hold, the seven-day average weight, or the latest body-fat estimate from the tape. A total to build up: hours of study from the day it is set, on one subject or all. A result to get: an exam (below). Doing something so many times a week is a routine, not a goal. Net worth cannot be a goal yet; it is planned (build plan, step 13).
- **Setting one.** Goals > NEW GOAL: what it reads, the figure, the date, and a name if the one it gets is not wanted. It starts where its reading stands that day, so one with no reading yet (no weigh-ins, no [tape measurement](#training-tape-and-target-review)) cannot be set until there is one. Setting and changing a goal need a connection.
- **Pace.** The straight line from where it started to its figure on its date. A goal shows where it stands, how far ahead or behind that line it is in its own unit, and what would now be needed a week to get there. Behind is an amount, never a failed state. Past its date the line stays at the figure until the date is moved or the goal dropped.
- **Three at a time.** Three goals are active; a new one beyond that starts parked, and a parked one is made active once another is parked. A goal is never deleted: it is parked, reached or dropped (with a line why), and an ended one can be taken up again. Changing a goal's figure, date or name is recorded beside it, and lyfe never moves a date by itself.
- **On the band.** Each active goal is a band in the colour of the routine that moves it (study green, breath blue, the gym and food red), with the routine's week under it.

### Exams

A certification or any exam is a result to get: no percentage and no line, a countdown to the day it is sat, and under it what says whether the owner is ready.

- **Set once from what the exam's owner publishes:** what it is marked out of, the pass mark, how many months a pass is valid, and the parts it is marked in with each part's share. And the owner's own rule for being ready: so many practice tests in a row at least so many points over the pass mark. No default is evidence; it is a habit to set by what one trusts.
- **Practice.** ADD A PRACTICE SCORE after each practice test: the score, and each part's percentage where the test gave one. The last ten are shown as squares, solid at the ready score; each part shows its latest figure, and the weakest is named. A score is kept once even if sent twice.
- **Study.** An exam can be on a study subject; the hours on that subject since it was set are shown with it, and its band shows the study week.
- **The result.** PASSED ends the goal as reached on that day and, where a pass expires, shows until when it is valid. NOT PASSED keeps the goal, for its date to be moved to the next sitting.

## Weigh-ins

The scale is not connected, so the weight is typed, normally straight into the morning prompt without opening lyfe. The backend decides what the numbers mean (`backend/src/routines/weight.rs`).

- **The prompt.** One notification a day at 06:30 in your time zone. Press and hold it, type the weight, tap Save. It needs no unlock and lyfe does not come forward. If the server was not running at 06:30 the prompt still goes out until 09:30, and not after; it is a morning weigh-in. It is skipped once today has a weight, and there is never a second one that day.
- **Not a streak.** A missed morning costs nothing and nothing nags about it.
- **What was typed.** `176.4`, `176,4` and `176.4 lb` all read the same; a unit typed after the number wins (`80.0 kg` on a server set to pounds is stored as 80 kg and shown as 176.37 lb). Anything under 44 lb or over 880 lb (20 to 400 kg) is a slip and is refused; a reply that is not a weight brings the prompt straight back, asking again.
- **Offline.** A weight is written to the phone before it is sent, with an id made on the phone, so a reply typed without a connection is sent the next time lyfe opens and is never stored twice.
- **The numbers.** A day's weight is the last one typed that day, so typing it again corrects it. The seven-day average covers the days of the last seven that have a weight, and is shown once at least three do. Progress shows it as the giant figure and as a line over eight weeks, each morning's weight as a small square, with the change on the week before.
- **In the app.** Home's weight strip opens Progress; the black bar there opens the entry, for a morning the prompt was missed or switched off. Tapping the prompt instead of typing into it opens the same entry.

The unit and the prompt's time are settings (`LYFE_WEIGHT_UNIT`, `lb` unless set to `kg`; `LYFE_WEIGH_IN_AT`, a time like `06:30` or `off`). Weights are stored in grams, so changing the unit changes only what is shown. The weight itself is never written to the server log.

## Training, tape and target review

Step 8 of the build plan, partly built: the backend and a first, plain version of the screens are in place, and the walkthrough on the phone is still to do. The rules are `backend/src/api/progress.rs`; the screen is `apps/LyfeKit/Sources/LyfeKit/Views/ProgressDetails.swift`.

- **On the phone.** Progress has two views, Weight (above) and Training & more. Training & more shows this week's sessions, the last seven gym weeks with how each was counted, and eight weeks of: the best hold of each breath session, swim distances from Garmin's lap swimming, pool distances typed in, and body-fat estimates from the tape. The entry screens are plain forms for now.
- **Pool distance.** One number: the metres of a dynamic apnea swim, more than 0 and at most 10,000, typed for today. Garmin's own swims are shown apart.
- **Tape measurement.** Height, waist and neck in centimetres, and the hip too for the formula that uses it (the screen says where to measure for each). The backend works out the body-fat estimate from them with the circumference equations. It refuses a height outside 80 to 250 cm, a waist outside 20 to 250, a neck outside 15 to 80, a hip outside 30 to 250, or an estimate outside 1 to 75%. One is due every two weeks: Progress says TAPE MEASUREMENT DUE when there is none from the last 14 days. Nothing is sent about it. A body-fat goal reads the latest estimate.
- **Saving.** A pool distance and a tape measurement each carry an id made on the phone, so sending one twice stores it once. Unlike the other captures, they are not kept on the phone to send later: saving needs a connection, and without one the screen says the server could not be reached.
- **The weekly rate.** How fast you mean your weight to change, as a percentage a week, from −1 to +1; 0 holds it. It is not a goal (ADR 0010). Changing it starts its two weeks again (below).
- **Confirming a day.** CONFIRM I LOGGED ALL FOOD TODAY says today's food log is the whole day. Only today can be confirmed, so a day not confirmed on the day stays unconfirmed.
- **Target review.** lyfe proposes a new calorie target only when all of these hold:
  - the weekly rate was set at least 14 days ago, and a calorie target is set;
  - the target has not changed in the last two weeks;
  - each of the 14 days before today is confirmed, has food logged, and has every figure known (nothing still being estimated or waiting for its label);
  - each of the three weeks before today has a seven-day average from at least three mornings;
  - from the first of those weeks to the second, and from the second to the third, the average moved by more than 0.25 percentage points away from the weekly rate, both times on the same side.

  Weight moving up faster (or down slower) than the rate proposes 100 kcal a day less; the other way, 100 more. A proposal is never below 800 or above 10,000 kcal.
- **Approving.** Progress shows the proposal with APPROVE. Approving sets the new calorie target from today; protein stays as it was, and earlier days keep the target they had. lyfe checks the proposal still stands when it is approved, and never changes a target without that approval.

## Food

A meal you eat repeatedly is weighed once and saved; after that logging it is one tap, and its numbers are measured rather than guessed. Anything else is built from parts: barcodes, photos and typed foods, added up as you go ([Building a meal](#building-a-meal)). The backend decides what the numbers mean (`backend/src/routines/food.rs`).

- **A saved meal.** In the app, Food > New saved meal: a name, the part of the day it belongs to (breakfast, lunch, dinner or snack), how many portions the recipe makes, and each ingredient as weighed with the kcal and protein per 100 g from its label. An ingredient can also be scanned, or typed as just what it comes to. A batch that makes five lunches is typed as the whole pot with 5 portions. The backend works out a portion; the figure in the bar is a preview of the same sum, so a slipped decimal point shows before you save. Saving needs a connection.
- **One tap.** On the Food screen, tapping a saved meal logs one portion of it now, under its part of the day. Holding it offers half, one and a half, or two portions. The black bar always offers the saved meal for the next of breakfast, lunch and dinner that is still open, the one you logged last for it, so a weekday with three saved meals is three taps on the bar.
- **A slip.** Tapping a logged meal takes it off the day; tapping a meal built from parts shows the parts, where one can be taken out or the whole meal taken off. Changing a recipe (hold the meal, Change the recipe) does not rewrite days already logged: an entry keeps the name and figures of the recipe as it was when it arrived. A removed meal leaves the list and what was logged from it stays.
- **Targets.** You type a calorie and a protein target (Food > Targets). The day is shown against them: the giant figure is what is logged, the bars fill toward the targets, and the line beside the heading says how much is left or how far over. A target counts from the day it is set, and earlier days keep the one they had. lyfe never changes a target by itself; it can propose a calorie change, which counts only once you approve it ([Target review](#training-tape-and-target-review)). The figures are yours and are not in this repository or the server log.
- **Unknown is not zero.** A breakfast, lunch or dinner with nothing logged shows a question mark and is listed as open, so the day's figure is never read as the whole day when it is not. Snacks are extra: a day without one is not missing anything. A meal that is logged but whose figures are not known yet (a photo still being estimated, a barcode the database does not have) fills its part of the day and counts for the streak, but is left out of the total and said so above the day.
- **Measured and estimated.** Saved meals, labels and typed figures are measured; photos are estimated, each part of a meal by itself. The bars fill solid for the first and striped for the second, and once anything is estimated the line under the figure gives the estimated part and the range the day may really be in.
- **The streak.** By the day: a day counts once anything is logged on it, whatever the numbers, so a day over target does not break it. One missed day is recovered by logging the next (shown striped), two in a row end the streak, and nothing is ever made up. The fuel band on Home shows the days in a row and the last seven days as squares, today last.
- **Offline.** A tap is written to the phone before it is sent, with an id made on the phone and the time it was tapped, so a meal logged without a connection is sent the next time lyfe opens, counts for the day it was eaten on, and is never logged twice. Until then it shows in its part of the day marked as not counted yet. Saved meals come with the last state the phone saw, so one-tap logging works from them offline.
- **The prompt.** When a streak is alive and nothing is logged by 12:00 in your time zone, one prompt goes out that day, worded for recovery when yesterday was missed. Tapping it opens the Food screen. Nothing is sent when today is already logged or no streak is alive. A meal still waiting on the phone to be sent is not known to the backend, so it can be prompted for.

The prompt's time is a setting (`LYFE_FOOD_PROMPT_AT`, a time like `12:00` or `off`); it is also held to the hours prompts are sent between ([Notifications](#notifications)).

## Building a meal

A meal that is not a saved one is what you ate, added part by part, and logged as one meal. The builder is a calculator as much as a log: the total is on screen from the first part. The rules are in `backend/src/routines/food.rs`; a part of a meal is stored as an entry of its own that points at its meal, so it is estimated, corrected, or waits for its label exactly as a meal of one part would.

- **On the phone.** Food > SCAN, PHOTO or TYPE starts a meal with that kind of part and lands in the builder; the same three buttons there add the next. SCAN reads a barcode and takes the grams ([Barcodes](#barcodes)). PHOTO takes a picture and one line ([Photo meals](#photo-meals)). TYPE takes a food by hand, three ways: weighed, with the kcal and protein per 100 g from its label; just the totals, for a menu item or a coffee that comes with its figures; or macros, below. *Find an ingredient* opens the catalogue ([The catalogue and its icons](#the-catalogue-and-its-icons)). Tapping a part changes it or takes it out.
- **Macros.** When you know what a food has in it and not what it comes to, type only the grams: TYPE > MACROS, then protein, carbs and fat, any of them left blank for none. lyfe works out the calories at 4 kcal a gram of protein or carbs and 9 a gram of fat, and shows the figure as you type, so ten grams of fat is logged by typing 10 and comes to 90 kcal. A name is optional; without one the part is called by what it is (*10 G FAT*, *30 G PROTEIN + 10 G FAT*). It counts as measured, and its carbs and fat go on the meal's macros line. The backend stores it as any food typed whole (`FoodTyping.macros`, `Macros`, in `apps/LyfeKit/Sources/LyfeKit/Food/FoodLog.swift`).
- **The running total.** The giant figure is what the parts with known figures add up to, with the protein, how much of it is estimated, and how many parts are still unknown under it. A part that is not known yet (a photo still with the model, a barcode scanned without a connection) is left out, not counted as zero.
- **Photos go ahead.** A photo is sent to the Spark as soon as it is added, so its estimate usually arrives while you add the rest, and joins the total. Until the meal is logged the photo is on no day and counts for nothing.
- **LOG IT.** Logs everything as one meal under the part of the day chosen, named after it unless you typed a name. It does not wait for a photo still being estimated: the meal is logged and that part fills in. On the day the meal is one row with its parts counted (*BREAKFAST · 4 PARTS*), striped once a photo is among them; each part still counts as measured or estimated in the day's bars.
- **A logged meal.** Tapping its row shows the parts. A photo opens its estimate, to correct as before; a code lyfe did not know asks for its label; anything else can be taken out. SCAN, PHOTO and TYPE there add a part to the meal after the fact. Taking the last part out takes the meal off the day.
- **Save it for one tap.** In the builder, *Save it for one tap next time* asks for a name and how many portions the recipe makes, and saves the parts as a saved meal; LOG IT afterwards logs one portion of it. A meal already logged can be saved the same way from its parts. Saving needs every part's figures, so it waits for a photo's estimate. A photo's part is saved at what it was estimated (and corrected) to be, and stays an estimate every time the meal is logged, so the bars stay honest; change the recipe and type it weighed to replace it. Half a portion of a saved meal is half of every ingredient, the ones typed as totals included.
- **Left half way.** Closing the builder keeps the meal: Food shows *MEAL IN PROGRESS* with a way back, and it is still there after lyfe is closed, for three days. *Throw this meal away* drops it and the photos sent for it.
- **Offline.** The builder needs no connection. A scan the phone cannot look up is added with a question mark and looked up when the meal is sent; a photo is kept and sent before its meal. The meal is written to the phone before anything is sent, with ids made on the phone, so it is never logged twice.

## Photo meals

A photo and one line saying what it was: one part of a meal, or all of it. A vision model, gemma4:31b, estimates it afterwards in the Ollama on the Spark. That Ollama is run by another account and shared with the Spark's other users ([Security model](operations.md#security-model)). The pure rules are `backend/src/routines/photo.rs`; the asking is `backend/src/estimator.rs`.

- **On the phone.** PHOTO, on Food or in the builder, opens the camera. Take the picture, type the line (*stir fry, rice, some oil*), ADD IT. A food can also be described without a photo, or a picture chosen from the library. The picture is shrunk to 1280 pixels and the location and camera details the phone writes into it are dropped before it is kept or sent.
- **It never holds the meal up.** The photo is sent when it is added and estimated in the background: seconds if the model is loaded, a couple of minutes if it has to load first. Until then its part shows as being estimated and is not in any total; the meal can be logged meanwhile and counts for the streak at once.
- **The estimate.** The model lists each food it sees with its grams, kcal and protein; the meal is their sum. It is shown with a range of ±35% either way, because photo estimates are that rough (`LYFE_PHOTO_RANGE_PERCENT`). The one-line description is trusted over the photo for what each food is.
- **Correcting it.** Tap the photo's part to open its estimate. Tap a food to change its grams (0 takes it out); its kcal and protein scale with it. Or type the meal's figures instead, from a menu that gives them; those have no range.
- **Oil.** The model is told to leave cooking fat and sauce out of its foods and to say whether the meal is fried, sauced or from a restaurant. Only then does the screen ask HOW MUCH OIL OR SAUCE?: none adds nothing, some adds 120 kcal (a tablespoon of oil), a lot adds 360. Until it is answered the meal is counted with some, since missed cooking fat is the commonest error in photo estimates.
- **Offline.** The meal and its photo are kept on the phone with an id made there, sent when the server can next be reached, and estimated then. It counts for the day it was eaten on and is never logged twice.
- **When the Spark is busy.** The model is loaded only when a photo is waiting, and only when at least 32 GB of memory are free (`LYFE_PHOTO_MIN_FREE_GB`), unless it is already loaded. Its context is capped at 8,192 tokens, which keeps it to about 26 GB where Ollama's default took twice that, and it is let go two minutes after the last photo, so meals logged together are estimated together (`LYFE_PHOTO_CONTEXT`, `LYFE_PHOTO_KEEP_ALIVE_SECONDS`). Short of memory, it tries again every five minutes; with Ollama not answering, every two. The estimate screen says which.
- **When the model gets it wrong.** An answer that is not the JSON asked for, or has figures no food could have (more than 9 kcal a gram, or more protein than grams), is not used. After three such answers lyfe stops asking and the meal waits for its figures to be typed.

`lyfe-server photo-check <photo.jpg> --note "<one line>"` asks the model about one photo and prints its answer, storing nothing. On a real plate it answered in about 20 seconds with the model loading. `LYFE_OLLAMA_URL=off` switches estimates off; photo meals are then typed in by hand. The photos are kept in the database, so they are in the backup.

## Meal illustrations

Each meal photo is redrawn as an illustration of the meal as it is, with the app's ink and colours on it: the model and how it runs are decided in ADR 0005, the look in ADR 0006. The prompt and how answers are read are `backend/src/routines/illustration.rs`; the running is `backend/src/illustrator.rs`; the drawing is `deploy/spark/lyfe-illustrate.py`.

- **What it is.** FLUX.2 klein 4B redraws the photo, with its one line in a fixed prompt: the food and drink in their own colours, thick black ink outlines, flat fills, only the cup, plate or bowl in one Poster colour (cobalt blue, red-orange or yellow), and nothing else from the photo, on a plain off-white background. That background is then set to exactly the app's paper, so the drawing sits on the screen without a box around it, and it is kept next to the photo as a PNG of 768 pixels square in at most 64 colours, about 100 kB. The same photo is drawn the same way each time. The dish's colour is the model's choice and varies from meal to meal; a glass gets a dish invented around it; and what is beside the plate is usually left out, not always.
- **It never holds anything up.** The meal is logged and counted without it. It is drawn after the photo's estimate, so the two models are not loaded for it at once; until it comes, and if it never does, the photo is shown as before.
- **Where it shows.** On a photo's estimate, the drawing takes the photo's place; tap it (PHOTO, top right) to see the photo, and again for the drawing. On Food and on a logged meal, a meal with a drawn photo shows it small beside its figure; a meal built from parts shows its first drawn photo. A photo sent ahead for a meal still being built is drawn once the meal is logged. A meal described without a photo has nothing to draw. Food and a logged meal look again while a photo is being estimated or drawn, so the drawing arrives without leaving the screen. Drawings are fetched once and kept on the phone, and fetched again only if the meal is drawn again.
- **When the Spark is busy.** The illustrator is a program lyfe-server starts itself, only when a photo is waiting and at least 24 GB of memory are free (`LYFE_ILLUSTRATION_MIN_FREE_GB`). It loads the model (about 110 seconds), draws every photo waiting (about 7 seconds each, about 17 GB of GPU memory), and is let go three minutes after the last (`LYFE_ILLUSTRATION_KEEP_ALIVE_SECONDS`): it exits and its memory goes back. Short of memory, it tries again every five minutes; not set up, every half hour; a model that would not load, every ten minutes. None of that counts against a photo. A photo that fails to draw three times is left as a photo.
- **Earlier meals, and a new look.** Photos logged before step 7 are drawn too, oldest first, the first time the illustrator runs. Each drawing is stored with the look it was drawn in (`illustration::LOOK`); when the look changes, the server marks older drawings to be drawn again as it starts, each stays until its new one replaces it, and the phone fetches the new one. The first look, a pictogram snapped to the five Poster colours, lost the meal and was replaced this way.

`lyfe-server illustration-check <photo.jpg> --note "<one line>" --out meal.png` draws one photo and writes it out, storing nothing. `LYFE_ILLUSTRATOR=off` switches illustrations off; meals then keep their photos. The drawings are kept in the database, so they are in the backup. Setting the illustrator up is in [operations.md](operations.md#the-illustrator).

## The catalogue and its icons

*Find an ingredient*, in the builder and on a logged meal, opens the foods lyfe comes with: twenty staples, then the generic foods of the USDA database, about 3,700 in all, each with its kcal, protein, carbs and fat per 100 g (`apps/LyfeKit/Sources/LyfeKit/Food/Ingredients.json`). Search by name, or pick one of seventeen categories; tap a food, type the grams, and it is added as a weighed part.

Each food is shown by an icon: a small drawing of the food, made on the Spark from its name alone by the model that draws meal illustrations. Why they are drawn and not stock photos is ADR 0008. The prompt is `icon_prompt` in `backend/src/routines/illustration.rs`; the phone's side is `apps/LyfeKit/Sources/LyfeKit/Food/FoodIcons.swift`.

- **Drawn ahead of time.** `deploy/spark/draw-icons.sh` lists every name in the app's catalogue and has the Spark queue them (`lyfe-server queue-icons`); the server then draws them in the background, what each category is drawn as and the staples first. All 3,748 take a little over an hour, once. Run it again after the catalogue or the look changes: icons already drawn are left alone, so running it again only says how far along it is.
- **On the phone.** A food that stays on screen for a moment is asked for (`GET /v1/food/icons?name=`), fetched and kept, so each icon is fetched once and swiping past a food fetches nothing. With no connection the phone shows what it has kept.
- **One not drawn yet.** Asking for it puts it at the front of the queue, ahead of the ones queued in bulk, and the phone asks again every few seconds until it comes. Until then the food is shown by its category's drawing (a roast chicken for poultry, bread for breads and baking), which is an icon like any other; before even that has arrived, by an empty frame.
- **What it costs the Spark.** About a second an icon once the model is loaded, and about two minutes for the model to load. Meal photos are drawn first. The illustrator's rules hold as they do for meals: it is started only when the memory is free, and let go a few minutes after the last picture. An icon is 256 pixels square in at most 48 colours, 5 to 12 kB; the catalogue's come to about 30 MB in the database.
- **When the model gets it wrong.** It reads names literally, so an odd one can come out as the wrong thing: black turtle beans as a turtle, a branded food as a jar with lettering on it. An icon that fails to draw three times is left as its category's. There is no way to ask for another drawing from the phone yet.
- **A new look.** Each icon is stored with the look it was drawn in (`illustration::ICON_LOOK`), and the day tells the phone which look is current. When it moves on, `draw-icons.sh` queues them all again, an icon asked for meanwhile goes first, and the phone shows the one it has until the new one comes.

`lyfe-server icon-check "<food name>" --out icon.png` draws one icon and writes it out, storing nothing. `LYFE_ILLUSTRATOR=off` switches icons off with illustrations; foods are then shown by an empty frame. Icons are kept in the database but left out of the backup, since they can be drawn again.

## Barcodes

Packaged food is logged from its label: a barcode and the grams eaten. Label figures are measured, not estimated. The rules are `backend/src/routines/product.rs`.

- **On the phone.** SCAN, on Food or in the builder, reads the barcode with the camera (or type the number under the bars). lyfe shows the product and its figures per 100 g; type the grams, or tap ½, 1 or 2 servings when the label states one, and ADD IT. The builder comes back with the part in it, and SCAN is there for the next packet.
- **Where the figures come from.** A downloaded copy of Open Food Facts on the Spark, or a label you typed. A product you have logged lately is known on the phone, so scanning it again works without a connection.
- **Not in the database.** Type it once from the packet: its name, kcal and protein per 100 g, and the serving if it has one. It is remembered, and wins over the database's figures from then on. Meals logged earlier keep the figures they had.
- **Offline.** A scan is kept on the phone with the grams, and looked up when it is sent. If the code turns out to be unknown, the meal is logged with a question mark and Food asks for its label; typing it fills in that meal.
- **A UPC and its EAN** (the same digits with a 0 in front) are the same product, whichever the scanner reads.

The food database is about 1.5 GB to download and is not in the backup, since it can be fetched again; fetching it is in [operations.md](operations.md#the-food-database). Lines without a name, energy or protein are skipped. The labels you typed are kept apart from it and are in the backup. Open Food Facts is published under the Open Database License; lyfe uses it privately and does not pass it on.

## Money

Money has three sections under one head: MONTH, WORTH and FIRE. The month is what its spending comes to across every account, by category, with the entries behind it. Nothing is typed: the accounts, their transactions and what the investment accounts hold come from the banks through SimpleFIN Bridge (ADR 0007). The month's rules are `backend/src/money/ledger.rs`; the importing is `backend/src/money/sync.rs` and the bridge's client `backend/src/money/mod.rs`. Worth and FIRE are further down.

- **Where it comes from.** You connect each bank at SimpleFIN Bridge, in a browser. lyfe never sees a bank password: the bridge gives it one read-only access address, which stays in a file on the Spark. Every six hours lyfe-server asks the bridge for the balances and for the transactions posted in the last two weeks, and the first time for as far back as the banks give, up to 180 days in four requests. The bridge itself refreshes about once a day and a purchase can take a few days to post, so Money is a day or two behind your cards. It allows about 24 requests a day; lyfe makes four. Connecting is in [operations.md](operations.md#money-simplefin-bridge).
- **What an entry is.** One of four things: an expense, a refund (money back for something bought, which comes off its category), money in, or money moved between your own accounts. Only expenses and refunds are spending.
- **A card payment is not spending.** The purchases were counted when they were made. The same amount leaving one account and arriving in another within three days is paired as money moved, and both halves are shown dimmed and left out of the month.
- **Sorting.** Everything else waits for you once: SORT THEM, on the black bar, goes through what is waiting, oldest first, and you tap what each was. Said of an entry, it holds for its payee: every entry from it, in any account, past and to come. So a month takes a tap for each new payee, not for each entry. The switch above the choices makes it this one entry only, for the shop that is sometimes groceries and sometimes not. Money that came in is asked for too, once for each payee: pay is MONEY IN, and a category there means money back. Tapping any entry on Money opens the same screen, to change it or take back what was said.
- **Categories.** Twelve, fixed: groceries, eating out, fuel, transport, home, bills, subscriptions, health, shopping, fun, travel, other. Tapping one on Money shows only its entries.
- **The month.** The giant figure is expenses less refunds, sorted or not, with how much of it is not sorted yet under it. Beside the heading it is set against what had been spent by the same day last month, but only once lyfe holds the whole of last month: a part month is never compared as a whole one. An entry counts on the day the bank says it happened. The arrows by the month step to the months before.
- **Accounts.** On WORTH, each with its balance as the bank last gave it, and marked when that is more than three days old. EVERYDAY is them added up: what is in the bank less what is owed on cards. Tap an account to set it aside, for savings and investments: its balance stays on show, and nothing that moves in it counts as spending or waits to be sorted. An account the bank lists holdings for starts set aside. An account closed at its bank drops out once the bank stops listing it, and what was imported from it stays in its months; while a bank is waiting to be signed in to again, its accounts stay, with what was last seen of them.
- **Another currency.** Totals are in the currency most accounts are in (`LYFE_MONEY_CURRENCY` to say otherwise). An account in another is listed with its entries and left out of every total; nothing is converted. A bank can name the wrong currency, as a bridge can for a broker's account while giving its holdings none at all: tap the account on WORTH and say it is in the totals' currency, and it counts; the line under its name then says what the bank says, and the same tap takes it back.
- **Only what has posted.** A pending charge can change or vanish, so it is not asked for or shown. When a bank corrects a posted transaction, the entry is corrected and keeps how it was sorted.
- **When a bank stops.** Banks ask to be signed in to again from time to time, and until you do, at the bridge, that bank's month quietly stops filling. Money and Home then say which bank, and one prompt goes out for each time it happens. A failed import is shown the same way, with the reason. Anything else the bridge has to say, such as a warning about how it is being asked, is shown on Money only.
- **What the phone keeps.** MONTH, WORTH and FIRE are fetched when opened and held only while lyfe runs, so Money needs a connection. Home's strip (the month's figure, how many entries wait, and the first problem with the import) comes with Home and is kept on the phone with the rest of Home, so it shows offline with Home's age (ADR 0007, amended).
- **Not there yet.** Bills and what is left until payday, and anything about card rewards.

Account names, payees, amounts, what the investment accounts hold and the plan are in the database, so they are in the encrypted backup, and never in the server log, which only counts. The hours between imports, the history asked for at first and the days re-read each time are settings (`LYFE_MONEY_SYNC_HOURS`, `LYFE_MONEY_BACKFILL_DAYS`, `LYFE_MONEY_WINDOW_DAYS`).

### Worth

What everything comes to, and what the investments are in. The rules are `backend/src/money/worth.rs`; why it is done this way is ADR 0009.

- **Net worth.** The giant figure is every account added up: what is in the bank and what is invested, less what is owed. Under it, a bar each for those three, drawn against the largest; what is owed is striped, since it takes away.
- **The line.** The bank gives a balance now and no history, so every import keeps each account's balance for the day, and the line is drawn from those: one point a day, a day nothing was imported taking the balance before it, and a week at a time once it is longer than about a year. It starts the day this was installed, and says so until there are two days to join. Beside the heading is how it moved over the last thirty days, or since the first day kept when that is nearer. A bank connected later makes the line step up on the day it is first seen: that is lyfe learning of the money, not the money arriving, so the figure beside the heading leaves such an account out. One closed since then is counted: what was in it left.
- **What the investments are in.** An account the bank lists holdings for is an investment account, and each holding is shown with how many shares, what they are worth as the bank last priced them, its share of all the holdings, a bar against the largest, and the accounts it is in. The same fund in two accounts is one holding. lyfe looks no prices up, so a holding is as old as the import: a day or two.
- **Paid against worth.** Where the bank says what was paid for a holding, the bar over the holdings is that, solid, with what it has grown by striped: there until it is sold. A loss is the part of what was paid that is gone, as an outline. It is said only of the holdings a cost is known for, and how many that is.
- **In no holding.** What an investment account has beyond what its holdings come to is waiting in it uninvested, and is shown as that.
- **Another currency.** A holding in a currency other than the totals' is listed with its currency and has no share and no bar: nothing is converted. A holding the bank gives no currency for is in its account's, including one the owner has said.
- **What the bridge sends.** Its list of holdings is not in its published format, so lyfe reads the little it needs and takes nothing for granted. `lyfe-server money-check` says how many holdings each investment account lists, how many could not be read, how many come with what was paid, and what share of the account's balance they come to. That share should be near 100%: lyfe takes an investment account's balance to be the whole account, holdings included.

### FIRE

How far off financial independence is. The rules are `backend/src/money/fire.rs`, and the reasons, with where the starting figures come from, are in ADR 0009. What came in and what was spent is measured; everything from the FI number on is worked out from that and from the plan, in today's money.

- **Kept.** The giant figure is the savings rate: what came in less what was spent, as a share of what came in. It is taken over the last twelve whole months, or as many as lyfe holds; the screen says how many. A month is whole once every bank's entries reach back to its first day: banks give different amounts of history when first connected, and a month that has the card's spending and not the account the pay lands in would read as all spent and nothing in. The month still running is drawn dim and not counted. Under it, two bars a month on one scale: what came in as an outline, what was spent solid, so the gap between their tops is what was kept.
- **What it leaves out.** It is the rate on pay as it lands in the bank. What is taken off before that, for tax or a plan at work, is in neither figure, since the bank never sees it. And it is as good as the sorting: money a friend sent counts as money in until you say it was moved, and money sent to a person and sorted as money moved counts as kept. Money moved to savings or to a broker is kept, whether or not the broker's own account shows it arriving.
- **When a bank stops.** FIRE says so at its top, as MONTH and WORTH do. A month a bank was missing from reads low, and so does everything worked out from it. lyfe re-reads the last two weeks at each import, so a bank left unsigned for longer than that leaves a hole it does not go back for (`LYFE_MONEY_WINDOW_DAYS` widens it, to 44 at most).
- **The FI number.** A year's spending divided by the withdrawal rate: at 3.5%, 28.6 years of spending. The bar under it is filled as far as what is set aside has got. What is set aside is what counts, not net worth: mark savings as set aside on WORTH and they count, less the emergency fund. An investment account is set aside from the first time its bank lists what it holds.
- **The years to it.** How long what is set aside takes to grow to the FI number with a year's keeping added each year. Beside the heading as years, and as the year it falls in, with your age if the plan has your birth year. NOT AT THIS RATE when it would never get there, or not within a lifetime: more spent than comes in, faster than what is set aside grows.
- **The line ahead.** What is set aside in the years to come, a point a year: a heavy broken line with a year's keeping added each year, a thin one with nothing added, and the FI number as a rule across. Broken, because none of it has happened. Where the heavy line reaches the rule it stops, on a square, with the year.
- **The coast number.** What would grow to the FI number by itself by a given age, 65 unless you say otherwise. It is the tick on the bar; once what is set aside is past it, nothing more would have to be added to get there by then. It needs your birth year.
- **The emergency fund.** What you keep in savings for the unexpected, set in the plan. It is held back from the savings set aside before they count, shown as its own line under what is set aside, and never held back from investments: savings beyond it are money on its way to being invested. With no savings set aside nothing is held back, and with less than the fund, all of them are.
- **Runway.** How many months of spending the money on hand covers: what is in the bank less what is owed, over a month's spending. The emergency fund is part of it. The bar is full at six months and ticked at three, the cushion usually advised.
- **The plan.** WHAT THIS ASSUMES opens it: the withdrawal rate (3.5%), growth a year above inflation and after fees (4%), the age to coast by (65), the emergency fund (none), and your birth year (none). They start careful, so that a date that is wrong is wrong by being late; each says what it does. They are yours to set, and lyfe never changes them. The birth year is kept in the database with everything else of yours, and is only for saying an age.
- **Before there is a whole month.** There is nothing to average, so there is no rate, no FI number and no date; the screen says what it is waiting for.
- **Not there.** The fees inside a fund, tax, pensions, and how much room a registered account has left: none of it is in what the banks send. And nothing here is advice: lyfe shows what is held and how far along you are, never what to buy or sell.

## The lock

lyfe asks for Face ID, with the passcode behind it, each time it is opened (`AppModel.lock`, `apps/LyfeKit/Sources/LyfeKit/Store/OwnerCheck.swift`).

- It locks when it starts and every time it leaves the screen, so the picture iOS keeps for the app switcher is the lock screen, not your week.
- A weight typed into the morning prompt does not need it: that only adds a number from the lock screen and shows nothing.
- A running breath session is not locked away. The phone can be locked and woken mid-session, and the next tap lands without waiting for a face. It locks again once the session is over and lyfe leaves the screen.
- Signed out, the password is the lock; just after typing it you are not asked for a face as well.
- A device with no passcode cannot check, and lyfe then opens without asking.

## Notifications

The backend decides when to prompt; the phone only shows what arrives. Each weekly routine, the gym, breath training and study, is looked at on its own. A prompt is sent only when a streak is alive and today is a day to act on it:

- **Train today** (*Do a session today* for breath, *Study today* for study): every day left this week is needed to reach the week's count (four for the gym and study, three for breath), and today has no session yet. Sent once that day.
- **Recovery open**: last week was missed and this week recovers it. Sent once that week.

The morning weigh-in prompt ([Weigh-ins](#weigh-ins)) has its own time and is not held to this window. The food-logging prompt ([Food](#food)) is sent inside it, from its own time on. So is the one prompt money has: a bank to sign in to again at the bridge, sent once for each time a connection breaks.

Nothing is sent when there is slack left in the week, when the week is already out of reach, when no streak is alive, or outside 07:00 to 18:00 (`LYFE_NOTIFY_FROM_HOUR`, `LYFE_NOTIFY_UNTIL_HOUR`). Garmin is checked again just before a gym prompt, so a session recorded that morning cancels it. A breath or study session still waiting on the phone to be sent is not known to the backend, so it can be prompted for. Nothing is sent about the tape or a target review; those show on Progress.

Sending needs a key from the Apple developer account, set up once ([operations.md](operations.md#notifications-the-apple-push-key)). Without the key the server runs and sends nothing, and the Home screen says prompts are off.
