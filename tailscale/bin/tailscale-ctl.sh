#!/bin/sh
# tailscale-ctl.sh: single entry point for managing Tailscale on My Cloud OS5.
# Used by the apkg lifecycle scripts (start.sh/stop.sh) and by the settings
# page (web/api.php). POSIX sh only: the NAS runs busybox.
#
#   tailscale-ctl.sh start|stop|restart|status|version
#   tailscale-ctl.sh login <authkey>        connect using a one-off auth key
#   tailscale-ctl.sh login-url              start browser login, prints URL when ready
#   tailscale-ctl.sh login-url-poll         print URL if available
#   tailscale-ctl.sh logout
#   tailscale-ctl.sh apply                  push settings.conf via 'tailscale set'
#   tailscale-ctl.sh check-update           JSON: current/latest/update_available
#   tailscale-ctl.sh update [version]       download+verify+swap binaries
#   tailscale-ctl.sh update-status          print update.status file
#   tailscale-ctl.sh rollback               restore previous binaries
#   tailscale-ctl.sh log [lines]
#   tailscale-ctl.sh notify-check           alert via the My Cloud alert system when an update is due
#   tailscale-ctl.sh notify-test            send a test alert (shows under the bell icon, mails if configured)
#   tailscale-ctl.sh notify-loop            background loop started by 'start', runs notify-check every 6h

set -u

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
LOGIN_OUT="$TMP_DIR/login.out"
PIDFILE="/var/run/tailscale-app.pid"
NOTIFY_PIDFILE="/var/run/tailscale-app-notify.pid"
NOTIFY_STATE="$CONF_DIR/notify.state"
BULLETIN_FEED="https://tailscale.com/security-bulletins/index.xml"
ALERT_CODE_APP_UPDATE=1501   # My Cloud alert "App Update Available", %1 = text
SOCK_DIR="/var/run/tailscale"
SOCK="$SOCK_DIR/tailscaled.sock"
TS="$BIN_DIR/tailscale"
TSD="$BIN_DIR/tailscaled"
PKG_BASE="https://pkgs.tailscale.com"

# Refuse to run with a nonsensical layout (protects every rm below).
case "$CONF_DIR" in */Nas_Prog/tailscale_conf) ;; *) echo "unexpected conf dir: $CONF_DIR" >&2; exit 1 ;; esac

mkdir -p "$BIN_DIR" "$STATE_DIR" "$LOG_DIR" "$TMP_DIR" "$SOCK_DIR" 2>/dev/null
chmod 700 "$STATE_DIR" 2>/dev/null
[ -f "$SETTINGS" ] || cp "$APP_DIR/settings.conf.default" "$SETTINGS" 2>/dev/null

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$CTL_LOG"; }
die() { echo "ERROR: $*" >&2; log "ERROR: $*"; exit 1; }

# --- settings -------------------------------------------------------------
TS_HOSTNAME=""; TS_ACCEPT_ROUTES=0; TS_ADVERTISE_ROUTES=""; TS_ADVERTISE_EXIT_NODE=0
TS_ACCEPT_DNS=1; TS_SSH=0; TS_EXTRA_UP_ARGS=""; TS_EXTRA_DAEMON_ARGS=""; TS_CHANNEL=stable; TS_NOTIFY=monthly
load_settings() {
    [ -f "$SETTINGS" ] || return 0
    # Only accept KEY=VALUE lines with known keys; values are never eval'ed as code.
    while IFS='=' read -r k v; do
        case "$k" in
            TS_HOSTNAME) TS_HOSTNAME="$v" ;;
            TS_ACCEPT_ROUTES) TS_ACCEPT_ROUTES="$v" ;;
            TS_ADVERTISE_ROUTES) TS_ADVERTISE_ROUTES="$v" ;;
            TS_ADVERTISE_EXIT_NODE) TS_ADVERTISE_EXIT_NODE="$v" ;;
            TS_ACCEPT_DNS) TS_ACCEPT_DNS="$v" ;;
            TS_SSH) TS_SSH="$v" ;;
            TS_EXTRA_UP_ARGS) TS_EXTRA_UP_ARGS="$v" ;;
            TS_EXTRA_DAEMON_ARGS) TS_EXTRA_DAEMON_ARGS="$v" ;;
            TS_CHANNEL) TS_CHANNEL="$v" ;;
            TS_NOTIFY) TS_NOTIFY="$v" ;;
        esac
    done < "$SETTINGS"
    case "$TS_CHANNEL" in stable|unstable) ;; *) TS_CHANNEL=stable ;; esac
    case "$TS_NOTIFY" in off|daily|weekly|monthly) ;; *) TS_NOTIFY=monthly ;; esac
}
bool() { case "$1" in 1|true|yes|on) echo true ;; *) echo false ;; esac; }

# WD's kernels ship without the iptables 'nat' table. Tailscale would then log
# a health warning on every start, so tell it not to touch netfilter at all.
# Consequence: no exit node and no SNAT for subnet routes on such devices.
have_nat() { iptables -t nat -L -n >/dev/null 2>&1; }

# Flags shared by 'tailscale up' and 'tailscale set'
pref_flags() {
    have_nat || printf -- '--netfilter-mode=off --snat-subnet-routes=false '
    printf -- '--accept-routes=%s ' "$(bool "$TS_ACCEPT_ROUTES")"
    printf -- '--accept-dns=%s ' "$(bool "$TS_ACCEPT_DNS")"
    printf -- '--advertise-exit-node=%s ' "$(bool "$TS_ADVERTISE_EXIT_NODE")"
    printf -- '--ssh=%s ' "$(bool "$TS_SSH")"
    printf -- '--advertise-routes=%s ' "$TS_ADVERTISE_ROUTES"
    [ -n "$TS_HOSTNAME" ] && printf -- '--hostname=%s ' "$TS_HOSTNAME"
    return 0
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
fetch() { # fetch URL DEST
    if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 3 --connect-timeout 20 -o "$2" "$1"
    else wget -q -O "$2" "$1"; fi
}

# --- daemon ---------------------------------------------------------------
daemon_pid() {
    if [ -f "$PIDFILE" ]; then
        p="$(cat "$PIDFILE" 2>/dev/null)"
        [ -n "$p" ] && [ -d "/proc/$p" ] && grep -q tailscaled "/proc/$p/cmdline" 2>/dev/null && { echo "$p"; return 0; }
    fi
    pgrep -f "$TSD" 2>/dev/null | head -1
}
is_running() { [ -n "$(daemon_pid)" ]; }

installed_version() { [ -x "$TS" ] && "$TS" version 2>/dev/null | head -1; }
prev_version() { [ -x "$PREV_DIR/tailscale" ] && "$PREV_DIR/tailscale" version 2>/dev/null | head -1; }

cmd_start() {
    load_settings
    if ! [ -x "$TSD" ]; then
        log "No tailscale binaries yet, installing latest ($TS_CHANNEL)"
        cmd_update "" || die "could not install Tailscale binaries"
        return 0   # cmd_update starts the daemon
    fi
    if is_running; then echo "already running (pid $(daemon_pid))"; return 0; fi
    tunflag=""
    have_tun || { tunflag="--tun=userspace-networking"; log "no /dev/net/tun, using userspace networking"; }
    # Rotate the daemon log when it grows past ~5 MB
    if [ -f "$DAEMON_LOG" ] && [ "$(wc -c < "$DAEMON_LOG")" -gt 5000000 ]; then mv -f "$DAEMON_LOG" "$DAEMON_LOG.1"; fi
    # shellcheck disable=SC2086
    nohup "$TSD" --state="$STATE_DIR/tailscaled.state" --socket="$SOCK" --statedir="$STATE_DIR" $tunflag $TS_EXTRA_DAEMON_ARGS >> "$DAEMON_LOG" 2>&1 &
    echo $! > "$PIDFILE"
    log "started tailscaled pid $!"
    echo "started (pid $!)"
    notify_loop_start
}
cmd_stop() {
    p="$(daemon_pid)"
    if [ -z "$p" ]; then echo "not running"; rm -f "$PIDFILE"; return 0; fi
    kill "$p" 2>/dev/null
    i=0; while [ $i -lt 10 ] && [ -d "/proc/$p" ]; do sleep 1; i=$((i+1)); done
    [ -d "/proc/$p" ] && kill -9 "$p" 2>/dev/null
    pkill -9 -f "$TSD" 2>/dev/null
    rm -f "$PIDFILE"
    log "stopped tailscaled pid $p"
    echo "stopped"
    notify_loop_stop
}
cmd_status() {
    # Machine-readable status for the settings page.
    running=false; is_running && running=true
    tun=false; have_tun && tun=true
    nat=false; have_nat && nat=true
    ver="$(installed_version)"; prev="$(prev_version)"
    st='{}'
    if $running && [ -x "$TS" ]; then st="$("$TS" --socket="$SOCK" status --json 2>/dev/null || echo '{}')"; fi
    [ -z "$st" ] && st='{}'
    printf '{"daemon_running":%s,"tun":%s,"nat":%s,"arch":"%s","installed_version":"%s","previous_version":"%s","conf_dir":"%s","app_dir":"%s","status":%s}\n' \
        "$running" "$tun" "$nat" "$(ts_arch)" "$ver" "$prev" "$CONF_DIR" "$APP_DIR" "$st"
}
cmd_login() {
    key="$1"
    case "$key" in
        tskey-*) ;;
        *) die "that does not look like a Tailscale auth key (expected tskey-...)" ;;
    esac
    case "$key" in *[!A-Za-z0-9_-]*) die "auth key contains invalid characters" ;; esac
    load_settings
    is_running || cmd_start >/dev/null
    sleep 2
    # shellcheck disable=SC2046,SC2086
    out="$("$TS" --socket="$SOCK" up --reset --timeout=90s --auth-key="$key" $(pref_flags) $TS_EXTRA_UP_ARGS 2>&1)"
    rc=$?
    log "login rc=$rc: $(echo "$out" | tail -3 | tr '\n' ' ')"
    echo "$out"
    return $rc
}
cmd_login_url() {
    load_settings
    is_running || cmd_start >/dev/null
    sleep 2
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
    url="$(grep -o 'https://login.tailscale.com/[A-Za-z0-9/_-]*' "$LOGIN_OUT" 2>/dev/null | head -1)"
    [ -n "$url" ] && echo "$url" || echo "pending"
}
cmd_logout() { "$TS" --socket="$SOCK" logout 2>&1; }
cmd_apply() {
    load_settings
    is_running || die "daemon not running"
    # shellcheck disable=SC2046
    "$TS" --socket="$SOCK" set $(pref_flags) 2>&1
}

# --- updates --------------------------------------------------------------
latest_version() { # prints version for the configured channel, empty on failure
    load_settings
    fetch "$PKG_BASE/$TS_CHANNEL/?mode=json" "$TMP_DIR/latest.json" || return 1
    # Extract "TarballsVersion":"1.2.3" without needing jq
    sed -n 's/.*"TarballsVersion":[[:space:]]*"\([^"]*\)".*/\1/p' "$TMP_DIR/latest.json" | head -1
}
cmd_check_update() {
    load_settings
    cur="$(installed_version)"; lat="$(latest_version)"
    avail=false; [ -n "$lat" ] && [ "$lat" != "$cur" ] && avail=true
    printf '{"installed":"%s","latest":"%s","update_available":%s,"channel":"%s","arch":"%s","previous":"%s"}\n' \
        "$cur" "$lat" "$avail" "$TS_CHANNEL" "$(ts_arch)" "$(prev_version)"
}
ustat() { echo "$1|$2" > "$UPDATE_STATUS"; log "update: $1 $2"; }
cmd_update() {
    load_settings
    want="${1:-}"
    arch="$(ts_arch)"; [ "$arch" = unknown ] && { ustat failed "unsupported CPU: $(uname -m)"; return 1; }
    ustat running "Looking up latest version…"
    [ -z "$want" ] && want="$(latest_version)"
    [ -z "$want" ] && { ustat failed "could not read version list from $PKG_BASE"; return 1; }
    case "$want" in *[!0-9.]*) ustat failed "invalid version string"; return 1 ;; esac
    cur="$(installed_version)"
    if [ "$want" = "$cur" ]; then ustat done "Already on $cur"; return 0; fi
    name="tailscale_${want}_${arch}"
    work="${TMP_DIR:?}/${name:?}"
    tgz="$work.tgz"
    rm -rf "$work" "$tgz" "$tgz.sha256"
    ustat running "Downloading $name.tgz…"
    fetch "$PKG_BASE/$TS_CHANNEL/$name.tgz" "$tgz" || { ustat failed "download failed"; return 1; }
    ustat running "Verifying checksum…"
    if fetch "$PKG_BASE/$TS_CHANNEL/$name.tgz.sha256" "$tgz.sha256"; then
        want_sum="$(cut -d' ' -f1 "$tgz.sha256")"; have_sum="$(sha256_of "$tgz")"
        if [ -n "$have_sum" ] && [ "$want_sum" != "$have_sum" ]; then ustat failed "checksum mismatch"; rm -f "$tgz"; return 1; fi
    else
        log "warning: no .sha256 file available, skipping verification"
    fi
    ustat running "Extracting…"
    ( cd "$TMP_DIR" && tar xzf "$tgz" ) || { ustat failed "extract failed"; return 1; }
    [ -x "$work/tailscaled" ] && [ -x "$work/tailscale" ] || { ustat failed "archive did not contain the binaries"; return 1; }
    ustat running "Stopping daemon…"
    cmd_stop >/dev/null
    ustat running "Installing $want…"
    rm -rf "${PREV_DIR:?}"
    [ -x "$TSD" ] && mv "$BIN_DIR" "$PREV_DIR"
    mkdir -p "$BIN_DIR"
    mv "$work/tailscale" "$work/tailscaled" "$BIN_DIR/"
    chmod 755 "$BIN_DIR"/*
    rm -rf "$work" "$tgz" "$tgz.sha256"
    ustat running "Starting daemon…"
    cmd_start >/dev/null
    ustat done "Updated ${cur:-nothing} → $(installed_version)"
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
        cmd_notify_check >/dev/null 2>&1
        sleep 21600    # 6 hours
    done
}
send_alert() { # send_alert "text"
    if command -v fireAlert >/dev/null 2>&1; then
        fireAlert -a "$ALERT_CODE_APP_UPDATE" -p " $1" -f
    elif command -v sendAlert.sh >/dev/null 2>&1; then
        sendAlert.sh "$ALERT_CODE_APP_UPDATE" " $1"
    else
        log "no alert tool on this firmware: $1"; return 1
    fi
}
notify_state() { # notify_state KEY -> value
    [ -f "$NOTIFY_STATE" ] && sed -n "s/^$1=//p" "$NOTIFY_STATE" | head -1
}
notify_state_set() { # notify_state_set KEY VALUE
    { [ -f "$NOTIFY_STATE" ] && grep -v "^$1=" "$NOTIFY_STATE"; echo "$1=$2"; } > "$NOTIFY_STATE.tmp" 2>/dev/null
    mv -f "$NOTIFY_STATE.tmp" "$NOTIFY_STATE"
}
latest_bulletin() { # newest security bulletin id from Tailscale's RSS feed, e.g. TS-2026-011
    fetch "$BULLETIN_FEED" "$TMP_DIR/bulletins.xml" || return 1
    sed -n 's/.*<title>\(TS-[0-9][0-9-]*\)<\/title>.*/\1/p' "$TMP_DIR/bulletins.xml" | head -1
}
cmd_notify_check() {
    load_settings
    now="$(date +%s)"
    notify_state_set LAST_CHECK "$now"
    [ "$TS_NOTIFY" = off ] && { echo "notifications off"; return 0; }
    cur="$(installed_version)"; lat="$(latest_version)"
    [ -z "$lat" ] && { echo "could not fetch latest version"; return 1; }
    bulletin="$(latest_bulletin)"; last_bulletin="$(notify_state LAST_BULLETIN)"
    new_bulletin=false
    if [ -n "$bulletin" ] && [ "$bulletin" != "$last_bulletin" ]; then
        notify_state_set LAST_BULLETIN "$bulletin"
        # First run only records the baseline; afterwards a new bulletin counts as urgent.
        [ -n "$last_bulletin" ] && new_bulletin=true
    fi
    if [ "$lat" = "$cur" ]; then echo "up to date ($cur)"; return 0; fi
    case "$TS_NOTIFY" in daily) interval=86400 ;; weekly) interval=604800 ;; *) interval=2592000 ;; esac
    last_at="$(notify_state LAST_NOTIFIED)"; last_at="${last_at:-0}"
    last_ver="$(notify_state LAST_NOTIFIED_VERSION)"
    reason=""
    if $new_bulletin; then reason="Tailscale published security bulletin $bulletin"
    elif [ $((now - last_at)) -ge "$interval" ] || [ "$lat" != "$last_ver" ] && [ $((now - last_at)) -ge 86400 ]; then reason="periodic reminder ($TS_NOTIFY)"
    fi
    [ -z "$reason" ] && { echo "update $cur -> $lat available, reminder not due yet"; return 0; }
    text="Tailscale ${cur:-?} -> $lat is available for this NAS. Open Apps > Tailscale and press Update now. ($reason)"
    if send_alert "$text"; then
        notify_state_set LAST_NOTIFIED "$now"; notify_state_set LAST_NOTIFIED_VERSION "$lat"
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

cmd_update_status() { [ -f "$UPDATE_STATUS" ] && cat "$UPDATE_STATUS" || echo "idle|"; }
cmd_rollback() {
    [ -x "$PREV_DIR/tailscaled" ] || die "no previous version to roll back to"
    cmd_stop >/dev/null
    swap="${TMP_DIR:?}/bin.swap"
    rm -rf "$swap"; mv "$BIN_DIR" "$swap"; mv "$PREV_DIR" "$BIN_DIR"; mv "$swap" "$PREV_DIR"
    cmd_start >/dev/null
    echo "rolled back to $(installed_version)"
}
cmd_log() { n="${1:-80}"; tail -n "$n" "$DAEMON_LOG" 2>/dev/null; echo "--- tailscale-ctl ---"; tail -n 15 "$CTL_LOG" 2>/dev/null; }

case "${1:-}" in
    start) cmd_start ;;
    stop) cmd_stop ;;
    restart) cmd_stop; cmd_start ;;
    status) cmd_status ;;
    version) installed_version ;;
    login) cmd_login "${2:-}" ;;
    login-url) cmd_login_url ;;
    login-url-poll) cmd_login_url_poll ;;
    logout) cmd_logout ;;
    apply) cmd_apply ;;
    check-update) cmd_check_update ;;
    update) cmd_update "${2:-}" ;;
    update-status) cmd_update_status ;;
    rollback) cmd_rollback ;;
    log) cmd_log "${2:-80}" ;;
    notify-check) cmd_notify_check ;;
    notify-test) cmd_notify_test ;;
    notify-loop) cmd_notify_loop ;;
    notify-status) cmd_notify_status ;;
    paths) echo "APP_DIR=$APP_DIR"; echo "CONF_DIR=$CONF_DIR" ;;
    *) echo "usage: $0 start|stop|restart|status|version|login <key>|login-url|login-url-poll|logout|apply|check-update|update [ver]|update-status|rollback|log [n]|notify-check|notify-test|notify-status" >&2; exit 2 ;;
esac
