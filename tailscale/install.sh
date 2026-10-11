#!/bin/sh
# install.sh: move the unpacked app from the upload folder to its final place.
. "$(dirname "$(readlink -f "$0")")/common.sh"
log "Script called: $0 $*"
path_src="$1"
path_des="$2"
mv -f "$path_src" "$path_des"
