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
      loginBanner(s);
      lastStatus = s; loginCard(s);
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
      $('ts-auto-update').checked = r.auto_update === true;
      var info = 'Last check: ' + fmtTs(r.last_check) + ' · last alert: ' + fmtTs(r.last_notified) + (r.last_notified_version ? ' (for ' + r.last_notified_version + ')' : '') +
        ' · newest bulletin seen: ' + (r.last_bulletin || '–') + (r.key_days_left !== '' ? ' · machine key expires in ' + r.key_days_left + ' days' : '') + (r.loop_running ? '' : ' · scheduler not running (start the app)') +
        (r.alert_tool ? '' : ' · this firmware has no alert tool');
      $('ts-notify-info').textContent = info;
    }).catch(function (e) { $('ts-notify-info').textContent = e.message; });
  }
  $('ts-auto-update').addEventListener('change', function () {
    var on = $('ts-auto-update').checked;
    busy(true);
    api('save_settings', { TS_AUTO_UPDATE: on ? '1' : '0' }).then(function () { toast(on ? 'Tailscale updates will be installed automatically.' : 'Automatic updates off.'); })
      .catch(function (e) { toast(e.message, true); })
      .then(function () { busy(false); return loadNotify(); });
  });
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

  // ---- banner (login problems, key expiry, app update) ------------------
  var bannerParts = {};
  function renderBanner() {
    var b = $('ts-banner'); var keys = Object.keys(bannerParts);
    if (!keys.length) { b.style.display = 'none'; b.innerHTML = ''; return; }
    var red = keys.some(function (k) { return bannerParts[k].red; });
    b.className = 'ts-banner' + (red ? ' ts-banner-red' : '');
    b.innerHTML = keys.map(function (k) { return '<div>' + bannerParts[k].html + '</div>'; }).join('');
    b.style.display = '';
  }
  function setBanner(key, html, red) { if (html) bannerParts[key] = { html: html, red: !!red }; else delete bannerParts[key]; renderBanner(); }

  // Login card: compact when connected, full instructions otherwise.
  var loginFormRequested = false;
  function loginCard(s) {
    var st = s.status || {}; var self = st.Self || {};
    var connected = s.daemon_running && st.BackendState === 'Running';
    $('ts-login-connected').style.display = connected ? '' : 'none';
    $('ts-login-form').style.display = (!connected || loginFormRequested) ? '' : 'none';
    $('ts-login-switch-note').style.display = (connected && loginFormRequested) ? '' : 'none';
    $('ts-login-show-btn').textContent = loginFormRequested ? 'Hide login options' : 'Log in with another account…';
    if (connected) {
      var users = st.User || {}; var u = users[self.UserID] || {};
      $('ts-login-user').textContent = u.LoginName || (st.CurrentTailnet && st.CurrentTailnet.Name) || 'your tailnet';
      var exp = self.KeyExpiry ? new Date(self.KeyExpiry) : null;
      $('ts-login-expiry').textContent = exp && exp.getFullYear() > 2000 ? ' · machine key valid until ' + exp.toLocaleDateString() : ' · key expiry disabled';
    } else {
      loginFormRequested = false;
    }
  }
  var lastStatus = null;
  $('ts-login-show-btn').addEventListener('click', function () {
    loginFormRequested = !loginFormRequested;
    if (lastStatus) loginCard(lastStatus);
  });

  function loginBanner(s) {
    var st = s.status || {}; var self = st.Self || {};
    var state = s.daemon_running ? (st.BackendState || '') : 'Stopped';
    if (state === 'NeedsLogin') {
      setBanner('login', '<strong>Tailscale is logged out.</strong> This NAS is not reachable through your tailnet until you log in again: paste a new auth key below or use the browser login link. If you did not log out yourself, the machine key has probably expired (see the Login section).', true);
    } else if (state === 'NeedsMachineAuth') {
      setBanner('login', '<strong>Waiting for approval.</strong> Approve this machine in the Tailscale admin console (Machines) to finish connecting.', false);
    } else if (state === 'Running' && self.KeyExpiry) {
      var days = (new Date(self.KeyExpiry) - new Date()) / 86400000;
      if (days < 14) {
        setBanner('login', '<strong>Machine key expires ' + (days < 1 ? 'today' : 'in ' + Math.floor(days) + ' days') + '</strong> (' + esc(new Date(self.KeyExpiry).toLocaleDateString()) + '). After that the NAS drops off your tailnet until you log in again. To avoid this, open the machine in the <a href="https://login.tailscale.com/admin/machines" target="_blank" rel="noopener">Tailscale admin console</a> and choose "Disable key expiry", or log in again with a new auth key.', days < 3);
      } else setBanner('login', null);
    } else setBanner('login', null);
  }

  // ---- dashboard over the tailnet ---------------------------------------
  function loadServe() {
    return api('serve_status').then(function (r) {
      $('ts-serve').checked = r.enabled === true;
      var el = $('ts-serve-info');
      if (r.enabled && r.active && r.url) el.innerHTML = 'Dashboard URL on your tailnet: <a href="' + esc(r.url) + '" target="_blank" rel="noopener">' + esc(r.url) + '</a> (from any device where Tailscale is connected; MagicDNS must be on). Use this short name: browsers force HTTPS for the long ' + esc(r.fqdn || '…ts.net') + ' name, and this proxy is plain HTTP inside the already encrypted tailnet.';
      else if (r.enabled) el.textContent = 'Enabled; it becomes active once Tailscale is connected.';
      else el.textContent = '';
    }).catch(function (e) { $('ts-serve-info').textContent = e.message; });
  }
  $('ts-serve').addEventListener('change', function () {
    var on = $('ts-serve').checked;
    busy(true);
    api('save_settings', { TS_SERVE_DASHBOARD: on ? '1' : '0' }).then(function () { toast(on ? 'Dashboard published on your tailnet.' : 'Dashboard no longer published on the tailnet.'); })
      .catch(function (e) { toast(e.message, true); })
      .then(function () { busy(false); return loadServe(); });
  });

  // ---- app (package) update -------------------------------------------
  function checkAppUpdate() {
    api('check_app_update').then(function (r) {
      var el = $('ts-app-update');
      if (r.update_available) {
        el.textContent = 'newer app version available: ' + r.latest;
        setBanner('app', '<strong>New version of this app: ' + esc(r.latest) + '</strong> (you have ' + esc(r.installed) + '). <a href="' + esc(r.url) + '" target="_blank" rel="noopener">Download the .bin for your model</a>, then install it via Apps → Install an app manually. Your login and settings are kept.', false);
      } else {
        el.textContent = 'app is up to date';
        setBanner('app', null);
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
  loadServe();
  loadLog();
  checkAppUpdate();
})();
