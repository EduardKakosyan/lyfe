# Running lyfe on the Spark

How lyfe is installed and kept on the shared Spark: the setup, every setting, the outside services it reads, the nightly backup, how to restore it, and who can see what. What lyfe counts and shows is in [rules.md](rules.md).

lyfe runs under an account of its own, `lyfe`, and needs sudo only for the first setup. "As `lyfe`" below means on the Spark, logged in to that account, after loading its settings:

```sh
set -a; . ~/.config/lyfe/lyfe.env; set +a
```

## What is where

| In lyfe's home on the Spark | What it is |
|---|---|
| `~/bin/lyfe-server` | The backend. `lyfe-server --help` lists its commands. |
| `~/pgdata` | The database files. |
| `~/.config/lyfe/lyfe.env` | The server's settings. Written once by `install.sh`, never overwritten. |
| `~/.config/lyfe/backup.env` | The backup's settings, written the same way. |
| `~/.config/lyfe/garmin-api-key`, `simplefin-access`, `AuthKey_<key id>.p8`, `backup-s3-key`, `backup-passphrase` | The secrets, one file each, readable only by `lyfe`. None of them is in the backup. |
| `~/bin/lyfe-backup`, `~/bin/lyfe-food-db` | The backup, and the download of the barcode database. |
| `~/bin/lyfe-illustrator-setup`, `~/bin/lyfe-illustrate`, `~/illustrator` | The illustrator: its setup, its starter, and its own Python and model. |

Three systemd user units run as `lyfe` and keep running with nobody logged in: the `lyfe-postgres` and `lyfe-server` services and the `lyfe-backup.timer`. The server's log is `journalctl --user -u lyfe-server -n 50 --no-pager`.

## First setup

### 1. Bootstrap, once, with sudo

On the Mac, say how you reach the Spark in `deploy/spark/local.env`, which is not committed: `ADMIN_SSH` for the account with sudo rights, `LYFE_SSH` for the `lyfe` account, `LYFE_SSH_KEY` for the key that logs in as it, and `GARMIN_KEY_FROM` (below). The scripts read it, or the same names from the environment ([Settings for the scripts](#settings-for-the-scripts)). Then:

```sh
deploy/spark/bootstrap.sh
```

It copies `setup-admin.sh` to the admin account and runs it with sudo; you type your sudo password on the Spark. Read `deploy/spark/setup-admin.sh` first. It lists exactly what it changes, and is safe to run again:

1. creates the `lyfe` account, with no password and a home only it can read;
2. installs the PostgreSQL programs with apt, without a machine-wide database;
3. lets your SSH key log in as `lyfe`;
4. turns on lingering for `lyfe`, so its services run with nobody logged in;
5. copies the Garmin key file to `~/.config/lyfe/garmin-api-key`, if it was given one;
6. publishes the backend's loopback port to the tailnet over HTTPS, on port 8444, with `tailscale serve` (tailnet only, never Funnel).

**The Garmin key.** `bootstrap.sh` copies it from `lyfe-prototype/garmin/api-key` in the admin account's home on the Spark unless told otherwise. If that file is not there, `setup-admin.sh` stops before changing anything. Set `GARMIN_KEY_FROM` to the key file's path relative to the admin account's home, or set it empty (`GARMIN_KEY_FROM=`) to skip the copy and put the key in place later ([Garmin](#garmin)).

### 2. Install, and again for every new version (no sudo)

```sh
deploy/spark/install.sh
```

It builds the backend for Linux on arm64 in Docker (`rust:1-bookworm`), checks it can log in as `lyfe` with your key, and copies everything over. On the Spark it writes `lyfe.env` and `backup.env` if they are not there yet, creates `~/pgdata` and the `lyfe` database the first time, swaps the binary in, restarts the server, installs the backup, food database and illustrator scripts, and checks that the server answers. The time zone written into a new `lyfe.env` is `LYFE_TIMEZONE` if set, otherwise the Mac's; after that, change it in `lyfe.env`. `SKIP_BUILD=1` reuses the last build.

Each run says what is still missing among the illustrator, the banks and the backup.

### 3. After the first install

- **The password**, as `lyfe`: `~/bin/lyfe-server set-password`, at least 12 characters. `install.sh` prints the whole command.
- **The app's server address** is `<machine>.<tailnet>.ts.net:8444`. As `LYFE_DEFAULT_SERVER` in `apps/Lyfe/Local.xcconfig`, it is filled in on the sign-in screen.
- **Barcodes**: [The food database](#the-food-database).
- **Photo meals**: [Photo estimates](#photo-estimates).
- **Illustrations and icons**: [The illustrator](#the-illustrator).
- **Money**: [Money: SimpleFIN Bridge](#money-simplefin-bridge).
- **Notifications**: [Notifications: the Apple push key](#notifications-the-apple-push-key).
- **The backup**: [Backups](#backups). Until it is set up, the database on the Spark is the only copy.

## Settings

### The server

`lyfe-server` reads these from the environment; on the Spark that is `~/.config/lyfe/lyfe.env`, which shows most of them with their defaults. After a change: `systemctl --user restart lyfe-server`. No secret goes in it: each secret is a file, and a setting points at it.

| Setting | Default | What it does |
|---|---|---|
| `LYFE_DATABASE_URL` | none; `install.sh` writes the socket address | The PostgreSQL connection string. |
| `LYFE_LISTEN_ADDR` | `127.0.0.1:8787` | Where the server listens. Keep it on loopback; `tailscale serve` publishes it. |
| `LYFE_TIMEZONE` | none; `install.sh` writes it | The owner's time zone (an IANA name). It decides what today and this week are. |
| `LYFE_GARMIN_KEY_FILE` | unset: nothing is imported | The file holding the Garmin key. `lyfe.env` sets `~/.config/lyfe/garmin-api-key`. |
| `LYFE_GARMIN_BASE_URL` | `https://personal.connectapi.garmin.com` | Garmin's API. The tests point it at a stand-in. |
| `LYFE_GARMIN_POLL_SECONDS` | `900` | Seconds between polls. |
| `LYFE_GARMIN_BACKFILL_DAYS` | `180` | Days fetched on the first poll, when nothing is stored yet. |
| `LYFE_GARMIN_WINDOW_DAYS` | `30` | Days re-read on every later poll, so a watch synced late or an activity deleted in Garmin Connect is still picked up. |
| `LYFE_GYM_ACTIVITY_TYPES` | the types in `lyfe.env.template` | Garmin activity types that count as a gym session, comma separated. |
| `LYFE_GYM_MIN_MINUTES` | `15` | Shorter activities do not count. |
| `LYFE_BREATH_START_ROUND_SECONDS` | `240` | Round length of the first breath table. |
| `LYFE_BREATH_ROUNDS` | `6` | Rounds in a breath table. |
| `LYFE_BREATH_ADVANCE_UNDER_SECONDS` | `45` | Rounds get longer once a session leaves less recovery than this after its longest hold... |
| `LYFE_BREATH_STEP_SECONDS` | `15` | ...by this many seconds. |
| `LYFE_STUDY_MIN_MINUTES` | `45` | A study session counts once its timer passes this. |
| `LYFE_STUDY_TARGET_MINUTES` | `90` | Shown as the target; never needed. |
| `LYFE_STUDY_BUILDS_PER_WEEK` | `2` | Build sessions that can count toward a study week. |
| `LYFE_WEIGHT_UNIT` | `lb` | `lb` or `kg`. Weights are stored in grams, so a change only changes what is shown. |
| `LYFE_WEIGH_IN_AT` | `06:30` | When the morning weigh-in prompt goes out, or `off`. |
| `LYFE_FOOD_PROMPT_AT` | `12:00` | From when an unlogged food day is prompted for, or `off`. |
| `LYFE_NOTIFY_FROM_HOUR` | `7` | Prompts are sent from this hour... |
| `LYFE_NOTIFY_UNTIL_HOUR` | `18` | ...until this one. |
| `LYFE_APNS_KEY_FILE` | unset: no notifications | The `.p8` key from the Apple developer account. |
| `LYFE_APNS_KEY_ID` | read from the file name `AuthKey_<key id>.p8` | The key's ID. |
| `LYFE_APNS_TEAM_ID` | none; needed with the key | The developer team the key belongs to. |
| `LYFE_APNS_TOPIC` | the app's bundle ID | What Apple delivers to. |
| `LYFE_APNS_ENVIRONMENT` | `development` | The Apple service tried first for a new device: `development` for an app installed from Xcode, `production` for TestFlight or the App Store. The other is tried when the first does not know the device. |
| `LYFE_SIMPLEFIN_ACCESS_FILE` | unset: no money is imported | The file `money-connect` writes. `lyfe.env` sets `~/.config/lyfe/simplefin-access`. |
| `LYFE_MONEY_SYNC_HOURS` | `6` | Hours between imports (1 to 168). |
| `LYFE_MONEY_BACKFILL_DAYS` | `180` | Days of history asked for on the first import (at most 180). |
| `LYFE_MONEY_WINDOW_DAYS` | `14` | Days re-read on every later import (at most 44). |
| `LYFE_MONEY_CURRENCY` | the one most accounts are in | The currency totals are in, as a three-letter code. |
| `LYFE_OLLAMA_URL` | `http://127.0.0.1:11434` | The Ollama that estimates photo meals, or `off`. |
| `LYFE_PHOTO_MODEL` | `gemma4:31b` | The vision model. |
| `LYFE_PHOTO_CONTEXT` | `8192` | The context it is loaded with, in tokens. |
| `LYFE_PHOTO_MIN_FREE_GB` | `32` | It is not loaded unless this much memory is free. |
| `LYFE_PHOTO_KEEP_ALIVE_SECONDS` | `120` | How long it stays loaded after the last photo. |
| `LYFE_PHOTO_RANGE_PERCENT` | `35` | How far either way an estimate is shown to be. |
| `LYFE_ILLUSTRATOR` | `~/bin/lyfe-illustrate` | The program that draws illustrations and icons, or `off`. |
| `LYFE_ILLUSTRATION_MIN_FREE_GB` | `24` | It is not started unless this much memory is free. |
| `LYFE_ILLUSTRATION_KEEP_ALIVE_SECONDS` | `180` | How long it stays loaded after the last picture. |

How much the log says is `RUST_LOG`, `info,sqlx=warn` unless set.

### Settings for the scripts

On the Mac, in `deploy/spark/local.env` or the environment:

| Setting | Default | Read by | What it does |
|---|---|---|---|
| `ADMIN_SSH` | `spark-admin` | `bootstrap.sh` | How you reach the Spark with sudo rights. |
| `LYFE_SSH` | `lyfe@spark` | `install.sh`, `draw-icons.sh` | How you reach the `lyfe` account. |
| `LYFE_SSH_KEY` | `~/.ssh/id_ed25519` | all three | The private key that logs in as `lyfe`; `bootstrap.sh` authorises its `.pub`. |
| `GARMIN_KEY_FROM` | `lyfe-prototype/garmin/api-key` | `bootstrap.sh` | The Garmin key file to copy, relative to the admin account's home on the Spark; empty to skip. |
| `LYFE_TIMEZONE` | the Mac's time zone | `install.sh` | Written into `lyfe.env` when it is first made, and only then. |
| `SKIP_BUILD` | unset | `install.sh` | `1` reuses the last build. |

On the Spark, for `lyfe-backup` and `lyfe-food-db`:

| Setting | Default | What it does |
|---|---|---|
| `LYFE_ENV` | `~/.config/lyfe/lyfe.env` | Where the server's settings are; the scripts take `LYFE_DATABASE_URL` from it. |
| `LYFE_BACKUP_ENV` | `~/.config/lyfe/backup.env` | Where the backup's settings are. |
| `LYFE_BACKUP_S3_ENDPOINT` | none | The bucket's S3 endpoint (https). In `backup.env`. |
| `LYFE_BACKUP_S3_REGION` | none | Its region. In `backup.env`. |
| `LYFE_BACKUP_BUCKET` | none | The bucket. In `backup.env`. |
| `LYFE_BACKUP_S3_KEY_FILE` | `~/.config/lyfe/backup-s3-key` | The S3 access key: the key ID on line 1, the secret on line 2. |
| `LYFE_BACKUP_PASSPHRASE_FILE` | `~/.config/lyfe/backup-passphrase` | The passphrase every backup is encrypted with. |
| `LYFE_FOOD_DB_URL` | Open Food Facts' CSV export | Where `lyfe-food-db` downloads from. |

## Garmin

lyfe reads activities from the Garmin Connect Personal API with a key made in your Garmin account. The key is the file `~/.config/lyfe/garmin-api-key`, owned by `lyfe` and readable only by it, and `LYFE_GARMIN_KEY_FILE` points at it. It is never in this repository, the settings or the logs.

- **Putting a key in place, or a new one**, as `lyfe`: `umask 077; nano ~/.config/lyfe/garmin-api-key`, then `~/bin/lyfe-server garmin-check`, which asks Garmin for recent activities and prints counts only. The server reads the file whenever it needs a new token from Garmin; `systemctl --user restart lyfe-server` makes it use a new key at once.
- **Polling.** Every 15 minutes, and when the app is opened unless a poll was just made. The first poll fetches 180 days; later ones re-read the last 30.
- **When Garmin rejects the key**, because it expired or was deleted, nothing new is imported. Each poll records "Garmin rejected the API key; it may have expired or been deleted", the server log has it, and Home's Garmin strip turns striped with that line and the time of the last good sync. No notification is sent. Make a new key and put it in place as above. The next poll re-reads the last 30 days, so a longer gap is not filled in unless `LYFE_GARMIN_WINDOW_DAYS` is raised first.
- **Expiry.** A reminder before the key expires is planned and not built ([build plan](build-plan.md#to-settle-before-or-during-the-build)).

## Money: SimpleFIN Bridge

lyfe imports accounts and posted transactions through SimpleFIN Bridge, a paid service that holds the bank sign-ins (ADR 0007). To connect, once:

1. At SimpleFIN Bridge, make an account, connect each bank under it, and make a setup token for a new app. A token works once.
2. As `lyfe`: `~/bin/lyfe-server money-connect`, and paste the token. It is typed hidden, traded for the access address, and that is written to `LYFE_SIMPLEFIN_ACCESS_FILE`, readable only by `lyfe`.
3. `~/bin/lyfe-server money-check` asks the bridge for the last week and prints counts only, with what share of each investment account's balance its holdings come to. Then `systemctl --user restart lyfe-server`; the first import follows within ten minutes, or at once with `~/bin/lyfe-server money-import`.

The access address is a password to everything the bridge can read: it is never in this repository, in settings, or in logs, and it is not in the backup. To cut lyfe off, delete the app's access at the bridge. When a bank wants signing in to again, that is done at the bridge; lyfe only says so ([rules](rules.md#money)). `money-check` and `money-import` each use one of the bridge's roughly 24 requests a day.

## Notifications: the Apple push key

Sending needs a key from the Apple developer account, set up once:

1. At developer.apple.com, under Certificates, Identifiers & Profiles > Keys, create a key with Apple Push Notifications service enabled and download it (`AuthKey_<key id>.p8`). Apple lets you download it only once.
2. Copy it to the Spark, readable only by `lyfe`, keeping Apple's file name: `scp -i <key> AuthKey_*.p8 lyfe@<spark>:.config/lyfe/ && ssh -i <key> lyfe@<spark> 'chmod 600 ~/.config/lyfe/AuthKey_*.p8'`.
3. In `~/.config/lyfe/lyfe.env` on the Spark, set `LYFE_APNS_KEY_FILE` to that path and `LYFE_APNS_TEAM_ID` to your team ID, then `systemctl --user restart lyfe-server`.
4. Open lyfe on the phone and allow notifications, then send a test, as `lyfe`: `~/bin/lyfe-server push-test`.

The server checks the key when it starts. Without a usable key it runs and sends nothing, says so in its log, and the Home screen says prompts are off. For a new device the server tries Apple's development service first, which is the one an app installed from Xcode uses, and the other when that one does not know the device; `LYFE_APNS_ENVIRONMENT=production` tries production first, for TestFlight or the App Store.

## Photo estimates

Photo meals are estimated by gemma4:31b in the Ollama on the Spark, at `LYFE_OLLAMA_URL`. That Ollama is not lyfe's: another account runs it, and the Spark's other users share it. If the model is missing, whoever runs Ollama pulls it (`ollama pull gemma4:31b`). To check it, as `lyfe`:

```sh
~/bin/lyfe-server photo-check <photo.jpg> --note "<one line>"
```

It prints the model's answer and stores nothing. `LYFE_OLLAMA_URL=off` switches estimates off; photo meals are then typed in by hand. How the model is loaded and let go is in [rules](rules.md#photo-meals).

## The illustrator

Meal illustrations and food icons are drawn by FLUX.2 klein 4B, in a program lyfe-server starts itself when a picture is waiting and the memory is free ([rules](rules.md#meal-illustrations)). Set it up once, as `lyfe`:

```sh
~/bin/lyfe-illustrator-setup
```

It makes a Python of its own in `~/illustrator` with pinned versions of PyTorch, from PyTorch's CUDA 13.0 builds, and diffusers (about 6 GB), downloads FLUX.2 klein 4B at a pinned revision (about 15 GB; Apache 2.0, not gated), checks the GPU can be used from the account, runs a self-test, and says how to try it. It needs `python3` with `venv` (on Ubuntu, the `python3-venv` package) and an NVIDIA driver recent enough for CUDA 13. Running it again changes nothing already in place. After it, the illustrator reads the model from disk and never goes to the network. Until it has run, meals keep their photos, and `install.sh` says so.

Then, from the Mac, have every food's icon drawn, a little over an hour of the GPU, once ([rules](rules.md#the-catalogue-and-its-icons)). It lists the catalogue with `swift run`, so it needs Swift on the Mac:

```sh
deploy/spark/draw-icons.sh
```

To try one picture, as `lyfe`: `~/bin/lyfe-server illustration-check <photo.jpg> --note "<one line>" --out /tmp/meal.png`, or `~/bin/lyfe-server icon-check "<food name>" --out /tmp/icon.png`. `LYFE_ILLUSTRATOR=off` switches illustrations and icons off.

## The food database

Barcodes are looked up in a downloaded copy of Open Food Facts. Fetch it once, and again whenever you want newer products (it is not scheduled), as `lyfe`:

```sh
~/bin/lyfe-food-db
```

It downloads the export (about 1.5 GB, kept in `~/.cache/lyfe`, and downloaded again only when there is a newer one), checks it is whole, and swaps it in all at once, so a lookup meanwhile still finds the old copy. Labels typed in the app are kept apart and not touched. The food database is not in the backup.

## Backups

Every night the Spark sends an encrypted copy of the database to a private bucket in Supabase Storage (`deploy/spark/lyfe-backup`, started by `lyfe-backup.timer` at 03:30 by the Spark's own clock, which need not be your time zone, or when the Spark is next up if it was off). Until it is set up, the database on the Spark is the only copy, and `install.sh` says so each time it runs.

- **What leaves the Spark.** One file a night, `lyfe-<date and time>.dump.gpg`: a `pg_dump` of the database, with meal photos, their illustrations and everything imported from the banks, and without the downloaded food database and the food icons, which can be fetched or drawn again. It is encrypted on the Spark with AES-256 under the passphrase in `~/.config/lyfe/backup-passphrase`. Supabase stores a file it cannot read. The passphrase sits on the Spark next to the S3 key, so the Spark's admins could read both; the encryption keeps the backup from the storage provider, not from them ([Security model](#security-model)). After each upload the script reads the bucket's listing and fails unless the file is there at its full size.
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
5. Run `~/bin/lyfe-backup` once and check it says "Backed up", then `deploy/spark/install.sh` from the Mac (with `SKIP_BUILD=1` if nothing else changed), which switches the nightly timer on.

Then try a restore once, into a scratch database (below): a backup that has never been restored is not yet a backup.

## Restoring a backup

A backup holds the database and nothing else. These are not in it, and have to come back from elsewhere:

| Not in the backup | Where it comes back from |
|---|---|
| The backup passphrase | Your password manager. Without it no backup can be read. |
| The S3 access key | Supabase; make a new one if it is lost. |
| `lyfe.env` and `backup.env` | `install.sh` writes them again. Put back any setting you had changed, and the bucket's endpoint, region and name. |
| The Garmin key | Garmin Connect; make a new key if it is lost. |
| The SimpleFIN access file | A new setup token at the bridge, through `money-connect`. Delete the old app's access there. |
| The Apple push key | Your own copy. Apple lets you download it only once, so if it is lost, make a new key. |
| The food database | `~/bin/lyfe-food-db`. |
| The food icons | `deploy/spark/draw-icons.sh`. Meal illustrations are in the backup. |
| The illustrator and its model | `~/bin/lyfe-illustrator-setup`, on a new machine. |
| The photo model | `ollama pull gemma4:31b`, by whoever runs the Spark's Ollama. |

### On the Spark, or a machine that replaces it

1. **Set the machine up**, if it is new: `deploy/spark/bootstrap.sh`, then `deploy/spark/install.sh`, from the Mac. Install the version of lyfe the backup was taken with, or a newer one: the server brings an older database up to date when it starts, and will not start on one that ran migrations it does not have. `install.sh` makes an empty `lyfe` database and starts the server on it; step 4 replaces it.
2. **Put the backup's settings back**, as `lyfe`: the S3 key in `~/.config/lyfe/backup-s3-key`, the passphrase the backups were made with in `~/.config/lyfe/backup-passphrase`, and the endpoint, region and bucket in `~/.config/lyfe/backup.env`. `~/bin/lyfe-backup ready` prints nothing once they are complete.

   ```sh
   umask 077
   nano ~/.config/lyfe/backup-s3-key
   nano ~/.config/lyfe/backup-passphrase
   nano ~/.config/lyfe/backup.env
   ~/bin/lyfe-backup ready
   ```

3. **Fetch the backup**, as `lyfe`. The file it writes is the whole database, decrypted, readable only by `lyfe`.

   ```sh
   ~/bin/lyfe-backup list                                          # names and sizes, oldest first
   ~/bin/lyfe-backup fetch lyfe-<date and time>.dump.gpg ~/lyfe.dump
   ```

4. **Put it in place of the database**, as `lyfe`. The database there is kept, renamed, until the restored one is checked.

   ```sh
   systemctl --user stop lyfe-server
   PG_BIN=$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)
   SOCKET=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/lyfe-postgres
   "$PG_BIN/psql" -h "$SOCKET" -d postgres -c 'alter database lyfe rename to lyfe_before_restore'
   "$PG_BIN/createdb" -h "$SOCKET" lyfe
   "$PG_BIN/pg_restore" -h "$SOCKET" --no-owner --dbname=lyfe ~/lyfe.dump
   systemctl --user start lyfe-server
   journalctl --user -u lyfe-server -n 20 --no-pager
   ```

5. **Check it.** Open lyfe on the phone. Devices stay signed in, since their tokens are in the database, as long as the server's address has not changed; if it has, sign in again with the new one. Then drop the old database and the decrypted file:

   ```sh
   "$PG_BIN/dropdb" -h "$SOCKET" lyfe_before_restore
   rm ~/lyfe.dump
   ```

6. **Put back what the backup leaves out** (the table above): the Garmin key (`garmin-check`), the banks (`money-connect`, then `money-check`), the Apple push key (`push-test`), the food database (`~/bin/lyfe-food-db`), the illustrator on a new machine (`~/bin/lyfe-illustrator-setup`), the icons (`deploy/spark/draw-icons.sh` from the Mac), the photo model, and any setting you had changed in `lyfe.env`.
7. **Switch the nightly backup on again**: `SKIP_BUILD=1 deploy/spark/install.sh` from the Mac turns the timer on once `lyfe-backup ready` passes. Run `~/bin/lyfe-backup` once, as `lyfe`, and check it says "Backed up".

To test a backup without touching the live database, do steps 3 and 4 into a scratch database instead (`createdb` and `pg_restore --dbname=lyfe_restored`, with the server left running), compare, then `dropdb` it and remove the file.

### On another machine

`~/bin/lyfe-backup` exists only on the Spark. Elsewhere, for instance to look at a backup on the Mac, use `deploy/spark/lyfe-backup` from this repository. It needs `curl` with `--aws-sigv4` and `gpg`; a `backup.env` with the endpoint, region and bucket, and with `LYFE_BACKUP_S3_KEY_FILE` and `LYFE_BACKUP_PASSPHRASE_FILE` pointing at copies of the two secret files; `LYFE_BACKUP_ENV` pointing at that `backup.env`; and `LYFE_DATABASE_URL` set, which it checks even though `list` and `fetch` do not use it. Restore into a PostgreSQL at least as new as the Spark's, such as the development database:

```sh
export LYFE_BACKUP_ENV=<path to backup.env> LYFE_DATABASE_URL=postgres://postgres:dev@127.0.0.1:54329/lyfe_restored
deploy/spark/lyfe-backup list
deploy/spark/lyfe-backup fetch lyfe-<date and time>.dump.gpg lyfe.dump
docker exec lyfe-dev-db createdb -U postgres lyfe_restored
docker exec -i lyfe-dev-db pg_restore -U postgres --no-owner --dbname=lyfe_restored < lyfe.dump
```

The backend can then run against it as in [Working on it locally](../README.md#working-on-it-locally), with that `LYFE_DATABASE_URL`. Delete `lyfe.dump` and the copies of the secrets when done.

## Security model

ADR 0001 sets the trust boundary: lyfe runs on a machine shared with other people, and its owner accepts that the machine's administrators could read everything it holds.

- **Root and the Spark's admins can read everything lyfe has:** the database files, the settings, every secret file (the Garmin key, the bridge's access address, the Apple push key, the S3 key) and the backup passphrase. Encryption on the Spark cannot change that while the running server can read its own data.
- **Other accounts cannot.** lyfe's home is readable only by `lyfe`, its secret files only by `lyfe`, and PostgreSQL has no network port, only a Unix socket in a folder only `lyfe` can open.
- **Who can reach lyfe.** `lyfe-server` listens on loopback, and `tailscale serve` publishes it to the tailnet over HTTPS; it is never published with Funnel. Anyone on the tailnet whose access rules let them reach the Spark can reach the HTTPS port, and any account on the Spark can reach the loopback port. So lyfe's password is the real gate.
- **The password.** It is stored only as an argon2id hash, and `set-password` refuses one shorter than 12 characters. After five wrong attempts in a row, each further wrong attempt doubles the wait before the next is looked at, from one second up to 15 minutes, and a right one clears it. The count is one for the whole server and kept in memory, so restarting the server clears it too.
- **Devices.** Each signed-in device has its own random token, stored only as a SHA-256 hash, so a copy of the database cannot sign in. Signing out on the phone revokes its token, and `lyfe-server set-password` signs every device out.
- **Meal photos.** A photo and its line go, over loopback, to the Ollama on the Spark, which another account runs and other people use; whoever runs it can see what it is sent. The illustrator runs as `lyfe`, reads its model from disk and never goes to the network. Nothing about food leaves the Spark except in the encrypted backup.
- **Banks.** SimpleFIN Bridge, and the aggregator behind it, hold the bank sign-ins and see every balance and transaction (ADR 0007). The access address is a password to all of it; deleting the app's access at the bridge cuts lyfe off.
- **Backups.** They are encrypted before they leave, so the storage provider holds a file it cannot read. The passphrase is a file next to the S3 key on the Spark, so this keeps a backup from the provider, not from the Spark's admins. The S3 key reaches every bucket in its Supabase project, so lyfe's backups go in a project of their own.
- **The phone.** lyfe asks for Face ID each time it is opened ([rules](rules.md#the-lock)). It keeps in its own storage the last Home it saw, Home's money strip included (ADR 0007, amended), the captures waiting to be sent, and the drawings and icons it has fetched.
- **The log.** The server log counts things. Weights, food targets, payees and amounts are not written to it.
