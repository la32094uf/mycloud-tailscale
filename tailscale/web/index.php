<?php
// Settings page for the Tailscale app. CenterType=1 apps are loaded as an HTML
// fragment inside the My Cloud dashboard, so this file has no <html>/<head>.
// Access is protected by the My Cloud login (Apache returns 403 otherwise).
$v = '0';
if (preg_match('/^Version:\s*(\S+)/m', @file_get_contents(dirname(dirname(realpath(__FILE__))) . '/apkg.rc'), $m)) $v = $m[1];
?>
<script>(function(){if(!document.getElementById('ts-css')){var l=document.createElement('link');l.id='ts-css';l.rel='stylesheet';l.href='/apps/tailscale/tailscale.css?v='+<?php echo json_encode(rawurlencode($v)); ?>;document.head.appendChild(l);}})();</script>
<div id="ts-app">
  <div class="ts-row">
    <div class="ts-card" id="ts-status-card">
      <h3>Status <span id="ts-state" class="ts-badge ts-gray">loading…</span></h3>
      <table class="ts-kv">
        <tr><th>Tailscale IP</th><td id="ts-ip">–</td></tr>
        <tr><th>Machine name</th><td id="ts-dns">–</td></tr>
        <tr><th>Tailnet</th><td id="ts-tailnet">–</td></tr>
        <tr><th>Daemon</th><td id="ts-daemon">–</td></tr>
        <tr><th>Version</th><td id="ts-version">–</td></tr>
        <tr><th>Health</th><td id="ts-health">–</td></tr>
      </table>
      <div class="ts-actions">
        <button class="ts-btn" data-act="start">Start</button>
        <button class="ts-btn" data-act="stop">Stop</button>
        <button class="ts-btn" data-act="restart">Restart</button>
        <button class="ts-btn ts-secondary" data-act="status">Refresh</button>
      </div>
    </div>

    <div class="ts-card" id="ts-login-card">
      <h3>Login</h3>
      <p class="ts-help">Go to <a href="https://login.tailscale.com/admin/settings/keys" target="_blank" rel="noopener">Tailscale admin → Settings → Keys</a>, press <strong>Generate auth key</strong>, copy the key that appears and paste it here. The <em>expiration</em> you choose there only limits how long the key can be used to connect a machine, not how long this NAS stays logged in. Leave "Ephemeral" off. The key is written to a root-only temporary file during login and deleted right after; it is not kept.</p>
      <div class="ts-field">
        <input type="password" id="ts-authkey" placeholder="tskey-auth-…" autocomplete="off" spellcheck="false">
        <button class="ts-btn ts-primary" id="ts-login-btn">Connect with auth key</button>
      </div>
      <div class="ts-field">
        <button class="ts-btn ts-secondary" id="ts-loginurl-btn">Get a browser login link instead</button>
        <span id="ts-loginurl"></span>
      </div>
      <div class="ts-field">
        <button class="ts-btn ts-danger" id="ts-logout-btn">Log out of Tailscale</button>
      </div>
    </div>
  </div>

  <div class="ts-row">
    <div class="ts-card" id="ts-settings-card">
      <h3>Settings</h3>
      <form id="ts-settings-form" onsubmit="return false;">
        <label>Machine name <input type="text" name="TS_HOSTNAME" placeholder="(default: NAS hostname)"></label>
        <label><input type="checkbox" name="TS_ACCEPT_ROUTES"> Accept subnet routes from other nodes</label>
        <label><input type="checkbox" name="TS_ACCEPT_DNS"> Use Tailscale DNS (MagicDNS) on the NAS itself <span class="ts-help">(rewrites the NAS's resolv.conf; off is safer for an appliance)</span></label>
        <label><input type="checkbox" name="TS_ADVERTISE_EXIT_NODE"> Advertise this NAS as exit node</label>
        <label><input type="checkbox" name="TS_SSH"> Enable Tailscale SSH <span class="ts-help">(gives tailnet users allowed by your ACLs a root shell on this NAS)</span></label>
        <label>Advertise routes <input type="text" name="TS_ADVERTISE_ROUTES" placeholder="192.168.1.0/24,10.0.0.0/8"></label>
        <p class="ts-help" id="ts-nat-note" style="display:none">This NAS kernel has no iptables NAT table, so Tailscale runs with <code>--netfilter-mode=off</code>: exit node is not possible, and advertised subnet routes work only without SNAT (your router needs a static route for 100.64.0.0/10 to this NAS).</p>
        <details>
          <summary>Advanced</summary>
          <label>Extra <code>tailscale up</code> flags <input type="text" name="TS_EXTRA_UP_ARGS" placeholder="--operator=… --netfilter-mode=off"></label>
          <label>Extra <code>tailscaled</code> flags (needs restart) <input type="text" name="TS_EXTRA_DAEMON_ARGS" placeholder="--port=41641"></label>
          <label>Update channel
            <select name="TS_CHANNEL"><option value="stable">stable</option><option value="unstable">unstable</option></select>
          </label>
        </details>
        <div class="ts-actions">
          <button class="ts-btn ts-primary" id="ts-save-btn">Save &amp; apply</button>
        </div>
      </form>
    </div>

    <div class="ts-card" id="ts-update-card">
      <h3>Update Tailscale</h3>
      <table class="ts-kv">
        <tr><th>Installed</th><td id="ts-upd-current">–</td></tr>
        <tr><th>Latest</th><td id="ts-upd-latest">–</td></tr>
        <tr><th>Previous</th><td id="ts-upd-prev">–</td></tr>
      </table>
      <div class="ts-actions">
        <button class="ts-btn ts-secondary" id="ts-check-btn">Check for updates</button>
        <button class="ts-btn ts-primary" id="ts-update-btn" disabled>Update now</button>
        <button class="ts-btn" id="ts-rollback-btn" disabled>Roll back</button>
      </div>
      <pre id="ts-upd-log" class="ts-log ts-small"></pre>
      <h3 class="ts-sub">Update notifications</h3>
      <p class="ts-help">Uses the My Cloud alert system: the alert appears under the bell icon and is e-mailed when alert e-mails are set up (Settings → Notifications). A new <a href="https://tailscale.com/security-bulletins/" target="_blank" rel="noopener">Tailscale security bulletin</a> always alerts right away; otherwise you get a reminder at the chosen interval while an update is available.</p>
      <div class="ts-field">
        <label class="ts-inline-label">Remind me
          <select id="ts-notify" name="TS_NOTIFY">
            <option value="off">never</option>
            <option value="daily">daily</option>
            <option value="weekly">weekly</option>
            <option value="monthly" selected>monthly</option>
          </select>
        </label>
        <button class="ts-btn ts-secondary" id="ts-notify-save-btn">Save</button>
        <button class="ts-btn ts-secondary" id="ts-notify-test-btn">Send test alert</button>
        <button class="ts-btn ts-secondary" id="ts-notify-check-btn">Check now</button>
      </div>
      <p class="ts-help" id="ts-notify-info"></p>
    </div>
  </div>

  <div class="ts-card">
    <h3>Log <button class="ts-btn ts-secondary ts-inline" id="ts-log-btn">Refresh</button></h3>
    <pre id="ts-log" class="ts-log"></pre>
  </div>

  <div id="ts-toast"></div>
  <p class="ts-footer">Tailscale app <span id="ts-app-version"></span> · <a href="https://github.com/la32094uf/mycloud-tailscale" target="_blank" rel="noopener">github.com/la32094uf/mycloud-tailscale</a> · <span id="ts-app-update">checking for a newer app version…</span></p>
</div>
<script src="/apps/tailscale/tailscale.js?v=<?php echo rawurlencode($v); ?>"></script>
