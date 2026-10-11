<?php
/**
 * api.php: JSON backend for the Tailscale settings page.
 *
 * Runs under the My Cloud web server (Apache + php-fpm, as root). Apache only
 * serves /apps/* to a browser that is logged in to the My Cloud dashboard, so
 * this script relies on that gate. On top of that: mutating actions must be
 * POST requests carrying the X-Requested-With header (blocks cross-site forms),
 * and every value handed to the shell is validated and escaped.
 */

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

$APP_DIR  = dirname(dirname(realpath(__FILE__)));
$CTL      = $APP_DIR . '/bin/tailscale-ctl.sh';
$CONF_DIR = dirname($APP_DIR) . '/tailscale_conf';
$SETTINGS = $CONF_DIR . '/settings.conf';
$APP_VERSION = '1.0.7';
if (preg_match('/^Version:\s*(\S+)/m', @file_get_contents($APP_DIR . '/apkg.rc'), $m)) $APP_VERSION = $m[1];

$SETTING_KEYS = [
    'TS_HOSTNAME', 'TS_ACCEPT_ROUTES', 'TS_ADVERTISE_ROUTES', 'TS_ADVERTISE_EXIT_NODE',
    'TS_ACCEPT_DNS', 'TS_SSH', 'TS_EXTRA_UP_ARGS', 'TS_EXTRA_DAEMON_ARGS', 'TS_CHANNEL', 'TS_NOTIFY',
];

function out($data, $code = 200) {
    http_response_code($code);
    echo json_encode($data, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE);
    exit;
}
function fail($msg, $code = 400) { out(['ok' => false, 'error' => $msg], $code); }

function ctl($args, $timeout = 120, $env = []) {
    global $CTL;
    $cmd = '/bin/sh ' . escapeshellarg($CTL);
    foreach ($args as $a) $cmd .= ' ' . escapeshellarg($a);
    $cmd .= ' 2>&1';
    // The NAS has no 'timeout' binary, so run through proc_open and kill the
    // wrapper ourselves when it takes too long (set_time_limit does not cover exec;
    // long-running children such as curl may outlive us, which is harmless).
    $desc = [0 => ['file', '/dev/null', 'r'], 1 => ['pipe', 'w']];
    // php-fpm hands us an empty $_ENV; give the script a sane PATH plus whatever we add.
    $proc = proc_open($cmd, $desc, $pipes, null, array_merge(['PATH' => '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'], $env));
    if (!is_resource($proc)) return [127, 'could not start ctl script'];
    stream_set_blocking($pipes[1], false);
    $out = ''; $deadline = microtime(true) + $timeout;
    while (true) {
        $out .= (string)stream_get_contents($pipes[1]);
        $st = proc_get_status($proc);
        if (!$st['running']) { $out .= (string)stream_get_contents($pipes[1]); $rc = $st['exitcode']; break; }
        if (microtime(true) > $deadline) { proc_terminate($proc, 9); $rc = 124; $out .= "\n(timed out after {$timeout}s)"; break; }
        usleep(100000);
    }
    fclose($pipes[1]); proc_close($proc);
    return [$rc, trim($out)];
}

function read_settings() {
    global $SETTINGS, $SETTING_KEYS, $APP_DIR;
    $file = file_exists($SETTINGS) ? $SETTINGS : $APP_DIR . '/settings.conf.default';
    $s = array_fill_keys($SETTING_KEYS, '');
    foreach (@file($file, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
        if ($line === '' || $line[0] === '#' || strpos($line, '=') === false) continue;
        [$k, $v] = explode('=', $line, 2);
        if (in_array($k, $SETTING_KEYS, true)) $s[$k] = $v;
    }
    return $s;
}
function write_settings($s) {
    global $SETTINGS, $CONF_DIR;
    if (!is_dir($CONF_DIR)) mkdir($CONF_DIR, 0700, true);
    $txt = "# Tailscale app settings. Edit via the settings page; KEY=VALUE, no quotes.\n";
    foreach ($s as $k => $v) $txt .= "$k=$v\n";
    $tmp = $SETTINGS . '.tmp.' . getmypid();
    if (file_put_contents($tmp, $txt) === false) return false;
    chmod($tmp, 0600);
    return rename($tmp, $SETTINGS);
}

$action = $_GET['action'] ?? 'status';
$mutating = !in_array($action, ['status', 'settings', 'check_update', 'check_app_update', 'update_status', 'login_url_poll', 'log', 'notify_status'], true);
if ($mutating) {
    if ($_SERVER['REQUEST_METHOD'] !== 'POST') fail('POST required', 405);
    if (($_SERVER['HTTP_X_REQUESTED_WITH'] ?? '') !== 'XMLHttpRequest') fail('missing X-Requested-With header', 403);
    // Defence in depth next to the dashboard's own login gate: the request must
    // originate from this NAS's dashboard (Origin or Referer host == Host).
    $src = $_SERVER['HTTP_ORIGIN'] ?? $_SERVER['HTTP_REFERER'] ?? '';
    $srcHost = $src === '' ? '' : (string)parse_url($src, PHP_URL_HOST);
    $host = (string)preg_replace('/:\d+$/', '', $_SERVER['HTTP_HOST'] ?? '');
    $host = trim($host, '[]');
    if ($srcHost === '' || strcasecmp(trim($srcHost, '[]'), $host) !== 0) fail('cross-origin request refused', 403);
    // DNS rebinding: Host and Origin both carry the attacker's name then. Only accept
    // names that really are this NAS: one of its addresses or its own hostname.
    $ownNames = array_filter([$_SERVER['SERVER_ADDR'] ?? '', strtolower((string)gethostname())]);
    $bare = strtolower(preg_replace('/\..*$/', '', $host));   // "mycloud.lan" -> "mycloud"
    if (!in_array(strtolower($host), array_map('strtolower', $ownNames), true) && !in_array($bare, $ownNames, true)) fail('request not addressed to this NAS', 403);
}

switch ($action) {
    case 'status':
        [$rc, $o] = ctl(['status'], 30);
        $data = json_decode($o, true);
        if (!is_array($data)) fail('status failed: ' . $o, 500);
        $data['ok'] = true;
        $data['app_version'] = $APP_VERSION;
        out($data);

    case 'start': case 'stop': case 'restart':
        [$rc, $o] = ctl([$action], 90);
        out(['ok' => $rc === 0, 'output' => $o, 'downloading' => strpos($o, 'downloading') !== false]);

    case 'login':
        $key = trim($_POST['authkey'] ?? '');
        if (!preg_match('/^tskey-[A-Za-z0-9_-]{10,200}$/D', $key)) fail('That does not look like a Tailscale auth key (tskey-…).');
        // Handed to the ctl script in its environment; it writes the key to a 0600 file
        // and passes --auth-key=file:... so the key never appears in the process list.
        [$rc, $o] = ctl(['login'], 150, ['TS_AUTHKEY' => $key]);
        out(['ok' => $rc === 0, 'output' => $o]);

    case 'login_url':
        [$rc, $o] = ctl(['login-url'], 60);
        $url = trim($o);
        out(['ok' => $rc === 0, 'url' => (strpos($url, 'https://') === 0 ? $url : ''), 'pending' => $url === 'pending', 'output' => $o]);

    case 'login_url_poll':
        [$rc, $o] = ctl(['login-url-poll'], 10);
        $url = trim($o);
        out(['ok' => true, 'url' => (strpos($url, 'https://') === 0 ? $url : ''), 'pending' => $url === 'pending', 'connected' => $url === 'connected']);

    case 'logout':
        [$rc, $o] = ctl(['logout'], 60);
        out(['ok' => $rc === 0, 'output' => $o]);

    case 'settings':
        out(['ok' => true, 'settings' => read_settings()]);

    case 'save_settings':
        $cur = read_settings();
        foreach ($SETTING_KEYS as $k) {
            if (!array_key_exists($k, $_POST)) continue;
            $v = trim((string)$_POST[$k]);
            switch ($k) {
                case 'TS_ACCEPT_ROUTES': case 'TS_ADVERTISE_EXIT_NODE': case 'TS_ACCEPT_DNS': case 'TS_SSH':
                    $v = in_array(strtolower($v), ['1', 'true', 'on', 'yes'], true) ? '1' : '0'; break;
                case 'TS_HOSTNAME':
                    if ($v !== '' && !preg_match('/^[A-Za-z0-9][A-Za-z0-9-]{0,62}$/D', $v)) fail('Machine name may only contain letters, digits and dashes.'); break;
                case 'TS_ADVERTISE_ROUTES':
                    $v = preg_replace('/\s+/', '', $v);
                    if ($v !== '' && !preg_match('#^([0-9a-fA-F:.]+/\d{1,3})(,[0-9a-fA-F:.]+/\d{1,3})*$#D', $v)) fail('Advertise routes must be CIDRs separated by commas, e.g. 192.168.1.0/24');
                    break;
                case 'TS_CHANNEL':
                    if (!in_array($v, ['stable', 'unstable'], true)) $v = 'stable'; break;
                case 'TS_NOTIFY':
                    if (!in_array($v, ['off', 'daily', 'weekly', 'monthly'], true)) $v = 'monthly'; break;
                case 'TS_EXTRA_UP_ARGS': case 'TS_EXTRA_DAEMON_ARGS':
                    // Flags only, space separated, no shell metacharacters or line breaks.
                    $v = trim(preg_replace('/[ \t]+/', ' ', $v));
                    if ($v !== '' && !preg_match('/^-{1,2}[A-Za-z0-9][A-Za-z0-9=.,:\/_@+-]*( -{1,2}[A-Za-z0-9][A-Za-z0-9=.,:\/_@+-]*)*$/D', $v)) fail("Extra flags may only contain --flag=value pairs separated by spaces, no shell characters.");
                    // Flags the app sets itself, or that would persist a key in plain text.
                    if (preg_match('/(^| )--?(socket|state|statedir|tun|auth-?key|authkey|reset|timeout|config)(=|$| )/', $v)) fail("That flag is managed by the app and cannot be overridden here.");
                    break;
            }
            $cur[$k] = $v;
        }
        if (!write_settings($cur)) fail('Could not write settings file', 500);
        [$rc, $o] = ctl(['apply'], 60);
        out(['ok' => true, 'applied' => $rc === 0, 'output' => $o, 'settings' => $cur]);

    case 'check_update':
        [$rc, $o] = ctl(['check-update'], 60);
        $data = json_decode($o, true);
        if (!is_array($data)) fail('check failed: ' . $o, 500);
        if (!empty($data['error'])) fail($data['error'], 502);
        $data['ok'] = true;
        out($data);

    case 'check_app_update':
        [$rc, $o] = ctl(['check-app-update'], 60);
        $data = json_decode($o, true);
        if (!is_array($data)) fail('check failed: ' . $o, 500);
        if (!empty($data['error'])) fail($data['error'], 502);
        $data['ok'] = true;
        out($data);

    case 'update':
        $ver = trim($_POST['version'] ?? '');
        if ($ver !== '' && !preg_match('/^\d+\.\d+\.\d+$/D', $ver)) fail('Invalid version');
        [$rc, $o] = ctl($ver === '' ? ['update-bg'] : ['update-bg', $ver], 20);
        out(['ok' => $rc === 0, 'output' => $o]);

    case 'update_status':
        [$rc, $o] = ctl(['update-status'], 10);
        [$state, $msg] = array_pad(explode('|', trim($o), 2), 2, '');
        out(['ok' => true, 'state' => $state, 'message' => $msg]);

    case 'notify_status':
        [$rc, $o] = ctl(['notify-status'], 10);
        $data = json_decode($o, true);
        if (!is_array($data)) fail('notify status failed: ' . $o, 500);
        $data['ok'] = true;
        out($data);

    case 'notify_test':
        [$rc, $o] = ctl(['notify-test'], 30);
        out(['ok' => $rc === 0, 'output' => $o]);

    case 'notify_check':
        [$rc, $o] = ctl(['notify-check'], 60);
        out(['ok' => $rc === 0, 'output' => $o]);

    case 'rollback':
        [$rc, $o] = ctl(['rollback'], 90);
        out(['ok' => $rc === 0, 'output' => $o]);

    case 'log':
        $n = max(10, min(500, (int)($_GET['lines'] ?? 80)));
        [$rc, $o] = ctl(['log', (string)$n], 20);
        out(['ok' => true, 'log' => $o]);

    default:
        fail('unknown action', 404);
}
