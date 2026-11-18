# lyfe

A private app that keeps three routines going: gym, breath training and food logging. What it is and why is in `CONTEXT.md`, `docs/adr/` and `docs/build-plan.md`.

Built so far: step 1 of the build plan. A strength session recorded on the watch shows up as a filled square on the Home screen, with nothing entered in lyfe.

## Layout

| Folder | What it is |
|---|---|
| `backend/` | The Rust backend: API, sign-in, Garmin poller, gym rules. The single authority for what counts. |
| `apps/LyfeKit/` | Swift package shared by the iPhone app and the later Mac app: API client, local storage, app model, Poster screens. |
| `apps/Lyfe/` | The iPhone app target. It only launches LyfeKit. |
| `deploy/spark/` | Scripts and service files for running the backend on the Spark. |

## How the pieces connect

```mermaid
flowchart LR
    watch[Garmin watch] --> garmin[Garmin Connect]
    garmin -- polled every 15 min --> server[lyfe-server on the Spark]
    server --- db[(PostgreSQL, lyfe account only)]
    phone[iPhone app] -- HTTPS over Tailscale, lyfe sign-in --> server
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

The tests that need a real server are skipped unless told where one is: `LYFE_LIVE_SERVER=<name>:8444@<tailnet address> swift test`.

## Running on the Spark

Once, with administrator rights (you type your sudo password on the Spark):

```sh
deploy/spark/bootstrap.sh
```

This creates the `lyfe` account, installs the PostgreSQL programs without a machine-wide database, lets your SSH key log in as `lyfe`, copies the Garmin key file into lyfe's home, and publishes port 8444 on the tailnet. Read `deploy/spark/setup-admin.sh` first; it lists exactly what it changes.

Then, and again for every new version (no sudo):

```sh
deploy/spark/install.sh
```

After the first install, set the password as the script tells you. The app's server address is then `<spark-name>.<tailnet>.ts.net:8444`.

There is no backup yet: the database on the Spark is the only copy.
