#!/bin/sh
# Test api.php's host check (DNS-rebinding guard) with the PHP CLI.
# Runs api.php with a fake POST for a mutating action and checks whether the
# request is refused as "not this NAS". Run twice in CI: with a normal
# environment and with an empty one (php-fpm on some firmware has no PATH).
set -u
cd "$(dirname "$0")/.."
API="$PWD/tailscale/web/api.php"
HOST_NAME="$(php -r 'echo strtolower(gethostname());')"
SEARCH="$(sed -n 's/^search[[:space:]]*\([^[:space:]]*\).*/\1/p' /etc/resolv.conf | head -1)"
fail=0

check() { # check HOST expect(allow|deny)
    out="$(env ${ENVMODE:-} php -r '
        $_SERVER = ["REQUEST_METHOD"=>"POST","HTTP_X_REQUESTED_WITH"=>"XMLHttpRequest",
                    "HTTP_HOST"=>$argv[1],"HTTP_ORIGIN"=>"http://".$argv[1],"SERVER_ADDR"=>"127.0.0.1"];
        $_GET["action"] = "notify_status_probe";
        include $argv[2];' "$1" "$API" 2>&1)"
    case "$out" in *"does not recognise"*) got=deny ;; *) got=allow ;; esac
    if [ "$got" = "$2" ]; then echo "ok    $2  $1"; else echo "FAIL  expected $2, got $got: $1"; echo "      $out" | head -c 300; echo; fail=1; fi
}

for ENVMODE in "" "-i"; do
    echo "== environment: ${ENVMODE:-normal}"
    check 192.168.1.50 allow
    check 10.0.0.7 allow
    check "[fe80::1]" allow
    check MyCloudPR4100 allow
    check nas allow
    check "$HOST_NAME.lan" allow
    check "$HOST_NAME.local" allow
    [ -n "$SEARCH" ] && check "$HOST_NAME.$SEARCH" allow
    check evil.example deny
    check "$HOST_NAME.evil.example" deny
    check "nas.attacker.example" deny
done
exit $fail
