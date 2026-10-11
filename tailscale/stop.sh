#!/bin/sh
# stop.sh: stop the Tailscale daemon.
. "$(dirname "$(readlink -f "$0")")/common.sh"
log "Script called: $0 $*"
APP_DIR="$(app_dir "$1")"
sh "$APP_DIR/bin/tailscale-ctl.sh" stop >> "$LOG" 2>&1
