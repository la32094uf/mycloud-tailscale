#!/bin/sh
# before_apkg.sh: runs before the installer unpacks anything.
. "$(dirname "$(readlink -f "$0")")/common.sh"
log "Script called: $0 $*"
exit 0
