#!/bin/sh
# remove.sh: runs on uninstall AND as part of a reinstall/upgrade.
# - upgrade (before_apkg.sh left a marker): keep <volume>/Nas_Prog/tailscale_conf
#   so binaries, node state and settings survive.
# - real uninstall: log the node out of the tailnet and delete tailscale_conf,
#   as the dashboard's uninstall dialog promises ("all app data will be deleted").
. "$(dirname "$(readlink -f "$0")")/common.sh"
log "Script called: $0 $*"
APP_DIR="$(app_dir "$1")"
CONF_DIR="$(dirname "$APP_DIR")/tailscale_conf"
if [ -f /tmp/tailscale_apkg_upgrade ]; then
    log "upgrade: keeping $CONF_DIR"
    sh "$APP_DIR/bin/tailscale-ctl.sh" stop >> "$LOG" 2>&1
else
    log "uninstall: logging out and removing $CONF_DIR"
    sh "$APP_DIR/bin/tailscale-ctl.sh" logout >> "$LOG" 2>&1
    sh "$APP_DIR/bin/tailscale-ctl.sh" stop >> "$LOG" 2>&1
    case "$CONF_DIR" in */Nas_Prog/tailscale_conf) rm -rf "$CONF_DIR" ;; esac
fi
rm -rf "$WEB_DIR"
rm -rf "$APP_DIR"
