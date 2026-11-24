# lyfe

A private app that keeps three routines going: gym, breath training and food logging, and shows where the month's money went, what everything comes to, and how far off financial independence is. What it is and why is in `CONTEXT.md`, `docs/adr/` and `docs/build-plan.md`.

Built so far: steps 1 to 7 of the build plan. A strength session recorded on the watch shows up as a filled square on the Home screen, with nothing entered in lyfe. The gym band shows the streak in weeks, with recovery after a missed week, and the backend can prompt the phone when a streak needs sessions. A breath session runs in the app, one tap per hold, and the backend sets the next table from it. A morning prompt takes your weight typed into the notification itself, and Progress shows the seven-day average as a line. A meal you weighed once is logged with one tap, the Food screen shows the day against your calorie and protein targets, and the fuel band counts the days logged in a row. Any other meal is built from parts and logged as one meal: packets scanned by their barcodes, photos with one line each, which a model on the Spark estimates, and foods typed by hand, with the total kept on screen as parts are added. A built meal can be saved for one tap next time. A food can also be picked from a catalogue of 3,700 common ones, each shown by a small icon drawn on the Spark, or typed as just its grams of protein, carbs and fat. The day keeps what was measured apart from what was estimated. Each meal photo is then redrawn on the Spark as an illustration, the meal as it is with the app's ink outlines and its dish in a Poster colour, shown in the photo's place once it is ready. A month's spending is added up across every account by category, from transactions imported from the banks, with card payments and other money moved between accounts left out. Beside the month, Money shows net worth as a line over time with what the investment accounts hold, and the way to financial independence: what is kept of what comes in, the FI number, and the years to it. lyfe asks for Face ID each time it is opened.

## Layout

| Folder | What it is |
|---|---|
| `backend/` | The Rust backend: API, sign-in, Garmin poller, gym, breath, weight, food and streak rules, photo estimates, meal illustrations, food icons, the barcode food database, the money import with its sorting rules, net worth and the way to financial independence, notifications. The single authority for what counts. |
| `apps/LyfeKit/` | Swift package shared by the iPhone app and the later Mac app: API client, local storage, app model, breath timer, weigh-ins, food log, the meal builder, photo and barcode capture, money, Poster screens. |
| `apps/Lyfe/` | The iPhone app target. It only launches LyfeKit. |
| `deploy/spark/` | Scripts and service files for running the backend on the Spark, and the illustrator (`lyfe-illustrate.py`), which draws meal photos and food icons. |

## How the pieces connect

```mermaid
flowchart LR
    watch[Garmin watch] --> garmin[Garmin Connect]
    garmin -- polled every 15 min --> server[lyfe-server on the Spark]
    server --- db[(PostgreSQL, lyfe account only)]
    phone[iPhone app] -- HTTPS over Tailscale, lyfe sign-in --> server
    server -- prompts --> apple[Apple push service] --> phone
    server -- photo meals, on loopback --> ollama[Ollama on the Spark: gemma4:31b]
    server -- meal photos and food names, over a pipe --> illustrator[lyfe-illustrate: FLUX.2 klein 4B, started when needed]
    banks[Banks] --> bridge[SimpleFIN Bridge]
    bridge -- asked every 6 h, read-only --> server
```

- The backend listens on loopback only. `tailscale serve` publishes it to the tailnet over HTTPS; nothing is reachable from the public internet.
- The tailnet and the Spark are shared, so the backend has its own sign-in: one password, and one revocable token per device. Only a hash of each is stored.
- PostgreSQL runs under the `lyfe` account on a Unix socket in a folder only that account can open. It has no network port.
- The Garmin key stays in a file on the Spark. It is never in this repository, in settings, or in logs. The same goes for the address SimpleFIN Bridge issued for reading the banks; the bank sign-ins themselves are held by the bridge and never reach lyfe.
- Meal photos go only to the Spark's own Ollama, on loopback, and to the illustrator, a program lyfe-server starts itself under the `lyfe` account, which reads its model from disk and never goes to the network. Nothing about food leaves the Spark except in the encrypted backup.
- When the phone cannot reach the backend it shows the last week it saw, marked offline with its age.
- The app does not depend on the phone using Tailscale's DNS. The Spark's name also has a public answer, because other services on it are published to the internet, and a phone that looks the name up outside Tailscale gets that one, where port 8444 is closed. So when the system's answer for a `.ts.net` name is not a tailnet address, the app asks Tailscale's resolver (100.100.100.100) itself and connects to that address, still requiring the certificate to match the name (`apps/LyfeKit/Sources/LyfeKit/Net/TailnetTransport.swift`).

## What counts as a gym session

Decided by the backend (`backend/src/routines/gym.rs`):

- A Garmin activity of a counted type that lasted at least 15 minutes.
- Counted types by default: strength training, indoor cardio, HIIT, pool and open-water swimming, running, treadmill, cycling, indoor cycling, elliptical, stair climbing, indoor rowing. Walking does not count.
- A day counts once, however many activities were recorded on it.
- The week runs Monday to Sunday in the time zone set on the server.

The types and the minimum are settings (`LYFE_GYM_ACTIVITY_TYPES`, `LYFE_GYM_MIN_MINUTES`).

## Streaks and recovery

The rules are one module shared by every routine (`backend/src/routines/streak.rs`). The gym and breath training apply them to weeks (`weekly.rs`): four sessions keep a gym week, three keep a breath week. Food logging applies them to days (`food.rs`, below).

- A week with four sessions is kept, and the streak counts kept weeks in a row. The current week counts as soon as its fourth session is recorded.
- One missed week does not end the streak. Keeping the very next week recovers it, and the missed week is then shown as recovered (striped). Nothing has to be made up, and a missed week never adds to the count.
- Two missed weeks in a row end the streak. The next kept week starts a new one, and the longest ended streak stays visible as the best.
- Weeks before the first kept week are not part of any streak and are not shown.

To see every recorded week as the rules count it, on the Spark:

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

## Weigh-ins

The scale is not connected, so the weight is typed, normally straight into the morning prompt without opening lyfe. The backend decides what the numbers mean (`backend/src/routines/weight.rs`).

- **The prompt.** One notification a day at 06:30 in your time zone. Press and hold it, type the weight, tap Save. It needs no unlock and lyfe does not come forward. If the server was not running at 06:30 the prompt still goes out until 09:30, and not after; it is a morning weigh-in. It is skipped once today has a weight, and there is never a second one that day.
- **Not a streak.** A missed morning costs nothing and nothing nags about it.
- **What was typed.** `181.4`, `181,4` and `181.4 lb` all read the same; a unit typed after the number wins (`82.4 kg` on a server set to pounds is stored as the same weight). Anything under 44 lb or over 880 lb (20 to 400 kg) is a slip and is refused; a reply that is not a weight brings the prompt straight back, asking again.
- **Offline.** A weight is written to the phone before it is sent, with an id made on the phone, so a reply typed without a connection is sent the next time lyfe opens and is never stored twice.
- **The numbers.** A day's weight is the last one typed that day, so typing it again corrects it. The seven-day average covers the days of the last seven that have a weight, and is shown once at least three do. Progress shows it as the giant figure and as a line over eight weeks, each morning's weight as a small square, with the change on the week before.
- **In the app.** Home's weight strip opens Progress; the black bar there opens the entry, for a morning the prompt was missed or switched off. Tapping the prompt instead of typing into it opens the same entry.

The unit and the prompt's time are settings (`LYFE_WEIGHT_UNIT`, `lb` unless set to `kg`; `LYFE_WEIGH_IN_AT`, a time like `06:30` or `off`). Weights are stored in grams, so changing the unit changes only what is shown. The weight itself is never written to the server log.

## Food

A meal you eat repeatedly is weighed once and saved; after that logging it is one tap, and its numbers are measured rather than guessed. Anything else is built from parts: barcodes, photos and typed foods, added up as you go (Building a meal, below). The backend decides what the numbers mean (`backend/src/routines/food.rs`).

- **A saved meal.** In the app, Food > New saved meal: a name, the part of the day it belongs to (breakfast, lunch, dinner or snack), how many portions the recipe makes, and each ingredient as weighed with the kcal and protein per 100 g from its label. An ingredient can also be scanned, or typed as just what it comes to. A batch that makes five lunches is typed as the whole pot with 5 portions. The backend works out a portion; the figure in the bar is a preview of the same sum, so a slipped decimal point shows before you save. Saving needs a connection.
- **One tap.** On the Food screen, tapping a saved meal logs one portion of it now, under its part of the day. Holding it offers half, one and a half, or two portions. The black bar always offers the saved meal for the next of breakfast, lunch and dinner that is still open, the one you logged last for it, so a weekday with three saved meals is three taps on the bar.
- **A slip.** Tapping a logged meal takes it off the day; tapping a meal built from parts shows the parts, where one can be taken out or the whole meal taken off. Changing a recipe (hold the meal, Change the recipe) does not rewrite days already logged: an entry keeps the name and figures of the recipe as it was when it arrived. A removed meal leaves the list and what was logged from it stays.
- **Targets.** You type a calorie and a protein target (Food > Targets). The day is shown against them: the giant figure is what is logged, the bars fill toward the targets, and the line beside the heading says how much is left or how far over. A target counts from the day it is set, and earlier days keep the one they had. lyfe never changes a target by itself. The figures are yours and are not in this repository or the server log.
- **Unknown is not zero.** A breakfast, lunch or dinner with nothing logged shows a question mark and is listed as open, so the day's figure is never read as the whole day when it is not. Snacks are extra: a day without one is not missing anything. A meal that is logged but whose figures are not known yet (a photo still being estimated, a barcode the database does not have) fills its part of the day and counts for the streak, but is left out of the total and said so above the day.
- **Measured and estimated.** Saved meals, labels and typed figures are measured; photos are estimated, each part of a meal by itself. The bars fill solid for the first and striped for the second, and once anything is estimated the line under the figure gives the estimated part and the range the day may really be in.
- **The streak.** By the day: a day counts once anything is logged on it, whatever the numbers, so a day over target does not break it. One missed day is recovered by logging the next (shown striped), two in a row end the streak, and nothing is ever made up. The fuel band on Home shows the days in a row and the last seven days as squares, today last.
- **Offline.** A tap is written to the phone before it is sent, with an id made on the phone and the time it was tapped, so a meal logged without a connection is sent the next time lyfe opens, counts for the day it was eaten on, and is never logged twice. Until then it shows in its part of the day marked as not counted yet. Saved meals come with the last state the phone saw, so one-tap logging works from them offline.
- **The prompt.** When a streak is alive and nothing is logged by 12:00 in your time zone, one prompt goes out that day, worded for recovery when yesterday was missed. Tapping it opens the Food screen. Nothing is sent when today is already logged or no streak is alive. A meal still waiting on the phone to be sent is not known to the backend, so it can be prompted for.

The prompt's time is a setting (`LYFE_FOOD_PROMPT_AT`, a time like `12:00` or `off`); it is also held to the hours below.

## Building a meal

A meal that is not a saved one is what you ate, added part by part, and logged as one meal. The builder is a calculator as much as a log: the total is on screen from the first part. The rules are in `backend/src/routines/food.rs`; a part of a meal is stored as an entry of its own that points at its meal, so it is estimated, corrected, or waits for its label exactly as before.

- **On the phone.** Food > SCAN, PHOTO or TYPE starts a meal with that kind of part and lands in the builder; the same three buttons there add the next. SCAN reads a barcode and takes the grams (Barcodes, below). PHOTO takes a picture and one line (Photo meals, below). TYPE takes a food by hand, three ways: weighed, with the kcal and protein per 100 g from its label; just the totals, for a menu item or a coffee that comes with its figures; or macros, below. *Find an ingredient* opens the catalogue (The catalogue and its icons, below). Tapping a part changes it or takes it out.
- **Macros.** When you know what a food has in it and not what it comes to, type only the grams: TYPE > MACROS, then protein, carbs and fat, any of them left blank for none. lyfe works out the calories at 4 kcal a gram of protein or carbs and 9 a gram of fat, and shows the figure as you type, so ten grams of fat is logged by typing 10 and comes to 90 kcal. A name is optional; without one the part is called by what it is (*10 G FAT*, *30 G PROTEIN + 10 G FAT*). It counts as measured, and its carbs and fat go on the meal's macros line. The backend stores it as any food typed whole (`FoodTyping.macros`, `Macros`, in `apps/LyfeKit/Sources/LyfeKit/Food/FoodLog.swift`).
- **The running total.** The giant figure is what the parts with known figures add up to, with the protein, how much of it is estimated, and how many parts are still unknown under it. A part that is not known yet (a photo still with the model, a barcode scanned without a connection) is left out, not counted as zero.
- **Photos go ahead.** A photo is sent to the Spark as soon as it is added, so its estimate usually arrives while you add the rest, and joins the total. Until the meal is logged the photo is on no day and counts for nothing.
- **LOG IT.** Logs everything as one meal under the part of the day chosen, named after it unless you typed a name. It does not wait for a photo still being estimated: the meal is logged and that part fills in. On the day the meal is one row with its parts counted (*BREAKFAST · 4 PARTS*), striped once a photo is among them; each part still counts as measured or estimated in the day's bars.
- **A logged meal.** Tapping its row shows the parts. A photo opens its estimate, to correct as before; a code lyfe did not know asks for its label; anything else can be taken out. SCAN, PHOTO and TYPE there add a part to the meal after the fact. Taking the last part out takes the meal off the day.
- **Save it for one tap.** In the builder, *Save it for one tap next time* asks for a name and how many portions the recipe makes, and saves the parts as a saved meal; LOG IT afterwards logs one portion of it. A meal already logged can be saved the same way from its parts. Saving needs every part's figures, so it waits for a photo's estimate. A photo's part is saved at what it was estimated (and corrected) to be, and stays an estimate every time the meal is logged, so the bars stay honest; change the recipe and type it weighed to replace it. Half a portion of a saved meal is half of every ingredient, the ones typed as totals included.
- **Left half way.** Closing the builder keeps the meal: Food shows *MEAL IN PROGRESS* with a way back, and it is still there after lyfe is closed, for three days. *Throw this meal away* drops it and the photos sent for it.
- **Offline.** The builder needs no connection. A scan the phone cannot look up is added with a question mark and looked up when the meal is sent; a photo is kept and sent before its meal. The meal is written to the phone before anything is sent, with ids made on the phone, so it is never logged twice.

## Photo meals

A photo and one line saying what it was: one part of a meal, or all of it. A vision model on the Spark (gemma4:31b, in the Spark's Ollama) estimates it afterwards. The pure rules are `backend/src/routines/photo.rs`; the asking is `backend/src/estimator.rs`.

- **On the phone.** PHOTO, on Food or in the builder, opens the camera. Take the picture, type the line (*stir fry, rice, some oil*), ADD IT. A food can also be described without a photo, or a picture chosen from the library. The picture is shrunk to 1280 pixels and the location and camera details the phone writes into it are dropped before it is kept or sent.
- **It never holds the meal up.** The photo is sent when it is added and estimated in the background: seconds if the model is loaded, a couple of minutes if it has to load first. Until then its part shows as being estimated and is not in any total; the meal can be logged meanwhile and counts for the streak at once.
- **The estimate.** The model lists each food it sees with its grams, kcal and protein; the meal is their sum. It is shown with a range of ±35% either way, because photo estimates are that rough (`LYFE_PHOTO_RANGE_PERCENT`). The one-line description is trusted over the photo for what each food is.
- **Correcting it.** Tap the photo's part to open its estimate. Tap a food to change its grams (0 takes it out); its kcal and protein scale with it. Or type the meal's figures instead, from a menu that gives them; those have no range.
- **Oil.** The model is told to leave cooking fat and sauce out of its foods and to say whether the meal is fried, sauced or from a restaurant. Only then does the screen ask HOW MUCH OIL OR SAUCE?: none adds nothing, some adds 120 kcal (a tablespoon of oil), a lot adds 360. Until it is answered the meal is counted with some, since missed cooking fat is the commonest error in photo estimates.
- **Offline.** The meal and its photo are kept on the phone with an id made there, sent when the server can next be reached, and estimated then. It counts for the day it was eaten on and is never logged twice.
- **When the Spark is busy.** The model is loaded only when a photo is waiting, and only when at least 32 GB of memory are free (`LYFE_PHOTO_MIN_FREE_GB`), unless it is already loaded. Its context is capped at 8,192 tokens, which keeps it to about 26 GB where Ollama's default took twice that, and it is let go two minutes after the last photo, so meals logged together are estimated together (`LYFE_PHOTO_CONTEXT`, `LYFE_PHOTO_KEEP_ALIVE_SECONDS`). Short of memory, it tries again every five minutes; with Ollama not answering, every two. The estimate screen says which.
- **When the model gets it wrong.** An answer that is not the JSON asked for, or has figures no food could have (more than 9 kcal or more protein than grams), is not used. After three such answers lyfe stops asking and the meal waits for its figures to be typed.

`lyfe-server photo-check <photo.jpg> --note "<one line>"` asks the model about one photo and prints its answer, storing nothing. On a real plate it answered in about 20 seconds with the model loading. `LYFE_OLLAMA_URL=off` switches estimates off; photo meals are then typed in by hand. The photos are kept in the database, so they are in the backup.

## Meal illustrations

Each meal photo is redrawn as an illustration of the meal as it is, with the app's ink and colours on it: the model and how it runs are decided in ADR 0005, the look in ADR 0006. The prompt and how answers are read are `backend/src/routines/illustration.rs`; the running is `backend/src/illustrator.rs`; the drawing is `deploy/spark/lyfe-illustrate.py`.

- **What it is.** FLUX.2 klein 4B redraws the photo, with its one line in a fixed prompt: the food and drink in their own colours, thick black ink outlines, flat fills, only the cup, plate or bowl in one Poster colour (cobalt blue, red-orange or yellow), and nothing else from the photo, on a plain off-white background. That background is then set to exactly the app's paper, so the drawing sits on the screen without a box around it, and it is kept next to the photo as a PNG of 768 pixels square in at most 64 colours, about 100 kB. The same photo is drawn the same way each time. The dish's colour is the model's choice and varies from meal to meal; a glass gets a dish invented around it; and what is beside the plate is usually left out, not always.
- **It never holds anything up.** The meal is logged and counted without it. It is drawn after the photo's estimate, so the two models are not loaded for it at once; until it comes, and if it never does, the photo is shown as before.
- **Where it shows.** On a photo's estimate, the drawing takes the photo's place; tap it (PHOTO, top right) to see the photo, and again for the drawing. On Food and on a logged meal, a meal with a drawn photo shows it small beside its figure; a meal built from parts shows its first drawn photo. A photo sent ahead for a meal still being built is drawn once the meal is logged. A meal described without a photo has nothing to draw. Food and a logged meal look again while a photo is being estimated or drawn, so the drawing arrives without leaving the screen. Drawings are fetched once and kept on the phone, and fetched again only if the meal is drawn again.
- **When the Spark is busy.** The illustrator is a program lyfe-server starts itself, only when a photo is waiting and at least 24 GB of memory are free (`LYFE_ILLUSTRATION_MIN_FREE_GB`). It loads the model (about 110 seconds), draws every photo waiting (about 7 seconds each, about 17 GB of GPU memory), and is let go three minutes after the last (`LYFE_ILLUSTRATION_KEEP_ALIVE_SECONDS`): it exits and its memory goes back. Short of memory, it tries again every five minutes; not set up, every half hour; a model that would not load, every ten minutes. None of that counts against a photo. A photo that fails to draw three times is left as a photo.
- **Earlier meals, and a new look.** Photos logged before step 7 are drawn too, oldest first, the first time the illustrator runs. Each drawing is stored with the look it was drawn in (`illustration::LOOK`); when the look changes, the server marks older drawings to be drawn again as it starts, each stays until its new one replaces it, and the phone fetches the new one. The first look, a pictogram snapped to the five Poster colours, lost the meal and was replaced this way.

`lyfe-server illustration-check <photo.jpg> --note "<one line>" --out meal.png` draws one photo and writes it out, storing nothing. `LYFE_ILLUSTRATOR=off` switches illustrations off; meals then keep their photos. The drawings are kept in the database, so they are in the backup.

## The catalogue and its icons

*Find an ingredient*, in the builder and on a logged meal, opens the foods lyfe comes with: twenty staples, then the generic foods of the USDA database, about 3,700 in all, each with its kcal, protein, carbs and fat per 100 g (`apps/LyfeKit/Sources/LyfeKit/Food/Ingredients.json`). Search by name, or pick one of seventeen categories; tap a food, type the grams, and it is added as a weighed part.

Each food is shown by an icon: a small drawing of the food, made on the Spark from its name alone by the model that draws meal illustrations. Why they are drawn and not stock photos is ADR 0008. The prompt is `icon_prompt` in `backend/src/routines/illustration.rs`; the phone's side is `apps/LyfeKit/Sources/LyfeKit/Food/FoodIcons.swift`.

- **Drawn ahead of time.** `deploy/spark/draw-icons.sh` lists every name in the app's catalogue and has the Spark queue them (`lyfe-server queue-icons`); the server then draws them in the background, what each category is drawn as and the staples first. All 3,748 take a little over an hour, once. Run it again after the catalogue or the look changes: icons already drawn are left alone, so running it again only says how far along it is.
- **On the phone.** A food that stays on screen for a moment is asked for (`GET /v1/food/icons?name=`), fetched and kept, so each icon is fetched once and swiping past a food fetches nothing. With no connection the phone shows what it has kept.
- **One not drawn yet.** Asking for it puts it at the front of the queue, ahead of the ones queued in bulk, and the phone asks again every few seconds until it comes. Until then the food is shown by its category's drawing (a roast chicken for poultry, bread for breads and baking), which is an icon like any other; before even that has arrived, by an empty frame.
- **What it costs the Spark.** About a second an icon once the model is loaded, and about two minutes for the model to load. Meal photos are drawn first. The illustrator's rules hold as they do for meals: it is started only when the memory is free, and let go a few minutes after the last picture. An icon is 256 pixels square in at most 48 colours, 5 to 12 kB; the catalogue's come to about 30 MB in the database.
- **When the model gets it wrong.** An answer that is not the JSON asked for, or has figures no food could have (more than 9 kcal or more protein than grams), is not used. After three such answers lyfe stops asking and the meal waits for its figures to be typed.

`lyfe-server photo-check <photo.jpg> --note "<one line>"` asks the model about one photo and prints its answer, storing nothing. On a real plate it answered in about 20 seconds with the model loading. `LYFE_OLLAMA_URL=off` switches estimates off; photo meals are then typed in by hand. The photos are kept in the database, so they are in the backup.

## Meal illustrations

Each meal photo is redrawn as an illustration of the meal as it is, with the app's ink and colours on it: the model and how it runs are decided in ADR 0005, the look in ADR 0006. The prompt and how answers are read are `backend/src/routines/illustration.rs`; the running is `backend/src/illustrator.rs`; the drawing is `deploy/spark/lyfe-illustrate.py`.

- **What it is.** FLUX.2 klein 4B redraws the photo, with its one line in a fixed prompt: the food and drink in their own colours, thick black ink outlines, flat fills, only the cup, plate or bowl in one Poster colour (cobalt blue, red-orange or yellow), and nothing else from the photo, on a plain off-white background. That background is then set to exactly the app's paper, so the drawing sits on the screen without a box around it, and it is kept next to the photo as a PNG of 768 pixels square in at most 64 colours, about 100 kB. The same photo is drawn the same way each time. The dish's colour is the model's choice and varies from meal to meal; a glass gets a dish invented around it; and what is beside the plate is usually left out, not always.
- **It never holds anything up.** The meal is logged and counted without it. It is drawn after the photo's estimate, so the two models are not loaded for it at once; until it comes, and if it never does, the photo is shown as before.
- **Where it shows.** On a photo's estimate, the drawing takes the photo's place; tap it (PHOTO, top right) to see the photo, and again for the drawing. On Food and on a logged meal, a meal with a drawn photo shows it small beside its figure; a meal built from parts shows its first drawn photo. A photo sent ahead for a meal still being built is drawn once the meal is logged. A meal described without a photo has nothing to draw. Food and a logged meal look again while a photo is being estimated or drawn, so the drawing arrives without leaving the screen. Drawings are fetched once and kept on the phone, and fetched again only if the meal is drawn again.
- **When the Spark is busy.** The illustrator is a program lyfe-server starts itself, only when a photo is waiting and at least 24 GB of memory are free (`LYFE_ILLUSTRATION_MIN_FREE_GB`). It loads the model (about 110 seconds), draws every photo waiting (about 7 seconds each, about 17 GB of GPU memory), and is let go three minutes after the last (`LYFE_ILLUSTRATION_KEEP_ALIVE_SECONDS`): it exits and its memory goes back. Short of memory, it tries again every five minutes; not set up, every half hour; a model that would not load, every ten minutes. None of that counts against a photo. A photo that fails to draw three times is left as a photo.
- **Earlier meals, and a new look.** Photos logged before step 7 are drawn too, oldest first, the first time the illustrator runs. Each drawing is stored with the look it was drawn in (`illustration::LOOK`); when the look changes, the server marks older drawings to be drawn again as it starts, each stays until its new one replaces it, and the phone fetches the new one. The first look, a pictogram snapped to the five Poster colours, lost the meal and was replaced this way.

`lyfe-server illustration-check <photo.jpg> --note "<one line>" --out meal.png` draws one photo and writes it out, storing nothing. `LYFE_ILLUSTRATOR=off` switches illustrations off; meals then keep their photos. The drawings are kept in the database, so they are in the backup.

## The catalogue and its icons

*Find an ingredient*, in the builder and on a logged meal, opens the foods lyfe comes with: twenty staples, then the generic foods of the USDA database, about 3,700 in all, each with its kcal, protein, carbs and fat per 100 g (`apps/LyfeKit/Sources/LyfeKit/Food/Ingredients.json`). Search by name, or pick one of seventeen categories; tap a food, type the grams, and it is added as a weighed part.

Each food is shown by an icon: a small drawing of the food, made on the Spark from its name alone by the model that draws meal illustrations. Why they are drawn and not stock photos is ADR 0008. The prompt is `icon_prompt` in `backend/src/routines/illustration.rs`; the phone's side is `apps/LyfeKit/Sources/LyfeKit/Food/FoodIcons.swift`.

- **Drawn when looked at.** Nothing is drawn ahead of time. A food that stays on screen for a moment is asked for (`GET /v1/food/icons?name=`), which puts it in the illustrator's queue; the phone asks again every few seconds until it is drawn, then keeps it, so each icon is fetched once. Swiping past a food does not ask for it. The food asked for latest is drawn first.
- **Until it comes.** A food is shown by its category's drawing (a roast chicken for poultry, bread for breads and baking), which is an icon like any other and is fetched the same way; before even that has arrived, by an empty frame. With no connection the phone shows what it has kept.
- **What it costs the Spark.** About a second an icon once the model is loaded, and about two minutes for the model to load when it is not, so the first icons of a sitting take that long. Meal photos are drawn first. The illustrator's rules hold as they do for meals: it is started only when the memory is free, and let go a few minutes after the last picture. An icon is 256 pixels square in at most 48 colours, 5 to 12 kB.
- **When the model gets it wrong.** It reads names literally, so an odd one can come out as the wrong thing: black turtle beans as a turtle, a branded food as a jar with lettering on it. An icon that fails to draw three times is left as its category's. There is no way to ask for another drawing from the phone yet.
- **A new look.** Each icon is stored with the look it was drawn in (`illustration::ICON_LOOK`), and the day tells the phone which look is current. When it moves on, `draw-icons.sh` queues them all again, an icon asked for meanwhile goes first, and the phone shows the one it has until the new one comes.

`lyfe-server icon-check "<food name>" --out icon.png` draws one icon and writes it out, storing nothing. `LYFE_ILLUSTRATOR=off` switches icons off with illustrations; foods are then shown by an empty frame. Icons are kept in the database but left out of the backup, since they can be drawn again.

## Barcodes

Packaged food is logged from its label: a barcode and the grams eaten. Label figures are measured, not estimated. The rules are `backend/src/routines/product.rs`.

- **On the phone.** SCAN, on Food or in the builder, reads the barcode with the camera (or type the number under the bars). lyfe shows the product and its figures per 100 g; type the grams, or tap ½, 1 or 2 servings when the label states one, and ADD IT. The builder comes back with the part in it, and SCAN is there for the next packet.
- **Where the figures come from.** A downloaded copy of Open Food Facts on the Spark (below), or a label you typed. A product you have logged lately is known on the phone, so scanning it again works without a connection.
- **Not in the database.** Type it once from the packet: its name, kcal and protein per 100 g, and the serving if it has one. It is remembered, and wins over the database's figures from then on. Meals logged earlier keep the figures they had.
- **Offline.** A scan is kept on the phone with the grams, and looked up when it is sent. If the code turns out to be unknown, the meal is logged with a question mark and Food asks for its label; typing it fills in that meal.
- **A UPC and its EAN** (the same digits with a 0 in front) are the same product, whichever the scanner reads.

The food database is about 1.5 GB to download and is not in the backup, since it can be fetched again. To fetch it, or a newer copy, on the Spark as `lyfe`:

```sh
~/bin/lyfe-food-db
```

It downloads the export, checks it is whole, and swaps it in all at once, so a lookup meanwhile still finds the old copy. Lines without a name, energy or protein are skipped. Open Food Facts is published under the Open Database License; lyfe uses it privately and does not pass it on.

## Money

Money has three sections under one head: MONTH, WORTH and FIRE. The month is what its spending comes to across every account, by category, with the entries behind it. Nothing is typed: the accounts, their transactions and what the investment accounts hold come from the banks through SimpleFIN Bridge (ADR 0007). The month's rules are `backend/src/money/ledger.rs`; the importing is `backend/src/money/sync.rs` and the bridge's client `backend/src/money/mod.rs`. Worth and FIRE are further down.

- **Where it comes from.** You connect each bank at SimpleFIN Bridge, in a browser. lyfe never sees a bank password: the bridge gives it one read-only access address, which stays in a file on the Spark. Every six hours lyfe-server asks the bridge for the balances and for the transactions posted in the last two weeks, and the first time for as far back as the banks give, up to 180 days in four requests. The bridge itself refreshes about once a day and a purchase can take a few days to post, so Money is a day or two behind your cards. It allows about 24 requests a day; lyfe makes four.
- **What an entry is.** One of four things: an expense, a refund (money back for something bought, which comes off its category), money in, or money moved between your own accounts. Only expenses and refunds are spending.
- **A card payment is not spending.** The purchases were counted when they were made. The same amount leaving one account and arriving in another within three days is paired as money moved, and both halves are shown dimmed and left out of the month.
- **Sorting.** Everything else waits for you once: SORT THEM, on the black bar, goes through what is waiting, oldest first, and you tap what each was. Said of an entry, it holds for its payee: every entry from it, in any account, past and to come. So a month takes a tap for each new payee, not for each entry. The switch above the choices makes it this one entry only, for the shop that is sometimes groceries and sometimes not. Money that came in is asked for too, once for each payee: pay is MONEY IN, and a category there means money back. Tapping any entry on Money opens the same screen, to change it or take back what was said.
- **Categories.** Twelve, fixed: groceries, eating out, fuel, transport, home, bills, subscriptions, health, shopping, fun, travel, other. Tapping one on Money shows only its entries.
- **The month.** The giant figure is expenses less refunds, sorted or not, with how much of it is not sorted yet under it. Beside the heading it is set against what had been spent by the same day last month, but only once lyfe holds the whole of last month: a part month is never compared as a whole one. An entry counts on the day the bank says it happened. The arrows by the month step to the months before.
- **Accounts.** On WORTH, each with its balance as the bank last gave it, and marked when that is more than three days old. EVERYDAY is them added up: what is in the bank less what is owed on cards. Tap an account to set it aside, for savings and investments: its balance stays on show, and nothing that moves in it counts as spending or waits to be sorted. An account the bank lists holdings for starts set aside. An account closed at its bank drops out once the bank stops listing it, and what was imported from it stays in its months; while a bank is waiting to be signed in to again, its accounts stay, with what was last seen of them.
- **Another currency.** Totals are in the currency most accounts are in (`LYFE_MONEY_CURRENCY` to say otherwise). An account in another is listed with its entries and left out of every total; nothing is converted.
- **Only what has posted.** A pending charge can change or vanish, so it is not asked for or shown. When a bank corrects a posted transaction, the entry is corrected and keeps how it was sorted.
- **When a bank stops.** Banks ask to be signed in to again from time to time, and until you do, at the bridge, that bank's month quietly stops filling. Money and Home then say which bank, and one prompt goes out for each time it happens. A failed import is shown the same way, with the reason. Anything else the bridge has to say, such as a warning about how it is being asked, is shown on Money only.
- **Not kept on the phone.** A month is fetched when Money is opened and held only while lyfe runs, so Money needs a connection. Home's strip, with the month's figure and how many entries wait, comes with Home.
- **Not there yet.** Bills and what is left until payday, and anything about card rewards.

### Worth

What everything comes to, and what the investments are in. The rules are `backend/src/money/worth.rs`; why it is done this way is ADR 0009.

- **Net worth.** The giant figure is every account added up: what is in the bank and what is invested, less what is owed. Under it, a bar each for those three, drawn against the largest; what is owed is striped, since it takes away.
- **The line.** The bank gives a balance now and no history, so every import keeps each account's balance for the day, and the line is drawn from those: one point a day, a day nothing was imported taking the balance before it, and a week at a time once it is longer than about a year. It starts the day this was installed, and says so until there are two days to join. Beside the heading is how it moved over the last thirty days, or since the first day kept when that is nearer. A bank connected later makes the line step up on the day it is first seen: that is lyfe learning of the money, not the money arriving, so the figure beside the heading leaves such an account out. One closed since then is counted: what was in it left.
- **What the investments are in.** An account the bank lists holdings for is an investment account, and each holding is shown with how many shares, what they are worth as the bank last priced them, its share of all the holdings, a bar against the largest, and the accounts it is in. The same fund in two accounts is one holding. lyfe looks no prices up, so a holding is as old as the import: a day or two.
- **Paid against worth.** Where the bank says what was paid for a holding, the bar over the holdings is that, solid, with what it has grown by striped: there until it is sold. A loss is the part of what was paid that is gone, as an outline. It is said only of the holdings a cost is known for, and how many that is.
- **In no holding.** What an investment account has beyond what its holdings come to is waiting in it uninvested, and is shown as that.
- **Another currency.** A holding in a currency other than the totals' is listed with its currency and has no share and no bar: nothing is converted.
- **What the bridge sends.** Its list of holdings is not in its published format, so lyfe reads the little it needs and takes nothing for granted. `lyfe-server money-check` says how many holdings each investment account lists, how many could not be read, how many come with what was paid, and what share of the account's balance they come to. That share should be near 100%: lyfe takes an investment account's balance to be the whole account, holdings included.

### FIRE

How far off financial independence is. The rules are `backend/src/money/fire.rs`, and the reasons, with where the starting figures come from, are in ADR 0009. What came in and what was spent is measured; everything from the FI number on is worked out from that and from the plan, in today's money.

- **Kept.** The giant figure is the savings rate: what came in less what was spent, as a share of what came in. It is taken over the last twelve whole months, or as many as lyfe holds; the screen says how many. The month still running is drawn dim and not counted. Under it, two bars a month on one scale: what came in as an outline, what was spent solid, so the gap between their tops is what was kept.
- **What it leaves out.** It is the rate on pay as it lands in the bank. What is taken off before that, for tax or a plan at work, is in neither figure, since the bank never sees it. And it is as good as the sorting: money a friend sent counts as money in until you say it was moved.
- **When a bank stops.** FIRE says so at its top, as MONTH and WORTH do. A month a bank was missing from reads low, and so does everything worked out from it. lyfe re-reads the last two weeks at each import, so a bank left unsigned for longer than that leaves a hole it does not go back for (`LYFE_MONEY_WINDOW_DAYS` widens it, to 44 at most).
- **The FI number.** A year's spending divided by the withdrawal rate: at 3.5%, 28.6 years of spending. The bar under it is filled as far as what is set aside has got. What is set aside is what counts, not net worth: mark savings as set aside on WORTH and they count.
- **The years to it.** How long what is set aside takes to grow to the FI number with a year's keeping added each year. Beside the heading as years, and as the year it falls in, with your age if the plan has your birth year. NOT AT THIS RATE when it would never get there, or not within a lifetime: more spent than comes in, faster than what is set aside grows.
- **The line ahead.** What is set aside in the years to come, a point a year: a heavy broken line with a year's keeping added each year, a thin one with nothing added, and the FI number as a rule across. Broken, because none of it has happened. Where the heavy line reaches the rule it stops, on a square, with the year.
- **The coast number.** What would grow to the FI number by itself by a given age, 65 unless you say otherwise. It is the tick on the bar; once what is set aside is past it, nothing more would have to be added to get there by then. It needs your birth year.
- **Runway.** How many months of spending the money on hand covers: what is in the bank less what is owed, over a month's spending. The bar is full at six months and ticked at three, the cushion usually advised.
- **The plan.** WHAT THIS ASSUMES opens it: the withdrawal rate (3.5%), growth a year above inflation and after fees (4%), the age to coast by (65), and your birth year (none). They start careful, so that a date that is wrong is wrong by being late; each says what it does. They are yours to set, and lyfe never changes them. The birth year is kept in the database with everything else of yours, and is only for saying an age.
- **Before there is a whole month.** There is nothing to average, so there is no rate, no FI number and no date; the screen says what it is waiting for.
- **Not there.** The fees inside a fund, tax, pensions, and how much room a registered account has left: none of it is in what the banks send. And nothing here is advice: lyfe shows what is held and how far along you are, never what to buy or sell.

To connect, once:

1. At SimpleFIN Bridge, make an account, connect each bank under it, and make a setup token for a new app. A token works once.
2. On the Spark, as `lyfe`: `set -a; . ~/.config/lyfe/lyfe.env; set +a; ~/bin/lyfe-server money-connect`, and paste the token. It is typed hidden, traded for the access address, and that is written to `LYFE_SIMPLEFIN_ACCESS_FILE`, readable only by `lyfe`.
3. `~/bin/lyfe-server money-check` asks the bridge for the last week and prints counts only, with what share of each investment account's balance its holdings come to. Then `systemctl --user restart lyfe-server`; the first import follows within ten minutes, or at once with `~/bin/lyfe-server money-import`.

The access address is a password to everything the bridge can read: it is never in this repository, in settings, or in logs, and it is not in the backup. To cut lyfe off, delete the app's access at the bridge. Account names, payees, amounts, what the investment accounts hold and the plan are in the database, so they are in the encrypted backup, and never in the server log, which only counts. The hours between imports, the history asked for at first and the days re-read each time are settings (`LYFE_MONEY_SYNC_HOURS`, `LYFE_MONEY_BACKFILL_DAYS`, `LYFE_MONEY_WINDOW_DAYS`).

## The lock

lyfe asks for Face ID, with the passcode behind it, each time it is opened (`AppModel.lock`, `apps/LyfeKit/Sources/LyfeKit/Store/OwnerCheck.swift`).

- It locks when it starts and every time it leaves the screen, so the picture iOS keeps for the app switcher is the lock screen, not your week.
- A weight typed into the morning prompt does not need it: that only adds a number from the lock screen and shows nothing.
- A running breath session is not locked away. The phone can be locked and woken mid-session, and the next tap lands without waiting for a face. It locks again once the session is over and lyfe leaves the screen.
- Signed out, the password is the lock; just after typing it you are not asked for a face as well.
- A device with no passcode cannot check, and lyfe then opens without asking.

## Notifications

The backend decides when to prompt; the phone only shows what arrives. Each weekly routine, the gym and breath training, is looked at on its own. A prompt is sent only when a streak is alive and today is a day to act on it:

- **Train today**: every day left this week is needed to reach four, and today has no session yet. Sent once that day.
- **Recovery open**: last week was missed and this week recovers it. Sent once that week.

The morning weigh-in prompt (above) has its own time and is not held to this window. The food-logging prompt (above) is sent inside it, from its own time on. So is the one prompt money has: a bank to sign in to again at the bridge, sent once for each time a connection breaks.

Nothing is sent when there is slack left in the week, when the week is already out of reach, when no streak is alive, or outside 07:00 to 18:00 (`LYFE_NOTIFY_FROM_HOUR`, `LYFE_NOTIFY_UNTIL_HOUR`). Garmin is checked again just before a gym prompt, so a session recorded that morning cancels it. A breath session still waiting on the phone to be sent is not known to the backend, so it can be prompted for.

Sending needs a key from the Apple developer account, set up once:

1. At developer.apple.com, under Certificates, Identifiers & Profiles > Keys, create a key with Apple Push Notifications service enabled and download it (`AuthKey_<key id>.p8`). Apple lets you download it only once.
2. Copy it to the Spark, readable only by `lyfe`, keeping Apple's file name: `scp -i <key> AuthKey_*.p8 lyfe@<spark>:.config/lyfe/ && ssh -i <key> lyfe@<spark> 'chmod 600 ~/.config/lyfe/AuthKey_*.p8'`.
3. In `~/.config/lyfe/lyfe.env` on the Spark, set `LYFE_APNS_KEY_FILE` to that path and `LYFE_APNS_TEAM_ID` to your team ID, then `systemctl --user restart lyfe-server`.
4. Open lyfe on the phone and allow notifications, then send a test: `~/bin/lyfe-server push-test` (with the settings loaded as above).

Without the key the server runs and sends nothing, and the Home screen says prompts are off.

## Working on the backend

Needs Rust and Docker.

```sh
# A database for development and tests
docker run -d --name lyfe-dev-db -e POSTGRES_PASSWORD=dev -e POSTGRES_DB=lyfe \
    -p 127.0.0.1:54329:5432 postgres:16-alpine

cd backend
export DATABASE_URL=postgres://postgres:dev@127.0.0.1:54329/lyfe
cargo test
```

The tests run the real API and Garmin client against a stand-in Garmin server and a real database; they never contact Garmin.

To run it locally:

```sh
export LYFE_DATABASE_URL=$DATABASE_URL LYFE_TIMEZONE=America/Puerto_Rico
cargo run -- set-password
cargo run -- serve
```

Without `LYFE_GARMIN_KEY_FILE` the server runs and imports nothing. `lyfe-server garmin-check` asks Garmin for recent activities and prints counts only, to confirm a key file works.

Photo meals need a model to estimate them. On this Mac, use the stand-in, which answers every photo with rice and chicken: `python3 -I backend/tests/ollama_stand_in.py 11499` and `LYFE_OLLAMA_URL=http://127.0.0.1:11499`. To try the real model instead, forward the Spark's Ollama (`ssh -L 11435:127.0.0.1:11434 <spark>`) and use `LYFE_OLLAMA_URL=http://127.0.0.1:11435`; it then loads on the Spark. Meal illustrations need the image model, which does not run on this Mac; the stand-in answers every photo, and every food's icon, with the same made-up plate: `LYFE_ILLUSTRATOR=$PWD/backend/tests/illustrator_stand_in.py` (the tests use it too; it is stdlib Python). For barcodes, `gunzip -c <export>.csv.gz | lyfe-server import-food-db` reads an Open Food Facts export, or any part of one with its header line. For money, the stand-in bridge serves two made-up banks and a broker, with four and a half months of made-up transactions ending today and two investment accounts with what they hold: `python3 -I backend/tests/simplefin_stand_in.py 11498`, an access file holding `http://lyfe:stand-in@127.0.0.1:11498/simplefin`, and `LYFE_SIMPLEFIN_ACCESS_FILE` set to it; `cargo run -- money-import` then imports at once. An address on this machine is the only one lyfe asks that is not the bridge's own.

## Working on the app

Needs Xcode and `xcodegen`.

```sh
cd apps/LyfeKit && swift test          # logic tests, run on the Mac

cd ../Lyfe && xcodegen && open Lyfe.xcodeproj
```

Put your signing team and the server address in `apps/Lyfe/Local.xcconfig` (not committed; `Config.xcconfig` shows the format). The app then installs on your phone without picking a team in Xcode, and the sign-in screen comes with the server filled in, so only the password is typed.

A debug build can be launched already signed in against a local backend by setting `LYFE_DEBUG_SERVER` and `LYFE_DEBUG_PASSWORD` in its environment.

When the phone cannot reach the server, a debug build can say why. With the phone unlocked:

```sh
xcrun devicectl device process launch --console --terminate-existing \
    --environment-variables '{"LYFE_DEBUG_PROBE":"1"}' --device "<phone name>" com.eduardkakosyan.lyfe
```

It prints what the system and Tailscale each answer for the server's name and whether the backend replied, then quits.

A debug build launched with `LYFE_DEBUG_GALLERY` set shows the gym and breath bands in every streak state with made-up numbers (`LYFE_DEBUG_GALLERY=3` skips the first three). `LYFE_DEBUG_BREATH` set to `ready`, `leadin`, `hold`, `beaten`, `recover`, `done` or `offline` shows that breath screen. `LYFE_DEBUG_PROGRESS` set to `full`, `new`, `empty`, `entry` or `kg` shows Progress or the weight entry with made-up weights. `LYFE_DEBUG_FOOD` set to `day`, `morning`, `done`, `over`, `recovering`, `offline`, `empty`, `editor`, `new` or `targets` shows the Food screen, the meal editor or the targets entry with made-up meals; set to `mixed`, `builder`, `building`, `logged`, `photo`, `estimate`, `estimating`, `failed`, `scan`, `product`, `notfound` or `label` it shows the builder, photo and barcode screens; set to `drawn`, `drawnday` or `drawnmeal` it shows an estimate, the day or a logged meal with their photos drawn as illustrations; set to `picker` or `macros` it shows the catalogue with a made-up icon on every food, or a food being typed as its macros. `LYFE_DEBUG_MONEY` set to `month`, `sorted`, `entries`, `sort`, `income`, `resort`, `trouble`, `empty` or `waiting` shows Money or its sorting screen with made-up figures; set to `worth`, `worth-new` (the first day kept) or `worth-plain` (no investments) it shows Worth, and set to `fire`, `fire-new` (no whole month yet), `fire-short` (more spent than comes in), `fire-there` (independent) or `plan` it shows FIRE or what it assumes. A Worth or FIRE screen followed by `+` and a number, as in `fire+330`, shows what is that many points down it, which a screenshot cannot scroll to. `LYFE_DEBUG_OPEN` set to `food`, `meal`, `build`, `targets`, `photo`, `scan`, `progress`, `money`, `worth`, `fire` or `plan` opens that screen of the real app once it has signed in; with `LYFE_DEBUG_FOOD_TAP` set as well it first logs the meal the Food screen's bar offers, and with `LYFE_DEBUG_FOOD_PHOTO` set to a line it logs a made-up plate as a photo meal and opens its estimate, or with `build` adds it to the meal being built, so use either against a local backend; with `money` and `LYFE_DEBUG_MONEY_SORT` set to a category it sorts the oldest entry waiting into it, so use that against a local backend with the stand-in bridge. `LYFE_DEBUG_UNLOCKED` opens lyfe without Face ID, `LYFE_DEBUG_LOCKED` keeps it on the lock screen, and `LYFE_DEBUG_LOCKED=open` lets the lock open by itself each time, for trying it in the simulator. `LYFE_DEBUG_BREATH_RUN=12` runs the next session by itself with 12-second holds; it plays the tones and records the session, so use it against a local backend with the sound down.

The tests that need a real server are skipped unless told where one is: `LYFE_LIVE_SERVER=<name>:8444@<tailnet address> swift test`. `LYFE_LOCAL_SERVER=http://127.0.0.1:8787 LYFE_LOCAL_PASSWORD=<password> swift test --no-parallel` runs the app's client against a backend on this machine; it records a breath session, saves and removes a meal, sets food targets, logs entries, a photo meal and a barcode, builds a meal from parts and saves it, waits for a photo's illustration, and types a label, so give that backend a scratch database, the stand-in model and the stand-in illustrator (above). `--no-parallel` keeps the checks from logging into each other's day.

## Running on the Spark

Once, with administrator rights (you type your sudo password on the Spark):

```sh
deploy/spark/bootstrap.sh
```

Say how you reach your Spark in `deploy/spark/local.env`, which is not committed: `ADMIN_SSH` for the account with sudo rights, `LYFE_SSH` for the `lyfe` account, and `LYFE_SSH_KEY` for the key that logs in as it. Both scripts read it.

This creates the `lyfe` account, installs the PostgreSQL programs without a machine-wide database, lets your SSH key log in as `lyfe`, copies the Garmin key file into lyfe's home, and publishes port 8444 on the tailnet. Read `deploy/spark/setup-admin.sh` first; it lists exactly what it changes.

Then, and again for every new version (no sudo):

```sh
deploy/spark/install.sh
```

After the first install, set the password as the script tells you. The app's server address is then `<spark-name>.<tailnet>.ts.net:8444`. For barcodes, fetch the food database once (`~/bin/lyfe-food-db` as `lyfe`, see Barcodes). Photo meals need gemma4:31b in the Spark's Ollama, which is shared: `ollama pull gemma4:31b` by whoever runs it, if `photo-check` says it is missing. Meal illustrations and food icons need the illustrator set up once, as `lyfe` (no sudo): `~/bin/lyfe-illustrator-setup`; then `deploy/spark/draw-icons.sh`, from this Mac, has every food's icon drawn (The catalogue and its icons, above). It makes a Python of its own in `~/illustrator` with pinned versions of PyTorch and diffusers (about 6 GB), downloads FLUX.2 klein 4B at a pinned revision (about 15 GB; Apache 2.0, not gated), checks the GPU can be used from the account, and says how to try it with `illustration-check`. Until it has run, meals keep their photos, and `install.sh` says so. Money needs the banks connected once (see Money); until then `install.sh` says that too.

## Backup

Every night the Spark sends an encrypted copy of the whole database to a private bucket in Supabase Storage (`deploy/spark/lyfe-backup`, started by `lyfe-backup.timer` at 03:30 by the Spark's own clock, which need not be your time zone, or when the Spark is next up if it was off). Until it is set up, the database on the Spark is the only copy, and `install.sh` says so each time it runs.

- **What leaves the Spark.** One file a night, `lyfe-<date and time>.dump.gpg`: a `pg_dump` of the database, meal photos, their illustrations and everything imported from the banks included and the downloaded food database and the food icons left out, encrypted on the Spark with AES-256 under a passphrase only you hold. Supabase stores a file it cannot read. After each upload the script reads the bucket's listing and fails unless the file is there at its full size.
- **What it does not do yet.** Old backups are never deleted. A failed night shows only in the Spark's log (`journalctl --user -u lyfe-backup`); nothing tells the phone.

Set it up once:

1. In Supabase, pick the project. An S3 access key reaches every bucket in its project and ignores row-level security, and it will sit on a shared machine, so use a project that holds nothing else you would mind exposing; a project of its own is safest.
2. In that project, create a private bucket (Storage > New bucket, not public), and an S3 access key (in the Storage settings, under S3). The same place shows the endpoint and region.
3. On the Spark, as `lyfe`, put the access key in `~/.config/lyfe/backup-s3-key` (the key ID on line 1, the secret on line 2) and make a passphrase:

   ```sh
   umask 077
   nano ~/.config/lyfe/backup-s3-key
   openssl rand -base64 32 > ~/.config/lyfe/backup-passphrase
   cat ~/.config/lyfe/backup-passphrase   # copy this into your password manager
   ```

   Without the passphrase no backup can be read, so a copy has to exist somewhere other than the Spark.
4. In `~/.config/lyfe/backup.env` on the Spark, fill in `LYFE_BACKUP_S3_ENDPOINT`, `LYFE_BACKUP_S3_REGION` and `LYFE_BACKUP_BUCKET`.
5. Run `~/bin/lyfe-backup` once and check it says "Backed up", then `deploy/spark/install.sh` (with `SKIP_BUILD=1` if nothing else changed), which switches the nightly timer on.

To get a backup back, on any machine with the settings and the passphrase:

```sh
~/bin/lyfe-backup list                                   # names and sizes, oldest first
~/bin/lyfe-backup fetch lyfe-<date and time>.dump.gpg lyfe.dump
createdb lyfe_restored && pg_restore --no-owner --dbname=lyfe_restored lyfe.dump
```

Try that once after setting it up: a backup that has never been restored is not yet a backup.
