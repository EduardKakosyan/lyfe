# lyfe

## What

A private iPhone app that keeps my routines going and holds them to a few goals: the gym, breath-hold training, study, a morning weigh-in and logging what I eat. It also shows where my money goes, my net worth over time and how far I am from financial independence.

## Why

I only buy software I can't build myself. A bank or a brokerage I pay for; an app for my own routines and goals I can build, and then it shows exactly what I need. The data sits in lyfe's own database on a machine I run, not in a budgeting app.

An earlier attempt tried to cover every part of my life at once, and I stopped using it. This one started with one routine, and each step worked end to end, from capture to a screen, before the next began.

## Demo

None. It is built for one person and holds my own data. The [write-up on my site](https://kakosyaneduard.ca/projects/lyfe) shows how the pieces connect, and a debug build can show every screen with made-up data ([docs/development.md](docs/development.md#screens-with-made-up-data)).

## Run it

### What you need

- **The server.** An NVIDIA GPU machine running Ubuntu on arm64, like the DGX Spark, with sudo once for setup, apt, and systemd user services kept running by lingering. About 32 GB of memory free while a photo is estimated, 24 GB while pictures are drawn (the two models are never loaded together), and about 21 GB of disk for the illustrator.
- **On the server.** Ollama with `gemma4:31b`; Python 3 with `venv` and an NVIDIA driver recent enough for PyTorch's CUDA 13 builds, for the illustrator; Tailscale, with HTTPS certificates turned on for the tailnet.
- **Accounts.** A Garmin Connect Personal API key and a Garmin watch, a paid SimpleFIN Bridge account, an Apple developer account for signing and the push key, and an S3 bucket for backups (I use Supabase Storage).
- **The phone.** An iPhone on iOS 18 or later, with Tailscale.
- **The Mac, to build it.** Rust 1.89 or later, Docker, Xcode 16 or later (Swift 6), `xcodegen`, and Python 3 for the stand-ins.

### On a Mac

```sh
# A database for development and tests
docker run -d --name lyfe-dev-db -e POSTGRES_PASSWORD=dev -e POSTGRES_DB=lyfe \
    -p 127.0.0.1:54329:5432 postgres:16-alpine

cd backend
export DATABASE_URL=postgres://postgres:dev@127.0.0.1:54329/lyfe
cargo test

export LYFE_DATABASE_URL=$DATABASE_URL LYFE_TIMEZONE=America/Puerto_Rico
cargo run -- set-password
cargo run -- serve                  # on 127.0.0.1:8787
```

```sh
cd apps/LyfeKit && swift test          # the app's logic tests
cd ../Lyfe && xcodegen && open Lyfe.xcodeproj
```

Put your signing team and the server address in `apps/Lyfe/Local.xcconfig` (not committed; `Config.xcconfig` shows the format). The stand-ins for Garmin, the bank bridge and both models, the debug settings and the tests that need a running server are in [docs/development.md](docs/development.md).

### On the Spark

Say how you reach the Spark in `deploy/spark/local.env` (not committed), then, from the Mac:

```sh
deploy/spark/bootstrap.sh   # once: the lyfe account and the tailnet port; you type your sudo password on the Spark
deploy/spark/install.sh     # the first install and every new version, no sudo
```

After the first install: set the password, fetch the food database, pull `gemma4:31b` into the Spark's Ollama, set up the illustrator and draw the icons, connect the banks, put the Apple push key in place, and set up the nightly backup. `install.sh` reminds you of the illustrator, the banks and the backup until they are done. Each step, every setting with its default, restoring a backup and the security model are in [docs/operations.md](docs/operations.md).

## How it's tested

The backend tests run the real API against a real PostgreSQL, with stand-ins for Garmin, the bank bridge and both models; they never contact the real services. The Swift package has its own tests for the app model, the breath timer, the network layer, food, money, goals, study and the lock. A few Swift tests run the app's client against a real backend and are skipped unless one is given ([docs/development.md](docs/development.md#tests-against-a-running-backend)).

## How it works

An iPhone app in Swift talks to a Rust backend with PostgreSQL. The backend runs on a DGX Spark and is reachable only over a private Tailscale network.

The backend is the only place that decides anything: whether a session counts, whether a streak is alive, what the next breath session is. The phone records what happened, keeps recording offline and sends it later, with an id made on the phone so a resend counts once. When it can't reach the backend it shows the last state it saw, marked offline with its age.

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

Who on the shared machine can see what is in the [security model](docs/operations.md#security-model).

### What it does

- **Gym.** A workout recorded on my Garmin watch fills a square on Home, with nothing typed. Four days with a workout keep a week, and a missed week is recovered by keeping the next. See [gym sessions](docs/rules.md#what-counts-as-a-gym-session) and [streaks](docs/rules.md#streaks-and-recovery).
- **Breath.** A breath-hold table of fixed rounds runs in the app, one tap per hold, offline too, and the backend sets the next table from it. See [breath sessions](docs/rules.md#breath-sessions).
- **Study.** A timer on a subject. A session counts past 45 minutes, and four days of study keep the week. See [study sessions](docs/rules.md#study-sessions).
- **Weigh-ins.** The morning weight is typed into the notification without opening lyfe, and Progress shows the seven-day average. See [weigh-ins](docs/rules.md#weigh-ins).
- **Food.** A meal I weighed once is logged with one tap, against calorie and protein targets I set. Anything else is built from barcodes, photos, catalogue foods and typed foods, with what was measured kept apart from what was estimated. See [food](docs/rules.md#food), [building a meal](docs/rules.md#building-a-meal), [photo meals](docs/rules.md#photo-meals), [illustrations](docs/rules.md#meal-illustrations), [the catalogue](docs/rules.md#the-catalogue-and-its-icons) and [barcodes](docs/rules.md#barcodes).
- **Goals and exams.** A figure and a date on something lyfe already reads (a breath hold, the weight trend, body fat, study hours), shown against its pace. An exam is a goal too, prepared for with practice scores. See [goals](docs/rules.md#goals) and [exams](docs/rules.md#exams).
- **Training, tape and target review** (partly built). Pool distances, tape measurements with a body-fat estimate, and a calorie target change that lyfe proposes only on complete logs and steady weigh-ins, and I approve. See [training, tape and target review](docs/rules.md#training-tape-and-target-review).
- **Money.** The month's spending across every account by category, imported through SimpleFIN Bridge, with card payments and transfers left out. Worth shows net worth over time and what the investments hold; FIRE shows the savings rate, the FI number and the years to it. See [money](docs/rules.md#money), [Worth](docs/rules.md#worth) and [FIRE](docs/rules.md#fire).
- **The lock.** Face ID each time lyfe is opened. See [the lock](docs/rules.md#the-lock).
- **Reminders.** A prompt only when a streak is at stake and today is a day to act on it, the morning weigh-in, one food-logging prompt, and a bank to sign in to again. See [notifications](docs/rules.md#notifications).

### Where models are used

- **Meal photos.** gemma4:31b estimates a photo and its one line, in the Ollama on the Spark, which another account runs and other people share. Its figures are marked as estimates, shown with a range of ±35% and kept apart from measured ones; an answer with figures no food could have is thrown away. See [photo meals](docs/rules.md#photo-meals).
- **Illustrations and icons.** FLUX.2 klein 4B, in a program of lyfe's own that the backend starts when it is needed, redraws each meal photo as an illustration and drew an icon for each food in the catalogue. It reads its model from disk and never goes to the network. See ADRs [0005](docs/adr/0005-generate-meal-illustrations-with-flux2-klein-4b.md), [0006](docs/adr/0006-draw-meals-true-to-the-photo.md) and [0008](docs/adr/0008-draw-food-icons-on-the-spark.md).
- **Nothing else.** No model touches money: I sort every payee myself ([ADR 0007](docs/adr/0007-import-spending-through-simplefin-bridge.md)). Everything else is rules in the backend.

### Repository layout

| Folder | What it is |
|---|---|
| `backend/` | The Rust backend: the API, sign-in, the Garmin poller, every rule, the model calls, the money import and notifications. `migrations/` makes the database; `tests/` has the end-to-end tests and the stand-ins. |
| `apps/LyfeKit/` | The Swift package with everything the iPhone app does: API client, local storage, app model, timers and screens. |
| `apps/Lyfe/` | The iPhone app target. It only launches LyfeKit. |
| `deploy/spark/` | Scripts and service files for the Spark: setup, install, backup, the food database and the illustrator. |
| `docs/` | The rules, development, operations, the decisions and the build plan. |

## Status

In daily use. Built with Claude Code, one step of [docs/build-plan.md](docs/build-plan.md) at a time. The gym, breath, study, weigh-ins, food, goals and money are on my phone. Pool distances, tape measurements and the calorie target review (step 8) are partly built and not yet checked on the phone. A Mac app with an MCP server (step 9) and marked mock interviews (step 15) are not started.

## More

- [CONTEXT.md](CONTEXT.md): the words lyfe uses.
- [docs/rules.md](docs/rules.md): what lyfe counts and shows, area by area.
- [docs/development.md](docs/development.md): the stand-ins, the debug settings and the tests against a running backend.
- [docs/operations.md](docs/operations.md): running it on the Spark, the settings, backups and restoring, and the security model.
- [docs/adr/](docs/adr/): each decision and what it costs.
- [The write-up on my site](https://kakosyaneduard.ca/projects/lyfe): the problem, the choices and where AI fits.

Licence: MIT. See [LICENSE](LICENSE).
