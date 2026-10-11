#!/bin/sh
# tailscale-ctl.sh: single entry point for managing Tailscale on My Cloud OS5.
# Used by the apkg lifecycle scripts (start.sh/stop.sh) and by the settings
# page (web/api.php). POSIX sh only: the NAS runs busybox ash.
#
#   tailscale-ctl.sh start|stop|restart|status|version
#   tailscale-ctl.sh login                  connect with the auth key in $TS_AUTHKEY (handed to tailscale via a 0600 file, never argv)
#   tailscale-ctl.sh login-url              start browser login, prints URL when ready
#   tailscale-ctl.sh login-url-poll         print URL if available
#   tailscale-ctl.sh logout
#   tailscale-ctl.sh apply                  push settings.conf via 'tailscale set'
#   tailscale-ctl.sh check-update           JSON: installed/latest/update_available
#   tailscale-ctl.sh update [version]       download+verify+swap binaries (takes a lock)
#   tailscale-ctl.sh update-bg [version]    same, detached; progress in update-status
#   tailscale-ctl.sh update-status          state|message of the last/current update
#   tailscale-ctl.sh rollback               restore previous binaries
#   tailscale-ctl.sh log [lines]
#   tailscale-ctl.sh check-app-update       JSON: this app's version vs. the latest GitHub release
#   tailscale-ctl.sh notify-check           alert via the My Cloud alert system when an update is due
#   tailscale-ctl.sh notify-test            send a test alert (bell icon + e-mail if configured)
#   tailscale-ctl.sh notify-status          JSON about the notification scheduler
#   tailscale-ctl.sh notify-loop            background scheduler, started by 'start'
#   tailscale-ctl.sh weblinks               (re)create the dashboard symlinks in /var/www/apps

set -u
set -f                       # no globbing of settings values (use 'set +f' locally where a glob is wanted)
umask 077
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

SELF="$(readlink -f "$0")"
APP_DIR="$(dirname "$(dirname "$SELF")")"
CONF_DIR="$(dirname "$APP_DIR")/tailscale_conf"
BIN_DIR="$CONF_DIR/bin"
PREV_DIR="$CONF_DIR/bin.prev"
STATE_DIR="$CONF_DIR/state"
LOG_DIR="$CONF_DIR/logs"
TMP_DIR="$CONF_DIR/tmp"
SETTINGS="$CONF_DIR/settings.conf"
DAEMON_LOG="$LOG_DIR/tailscaled.log"
CTL_LOG="$LOG_DIR/tailscale-ctl.log"
UPDATE_STATUS="$TMP_DIR/update.status"
UPDATE_LOCK="$TMP_DIR/update.lock"
LOGIN_OUT="$TMP_DIR/login.out"
NOTIFY_STATE="$CONF_DIR/notify.state"
PIDFILE="/var/run/tailscale-app.pid"
NOTIFY_PIDFILE="/var/run/tailscale-app-notify.pid"
SOCK_DIR="/var/run/tailscale"
SOCK="$SOCK_DIR/tailscaled.sock"
TS="$BIN_DIR/tailscale"
TSD="$BIN_DIR/tailscaled"
WEB_DIR="/var/www/apps/tailscale"
PKG_BASE="https://pkgs.tailscale.com"
BULLETIN_FEED="https://tailscale.com/security-bulletins/index.xml"
APP_RELEASES_API="https://api.github.com/repos/la32094uf/mycloud-tailscale/releases/latest"
APP_RELEASES_URL="https://github.com/la32094uf/mycloud-tailscale/releases"
ALERT_CODE_APP_UPDATE=1501   # My Cloud alert "App Update Available", %1 = text
MAX_LOG_BYTES=5000000

# Refuse to run with a nonsensical layout (protects every rm below).
case "$CONF_DIR" in */Nas_Prog/tailscale_conf) ;; *) echo "unexpected conf dir: $CONF_DIR" >&2; exit 1 ;; esac
# Nas_Prog is world-writable on OS5, so never trust a tailscale_conf we did not
# create: no symlink, root-owned. (Everything inside is created with umask 077.)
if [ -e "$CONF_DIR" ] || [ -L "$CONF_DIR" ]; then
    if [ -L "$CONF_DIR" ] || [ "$(stat -c %u "$CONF_DIR" 2>/dev/null)" != 0 ]; then
        echo "refusing: $CONF_DIR is a symlink or not owned by root" >&2; exit 1
    fi
fi
mkdir -p "$BIN_DIR" "$STATE_DIR" "$LOG_DIR" "$TMP_DIR" "$SOCK_DIR" 2>/dev/null
chmod 700 "$CONF_DIR" "$STATE_DIR" "$SOCK_DIR" 2>/dev/null
[ -f "$SETTINGS" ] || cp "$APP_DIR/settings.conf.default" "$SETTINGS" 2>/dev/null

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$CTL_LOG"; }
die() { echo "ERROR: $*" >&2; log "ERROR: $*"; exit 1; }

# --- settings -------------------------------------------------------------
TS_HOSTNAME=""; TS_ACCEPT_ROUTES=0; TS_ADVERTISE_ROUTES=""; TS_ADVERTISE_EXIT_NODE=0
TS_ACCEPT_DNS=0; TS_SSH=0; TS_EXTRA_UP_ARGS=""; TS_EXTRA_DAEMON_ARGS=""; TS_CHANNEL=stable; TS_NOTIFY=monthly
# Characters allowed in values (same whitelist as the settings page enforces).
clean_flags() { printf '%s' "$1" | tr -d '\r' | tr -cd 'A-Za-z0-9=.,:/_@+ -'; }
clean_word()  { printf '%s' "$1" | tr -d '\r' | tr -cd 'A-Za-z0-9.:/,_-'; }
load_settings() {
    [ -f "$SETTINGS" ] || return 0
    # A planted settings file could point the node at another control server: only read our own.
    if [ -L "$SETTINGS" ] || [ "$(stat -c %u "$SETTINGS" 2>/dev/null)" != 0 ]; then log "ignoring $SETTINGS: symlink or not root-owned"; return 0; fi
    # Only KEY=VALUE lines with known keys; values are never eval'ed as code.
    while IFS='=' read -r k v; do
        case "$k" in
            TS_HOSTNAME) TS_HOSTNAME="$(clean_word "$v")" ;;
            TS_ACCEPT_ROUTES) TS_ACCEPT_ROUTES="$(clean_word "$v")" ;;
            TS_ADVERTISE_ROUTES) TS_ADVERTISE_ROUTES="$(clean_word "$v")" ;;
            TS_ADVERTISE_EXIT_NODE) TS_ADVERTISE_EXIT_NODE="$(clean_word "$v")" ;;
            TS_ACCEPT_DNS) TS_ACCEPT_DNS="$(clean_word "$v")" ;;
            TS_SSH) TS_SSH="$(clean_word "$v")" ;;
            TS_EXTRA_UP_ARGS) TS_EXTRA_UP_ARGS="$(clean_flags "$v")" ;;
            TS_EXTRA_DAEMON_ARGS) TS_EXTRA_DAEMON_ARGS="$(clean_flags "$v")" ;;
            TS_CHANNEL) TS_CHANNEL="$(clean_word "$v")" ;;
            TS_NOTIFY) TS_NOTIFY="$(clean_word "$v")" ;;
        esac
    done < "$SETTINGS"
    case "$TS_CHANNEL" in stable|unstable) ;; *) TS_CHANNEL=stable ;; esac
    case "$TS_NOTIFY" in off|daily|weekly|monthly) ;; *) TS_NOTIFY=monthly ;; esac
}
bool() { case "$1" in 1|true|yes|on) echo true ;; *) echo false ;; esac; }

# WD's kernels ship without the iptables 'nat' table. Tailscale would then log
# a health warning on every start, so tell it not to touch netfilter at all.
# Consequence: no exit node and no SNAT for subnet routes on such devices.
have_nat() { command -v iptables >/dev/null 2>&1 && iptables -t nat -L -n >/dev/null 2>&1; }

# Flags shared by 'tailscale up' and 'tailscale set'
pref_flags() {
    have_nat || printf -- '--netfilter-mode=off --snat-subnet-routes=false '
    printf -- '--accept-routes=%s ' "$(bool "$TS_ACCEPT_ROUTES")"
    printf -- '--accept-dns=%s ' "$(bool "$TS_ACCEPT_DNS")"
    printf -- '--advertise-exit-node=%s ' "$(bool "$TS_ADVERTISE_EXIT_NODE")"
    printf -- '--ssh=%s ' "$(bool "$TS_SSH")"
    printf -- '--advertise-routes=%s ' "$TS_ADVERTISE_ROUTES"
    printf -- '--hostname=%s ' "$TS_HOSTNAME"     # empty resets to the OS hostname
}

# --- platform -------------------------------------------------------------
ts_arch() {
    case "$(uname -m)" in
        armv7l|armv6l|armv5*) echo arm ;;
        aarch64|arm64) echo arm64 ;;
        x86_64|amd64) echo amd64 ;;
        i?86) echo 386 ;;
        *) echo unknown ;;
    esac
}
have_tun() { [ -c /dev/net/tun ] || { modprobe tun 2>/dev/null; [ -c /dev/net/tun ]; }; }
sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | sed 's/.*= //'
    else echo ""; fi
}
fetch() { # fetch URL DEST [MAXBYTES]  (HTTPS only, bounded in time and size; no wget fallback: busybox wget may skip TLS checks)
    command -v curl >/dev/null 2>&1 || { log "curl missing"; return 1; }
    curl -fsSL --proto '=https' --proto-redir '=https' --retry 2 --connect-timeout 20 --max-time 900 \
         --max-filesize "${3:-2000000}" -o "$2" "$1"
}

# --- daemon ---------------------------------------------------------------
daemon_pid() {
    if [ -f "$PIDFILE" ]; then
        p="$(cat "$PIDFILE" 2>/dev/null)"
        [ -n "$p" ] && [ -d "/proc/$p" ] && grep -q tailscaled "/proc/$p/cmdline" 2>/dev/null && { echo "$p"; return 0; }
    fi
    # Fallback: find a process whose executable really is our tailscaled (argv can be faked by anyone).
    set +f
    for d in /proc/[0-9]*; do
        [ "$(readlink "$d/exe" 2>/dev/null)" = "$TSD" ] && { set -f; echo "${d#/proc/}"; return 0; }
    done
    set -f
    return 1
}
is_running() { [ -n "$(daemon_pid)" ]; }
backend_state() { "$TS" --socket="$SOCK" status --json 2>/dev/null | sed -n 's/.*"BackendState": *"\([A-Za-z]*\)".*/\1/p' | head -1; }
wait_for_socket() { # up to 20 s for tailscaled to answer on its socket ('status --json' works in every state)
    i=0
    while [ $i -lt 20 ]; do
        [ -S "$SOCK" ] && [ -n "$(backend_state)" ] && return 0
        sleep 1; i=$((i+1))
    done
    return 1
}

# Refuse to execute binaries that are not root-owned or are writable by others
# (defence in depth: Nas_Prog itself is mode 0777 on OS5).
safe_to_exec() { # safe_to_exec PATH...
    for f in "$@"; do
        [ -e "$f" ] || return 1
        [ -L "$f" ] && { log "refusing $f: symlink"; return 1; }
        [ "$(stat -c %u "$f" 2>/dev/null)" = 0 ] || { log "refusing $f: not owned by root"; return 1; }
        case "$(stat -c %A "$f" 2>/dev/null | cut -c6,9)" in --) ;; *) log "refusing $f: writable by group/others"; return 1 ;; esac
    done
}
installed_version() { [ -x "$TS" ] && "$TS" version 2>/dev/null | head -1; }
prev_version() { [ -x "$PREV_DIR/tailscale" ] && "$PREV_DIR/tailscale" version 2>/dev/null | head -1; }

rotate_log() { # copy-truncate is safe because tailscaled appends (O_APPEND)
    [ -f "$1" ] || return 0
    if [ "$(wc -c < "$1")" -gt "$MAX_LOG_BYTES" ]; then cp -f "$1" "$1.1" 2>/dev/null; : > "$1"; fi
}

cmd_weblinks() { # CenterType=1 apps are served from /var/www/apps/<name>; /var/www is a ramdisk
    mkdir -p "$WEB_DIR" 2>/dev/null || return 0
    set +f                     # globbing is off globally (set -f); needed here
    for f in "$APP_DIR"/web/*; do [ -e "$f" ] && ln -sf "$f" "$WEB_DIR/"; done
    set -f
}

cmd_start() {
    load_settings
    cmd_weblinks
    # Never start a daemon while another process is swapping bin/ (the updater itself may call us).
    if lock_held && [ "$(cat "$UPDATE_LOCK/pid" 2>/dev/null)" != "$$" ]; then echo "update in progress"; return 0; fi
    if ! [ -x "$TSD" ]; then
        log "No tailscale binaries yet, downloading latest ($TS_CHANNEL) in the background"
        cmd_update_bg ""
        notify_loop_start       # the loop keeps retrying the download if the network is slow to come up
        echo "downloading Tailscale, see update status"
        return 0
    fi
    if is_running; then echo "already running (pid $(daemon_pid))"; notify_loop_start; return 0; fi
    safe_to_exec "$CONF_DIR" "$BIN_DIR" "$TSD" "$TS" || die "binaries in $BIN_DIR are not root-owned/root-only; refusing to start (see tailscale-ctl.log)"
    tunflag=""
    have_tun || { tunflag="--tun=userspace-networking"; log "no /dev/net/tun, using userspace networking"; }
    rotate_log "$DAEMON_LOG"
    # shellcheck disable=SC2086
    nohup "$TSD" --state="$STATE_DIR/tailscaled.state" --socket="$SOCK" --statedir="$STATE_DIR" $tunflag $TS_EXTRA_DAEMON_ARGS >> "$DAEMON_LOG" 2>&1 &
    echo $! > "$PIDFILE"
    log "started tailscaled pid $!"
    echo "started (pid $!)"
    # tailscaled creates its control socket 0666; only root should drive it on a NAS.
    wait_for_socket >/dev/null 2>&1 && chmod 600 "$SOCK" 2>/dev/null
    notify_loop_start
}
cmd_stop() {
    notify_loop_stop
    p="$(daemon_pid)"
    if [ -z "$p" ]; then echo "not running"; rm -f "$PIDFILE"; return 0; fi
    kill "$p" 2>/dev/null
    i=0; while [ $i -lt 10 ] && [ -d "/proc/$p" ]; do sleep 1; i=$((i+1)); done
    [ -d "/proc/$p" ] && kill -9 "$p" 2>/dev/null
    q="$(daemon_pid)"; [ -n "$q" ] && kill -9 "$q" 2>/dev/null   # a second instance, if any
    rm -f "$PIDFILE"
    log "stopped tailscaled pid $p"
    echo "stopped"
}
cmd_status() {
    # Machine-readable status for the settings page.
    rotate_log "$DAEMON_LOG"; rotate_log "$CTL_LOG"
    running=false; is_running && running=true
    tun=false; have_tun && tun=true
    nat=false; have_nat && nat=true
    ver="$(installed_version)"; prev="$(prev_version)"
    st='{}'
    if $running && [ -x "$TS" ]; then st="$("$TS" --socket="$SOCK" status --json 2>/dev/null || echo '{}')"; fi
    [ -z "$st" ] && st='{}'
    printf '{"daemon_running":%s,"tun":%s,"nat":%s,"arch":"%s","installed_version":"%s","previous_version":"%s","updating":%s,"conf_dir":"%s","app_dir":"%s","status":%s}\n' \
        "$running" "$tun" "$nat" "$(ts_arch)" "$ver" "$prev" "$(lock_held && echo true || echo false)" "$CONF_DIR" "$APP_DIR" "$st"
}
cmd_login() {
    # The auth key comes from the environment so it never shows up in `ps`; drop it
    # from our environment at once so children (tailscaled, notify loop) don't inherit it.
    key="${TS_AUTHKEY:-}"; unset TS_AUTHKEY
    case "$key" in tskey-*) ;; *) die "that does not look like a Tailscale auth key (expected tskey-...)" ;; esac
    case "$key" in *[!A-Za-z0-9_-]*) die "auth key contains invalid characters" ;; esac
    load_settings
    [ -x "$TSD" ] || die "Tailscale is not downloaded yet; press Start first"
    is_running || cmd_start >/dev/null
    wait_for_socket || die "tailscaled did not come up"
    # An auth key is ignored by 'tailscale up' while already logged in; say so instead of pretending.
    [ "$(backend_state)" = Running ] && die "already connected to a tailnet; press 'Log out of Tailscale' first to switch"
    rm -f "$LOGIN_OUT"
    # The CLI reads the key from a file (--auth-key=file:...), so it never appears in ps/argv.
    keyfile="$STATE_DIR/authkey.$$"
    trap 'rm -f "$keyfile"' EXIT INT TERM
    printf '%s' "$key" > "$keyfile" && chmod 600 "$keyfile" || die "could not write key file"
    # shellcheck disable=SC2046,SC2086
    out="$("$TS" --socket="$SOCK" up --reset --timeout=90s --auth-key="file:$keyfile" $(pref_flags) $TS_EXTRA_UP_ARGS 2>&1)"
    rc=$?
    rm -f "$keyfile"
    log "login rc=$rc: $(echo "$out" | tail -3 | tr '\n' ' ')"
    echo "$out"
    return $rc
}
cmd_login_url() {
    load_settings
    [ -x "$TSD" ] || die "Tailscale is not downloaded yet; press Start first"
    is_running || cmd_start >/dev/null
    wait_for_socket || die "tailscaled did not come up"
    [ "$(backend_state)" = Running ] && { echo "already connected"; return 0; }
    rm -f "$LOGIN_OUT"
    # shellcheck disable=SC2046,SC2086
    nohup "$TS" --socket="$SOCK" up --reset --timeout=600s $(pref_flags) $TS_EXTRA_UP_ARGS > "$LOGIN_OUT" 2>&1 &
    i=0; while [ $i -lt 20 ]; do
        url="$(grep -o 'https://login.tailscale.com/[A-Za-z0-9/_-]*' "$LOGIN_OUT" 2>/dev/null | head -1)"
        [ -n "$url" ] && { echo "$url"; return 0; }
        sleep 1; i=$((i+1))
    done
    echo "pending"
}
cmd_login_url_poll() {
    if [ "$(backend_state)" = Running ]; then rm -f "$LOGIN_OUT"; echo "connected"; return 0; fi
    url="$(grep -o 'https://login.tailscale.com/[A-Za-z0-9/_-]*' "$LOGIN_OUT" 2>/dev/null | head -1)"
    [ -n "$url" ] && echo "$url" || echo "pending"
}
cmd_logout() {
    rm -f "$LOGIN_OUT"
    [ -x "$TS" ] || { echo "not installed"; return 0; }
    is_running || die "daemon not running (start it first to log out)"
    wait_for_socket || die "tailscaled did not answer"
    "$TS" --socket="$SOCK" logout 2>&1
}
cmd_apply() {
    load_settings
    is_running || die "daemon not running"
    # shellcheck disable=SC2046
    "$TS" --socket="$SOCK" set $(pref_flags) 2>&1
}

# --- updates --------------------------------------------------------------
# One updater at a time: mkdir is atomic. The lock holds the pid of the updater.
lock_held() {
    [ -d "$UPDATE_LOCK" ] || return 1
    if [ ! -f "$UPDATE_LOCK/pid" ]; then
        # Being taken right now (mkdir done, pid not written yet) unless it is old.
        [ -n "$(find "$UPDATE_LOCK" -maxdepth 0 -mmin +2 2>/dev/null)" ] || return 0
        rm -rf "$UPDATE_LOCK"; return 1
    fi
    p="$(cat "$UPDATE_LOCK/pid" 2>/dev/null)"
    if [ -n "$p" ] && [ -d "/proc/$p" ] && grep -q "tailscale-ctl" "/proc/$p/cmdline" 2>/dev/null; then return 0; fi
    rm -rf "$UPDATE_LOCK"; return 1       # stale lock from a killed updater (or a reused pid)
}
lock_take() { lock_held && return 1; mkdir "$UPDATE_LOCK" 2>/dev/null || return 1; echo $$ > "$UPDATE_LOCK/pid"; }
lock_release() { rm -rf "$UPDATE_LOCK"; }
# On INT/TERM release the lock and stop; on normal exit just release it.
lock_traps() { trap 'lock_release; trap - EXIT; exit 143' INT TERM; trap lock_release EXIT; }
lock_untrap() { trap - EXIT INT TERM; }
ustat() { echo "$1|$2|$$|$(date +%s)" > "$UPDATE_STATUS"; log "update: $1 $2"; }

latest_version() { # prints version for the configured channel, empty on failure
    load_settings
    fetch "$PKG_BASE/$TS_CHANNEL/?mode=json" "$TMP_DIR/latest.json" || return 1
    v="$(sed -n 's/.*"TarballsVersion":[[:space:]]*"\([^"]*\)".*/\1/p' "$TMP_DIR/latest.json" | head -1)"
    case "$v" in ''|*[!0-9.]*) return 1 ;; esac   # only digits and dots reach alerts, filenames, mails
    echo "$v"
}
cmd_check_update() {
    load_settings
    cur="$(installed_version)"; lat="$(latest_version)"
    err=""; [ -z "$lat" ] && err="could not reach $PKG_BASE (no internet?)"
    avail=false; [ -n "$lat" ] && [ "$lat" != "$cur" ] && avail=true
    printf '{"installed":"%s","latest":"%s","update_available":%s,"channel":"%s","arch":"%s","previous":"%s","error":"%s"}\n' \
        "$cur" "$lat" "$avail" "$TS_CHANNEL" "$(ts_arch)" "$(prev_version)" "$err"
}
cmd_update() {
    load_settings
    want="${1:-}"
    lock_take || { echo "another update is already running"; return 1; }
    lock_traps
    arch="$(ts_arch)"; [ "$arch" = unknown ] && { ustat failed "unsupported CPU: $(uname -m)"; return 1; }
    ustat running "Looking up latest version…"
    if [ -z "$want" ]; then
        # At boot the network may not be up yet: retry for a while.
        i=0; while [ $i -lt 20 ]; do want="$(latest_version)"; [ -n "$want" ] && break; sleep 30; i=$((i+1)); done
    fi
    [ -z "$want" ] && { ustat failed "could not read version list from $PKG_BASE"; return 1; }
    case "$want" in *[!0-9.]*) ustat failed "invalid version string"; return 1 ;; esac
    cur="$(installed_version)"
    if [ "$want" = "$cur" ]; then ustat done "Already on $cur"; return 0; fi
    find "$TMP_DIR" -maxdepth 1 -name 'tailscale_*' -exec rm -rf {} + 2>/dev/null   # leftovers of an interrupted update
    name="tailscale_${want}_${arch}"
    work="${TMP_DIR:?}/${name:?}"
    tgz="$work.tgz"
    rm -rf "$work" "$tgz" "$tgz.sha256"
    ustat running "Downloading $name.tgz…"
    fetch "$PKG_BASE/$TS_CHANNEL/$name.tgz" "$tgz" 150000000 || { ustat failed "download failed"; return 1; }
    ustat running "Verifying checksum…"
    fetch "$PKG_BASE/$TS_CHANNEL/$name.tgz.sha256" "$tgz.sha256" || { ustat failed "could not download checksum"; rm -f "$tgz"; return 1; }
    want_sum="$(cut -d' ' -f1 "$tgz.sha256")"; have_sum="$(sha256_of "$tgz")"
    case "$want_sum" in *[!0-9a-f]*|'') ustat failed "malformed checksum file"; rm -f "$tgz"; return 1 ;; esac
    [ -n "$have_sum" ] || { ustat failed "no sha256 tool on this device"; rm -f "$tgz"; return 1; }
    [ "$want_sum" = "$have_sum" ] || { ustat failed "checksum mismatch"; rm -f "$tgz"; return 1; }
    ustat running "Extracting…"
    # Extract only the two members we need; never let an archive drop other files as root.
    ( cd "$TMP_DIR" && tar xzf "$tgz" "$name/tailscale" "$name/tailscaled" ) || { ustat failed "extract failed"; return 1; }
    for f in "$work/tailscaled" "$work/tailscale"; do
        [ -f "$f" ] && [ ! -L "$f" ] || { ustat failed "archive did not contain the binaries"; rm -rf "$work"; return 1; }
    done
    chmod 755 "$work/tailscaled" "$work/tailscale"
    # Stage first, then swap: the old version is only discarded once the new one is in place.
    new="${CONF_DIR:?}/bin.new"; old="${CONF_DIR:?}/bin.old"
    rm -rf "$new" "$old"; mkdir -p "$new"
    if ! mv "$work/tailscale" "$work/tailscaled" "$new/"; then
        ustat failed "could not stage binaries (disk full?)"; rm -rf "$new" "$work" "$tgz" "$tgz.sha256"; return 1
    fi
    rm -rf "$work" "$tgz" "$tgz.sha256"
    ustat running "Stopping daemon…"
    cmd_stop >/dev/null
    ustat running "Installing $want…"
    # bin/ may exist but be empty on a first install: always move it aside, or mv would nest bin.new inside it.
    if [ -d "$BIN_DIR" ]; then mv "$BIN_DIR" "$old" || { ustat failed "could not move old binaries aside"; return 1; }; fi
    if ! mv "$new" "$BIN_DIR"; then
        [ -d "$old" ] && mv "$old" "$BIN_DIR"
        ustat failed "could not install new binaries"; [ -x "$TSD" ] && cmd_start >/dev/null; return 1
    fi
    if [ -x "$old/tailscaled" ]; then rm -rf "${PREV_DIR:?}"; mv "$old" "$PREV_DIR"; else rm -rf "$old"; fi
    ustat running "Starting daemon…"
    lock_release; lock_untrap
    [ -x "$TSD" ] && cmd_start >/dev/null
    ustat done "Updated ${cur:-nothing} → $(installed_version)"
}
cmd_update_bg() {
    lock_held && { echo "another update is already running"; return 1; }
    echo "running|Starting update…|0|$(date +%s)" > "$UPDATE_STATUS"
    if [ -n "${1:-}" ]; then nohup sh "$SELF" update "$1" >/dev/null 2>&1 &
    else nohup sh "$SELF" update >/dev/null 2>&1 &
    fi
    echo "update started"
}
cmd_update_status() {
    [ -f "$UPDATE_STATUS" ] || { echo "idle|"; return 0; }
    IFS='|' read -r st msg pid ts < "$UPDATE_STATUS"
    if [ "$st" = running ] && ! lock_held; then
        # Updater died (killed, reboot, power loss) without writing a final state.
        age=$(( $(date +%s) - ${ts:-0} ))
        [ "$age" -gt 30 ] && { st=failed; msg="updater stopped unexpectedly (last step: $msg)"; echo "$st|$msg|$pid|$ts" > "$UPDATE_STATUS"; }
    fi
    echo "$st|$msg"
}
cmd_rollback() {
    [ -x "$PREV_DIR/tailscaled" ] || die "no previous version to roll back to"
    lock_take || die "an update is running"
    lock_traps
    cmd_stop >/dev/null
    swap="${TMP_DIR:?}/bin.swap"
    rm -rf "$swap"
    if ! { mv "$BIN_DIR" "$swap" && mv "$PREV_DIR" "$BIN_DIR" && mv "$swap" "$PREV_DIR"; }; then
        [ -d "$BIN_DIR" ] || mv "$swap" "$BIN_DIR" 2>/dev/null
        lock_release; lock_untrap; cmd_start >/dev/null; die "rollback failed, kept $(installed_version)"
    fi
    lock_release; lock_untrap
    cmd_start >/dev/null
    ustat done "Rolled back to $(installed_version)"
    echo "rolled back to $(installed_version)"
}
cmd_log() { n="${1:-80}"; tail -n "$n" "$DAEMON_LOG" 2>/dev/null; echo "--- tailscale-ctl ---"; tail -n 15 "$CTL_LOG" 2>/dev/null; }

# --- app (package) updates ------------------------------------------------
app_version() { sed -n 's/^Version:[[:space:]]*\([0-9.]*\).*/\1/p' "$APP_DIR/apkg.rc" | head -1; }
latest_app_version() { # tag of the latest GitHub release, without the leading v; empty on failure
    fetch "$APP_RELEASES_API" "$TMP_DIR/app_release.json" || return 1
    v="$(sed -n 's/.*"tag_name":[[:space:]]*"v\{0,1\}\([0-9.]*\)".*/\1/p' "$TMP_DIR/app_release.json" | head -1)"
    case "$v" in ''|*[!0-9.]*) return 1 ;; esac
    echo "$v"
}
# "1.0.10" > "1.0.9": compare dot-separated numbers field by field
version_gt() { # version_gt A B  -> true if A > B
    a="$1."; b="$2."
    while [ -n "$a" ] || [ -n "$b" ]; do
        x="${a%%.*}"; y="${b%%.*}"; a="${a#*.}"; b="${b#*.}"
        [ "$(num "$x")" -gt "$(num "$y")" ] && return 0
        [ "$(num "$x")" -lt "$(num "$y")" ] && return 1
    done
    return 1
}
cmd_check_app_update() {
    cur="$(app_version)"; lat="$(latest_app_version)"
    err=""; [ -z "$lat" ] && err="could not reach GitHub"
    avail=false; [ -n "$lat" ] && version_gt "$lat" "$cur" && avail=true
    printf '{"installed":"%s","latest":"%s","update_available":%s,"url":"%s","error":"%s"}\n' "$cur" "$lat" "$avail" "$APP_RELEASES_URL" "$err"
}

# --- update notifications -------------------------------------------------
# Uses the NAS's own alert system (fireAlert): the alert shows under the bell
# icon in the dashboard and is e-mailed when alert e-mails are configured
# (Settings > Notifications). Root's crontab is regenerated by the firmware,
# so a small background loop does the scheduling instead of cron.
notify_loop_pid() {
    [ -f "$NOTIFY_PIDFILE" ] || return 1
    p="$(cat "$NOTIFY_PIDFILE" 2>/dev/null)"
    [ -n "$p" ] && [ -d "/proc/$p" ] && echo "$p"
}
notify_loop_start() {
    notify_loop_pid >/dev/null && return 0
    nohup sh "$SELF" notify-loop >/dev/null 2>&1 &
    echo $! > "$NOTIFY_PIDFILE"
    log "started notify loop pid $!"
}
notify_loop_stop() {
    p="$(notify_loop_pid)"; [ -n "$p" ] && kill "$p" 2>/dev/null
    rm -f "$NOTIFY_PIDFILE"
}
cmd_notify_loop() {
    sleep 180          # let the network come up after boot
    while :; do
        if ! [ -x "$TSD" ]; then
            # First download failed (no network at boot?): keep trying every 10 minutes.
            lock_held || cmd_update_bg "" >/dev/null 2>&1
            sleep 600; continue
        fi
        cmd_notify_check >/dev/null 2>&1
        sleep 21600    # 6 hours
    done
}
send_alert() { # send_alert "text"  (leading space: the firmware pastes %1 right after a full stop)
    if command -v fireAlert >/dev/null 2>&1; then
        fireAlert -a "$ALERT_CODE_APP_UPDATE" -p " $1" -f
    elif command -v sendAlert.sh >/dev/null 2>&1; then
        sendAlert.sh "$ALERT_CODE_APP_UPDATE" " $1"
    else
        log "no alert tool on this firmware: $1"; return 1
    fi
}
notify_state() { [ -f "$NOTIFY_STATE" ] && sed -n "s/^$1=//p" "$NOTIFY_STATE" | head -1; }
notify_state_set() {
    { [ -f "$NOTIFY_STATE" ] && grep -v "^$1=" "$NOTIFY_STATE"; echo "$1=$2"; } > "$NOTIFY_STATE.tmp.$$" 2>/dev/null
    mv -f "$NOTIFY_STATE.tmp.$$" "$NOTIFY_STATE"
}
num() { case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac; }
latest_bulletin() { # id of the first <item> (newest) in Tailscale's security bulletin feed, e.g. TS-2026-011
    fetch "$BULLETIN_FEED" "$TMP_DIR/bulletins.xml" || return 1
    sed -n '/<item>/,/<\/item>/p' "$TMP_DIR/bulletins.xml" | sed -n 's/.*<title>[^<]*\(TS-[0-9][0-9]*-[0-9][0-9]*\)<\/title>.*/\1/p' | head -1
}
cmd_notify_check() {
    load_settings
    now="$(date +%s)"
    notify_state_set LAST_CHECK "$now"
    [ "$TS_NOTIFY" = off ] && { echo "notifications off"; return 0; }
    cur="$(installed_version)"; lat="$(latest_version)"
    [ -z "$lat" ] && { echo "could not fetch latest version"; return 1; }
    bulletin="$(latest_bulletin)"; last_bulletin="$(notify_state LAST_BULLETIN)"
    # First run records the baseline. Later, a bulletin stays "new" until it has been
    # mentioned in an alert, so one seen while still up to date is not forgotten.
    [ -n "$bulletin" ] && [ -z "$last_bulletin" ] && { notify_state_set LAST_BULLETIN "$bulletin"; last_bulletin="$bulletin"; }
    new_bulletin=false; [ -n "$bulletin" ] && [ "$bulletin" != "$last_bulletin" ] && new_bulletin=true
    case "$TS_NOTIFY" in daily) interval=86400 ;; weekly) interval=604800 ;; *) interval=2592000 ;; esac
    # This app itself: a newer package on GitHub gets its own reminder at the same cadence.
    acur="$(app_version)"; alat="$(latest_app_version)"
    if [ -n "$alat" ] && version_gt "$alat" "$acur"; then
        alast="$(num "$(notify_state LAST_APP_NOTIFIED)")"
        if [ $((now - alast)) -ge "$interval" ] || [ "$(notify_state LAST_APP_NOTIFIED_VERSION)" != "$alat" ]; then
            if send_alert "Tailscale app $acur -> $alat is available. Download the .bin for your model from $APP_RELEASES_URL and install it with Apps > Install an app manually (your settings and login are kept)."; then
                notify_state_set LAST_APP_NOTIFIED "$now"; notify_state_set LAST_APP_NOTIFIED_VERSION "$alat"; log "notified app update $acur -> $alat"
            fi
        fi
    fi
    if [ "$lat" = "$cur" ]; then echo "up to date ($cur)"; return 0; fi
    last_at="$(num "$(notify_state LAST_NOTIFIED)")"
    reason=""
    if $new_bulletin; then reason="Tailscale published security bulletin $bulletin"
    elif [ $((now - last_at)) -ge "$interval" ]; then reason="reminder, $TS_NOTIFY"
    fi
    [ -z "$reason" ] && { echo "update $cur -> $lat available, reminder not due yet"; return 0; }
    text="Tailscale ${cur:-?} -> $lat is available for this NAS. Open Apps > Tailscale and press Update now. ($reason)"
    if send_alert "$text"; then
        notify_state_set LAST_NOTIFIED "$now"; notify_state_set LAST_NOTIFIED_VERSION "$lat"
        [ -n "$bulletin" ] && notify_state_set LAST_BULLETIN "$bulletin"
        log "notified: $text"; echo "notified: $text"
    else
        echo "alert failed"; return 1
    fi
}
cmd_notify_test() {
    send_alert "Tailscale app: test notification from the settings page. Installed: $(installed_version). If you can read this in your mailbox, update alerts work." && echo "test alert sent"
}
cmd_notify_status() {
    load_settings
    printf '{"mode":"%s","loop_running":%s,"last_check":"%s","last_notified":"%s","last_notified_version":"%s","last_bulletin":"%s","alert_tool":%s}\n' \
        "$TS_NOTIFY" "$(notify_loop_pid >/dev/null && echo true || echo false)" "$(notify_state LAST_CHECK)" "$(notify_state LAST_NOTIFIED)" "$(notify_state LAST_NOTIFIED_VERSION)" "$(notify_state LAST_BULLETIN)" "$(command -v fireAlert >/dev/null 2>&1 && echo true || echo false)"
}

case "${1:-}" in
    start) cmd_start ;;
    stop) cmd_stop ;;
    restart) cmd_stop; cmd_start ;;
    status) cmd_status ;;
    version) installed_version ;;
    login) cmd_login ;;
    login-url) cmd_login_url ;;
    login-url-poll) cmd_login_url_poll ;;
    logout) cmd_logout ;;
    apply) cmd_apply ;;
    check-update) cmd_check_update ;;
    check-app-update) cmd_check_app_update ;;
    update) cmd_update "${2:-}" ;;
    update-bg) cmd_update_bg "${2:-}" ;;
    update-status) cmd_update_status ;;
    rollback) cmd_rollback ;;
    log) cmd_log "${2:-80}" ;;
    notify-check) cmd_notify_check ;;
    notify-test) cmd_notify_test ;;
    notify-loop) cmd_notify_loop ;;
    notify-status) cmd_notify_status ;;
    weblinks) cmd_weblinks ;;
    paths) echo "APP_DIR=$APP_DIR"; echo "CONF_DIR=$CONF_DIR" ;;
    *) echo "usage: $0 start|stop|restart|status|version|login|login-url|login-url-poll|logout|apply|check-update|update [ver]|update-bg [ver]|update-status|rollback|log [n]|check-app-update|notify-check|notify-test|notify-status|weblinks" >&2; exit 2 ;;
esac
