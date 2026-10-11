#!/bin/sh
# before_apkg.sh: runs before the installer unpacks anything.
. "$(dirname "$(readlink -f "$0")")/common.sh"
log "Script called: $0 $*"
# before_apkg.sh only runs on (re)install/upgrade, never on uninstall. Leave a
# marker so remove.sh knows it must keep the persistent data this time.
touch /tmp/tailscale_apkg_upgrade
exit 0
