#!/bin/sh
# clean.sh: undo what init.sh created (web links).
. "$(dirname "$(readlink -f "$0")")/common.sh"
log "Script called: $0 $*"
rm -rf "$WEB_DIR"
