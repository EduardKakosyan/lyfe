#!/usr/bin/env bash
# Has the Spark draw the icon of every food in the catalogue ahead of time,
# so that none is waited for on the phone. Run it once after installing,
# and again after the catalogue or the icons' look changes; icons already
# drawn are left alone, so running it again only says how far along it is.
#
#   deploy/spark/draw-icons.sh
#
# The names come from the app's own catalogue (apps/LyfeKit); lyfe-server on
# the Spark queues them and draws them in the background, about a second
# each once the model is loaded: a little over an hour for all of them.
# Meal photos, and any icon the phone asks for meanwhile, go first.
# Settings are install.sh's (deploy/spark/local.env).
set -euo pipefail
cd "$(dirname "$0")"
REPO=$(cd ../.. && pwd)

[ -f local.env ] && . ./local.env
LYFE_SSH=${LYFE_SSH:-lyfe@spark}
LYFE_SSH_KEY=${LYFE_SSH_KEY:-$HOME/.ssh/id_ed25519}
SSH_OPTS=(-i "$LYFE_SSH_KEY" -o IdentitiesOnly=yes -o BatchMode=yes)

NAMES=$(mktemp)
trap 'rm -f "$NAMES"' EXIT
swift run --package-path "$REPO/apps/LyfeKit" lyfe-icon-names > "$NAMES"
[ -s "$NAMES" ] || { echo "The catalogue listed no names." >&2; exit 1; }
ssh "${SSH_OPTS[@]}" "$LYFE_SSH" 'set -a; . ~/.config/lyfe/lyfe.env; set +a; ~/bin/lyfe-server queue-icons' < "$NAMES"
