# lyfe

A private app that keeps three routines going: gym, breath training and food logging. What it is and why is in `CONTEXT.md`, `docs/adr/` and `docs/build-plan.md`.

Built so far: steps 1 to 3 of the build plan. A strength session recorded on the watch shows up as a filled square on the Home screen, with nothing entered in lyfe. The gym band shows the streak in weeks, with recovery after a missed week, and the backend can prompt the phone when a streak needs sessions. A breath session runs in the app, one tap per hold, and the backend sets the next table from it.

## Layout

| Folder | What it is |
|---|---|
| `backend/` | The Rust backend: API, sign-in, Garmin poller, gym, breath and streak rules, notifications. The single authority for what counts. |
| `apps/LyfeKit/` | Swift package shared by the iPhone app and the later Mac app: API client, local storage, app model, breath timer, Poster screens. |
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

The rules are one module shared by every routine (`backend/src/routines/streak.rs`). The gym and breath training apply them to weeks (`weekly.rs`): four sessions keep a gym week, three keep a breath week.

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

## Notifications

The backend decides when to prompt; the phone only shows what arrives. Each weekly routine, the gym and breath training, is looked at on its own. A prompt is sent only when a streak is alive and today is a day to act on it:

- **Train today**: every day left this week is needed to reach four, and today has no session yet. Sent once that day.
- **Recovery open**: last week was missed and this week recovers it. Sent once that week.

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

A debug build launched with `LYFE_DEBUG_GALLERY` set shows the gym and breath bands in every streak state with made-up numbers (`LYFE_DEBUG_GALLERY=3` skips the first three). `LYFE_DEBUG_BREATH` set to `ready`, `leadin`, `hold`, `beaten`, `recover`, `done` or `offline` shows that breath screen. `LYFE_DEBUG_BREATH_RUN=12` runs the next session by itself with 12-second holds; it plays the tones and records the session, so use it against a local backend with the sound down.

The tests that need a real server are skipped unless told where one is: `LYFE_LIVE_SERVER=<name>:8444@<tailnet address> swift test`. `LYFE_LOCAL_SERVER=http://127.0.0.1:8787 LYFE_LOCAL_PASSWORD=<password> swift test` runs the app's client against a backend on this machine; it records a breath session, so give that backend a scratch database.

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
