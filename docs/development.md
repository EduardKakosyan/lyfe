# Working on lyfe

How to run the backend and the app on a Mac without the real services, and how to check them. The first commands are in the [README](../README.md#on-a-mac). Every server setting is in [operations.md](operations.md#settings).

## The backend without the real services

Without `LYFE_GARMIN_KEY_FILE` the server runs and imports nothing. `lyfe-server garmin-check` asks Garmin for recent activities and prints counts only, to confirm a key file works.

The stand-ins are stdlib Python; the paths below are from the repository's root.

- **Photo estimates.** `python3 -I backend/tests/ollama_stand_in.py 11499` and `LYFE_OLLAMA_URL=http://127.0.0.1:11499`; it answers every photo with rice and chicken. To try the real model instead, forward the Spark's Ollama (`ssh -L 11435:127.0.0.1:11434 <spark>`) and use `LYFE_OLLAMA_URL=http://127.0.0.1:11435`; it then loads on the Spark.
- **Illustrations and icons.** The image model does not run on a Mac. `LYFE_ILLUSTRATOR=$PWD/backend/tests/illustrator_stand_in.py` answers every photo, and every food's icon, with the same made-up plate; the tests use it too.
- **Barcodes.** `gunzip -c <export>.csv.gz | cargo run -- import-food-db` reads an Open Food Facts export, or any part of one with its header line.
- **Money.** `python3 -I backend/tests/simplefin_stand_in.py 11498` serves two made-up banks and a broker, with four and a half months of made-up transactions ending today and two investment accounts with what they hold. Put `http://lyfe:stand-in@127.0.0.1:11498/simplefin` in a file and set `LYFE_SIMPLEFIN_ACCESS_FILE` to it; `cargo run -- money-import` then imports at once. An address on this machine is the only one lyfe asks that is not the bridge's own.

## The app against a local backend

A debug build launched with `LYFE_DEBUG_SERVER=http://127.0.0.1:8787` and `LYFE_DEBUG_PASSWORD` in its environment (the scheme's, or `SIMCTL_CHILD_` in front of each for `xcrun simctl launch`) starts signed in to a local backend. `Local.xcconfig` fills in the server on the sign-in screen, so on a phone only the password is typed.

## Screens with made-up data

The settings from `LYFE_DEBUG_GALLERY` to `LYFE_DEBUG_MONEY` show screens with made-up data and need no server. `LYFE_DEBUG_OPEN`, `LYFE_DEBUG_STUDY_RUN` and `LYFE_DEBUG_BREATH_RUN` act on the server, so use them against a local backend with a scratch database.

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

## Tests against a running backend

The Swift tests that need a real server are skipped unless told where one is.

- `LYFE_LIVE_SERVER=<name>:8444@<tailnet address> swift test` runs them against the Spark.
- `LYFE_LOCAL_SERVER=http://127.0.0.1:8787 LYFE_LOCAL_PASSWORD=<password> swift test --no-parallel` runs the app's client against a backend on this machine. It records a breath session, saves and removes a meal, sets food targets, logs entries, a photo meal and a barcode, builds a meal from parts and saves it, waits for a photo's illustration, and types a label, so give that backend a scratch database, the stand-in model and the stand-in illustrator. `--no-parallel` keeps the checks from logging into each other's day.

## When the phone can't reach the server

The app doesn't rely on the phone using Tailscale's DNS. When the system's answer for a `.ts.net` name is not a tailnet address, it asks Tailscale's resolver (100.100.100.100) and connects to that address, still requiring the certificate to match the name ([TailnetTransport.swift](../apps/LyfeKit/Sources/LyfeKit/Net/TailnetTransport.swift)).

A debug build can say why it can't connect. With the phone unlocked, this prints what the system and Tailscale each answer for the server's name and whether the backend replied, then quits:

```sh
xcrun devicectl device process launch --console --terminate-existing \
    --environment-variables '{"LYFE_DEBUG_PROBE":"1"}' --device "<phone name>" com.eduardkakosyan.lyfe
```
