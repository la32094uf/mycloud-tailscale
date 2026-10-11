#!/bin/sh
# start.sh: start the Tailscale daemon (also runs at boot when the app is enabled).
. "$(dirname "$(readlink -f "$0")")/common.sh"
log "Script called: $0 $*"
APP_DIR="$(app_dir "$1")"
sh "$APP_DIR/bin/tailscale-ctl.sh" start >> "$LOG" 2>&1
