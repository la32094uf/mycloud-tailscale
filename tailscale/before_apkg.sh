#!/bin/sh
# before_apkg.sh: runs before the installer unpacks anything.
. "$(dirname "$(readlink -f "$0")")/common.sh"
log "Script called: $0 $*"
# before_apkg.sh only runs on (re)install/upgrade, never on uninstall. Leave a
# marker so remove.sh knows it must keep the persistent data this time.
# CROSS-VERSION CONTRACT: during an upgrade the OLD app's remove.sh reads this
# path. Never rename or move it, or upgrading users lose their node key.
# /tmp is world-writable: never follow a planted symlink, and keep the
# authoritative copy in root-only /var/run (new remove.sh prefers that one).
write_marker() {
    rm -f "$1"
    [ -e "$1" ] || [ -L "$1" ] && return 1           # still there (e.g. a directory): leave it
    ( set -C; date +%s > "$1" ) 2>/dev/null         # noclobber: fails instead of following anything
}
write_marker /var/run/tailscale_apkg_upgrade
write_marker /tmp/tailscale_apkg_upgrade || log "could not write /tmp marker (planted file?)"
exit 0
