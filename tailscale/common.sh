#!/bin/sh
# common.sh: shared helpers for the apkg lifecycle scripts.
# The installer calls every script with the app path as first argument.

APP_NAME="tailscale"
LOG="/tmp/debug_apkg"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$APP_NAME] [$(basename "$0")] $1" >> "$LOG"
}

# Resolve the app directory: prefer the argument the installer passes,
# fall back to the directory this script lives in.
app_dir() {
    if [ -n "$1" ] && [ -d "$1" ]; then
        echo "$1"
    else
        dirname "$(readlink -f "$0")"
    fi
}

WEB_DIR="/var/www/apps/$APP_NAME"
