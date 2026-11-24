#!/usr/bin/env bash
# Builds the backend for the Spark and installs or updates it under the
# `lyfe` account. Needs no sudo; run setup-admin.sh (via bootstrap.sh) once
# first. Safe to run again: this is also how you deploy a new version.
#
#   deploy/spark/install.sh
#
# Settings (environment, or deploy/spark/local.env which is not committed):
#   LYFE_SSH        how to reach the lyfe account      (default: lyfe@spark)
#   LYFE_SSH_KEY    private key that logs in as lyfe   (default: ~/.ssh/id_ed25519)
#   LYFE_TIMEZONE   used only when first writing the settings file
#                   (default: this Mac's time zone)
#   SKIP_BUILD=1    reuse the last built binary
set -euo pipefail
cd "$(dirname "$0")"
REPO=$(cd ../.. && pwd)

[ -f local.env ] && . ./local.env
LYFE_SSH=${LYFE_SSH:-lyfe@spark}
LYFE_SSH_KEY=${LYFE_SSH_KEY:-$HOME/.ssh/id_ed25519}
# Use exactly this key, so SSH never falls through to other keys or a
# password prompt.
SSH_OPTS=(-i "$LYFE_SSH_KEY" -o IdentitiesOnly=yes)
TIMEZONE=${LYFE_TIMEZONE:-$(readlink /etc/localtime | sed 's|.*/zoneinfo/||')}
BINARY="$REPO/backend/target-linux/release/lyfe-server"

if [ "${SKIP_BUILD:-0}" != 1 ]; then
    echo "== Building for Linux arm64 (in Docker)"
    docker run --rm --platform linux/arm64 \
        -v "$REPO/backend":/src -v lyfe-cargo-registry:/usr/local/cargo/registry \
        -w /src -e CARGO_TARGET_DIR=/src/target-linux \
        rust:1-bookworm cargo build --release --locked
fi
[ -x "$BINARY" ] || { echo "No binary at $BINARY" >&2; exit 1; }

# The lyfe account has no password; it is reached by SSH key only. Check
# that works before anything else, so a locked key gives a clear message
# and not a password prompt that nothing can answer.
if ! ssh "${SSH_OPTS[@]}" -o BatchMode=yes -o ConnectTimeout=10 "$LYFE_SSH" true 2>/dev/null; then
    cat >&2 <<NOTE
Can't log in as $LYFE_SSH with the key $LYFE_SSH_KEY.
The lyfe account has no password; it only accepts the key bootstrap.sh authorised.
  - Account not set up yet, or set up with a different key: run deploy/spark/bootstrap.sh
  - Key has a passphrase: unlock it once with  ssh-add --apple-use-keychain $LYFE_SSH_KEY
  - Or use another key: set LYFE_SSH_KEY in deploy/spark/local.env and run bootstrap.sh again
NOTE
    exit 1
fi

echo "== Copying to $LYFE_SSH"
ssh "${SSH_OPTS[@]}" "$LYFE_SSH" 'mkdir -p ~/bin ~/.config/lyfe ~/.config/systemd/user ~/.cache/lyfe-install && chmod 700 ~/.config/lyfe'
scp -q "${SSH_OPTS[@]}" "$BINARY" "$LYFE_SSH:.cache/lyfe-install/lyfe-server"
scp -q "${SSH_OPTS[@]}" lyfe-postgres.service lyfe-server.service lyfe.env.template \
    lyfe-backup lyfe-backup.service lyfe-backup.timer backup.env.template lyfe-food-db \
    lyfe-illustrate lyfe-illustrate.py lyfe-illustrator-setup \
    "$LYFE_SSH:.cache/lyfe-install/"

echo "== Installing"
ssh "${SSH_OPTS[@]}" "$LYFE_SSH" "TIMEZONE='$TIMEZONE' bash -s" <<'REMOTE'
set -euo pipefail
export XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
STAGE=~/.cache/lyfe-install
PG_BIN=$(ls -d /usr/lib/postgresql/*/bin 2>/dev/null | sort -V | tail -1)
[ -n "$PG_BIN" ] || { echo "PostgreSQL is not installed; run bootstrap.sh first." >&2; exit 1; }

# Settings file: written once, never overwritten.
if [ ! -e ~/.config/lyfe/lyfe.env ]; then
    sed -e "s|@RUNTIME_DIR@|$XDG_RUNTIME_DIR|" -e "s|@TIMEZONE@|$TIMEZONE|" -e "s|@HOME@|$HOME|" \
        "$STAGE/lyfe.env.template" > ~/.config/lyfe/lyfe.env
    chmod 600 ~/.config/lyfe/lyfe.env
    echo "Wrote ~/.config/lyfe/lyfe.env (time zone $TIMEZONE)."
fi

# Database: created once.
if [ ! -e ~/pgdata/PG_VERSION ]; then
    "$PG_BIN/initdb" -D ~/pgdata --auth-local=peer --auth-host=reject --encoding=UTF8 --locale=C.UTF-8 >/dev/null
    chmod 700 ~/pgdata
    echo "Created the database folder ~/pgdata."
fi

sed "s|@PG_BIN@|$PG_BIN|" "$STAGE/lyfe-postgres.service" > ~/.config/systemd/user/lyfe-postgres.service
cp "$STAGE/lyfe-server.service" ~/.config/systemd/user/lyfe-server.service
systemctl --user daemon-reload
systemctl --user enable --now lyfe-postgres.service

SOCKET_DIR="$XDG_RUNTIME_DIR/lyfe-postgres"
if ! "$PG_BIN/psql" -h "$SOCKET_DIR" -d postgres -Atc "select 1 from pg_database where datname = 'lyfe'" | grep -q 1; then
    "$PG_BIN/createdb" -h "$SOCKET_DIR" lyfe
    echo "Created database lyfe."
fi

# Swap the binary in one step, then restart.
install -m 755 "$STAGE/lyfe-server" ~/bin/lyfe-server.new
mv ~/bin/lyfe-server.new ~/bin/lyfe-server
systemctl --user enable lyfe-server.service
systemctl --user restart lyfe-server.service

# The nightly backup. Its settings file is written once, never overwritten,
# and the timer is switched on only once those settings are complete.
if [ ! -e ~/.config/lyfe/backup.env ]; then
    sed -e "s|@HOME@|$HOME|" "$STAGE/backup.env.template" > ~/.config/lyfe/backup.env
    chmod 600 ~/.config/lyfe/backup.env
fi
install -m 755 "$STAGE/lyfe-backup" ~/bin/lyfe-backup
install -m 755 "$STAGE/lyfe-food-db" ~/bin/lyfe-food-db
# The meal illustrator. The program is updated here; its Python and the
# model are set up once, by lyfe-illustrator-setup.
mkdir -p ~/illustrator && chmod 700 ~/illustrator
install -m 644 "$STAGE/lyfe-illustrate.py" ~/illustrator/lyfe-illustrate.py
install -m 755 "$STAGE/lyfe-illustrate" ~/bin/lyfe-illustrate
install -m 755 "$STAGE/lyfe-illustrator-setup" ~/bin/lyfe-illustrator-setup
if [ ! -e ~/illustrator/ready ]; then
    echo "Meals are not illustrated, and food icons not drawn, yet: run ~/bin/lyfe-illustrator-setup once as lyfe (about 21 GB; see the README)."
fi
# Money. The access address is written once, by `lyfe-server money-connect`.
MONEY_FILE=$(sed -n 's/^LYFE_SIMPLEFIN_ACCESS_FILE=//p' ~/.config/lyfe/lyfe.env | tail -1)
if [ -z "$MONEY_FILE" ]; then
    echo "Money is off: LYFE_SIMPLEFIN_ACCESS_FILE is not set in ~/.config/lyfe/lyfe.env (see the README)."
elif [ ! -s "$MONEY_FILE" ]; then
    echo "No bank is connected yet: make a setup token at SimpleFIN Bridge, then run"
    echo "  set -a; . ~/.config/lyfe/lyfe.env; set +a; ~/bin/lyfe-server money-connect"
fi
cp "$STAGE/lyfe-backup.service" "$STAGE/lyfe-backup.timer" ~/.config/systemd/user/
systemctl --user daemon-reload
if BACKUP_MISSING=$(~/bin/lyfe-backup ready); then
    systemctl --user enable --now lyfe-backup.timer
    echo "The nightly backup is on. Last run: $(systemctl --user show lyfe-backup.service -p ExecMainExitTimestamp --value | grep . || echo never)."
else
    systemctl --user disable --now lyfe-backup.timer >/dev/null 2>&1 || true
    echo "NO BACKUP YET: the database on this machine is the only copy. Still to do (see the README):"
    echo "$BACKUP_MISSING" | sed 's/^/  - /'
fi
rm -rf "$STAGE"

for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS -m 2 http://127.0.0.1:8787/healthz >/dev/null 2>&1; then
        echo "lyfe-server $(~/bin/lyfe-server --version | cut -d' ' -f2) is running."
        exit 0
    fi
    sleep 1
done
echo "lyfe-server did not answer. Recent log:" >&2
journalctl --user -u lyfe-server -n 20 --no-pager >&2 || true
exit 1
REMOTE

cat <<NOTE

Installed. If this is the first install, set your lyfe password:
  ssh -t -i $LYFE_SSH_KEY $LYFE_SSH 'set -a; . ~/.config/lyfe/lyfe.env; set +a; ~/bin/lyfe-server set-password'
Logs:
  ssh -i $LYFE_SSH_KEY $LYFE_SSH 'journalctl --user -u lyfe-server -n 50 --no-pager'
NOTE
