#!/usr/bin/env bash
# One-time setup on the Spark that needs administrator rights. Everything
# after this runs as the `lyfe` account without sudo (see install.sh).
#
# Run it through bootstrap.sh from the Mac, or directly on the Spark:
#   sudo bash setup-admin.sh --ssh-key "ssh-ed25519 AAAA... you@mac" \
#        [--garmin-key-from /path/to/api-key] [--tailnet-port 8444] [--no-tailscale]
#
# What it does, and nothing else:
#   1. creates the `lyfe` account (no password, home readable only by it)
#   2. installs the PostgreSQL programs, without starting a system database
#   3. lets the given SSH key log in as `lyfe`
#   4. lets lyfe's services keep running when nobody is logged in
#   5. copies the Garmin key file into lyfe's home, if asked
#   6. publishes the backend's local port to the tailnet over HTTPS
#      (tailnet only: this is `tailscale serve`, never Funnel)
# It is safe to run again.
set -euo pipefail

ACCOUNT=lyfe
BACKEND_PORT=8787
TAILNET_PORT=8444
SSH_KEY=""
GARMIN_KEY_FROM=""
USE_TAILSCALE=1

while [ $# -gt 0 ]; do
    case "$1" in
        --ssh-key) SSH_KEY="$2"; shift 2 ;;
        --garmin-key-from) GARMIN_KEY_FROM="$2"; shift 2 ;;
        --tailnet-port) TAILNET_PORT="$2"; shift 2 ;;
        --no-tailscale) USE_TAILSCALE=0; shift ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done

if [ "$(uname -s)" != Linux ]; then
    echo "This script runs on the Spark, not on this machine. Nothing was changed." >&2
    echo "From the Mac, run: deploy/spark/bootstrap.sh   (no sudo; it asks for your Spark password)" >&2
    exit 1
fi
if [ "$(id -u)" -ne 0 ]; then
    echo "Run this with sudo." >&2
    exit 1
fi
case "$SSH_KEY" in
    ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-*\ *) ;;
    *)
        echo "--ssh-key must be a public key line (ssh-ed25519 AAAA...). Nothing was changed." >&2
        echo "The easy way is deploy/spark/bootstrap.sh from the Mac, which passes it for you." >&2
        exit 2
        ;;
esac
if [ -n "$GARMIN_KEY_FROM" ] && [ ! -s "$GARMIN_KEY_FROM" ]; then
    echo "Garmin key file not found or empty: $GARMIN_KEY_FROM" >&2
    exit 2
fi

step() { printf '\n== %s\n' "$1"; }

step "1/6 Account"
if id "$ACCOUNT" >/dev/null 2>&1; then
    echo "Account $ACCOUNT already exists."
else
    adduser --disabled-password --gecos "lyfe backend" "$ACCOUNT"
fi
HOME_DIR=$(getent passwd "$ACCOUNT" | cut -d: -f6)
chmod 700 "$HOME_DIR"

step "2/6 PostgreSQL programs"
if compgen -G "/usr/lib/postgresql/*/bin/postgres" >/dev/null; then
    echo "PostgreSQL is already installed."
else
    # lyfe runs its own database under its own account. Tell the package
    # not to create and start a machine-wide one.
    if [ ! -e /etc/postgresql-common/createcluster.conf ]; then
        mkdir -p /etc/postgresql-common
        printf '%s\n' "# Written by lyfe's setup-admin.sh: no machine-wide database." \
            "create_main_cluster = false" > /etc/postgresql-common/createcluster.conf
    fi
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -q
    apt-get install -y -q postgresql
fi
PG_BIN=$(ls -d /usr/lib/postgresql/*/bin | sort -V | tail -1)
echo "Using $PG_BIN"

step "3/6 SSH access for $ACCOUNT"
install -d -m 700 -o "$ACCOUNT" -g "$ACCOUNT" "$HOME_DIR/.ssh"
AUTH="$HOME_DIR/.ssh/authorized_keys"
touch "$AUTH"
if grep -qxF "$SSH_KEY" "$AUTH"; then
    echo "Key already authorised."
else
    printf '%s\n' "$SSH_KEY" >> "$AUTH"
    echo "Key added."
fi
chown "$ACCOUNT:$ACCOUNT" "$AUTH"
chmod 600 "$AUTH"

step "4/6 Services that outlive a login"
loginctl enable-linger "$ACCOUNT"
echo "Linger enabled for $ACCOUNT."

step "5/6 Garmin key"
install -d -m 700 -o "$ACCOUNT" -g "$ACCOUNT" "$HOME_DIR/.config" "$HOME_DIR/.config/lyfe"
if [ -n "$GARMIN_KEY_FROM" ]; then
    install -m 600 -o "$ACCOUNT" -g "$ACCOUNT" "$GARMIN_KEY_FROM" "$HOME_DIR/.config/lyfe/garmin-api-key"
    echo "Copied to $HOME_DIR/.config/lyfe/garmin-api-key. The original was left in place; delete it when you like."
elif [ -s "$HOME_DIR/.config/lyfe/garmin-api-key" ]; then
    echo "Key file already in place."
else
    echo "No key copied. Put it at $HOME_DIR/.config/lyfe/garmin-api-key (owner $ACCOUNT, mode 600)."
fi

step "6/6 Tailnet address"
if [ "$USE_TAILSCALE" -eq 1 ]; then
    tailscale serve --bg --yes --https="$TAILNET_PORT" "http://127.0.0.1:$BACKEND_PORT"
    DNS_NAME=$(tailscale status --json | sed -n 's/.*"DNSName": *"\([^"]*\)\.".*/\1/p' | head -1)
    echo "The backend will be at https://${DNS_NAME:-<this-machine>}:$TAILNET_PORT once installed (tailnet only)."
else
    echo "Skipped."
fi

printf '\nDone. Next, from the Mac: deploy/spark/install.sh\n'
