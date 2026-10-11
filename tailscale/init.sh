#!/bin/sh
# init.sh: create the persistent config folder and publish the settings page.
. "$(dirname "$(readlink -f "$0")")/common.sh"
log "Script called: $0 $*"
APP_DIR="$(app_dir "$1")"

chmod +x "$APP_DIR"/*.sh "$APP_DIR"/bin/* 2>/dev/null

# Persistent data next to the app folder (survives reinstall/upgrade of the app)
CONF_DIR="$(dirname "$APP_DIR")/tailscale_conf"
mkdir -p "$CONF_DIR/bin" "$CONF_DIR/state" "$CONF_DIR/logs" "$CONF_DIR/tmp"
chmod 700 "$CONF_DIR/state"
[ -f "$CONF_DIR/settings.conf" ] || cp "$APP_DIR/settings.conf.default" "$CONF_DIR/settings.conf"
log "Config dir: $CONF_DIR"

# Settings page: CenterType=1 apps are served from /var/www/apps/<name>
mkdir -p "$WEB_DIR"
ln -sf "$APP_DIR"/web/* "$WEB_DIR/"
log "Web dir linked: $WEB_DIR"
rm -f /tmp/tailscale_apkg_upgrade
