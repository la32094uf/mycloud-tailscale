/* Settings page logic for the Tailscale app (loaded inside the My Cloud dashboard). */
(function () {
  'use strict';
  var API = '/apps/tailscale/api.php';
  var root = document.getElementById('ts-app');
  if (!root || root.dataset.booted) return;
  root.dataset.booted = '1';

  function $(id) { return document.getElementById(id); }
  function esc(s) { return String(s == null ? '' : s).replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }

  var toastTimer;
  function toast(msg, isError) {
    var t = $('ts-toast');
    t.textContent = msg;
    t.className = 'ts-show' + (isError ? ' ts-error' : '');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { t.className = ''; }, isError ? 8000 : 3500);
  }

  function alive() { return document.body.contains(root); }

  function api(action, data, method) {
    var opts = { method: method || (data ? 'POST' : 'GET'), headers: { 'X-Requested-With': 'XMLHttpRequest' }, credentials: 'same-origin' };
    var url = API + '?action=' + encodeURIComponent(action);
    if (data) {
      var body = new URLSearchParams();
      Object.keys(data).forEach(function (k) { body.append(k, data[k]); });
      opts.body = body;
      opts.headers['Content-Type'] = 'application/x-www-form-urlencoded';
    }
    return fetch(url, opts).then(function (r) {
      return r.text().then(function (txt) {
        var j; try { j = JSON.parse(txt); } catch (e) { throw new Error('Unexpected reply (' + r.status + '): ' + txt.slice(0, 200)); }
        if (!j.ok && j.error) throw new Error(j.error);
        return j;
      });
    });
  }

  function busy(on) {
    root.querySelectorAll('button').forEach(function (b) { if (!b.dataset.keep) b.disabled = on; });
    if (!on) refreshUpdateButtons();
  }

  // ---- status -----------------------------------------------------------
  var lastUpdate = null;
  function badge(state) {
    var map = { Running: 'ts-green', NeedsLogin: 'ts-orange', NeedsMachineAuth: 'ts-orange', Stopped: 'ts-gray', Starting: 'ts-blue', NoState: 'ts-gray' };
    return map[state] || 'ts-gray';
  }
  function loadStatus() {
    return api('status').then(function (s) {
      $('ts-app-version').textContent = 'v' + (s.app_version || '');
      var st = s.status || {};
      var self = st.Self || {};
      var state = s.daemon_running ? (st.BackendState || 'Starting') : 'Stopped';
      var label = state;
      if (state === 'NeedsLogin') label = 'Needs login';
      if (state === 'NeedsMachineAuth') label = 'Waiting for admin approval';
      if (state === 'Running') label = 'Connected';
      var b = $('ts-state'); b.textContent = label; b.className = 'ts-badge ' + badge(state);
      $('ts-ip').textContent = (st.TailscaleIPs || []).join(', ') || '–';
      $('ts-dns').textContent = self.DNSName ? self.DNSName.replace(/\.$/, '') : (self.HostName || '–');
      $('ts-tailnet').textContent = (st.CurrentTailnet && st.CurrentTailnet.Name) || (st.MagicDNSSuffix || '–');
      $('ts-daemon').textContent = (s.daemon_running ? 'running' : 'stopped') + (s.tun ? ' · kernel TUN' : ' · userspace networking') + (s.nat === false ? ' · no NAT table' : '') + ' · ' + s.arch;
      var exitEl = form.elements['TS_ADVERTISE_EXIT_NODE'];
      if (s.nat === false) {
        exitEl.checked = false; exitEl.disabled = true;
        $('ts-nat-note').style.display = '';
      }
      $('ts-version').textContent = s.installed_version || 'not installed yet (press Start to download)';
      var health = (st.Health || []).filter(Boolean);
      $('ts-health').innerHTML = health.length ? '<span class="ts-warn">' + health.map(esc).join('<br>') + '</span>' : (state === 'Running' ? 'OK' : '–');
      $('ts-upd-current').textContent = s.installed_version || '–';
      $('ts-upd-prev').textContent = s.previous_version || '–';
      $('ts-rollback-btn').disabled = !s.previous_version;
      return s;
    }).catch(function (e) { toast(e.message, true); });
  }

  root.querySelectorAll('button[data-act]').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var act = btn.dataset.act;
      if (act === 'status') { loadStatus(); return; }
      busy(true);
      api(act, {}).then(function (r) {
        toast(r.output || (act + ' done'), !r.ok);
        if (r.downloading) { $('ts-upd-log').textContent = ''; watchUpdate(); return 'watching'; }
      }).catch(function (e) { toast(e.message, true); })
        .then(function (w) { if (w !== 'watching') { busy(false); return loadStatus(); } });
    });
  });

  // ---- login ------------------------------------------------------------
  $('ts-login-btn').addEventListener('click', function () {
    var key = $('ts-authkey').value.trim();
    if (!/^tskey-/.test(key)) { toast('Paste a Tailscale auth key first (starts with tskey-).', true); return; }
    busy(true); toast('Connecting… this can take up to a minute.');
    api('login', { authkey: key }).then(function (r) {
      $('ts-authkey').value = '';
      toast(r.ok ? 'Connected to Tailscale.' : ('Login failed: ' + r.output), !r.ok);
    }).catch(function (e) { toast(e.message, true); })
      .then(function () { busy(false); return loadStatus(); });
  });

  var urlPoll;
  function showLoginUrl(url) {
    $('ts-loginurl').innerHTML = '<a href="' + esc(url) + '" target="_blank" rel="noopener">' + esc(url) + '</a><br><small>Open the link, approve the machine, then press Refresh.</small>';
  }
  $('ts-loginurl-btn').addEventListener('click', function () {
    busy(true); $('ts-loginurl').textContent = 'Requesting login link…';
    api('login_url', {}).then(function (r) {
      if (r.url) { showLoginUrl(r.url); return; }
      if (/already connected/.test(r.output || '')) { $('ts-loginurl').textContent = 'Already connected. Log out first to switch tailnet.'; return; }
      var tries = 0;
      clearInterval(urlPoll);
      urlPoll = setInterval(function () {
        if (!alive()) { clearInterval(urlPoll); return; }
        api('login_url_poll').then(function (p) {
          if (p.connected) { clearInterval(urlPoll); $('ts-loginurl').textContent = 'Connected.'; loadStatus(); }
          else if (p.url) { clearInterval(urlPoll); showLoginUrl(p.url); }
          else if (++tries > 30) { clearInterval(urlPoll); $('ts-loginurl').textContent = 'No link received. Check the log below.'; }
        });
      }, 2000);
    }).catch(function (e) { toast(e.message, true); $('ts-loginurl').textContent = ''; })
      .then(function () { busy(false); });
  });

  $('ts-logout-btn').addEventListener('click', function () {
    if (!window.confirm('Log this NAS out of your tailnet? You will need a new auth key or login link to reconnect.')) return;
    busy(true);
    api('logout', {}).then(function (r) { toast(r.ok ? 'Logged out.' : r.output, !r.ok); })
      .catch(function (e) { toast(e.message, true); })
      .then(function () { busy(false); return loadStatus(); });
  });

  var form = $('ts-settings-form');

  // ---- settings ---------------------------------------------------------
  function loadSettings() {
    return api('settings').then(function (r) {
      Object.keys(r.settings).forEach(function (k) {
        var el = form.elements[k]; if (!el) return;
        if (el.type === 'checkbox') el.checked = r.settings[k] === '1'; else el.value = r.settings[k];
      });
    }).catch(function (e) { toast(e.message, true); });
  }
  $('ts-save-btn').addEventListener('click', function () {
    var data = {};
    Array.prototype.forEach.call(form.elements, function (el) {
      if (!el.name) return;
      data[el.name] = el.type === 'checkbox' ? (el.checked ? '1' : '0') : el.value;
    });
    busy(true);
    api('save_settings', data).then(function (r) {
      toast(r.applied ? 'Settings saved and applied.' : 'Settings saved. ' + (r.output ? 'Not applied: ' + r.output : 'They apply at next login.'), false);
    }).catch(function (e) { toast(e.message, true); })
      .then(function () { busy(false); return loadStatus(); });
  });

  // ---- updates ----------------------------------------------------------
  function refreshUpdateButtons() {
    $('ts-update-btn').disabled = !(lastUpdate && lastUpdate.update_available);
  }
  $('ts-check-btn').addEventListener('click', function () {
    busy(true); $('ts-upd-latest').textContent = 'checking…';
    api('check_update').then(function (r) {
      lastUpdate = r;
      $('ts-upd-current').textContent = r.installed || '–';
      $('ts-upd-latest').textContent = (r.latest || 'unknown') + ' (' + r.channel + ', ' + r.arch + ')';
      toast(r.update_available ? 'Update available: ' + r.latest : 'You are on the latest version.');
    }).catch(function (e) { toast(e.message, true); $('ts-upd-latest').textContent = '–'; })
      .then(function () { busy(false); });
  });

  var updPoll;
  function watchUpdate() {
    clearInterval(updPoll);
    var log = $('ts-upd-log'); var last = ''; var polls = 0;
    busy(true);
    updPoll = setInterval(function () {
      if (!alive()) { clearInterval(updPoll); return; }
      if (++polls > 900) { clearInterval(updPoll); busy(false); toast('Stopped waiting for the update; press Refresh.', true); return; }
      api('update_status').then(function (r) {
        var line = r.state + ': ' + r.message;
        if (line !== last) { log.textContent += line + '\n'; last = line; log.scrollTop = log.scrollHeight; }
        if (r.state !== 'running') {
          clearInterval(updPoll); busy(false); lastUpdate = null; refreshUpdateButtons();
          toast(r.message, r.state === 'failed');
          loadStatus();
        }
      }).catch(function (e) { clearInterval(updPoll); busy(false); toast(e.message, true); });
    }, 2000);
  }
  $('ts-update-btn').addEventListener('click', function () {
    if (!lastUpdate || !lastUpdate.update_available) return;
    if (!window.confirm('Update Tailscale ' + lastUpdate.installed + ' → ' + lastUpdate.latest + '? The connection drops for a few seconds.')) return;
    busy(true); $('ts-upd-log').textContent = '';
    api('update', { version: lastUpdate.latest }).then(watchUpdate).catch(function (e) { busy(false); toast(e.message, true); });
  });
  $('ts-rollback-btn').addEventListener('click', function () {
    if (!window.confirm('Roll back to the previous Tailscale version?')) return;
    busy(true);
    api('rollback', {}).then(function (r) { toast(r.output, !r.ok); })
      .catch(function (e) { toast(e.message, true); })
      .then(function () { busy(false); return loadStatus(); });
  });

  // ---- notifications ----------------------------------------------------
  function fmtTs(t) { return t ? new Date(parseInt(t, 10) * 1000).toLocaleString() : 'never'; }
  function loadNotify() {
    return api('notify_status').then(function (r) {
      $('ts-notify').value = r.mode || 'monthly';
      var info = 'Last check: ' + fmtTs(r.last_check) + ' · last alert: ' + fmtTs(r.last_notified) + (r.last_notified_version ? ' (for ' + r.last_notified_version + ')' : '') +
        ' · newest bulletin seen: ' + (r.last_bulletin || '–') + (r.loop_running ? '' : ' · scheduler not running (start the app)') +
        (r.alert_tool ? '' : ' · this firmware has no alert tool');
      $('ts-notify-info').textContent = info;
    }).catch(function (e) { $('ts-notify-info').textContent = e.message; });
  }
  $('ts-notify-save-btn').addEventListener('click', function () {
    busy(true);
    api('save_settings', { TS_NOTIFY: $('ts-notify').value }).then(function () { toast('Notification setting saved.'); })
      .catch(function (e) { toast(e.message, true); })
      .then(function () { busy(false); return loadNotify(); });
  });
  $('ts-notify-test-btn').addEventListener('click', function () {
    busy(true);
    api('notify_test', {}).then(function (r) { toast(r.ok ? 'Test alert sent. Check the bell icon and your mailbox.' : r.output, !r.ok); })
      .catch(function (e) { toast(e.message, true); })
      .then(function () { busy(false); });
  });
  $('ts-notify-check-btn').addEventListener('click', function () {
    busy(true);
    api('notify_check', {}).then(function (r) { toast(r.output || 'checked', !r.ok); })
      .catch(function (e) { toast(e.message, true); })
      .then(function () { busy(false); return loadNotify(); });
  });

  // ---- log --------------------------------------------------------------
  function loadLog() {
    return api('log').then(function (r) { var l = $('ts-log'); l.textContent = r.log || '(empty)'; l.scrollTop = l.scrollHeight; })
      .catch(function (e) { toast(e.message, true); });
  }
  $('ts-log-btn').addEventListener('click', loadLog);

  // ---- app (package) update -------------------------------------------
  function checkAppUpdate() {
    api('check_app_update').then(function (r) {
      var el = $('ts-app-update');
      if (r.update_available) {
        el.innerHTML = '<strong class="ts-warn">App update available: ' + esc(r.latest) + '</strong> · <a href="' + esc(r.url) + '" target="_blank" rel="noopener">download</a> and install it via Apps → Install an app manually (settings and login are kept)';
      } else {
        el.textContent = 'app is up to date';
      }
    }).catch(function (e) { $('ts-app-update').textContent = 'app update check: ' + e.message; });
  }

  // ---- boot -------------------------------------------------------------
  loadStatus().then(function (s) {
    // If an update/download was in flight when the page opened, keep following it.
    if (s && s.updating) { $('ts-upd-log').textContent = ''; watchUpdate(); }
  });
  loadSettings();
  loadNotify();
  loadLog();
  checkAppUpdate();
})();
