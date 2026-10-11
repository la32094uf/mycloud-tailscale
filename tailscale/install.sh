#!/bin/sh
# install.sh: move the unpacked app from the upload folder to its final place.
. "$(dirname "$(readlink -f "$0")")/common.sh"
log "Script called: $0 $*"
path_src="$1"
path_des="$2"
# mv into an existing directory would nest it; clear a leftover first (guarded).
dest="${path_des:?}/$(basename "${path_src:?}")"
case "$dest" in
    */Nas_Prog/tailscale) rm -rf "${dest:?}" ;;
esac
mv -f "$path_src" "$path_des"
