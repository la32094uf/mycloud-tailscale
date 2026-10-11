#!/bin/sh
# preinst.sh: runs before installation. Nothing to back up: all persistent
# data lives in <volume>/Nas_Prog/tailscale_conf, outside the app folder.
. "$(dirname "$(readlink -f "$0")")/common.sh"
log "Script called: $0 $*"
exit 0
