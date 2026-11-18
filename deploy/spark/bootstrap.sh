#!/usr/bin/env bash
# Runs setup-admin.sh on the Spark. You type your sudo password on the
# Spark yourself; nothing else is asked.
#
#   deploy/spark/bootstrap.sh
#
# Settings (environment, or deploy/spark/local.env which is not committed):
#   ADMIN_SSH          how you reach the Spark with sudo rights   (default: spark-admin)
#   LYFE_SSH_KEY       private key that will log in as lyfe; its .pub is
#                      authorised on the Spark          (default: ~/.ssh/id_ed25519)
#   GARMIN_KEY_FROM    path on the Spark of the Garmin key file to copy
#                      (default: lyfe-prototype/garmin/api-key in the admin account's home;
#                       set to "" to skip)
set -euo pipefail
cd "$(dirname "$0")"

[ -f local.env ] && . ./local.env
ADMIN_SSH=${ADMIN_SSH:-spark-admin}
LYFE_SSH_KEY=${LYFE_SSH_KEY:-$HOME/.ssh/id_ed25519}
LYFE_SSH_PUBKEY="$LYFE_SSH_KEY.pub"
GARMIN_KEY_FROM=${GARMIN_KEY_FROM-lyfe-prototype/garmin/api-key}

if [ ! -s "$LYFE_SSH_PUBKEY" ]; then
    echo "No public key at $LYFE_SSH_PUBKEY. Set LYFE_SSH_KEY." >&2
    exit 1
fi
KEY=$(head -1 "$LYFE_SSH_PUBKEY")

scp -q setup-admin.sh "$ADMIN_SSH:lyfe-setup-admin.sh"
GARMIN_ARG=""
if [ -n "$GARMIN_KEY_FROM" ]; then
    GARMIN_ARG="--garmin-key-from \"\$HOME/$GARMIN_KEY_FROM\""
fi
# -t gives sudo a terminal to ask for the password on.
ssh -t "$ADMIN_SSH" "sudo bash lyfe-setup-admin.sh --ssh-key '$KEY' $GARMIN_ARG; status=\$?; rm -f lyfe-setup-admin.sh; exit \$status"
