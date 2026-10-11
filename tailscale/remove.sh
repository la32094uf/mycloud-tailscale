#!/bin/sh
# remove.sh: runs on uninstall AND as part of a reinstall/upgrade.
# - upgrade (before_apkg.sh left a marker): keep <volume>/Nas_Prog/tailscale_conf
#   so binaries, node state and settings survive.
# - real uninstall: log the node out of the tailnet and delete tailscale_conf,
#   as the dashboard's uninstall dialog promises ("all app data will be deleted").
. "$(dirname "$(readlink -f "$0")")/common.sh"
log "Script called: $0 $*"
APP_DIR="$(app_dir "$1")"
case "$APP_DIR" in */Nas_Prog/tailscale) ;; *) log "refusing to remove unexpected path $APP_DIR"; exit 1 ;; esac
CONF_DIR="$(dirname "$APP_DIR")/tailscale_conf"
# Marker path is a cross-version contract (see before_apkg.sh). The root-only
# copy in /var/run is authoritative; /tmp is only consulted as a fallback and
# only when it is a root-owned regular file. A marker counts only when fresh:
# an aborted install could leave an old one behind.
upgrade=false
for m in /var/run/tailscale_apkg_upgrade /tmp/tailscale_apkg_upgrade; do
    [ -f "$m" ] && [ ! -L "$m" ] && [ "$(stat -c %u "$m" 2>/dev/null)" = 0 ] || continue
    stamp="$(cat "$m" 2>/dev/null)"
    case "$stamp" in *[!0-9]*|'') continue ;; esac
    age=$(( $(date +%s) - stamp ))
    [ "$age" -ge 0 ] && [ "$age" -lt 900 ] && { upgrade=true; break; }
done
if $upgrade; then
    log "upgrade: keeping $CONF_DIR"
    sh "$APP_DIR/bin/tailscale-ctl.sh" stop >> "$LOG" 2>&1
else
    log "uninstall: logging out and removing $CONF_DIR"
    # stop.sh already ran, but 'tailscale logout' needs the daemon: start it briefly.
    sh "$APP_DIR/bin/tailscale-ctl.sh" start >> "$LOG" 2>&1
    sh "$APP_DIR/bin/tailscale-ctl.sh" logout >> "$LOG" 2>&1
    sh "$APP_DIR/bin/tailscale-ctl.sh" stop >> "$LOG" 2>&1
    rm -f /tmp/tailscale_apkg_upgrade /var/run/tailscale_apkg_upgrade
    case "$CONF_DIR" in */Nas_Prog/tailscale_conf) rm -rf "$CONF_DIR" ;; esac
fi
rm -rf "$WEB_DIR"
rm -rf "$APP_DIR"
