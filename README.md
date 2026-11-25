# lyfe

## What

A private iPhone app that keeps my routines going and holds them to a few goals: the gym, breath-hold training, study, a morning weigh-in and logging what I eat. It also shows where my money goes, my net worth over time and how far I am from financial independence.

## Why

I only buy software I can't build myself. A bank or a brokerage I pay for; an app for my own routines and goals I can build, and then it shows exactly what I need. The data sits in lyfe's own database on a machine I run, not in a budgeting app.

An earlier attempt tried to cover every part of my life at once, and I stopped using it. This one started with one routine, and each step worked end to end, from capture to a screen, before the next began.

## Demo

None. It is built for one person and holds my own data. The [write-up on my site](https://kakosyaneduard.ca/projects/lyfe) shows how the pieces connect.

## Run it

The backend needs Rust and Docker; the app needs Xcode and `xcodegen`. [Working on it locally](#working-on-it-locally) has the commands, and [Running it on the Spark](#running-it-on-the-spark) covers the machine it runs on.

## How it's tested

The backend tests run the real API against a real PostgreSQL, with stand-ins for Garmin, the bank bridge and both models; they never contact the real services. The Swift package has its own tests for the app model, the breath timer, the network layer, food, money, goals, study and the lock.

## How it works

An iPhone app in Swift talks to a Rust backend with PostgreSQL. The backend runs on a DGX Spark and is reachable only over a private Tailscale network.

The backend is the only place that decides anything: whether a session counts, whether a streak is alive, what the next breath session is. The phone records what happened, keeps recording offline and sends it later, with an id made on the phone so a resend counts once. When it cannot reach the backend it shows the last state it saw, marked offline with its age.

```mermaid
flowchart LR
    watch[Garmin watch] --> garmin[Garmin Connect]
    garmin -- polled every 15 min --> server[lyfe-server on the Spark]
    server --- db[(PostgreSQL, lyfe account only)]
    phone[iPhone app] -- HTTPS over Tailscale, lyfe sign-in --> server
    server -- prompts --> apple[Apple push service] --> phone
    server -- photo meals, on loopback --> ollama[Shared Ollama on the Spark: gemma4:31b]
    server -- meal photos and food names, over a pipe --> illustrator[lyfe-illustrate: FLUX.2 klein 4B, started when needed]
    banks[Banks] --> bridge[SimpleFIN Bridge]
    bridge -- asked every 6 h, read-only --> server
```

- The backend listens on loopback only. `tailscale serve` publishes it to the tailnet over HTTPS, never Funnel, so nothing is reachable from the public internet.
- The tailnet and the Spark are shared, so the backend has its own sign-in: one password, and one revocable token per device. Only a hash of each is stored.
- PostgreSQL runs under the `lyfe` account on a Unix socket only that account can open, with no network port. The Garmin key, the bank bridge's access address and the Apple push key are files on the Spark, never in this repository, the settings or the logs.
- The app does not rely on the phone using Tailscale's DNS. When the system's answer for a `.ts.net` name is not a tailnet address, it asks Tailscale's resolver (100.100.100.100) and connects to that address, still requiring the certificate to match the name ([TailnetTransport.swift](apps/LyfeKit/Sources/LyfeKit/Net/TailnetTransport.swift)).

Who on the shared machine can see what is in the [security model](docs/operations.md#security-model). [CONTEXT.md](CONTEXT.md) defines the words the app uses, and [docs/adr/](docs/adr/) records each decision and what it costs.

## Status

In daily use. Built with Claude Code, one step of [docs/build-plan.md](docs/build-plan.md) at a time. The gym, breath, study, weigh-ins, food, goals and money are on my phone. Pool distances, tape measurements and the calorie target review (step 8) are partly built and not yet checked on the phone. A Mac app with an MCP server (step 9) and marked mock interviews (step 15) are not started.

## More

[lyfe: the problem, the choices and where AI fits](https://kakosyaneduard.ca/projects/lyfe).

## What it does

- **Gym.** A session recorded on my Garmin watch fills a square on Home with nothing typed. Four sessions keep a week, and a missed week is recovered by keeping the next. See [gym sessions](docs/rules.md#what-counts-as-a-gym-session) and [streaks](docs/rules.md#streaks-and-recovery).
- **Breath.** A breath-hold table of fixed rounds runs in the app, one tap per hold, offline too, and the backend sets the next table from it. See [breath sessions](docs/rules.md#breath-sessions).
- **Study.** A timer on a subject. A session counts past 45 minutes, and four days of study keep the week. See [study sessions](docs/rules.md#study-sessions).
- **Weigh-ins.** The morning weight is typed into the notification without opening lyfe, and Progress shows the seven-day average. See [weigh-ins](docs/rules.md#weigh-ins).
- **Food.** A meal I weighed once is logged with one tap, against calorie and protein targets I set. Anything else is built from barcodes, photos, catalogue foods and typed foods, with what was measured kept apart from what was estimated. See [food](docs/rules.md#food), [building a meal](docs/rules.md#building-a-meal), [photo meals](docs/rules.md#photo-meals), [illustrations](docs/rules.md#meal-illustrations), [the catalogue](docs/rules.md#the-catalogue-and-its-icons) and [barcodes](docs/rules.md#barcodes).
- **Goals and exams.** A figure and a date on something lyfe already reads (a breath hold, the weight trend, body fat, study hours), shown against its pace. An exam is a goal too, got ready for with practice scores. See [goals](docs/rules.md#goals) and [exams](docs/rules.md#exams).
- **Training, tape and target review** (partly built). Pool distances, tape measurements with a body-fat estimate, and a calorie target change that lyfe proposes only on complete logs and steady weigh-ins, and I approve. See [training, tape and target review](docs/rules.md#training-tape-and-target-review).
- **Money.** The month's spending across every account by category, imported from the banks through SimpleFIN Bridge, with card payments and transfers left out. Worth shows net worth over time and what the investments hold; FIRE shows the savings rate, the FI number and the years to it. See [money](docs/rules.md#money), [Worth](docs/rules.md#worth) and [FIRE](docs/rules.md#fire).
- **The lock.** Face ID each time lyfe is opened. See [the lock](docs/rules.md#the-lock).
- **Reminders.** A prompt only when a streak is at stake and today is a day to act on it, the morning weigh-in, one food-logging prompt, and a bank to sign in to again. See [notifications](docs/rules.md#notifications).

## Where models are used

- **Meal photos.** gemma4:31b estimates a photo and its one line, in the Ollama on the Spark, which another account runs and other people share. Its figures are marked as estimates, shown with a range of ±35% and kept apart from measured ones; an answer with figures no food could have is thrown away. See [photo meals](docs/rules.md#photo-meals).
- **Illustrations and icons.** FLUX.2 klein 4B, in a program of lyfe's own that the backend starts when it is needed, redraws each meal photo as an illustration and drew an icon for each food in the catalogue. It reads its model from disk and never goes to the network. See ADRs [0005](docs/adr/0005-generate-meal-illustrations-with-flux2-klein-4b.md), [0006](docs/adr/0006-draw-meals-true-to-the-photo.md) and [0008](docs/adr/0008-draw-food-icons-on-the-spark.md).
- **Nothing else.** No model touches money: I sort every payee myself ([ADR 0007](docs/adr/0007-import-spending-through-simplefin-bridge.md)). Everything else is rules in the backend.

## Repository layout

| Folder | What it is |
|---|---|
| `backend/` | The Rust backend: the API, sign-in, the Garmin poller, every rule, the model calls, the money import and notifications. `migrations/` makes the database; `tests/` has the end-to-end tests and the stand-ins. |
| `apps/LyfeKit/` | The Swift package the iPhone app shares, and a later Mac app would: API client, local storage, app model, timers and screens. |
| `apps/Lyfe/` | The iPhone app target. It only launches LyfeKit. |
| `deploy/spark/` | Scripts and service files for the Spark: setup, install, backup, the food database and the illustrator. |
| `docs/` | The rules, running it, the decisions and the build plan. |

## Requirements

- **The server.** An NVIDIA GPU machine running Ubuntu on arm64, like the DGX Spark: `install.sh` builds for Linux on arm64, and `setup-admin.sh` needs sudo once, apt, and systemd user services kept running by lingering.
- **Room on it.** About 32 GB of memory free when a photo is estimated and 24 GB when pictures are drawn (the two models are not loaded together), and about 21 GB of disk for the illustrator.
- **On it.** Ollama with `gemma4:31b`; for the illustrator, Python 3 with `venv` and an NVIDIA driver recent enough for PyTorch's CUDA 13 builds; Tailscale, with HTTPS certificates turned on for the tailnet.
- **Accounts.** A Garmin Connect Personal API key (and a Garmin watch), a paid SimpleFIN Bridge account, an Apple developer account for the push key and signing, and an S3 bucket for backups (I use Supabase Storage).
- **The phone.** An iPhone on iOS 18 or later, with Tailscale.
- **The Mac, to build it.** Rust 1.89 or later, Docker, Xcode 16 or later (Swift 6), `xcodegen`, and Python 3 for the stand-ins.

## Working on it locally

### The backend

```sh
# A database for development and tests
docker run -d --name lyfe-dev-db -e POSTGRES_PASSWORD=dev -e POSTGRES_DB=lyfe \
    -p 127.0.0.1:54329:5432 postgres:16-alpine

cd backend
export DATABASE_URL=postgres://postgres:dev@127.0.0.1:54329/lyfe
cargo test
```

The tests run the real API and Garmin client against a stand-in Garmin server and a real database; they never contact Garmin. To run it locally:

```sh
export LYFE_DATABASE_URL=$DATABASE_URL LYFE_TIMEZONE=America/Puerto_Rico
cargo run -- set-password
cargo run -- serve                  # on 127.0.0.1:8787
```

Without `LYFE_GARMIN_KEY_FILE` the server runs and imports nothing; `lyfe-server garmin-check` asks Garmin for recent activities and prints counts only, to confirm a key file works. Every setting is in [the settings table](docs/operations.md#settings). The stand-ins are stdlib Python; the paths below are from the repository's root.

- **Photo estimates.** `python3 -I backend/tests/ollama_stand_in.py 11499` and `LYFE_OLLAMA_URL=http://127.0.0.1:11499`; it answers every photo with rice and chicken. To try the real model instead, forward the Spark's Ollama (`ssh -L 11435:127.0.0.1:11434 <spark>`) and use `LYFE_OLLAMA_URL=http://127.0.0.1:11435`; it then loads on the Spark.
- **Illustrations and icons.** The image model does not run on a Mac. `LYFE_ILLUSTRATOR=$PWD/backend/tests/illustrator_stand_in.py` answers every photo, and every food's icon, with the same made-up plate; the tests use it too.
- **Barcodes.** `gunzip -c <export>.csv.gz | cargo run -- import-food-db` reads an Open Food Facts export, or any part of one with its header line.
- **Money.** `python3 -I backend/tests/simplefin_stand_in.py 11498` serves two made-up banks and a broker, with four and a half months of made-up transactions ending today and two investment accounts with what they hold. Put `http://lyfe:stand-in@127.0.0.1:11498/simplefin` in a file and set `LYFE_SIMPLEFIN_ACCESS_FILE` to it; `cargo run -- money-import` then imports at once. An address on this machine is the only one lyfe asks that is not the bridge's own.

### The app

```sh
cd apps/LyfeKit && swift test          # logic tests, run on the Mac

cd ../Lyfe && xcodegen && open Lyfe.xcodeproj
```

Put your signing team and the server address in `apps/Lyfe/Local.xcconfig` (not committed; `Config.xcconfig` shows the format). The app then installs on your phone without picking a team in Xcode, and the sign-in screen comes with the server filled in, so only the password is typed.

A debug build launched with `LYFE_DEBUG_SERVER=http://127.0.0.1:8787` and `LYFE_DEBUG_PASSWORD` in its environment (the scheme's, or `SIMCTL_CHILD_` in front of each for `xcrun simctl launch`) starts signed in to a local backend. The settings from `LYFE_DEBUG_GALLERY` to `LYFE_DEBUG_MONEY` show screens with made-up data and need no server. `LYFE_DEBUG_OPEN`, `LYFE_DEBUG_STUDY_RUN` and `LYFE_DEBUG_BREATH_RUN` act on the server, so use them against a local backend with a scratch database.

| Setting | What it does |
|---|---|
| `LYFE_DEBUG_GALLERY` | The gym and breath bands in every streak state (`3` skips the first three). |
| `LYFE_DEBUG_BREATH` | A breath screen: `ready`, `leadin`, `hold`, `beaten`, `recover`, `done`, `offline`. |
| `LYFE_DEBUG_STUDY` | A study screen: `ready`, `first`, `build`, `running`, `counted`, `paused`, `after`, `explain`, `short`, `stopped`. |
| `LYFE_DEBUG_GOALS` | Goals, one goal, an exam or the editor: `list`, `empty`, `detail`, `behind`, `parked`, `exam`, `ready`, `passed`, `change`, `examchange`, `new`. |
| `LYFE_DEBUG_PROGRESS` | Progress or the weight entry: `full`, `new`, `empty`, `entry`, `kg`. |
| `LYFE_DEBUG_FOOD` | Food, the meal editor or the targets: `day`, `morning`, `done`, `over`, `recovering`, `offline`, `empty`, `editor`, `new`, `targets`. The builder, photo and barcode screens: `mixed`, `builder`, `building`, `logged`, `photo`, `estimate`, `estimating`, `failed`, `scan`, `product`, `notfound`, `label`. Drawn meals: `drawn`, `drawnday`, `drawnmeal`. The catalogue or a food typed as macros: `picker`, `macros`. |
| `LYFE_DEBUG_MONEY` | Money or sorting: `month`, `sorted`, `entries`, `sort`, `income`, `resort`, `trouble`, `empty`, `waiting`. Worth: `worth`, `worth-new` (the first day kept), `worth-plain` (no investments). FIRE: `fire`, `fire-new` (no whole month yet), `fire-short` (more spent than comes in), `fire-there` (independent), `plan`. A `+` and a number, as in `fire+330`, shows what is that many points down, which a screenshot cannot scroll to. |
| `LYFE_DEBUG_OPEN` | Opens `food`, `meal`, `build`, `targets`, `photo`, `scan`, `progress`, `money`, `worth`, `fire`, `plan`, `study` or `goals` once signed in. With `LYFE_DEBUG_FOOD_TAP` set it first logs the meal the Food bar offers. With `LYFE_DEBUG_FOOD_PHOTO` set to a line it logs a made-up plate as a photo meal and opens its estimate, or with `build` adds it to the meal being built. With `money` and `LYFE_DEBUG_MONEY_SORT` set to a category it sorts the oldest entry waiting into it (use the stand-in bridge). |
| `LYFE_DEBUG_STUDY_RUN` | Records a study session of that many minutes, on `LYFE_DEBUG_STUDY_SUBJECT` if set. |
| `LYFE_DEBUG_BREATH_RUN` | Runs the next breath session by itself with holds of that many seconds (`12`). It plays the tones, so turn the sound down. |
| `LYFE_DEBUG_UNLOCKED`, `LYFE_DEBUG_LOCKED` | Opens without Face ID, or keeps the lock screen; `LYFE_DEBUG_LOCKED=open` lets the lock open by itself each time, for the simulator. |

When the phone cannot reach the server, a debug build can say why: with the phone unlocked, this prints what the system and Tailscale each answer for the server's name and whether the backend replied, then quits.

```sh
xcrun devicectl device process launch --console --terminate-existing \
    --environment-variables '{"LYFE_DEBUG_PROBE":"1"}' --device "<phone name>" com.eduardkakosyan.lyfe
```

The Swift tests that need a real server are skipped unless told where one is: `LYFE_LIVE_SERVER=<name>:8444@<tailnet address> swift test`. `LYFE_LOCAL_SERVER=http://127.0.0.1:8787 LYFE_LOCAL_PASSWORD=<password> swift test --no-parallel` runs the app's client against a backend on this machine; it records a breath session, saves and removes a meal, sets food targets, logs entries, a photo meal and a barcode, builds a meal from parts and saves it, waits for a photo's illustration, and types a label, so give that backend a scratch database, the stand-in model and the stand-in illustrator. `--no-parallel` keeps the checks from logging into each other's day.

## Running it on the Spark

Say how you reach the Spark in `deploy/spark/local.env` (not committed), then, from the Mac:

```sh
deploy/spark/bootstrap.sh   # once: the lyfe account and the tailnet port; you type your sudo password on the Spark
deploy/spark/install.sh     # the first install and every new version, no sudo
```

After the first install: set the password, fetch the food database, have `gemma4:31b` pulled into the Spark's Ollama, run `~/bin/lyfe-illustrator-setup` and `deploy/spark/draw-icons.sh`, connect the banks with `lyfe-server money-connect`, put the Apple push key in place (`LYFE_APNS_KEY_FILE`), and set up the nightly backup. `install.sh` reminds you of the illustrator, the banks and the backup until they are done. Each step, every setting with its default, restoring a backup and the security model are in [docs/operations.md](docs/operations.md).

## Docs

- [CONTEXT.md](CONTEXT.md): the words lyfe uses.
- [docs/rules.md](docs/rules.md): what lyfe counts and shows, area by area.
- [docs/operations.md](docs/operations.md): running it on the Spark, the settings, backups and restoring, and the security model.
- [docs/adr/](docs/adr/): each decision and what it costs.
- [docs/build-plan.md](docs/build-plan.md): the order of work and where each step stands.

## Licence

MIT. See [LICENSE](LICENSE).
