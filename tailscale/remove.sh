#!/bin/sh
# remove.sh: uninstall the app. The persistent folder tailscale_conf (binaries,
# node state, settings, logs) is kept on purpose so a reinstall picks up where
# you left off. Delete <volume>/Nas_Prog/tailscale_conf by hand for a clean slate.
. "$(dirname "$(readlink -f "$0")")/common.sh"
log "Script called: $0 $*"
APP_DIR="$(app_dir "$1")"
sh "$APP_DIR/bin/tailscale-ctl.sh" stop >> "$LOG" 2>&1
rm -rf "$WEB_DIR"
rm -rf "$APP_DIR"
