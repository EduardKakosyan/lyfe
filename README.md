# lyfe

A private app that keeps three routines going: gym, breath training and food logging. What it is and why is in `CONTEXT.md`, `docs/adr/` and `docs/build-plan.md`.

Built so far: steps 1 to 5 of the build plan. A strength session recorded on the watch shows up as a filled square on the Home screen, with nothing entered in lyfe. The gym band shows the streak in weeks, with recovery after a missed week, and the backend can prompt the phone when a streak needs sessions. A breath session runs in the app, one tap per hold, and the backend sets the next table from it. A morning prompt takes your weight typed into the notification itself, and Progress shows the seven-day average as a line. A meal you weighed once is logged with one tap, the Food screen shows the day against your calorie and protein targets, and the fuel band counts the days logged in a row. lyfe asks for Face ID each time it is opened.

## Layout

| Folder | What it is |
|---|---|
| `backend/` | The Rust backend: API, sign-in, Garmin poller, gym, breath, weight, food and streak rules, notifications. The single authority for what counts. |
| `apps/LyfeKit/` | Swift package shared by the iPhone app and the later Mac app: API client, local storage, app model, breath timer, weigh-ins, food log, Poster screens. |
| `apps/Lyfe/` | The iPhone app target. It only launches LyfeKit. |
| `deploy/spark/` | Scripts and service files for running the backend on the Spark. |

## How the pieces connect

```mermaid
flowchart LR
    watch[Garmin watch] --> garmin[Garmin Connect]
    garmin -- polled every 15 min --> server[lyfe-server on the Spark]
    server --- db[(PostgreSQL, lyfe account only)]
    phone[iPhone app] -- HTTPS over Tailscale, lyfe sign-in --> server
    server -- prompts --> apple[Apple push service] --> phone
```

- The backend listens on loopback only. `tailscale serve` publishes it to the tailnet over HTTPS; nothing is reachable from the public internet.
- The tailnet and the Spark are shared, so the backend has its own sign-in: one password, and one revocable token per device. Only a hash of each is stored.
- PostgreSQL runs under the `lyfe` account on a Unix socket in a folder only that account can open. It has no network port.
- The Garmin key stays in a file on the Spark. It is never in this repository, in settings, or in logs.
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

A meal you eat repeatedly is weighed once and saved; after that logging it is one tap, and its numbers are measured rather than guessed. Anything else cannot be logged yet: photo and barcode meals are step 6. The backend decides what the numbers mean (`backend/src/routines/food.rs`).

- **A saved meal.** In the app, Food > New saved meal: a name, the part of the day it belongs to (breakfast, lunch, dinner or snack), how many portions the recipe makes, and each ingredient as weighed with the kcal and protein per 100 g from its label. A batch that makes five lunches is typed as the whole pot with 5 portions. The backend works out a portion; the figure in the editor's bar is a preview of the same sum, so a slipped decimal point shows before you save. Saving needs a connection.
- **One tap.** On the Food screen, tapping a saved meal logs one portion of it now, under its part of the day. Holding it offers half, one and a half, or two portions. The black bar always offers the saved meal for the next of breakfast, lunch and dinner that is still open, the one you logged last for it, so a weekday with three saved meals is three taps on the bar.
- **A slip.** Tapping a logged meal takes it off the day. Changing a recipe (hold the meal, Change the recipe) does not rewrite days already logged: an entry keeps the name and figures of the recipe as it was when it arrived. A removed meal leaves the list and what was logged from it stays.
- **Targets.** You type a calorie and a protein target (Food > Targets). The day is shown against them: the giant figure is what is logged, the bars fill toward the targets, and the line beside the heading says how much is left or how far over. A target counts from the day it is set, and earlier days keep the one they had. lyfe never changes a target by itself. The figures are yours and are not in this repository or the server log.
- **Unknown is not zero.** A breakfast, lunch or dinner with nothing logged shows a question mark and is listed as open, so the day's figure is never read as the whole day when it is not. Snacks are extra: a day without one is not missing anything.
- **The streak.** By the day: a day counts once anything is logged on it, whatever the numbers, so a day over target does not break it. One missed day is recovered by logging the next (shown striped), two in a row end the streak, and nothing is ever made up. The fuel band on Home shows the days in a row and the last seven days as squares, today last.
- **Offline.** A tap is written to the phone before it is sent, with an id made on the phone and the time it was tapped, so a meal logged without a connection is sent the next time lyfe opens, counts for the day it was eaten on, and is never logged twice. Until then it shows in its part of the day marked as not counted yet. Saved meals come with the last state the phone saw, so one-tap logging works from them offline.
- **The prompt.** When a streak is alive and nothing is logged by 12:00 in your time zone, one prompt goes out that day, worded for recovery when yesterday was missed. Tapping it opens the Food screen. Nothing is sent when today is already logged or no streak is alive. A meal still waiting on the phone to be sent is not known to the backend, so it can be prompted for.

The prompt's time is a setting (`LYFE_FOOD_PROMPT_AT`, a time like `12:00` or `off`); it is also held to the hours below.

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

The morning weigh-in prompt (above) has its own time and is not held to this window. The food-logging prompt (above) is sent inside it, from its own time on.

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

A debug build launched with `LYFE_DEBUG_GALLERY` set shows the gym and breath bands in every streak state with made-up numbers (`LYFE_DEBUG_GALLERY=3` skips the first three). `LYFE_DEBUG_BREATH` set to `ready`, `leadin`, `hold`, `beaten`, `recover`, `done` or `offline` shows that breath screen. `LYFE_DEBUG_PROGRESS` set to `full`, `new`, `empty`, `entry` or `kg` shows Progress or the weight entry with made-up weights. `LYFE_DEBUG_FOOD` set to `day`, `morning`, `done`, `over`, `recovering`, `offline`, `empty`, `editor`, `new` or `targets` shows the Food screen, the meal editor or the targets entry with made-up meals. `LYFE_DEBUG_OPEN` set to `food`, `meal`, `targets` or `progress` opens that screen of the real app once it has signed in; with `LYFE_DEBUG_FOOD_TAP` set as well it first logs the meal the Food screen's bar offers, so use that against a local backend. `LYFE_DEBUG_UNLOCKED` opens lyfe without Face ID, `LYFE_DEBUG_LOCKED` keeps it on the lock screen, and `LYFE_DEBUG_LOCKED=open` lets the lock open by itself each time, for trying it in the simulator. `LYFE_DEBUG_BREATH_RUN=12` runs the next session by itself with 12-second holds; it plays the tones and records the session, so use it against a local backend with the sound down.

The tests that need a real server are skipped unless told where one is: `LYFE_LIVE_SERVER=<name>:8444@<tailnet address> swift test`. `LYFE_LOCAL_SERVER=http://127.0.0.1:8787 LYFE_LOCAL_PASSWORD=<password> swift test` runs the app's client against a backend on this machine; it records a breath session, saves and removes a meal, sets food targets and logs entries, so give that backend a scratch database.

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

After the first install, set the password as the script tells you. The app's server address is then `<spark-name>.<tailnet>.ts.net:8444`.

There is no backup yet: the database on the Spark is the only copy.
