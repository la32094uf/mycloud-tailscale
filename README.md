# Tailscale for WD My Cloud OS5

A third-party app that runs [Tailscale](https://tailscale.com) on Western Digital
My Cloud OS5 NAS devices (EX2 Ultra, PR2100, PR4100, EX4100, DL4100, EX2100,
DL2100, Mirror Gen2) with a settings page inside the My Cloud dashboard.


## What it does

- **Runs `tailscaled` as a proper OS5 app**: starts at boot, stops cleanly, and
  shows up under *Apps* like any other app. No more hooking into Plex's start
  script or editing files over SSH.
- **Settings page** right on the app's page (Apps → Tailscale), no extra click:
  - connect with an **auth key** (handed to Tailscale through a root-only
    temporary file that is deleted right after login) or with a
    **browser login link**
  - see status: Tailscale IP, machine name, tailnet, health warnings
  - change **machine name**, **accept routes**, **MagicDNS**, **advertise
    routes**, **Tailscale SSH**, **exit node** (only on models whose kernel
    has a NAT table; the page tells you), plus free-form extra flags
  - optionally **install Tailscale updates automatically**: the background
    check (every 6 hours) installs a newer release and alerts you that it did,
    or that it failed; roll back stays available
  - **update the Tailscale binaries in place** when a new release is out
    (HTTPS only, SHA-256 checked against the checksum pkgs.tailscale.com
    publishes) and one-click **roll back** to the previous version.
    You never need to reinstall the app for a Tailscale update.
  - **update notifications** through the My Cloud alert system (bell icon, and
    e-mail if alert e-mails are configured under Settings → Notifications):
    a reminder at the chosen interval while a Tailscale update is available
    (daily, weekly, monthly or off), an immediate alert when Tailscale has
    published a new [security bulletin](https://tailscale.com/security-bulletins/)
    and an update is available, a daily alert when the NAS has dropped off the
    tailnet (logged out or machine key expired) or the machine key expires
    within a week, and an alert when a newer version of this app is on GitHub.
    The page shows the same things as a banner at the top.
  - the page also checks GitHub for a **newer version of this app**, and an
    **Update app** button downloads the package for your model, checks it
    against the release's SHA256SUMS and installs it with WD's own installer
    (settings and login are kept). This skips the dashboard's manual upload,
    which fails now and then on OS5 firmware
  - **reach the dashboard from anywhere**: WD's web server refuses visitors
    with a Tailscale address, so the app can publish the dashboard on your
    tailnet with `tailscale serve`. You then open `http://<nas-name>/` (the
    short MagicDNS name, e.g. `http://mycloud/`) from any device running
    Tailscale. Use the short name: browsers force HTTPS for `*.ts.net` names
    and this proxy is plain HTTP inside the encrypted tailnet.
  - view the daemon log
- The Tailscale binaries are **downloaded on first start** from
  `pkgs.tailscale.com` for your CPU (arm, arm64, amd64), so the app package
  itself is tiny and always installs the current release.

## Install

1. Download the `.bin` for your model from the
   [latest release](https://github.com/la32094uf/mycloud-tailscale/releases)
   (`SHA256SUMS` is published next to the files).
2. My Cloud dashboard → **Apps** → **Install an app manually** → pick the file.
3. Open **Apps → Tailscale**. The first start downloads the Tailscale binaries
   (~30 MB) in the background; the page shows the progress.
4. Get an auth key: [Tailscale admin → Settings → Keys](https://login.tailscale.com/admin/settings/keys)
   → **Generate auth key**. In the dialog leave *Reusable* and *Ephemeral*
   off. *Expiration* (1–90 days) is how long the *key* can be used to
   connect a machine; you use it once, so any value is fine. It does not
   affect how long the NAS stays logged in. Press **Generate key**, copy the
   key, paste it on the app page and press **Connect**. Or use the browser
   login link instead.

How long the NAS stays logged in is governed by Tailscale's *node key expiry*
(180 days by default). To avoid re-authenticating, open the machine in the
admin console and choose **Disable key expiry**, or generate the auth key with
**Tags** enabled, which disables node key expiry for the device automatically.

Your NAS needs internet access for the download and for Tailscale itself.

## Uninstall

**Apps → Tailscale → Uninstall**. This logs the NAS out of your tailnet and
deletes everything under `tailscale_conf` (binaries, node key, settings), as the
dashboard's uninstall dialog promises. Remove the machine in the
[Tailscale admin console](https://login.tailscale.com/admin/machines) if it is
still listed there. Installing a newer app package over the existing one keeps
`tailscale_conf`.

## Things to know

- Everyone with an admin login on the dashboard controls the daemon as root
  through this page, like with any OS5 app.
- **Tailscale SSH** gives tailnet users allowed by your ACLs a root shell on the
  NAS. It is off by default.
- **MagicDNS on the NAS itself** (accept DNS) makes tailscaled rewrite the
  NAS's `/etc/resolv.conf`. Off by default: if the daemon is ever killed hard
  the NAS could be left without DNS. You don't need it to reach the NAS by
  name from other devices.
- The dashboard's **Run App** switch stops and starts the daemon too. Note that
  an app switched off there does not start at boot.
- Once connected, services on the NAS (SMB, Plex, ...) are reachable from
  your tailnet. The dashboard itself is not, unless you enable "Make the
  dashboard reachable over the tailnet" on the app page: WD's nasAdmin treats
  Tailscale's 100.x addresses as public and refuses them. Use Tailscale ACLs to limit
  who may reach those ports.
- On OS5 the apps folder `Nas_Prog` is world-writable, so any local user with
  a shell could tamper with any app's files. This app refuses to start binaries
  that are not root-owned and root-only, and sets its own data aside if it
  finds it replaced, but the app folder itself is the platform's responsibility.
  By default only the `sshd` user can log in over SSH on OS5.
- Update notifications use alert code 1501 ("App Update Available") of the
  firmware. E-mails go to the addresses under Settings → Notifications; the
  "Send test alert" button checks the whole chain.

## Limitations

- WD's kernels ship without the iptables `nat` table and without loadable
  modules. The app detects this and runs Tailscale with `--netfilter-mode=off`
  (otherwise every start logs a health warning). Consequences on such devices:
  **exit node is not possible**, and advertised subnet routes work only without
  SNAT, so your router needs a static route for `100.64.0.0/10` pointing at the
  NAS. Plain device-to-device access to the NAS works fine.
- Tested on a My Cloud EX2 Ultra with firmware 5.33.102. The other models are
  built from the same source but have not been tried; reports welcome. The
  inline settings page relies on the dashboard loading `desc.xml` as HTML,
  which is how 5.x firmware behaves.
- The single-bay My Cloud (Gen2) is not in the build list yet.

## Where things live on the NAS

```
<volume>/Nas_Prog/tailscale/         the app (replaced on reinstall)
<volume>/Nas_Prog/tailscale_conf/    persistent data (kept on reinstall)
  bin/                               current tailscale + tailscaled
  bin.prev/                          previous version, for roll back
  state/tailscaled.state             node identity and preferences
  settings.conf                      what you set on the settings page
  logs/                              tailscaled.log, tailscale-ctl.log
```

`<volume>` is `/mnt/HD/HD_a2` on most models; nothing in the app assumes that
path, everything is derived from where the installer put it. Reinstalling on a
different volume starts with a fresh `tailscale_conf` (new machine in the
tailnet).

Everything the settings page does goes through one shell script, which you can
also use over SSH:

```
sh <volume>/Nas_Prog/tailscale/bin/tailscale-ctl.sh status|start|stop|update|rollback|notify-check|log
TS_AUTHKEY=tskey-auth-… sh <volume>/Nas_Prog/tailscale/bin/tailscale-ctl.sh login
```

The `tailscale` CLI itself is at `<volume>/Nas_Prog/tailscale_conf/bin/tailscale`.

## How an OS5 app is built

An OS5 app is a folder with `apkg.rc` (metadata) and lifecycle scripts
(`install.sh`, `init.sh`, `start.sh`, `stop.sh`, `remove.sh`, `clean.sh`), packed
and **signed** into a `.bin` by `mksapkg-OS5`, a tool published by the
[WD Community wdpksrc project](https://github.com/WDCommunity/wdpksrc). Unsigned
packages are refused by the installer, so the build runs in GitHub Actions
(the tool is an x86_64 Linux binary): see
[`.github/workflows/build.yml`](.github/workflows/build.yml) and
[`build.sh`](build.sh). Every push builds packages for all models as workflow
artifacts; a `v*` tag publishes them as a release.

Apps with `CenterType: 1` are embedded in the dashboard: `web/index.php` is
loaded as an HTML fragment at `/apps/tailscale/index.php`, and Apache only serves
that path to a browser that is logged in to the dashboard. The dashboard also
fetches `web/desc.xml` and inserts the text for the current language as HTML on
the app's own page; this app uses that to load the settings page inline there,
so no "Configure" click is needed. `web/api.php` is the
JSON backend; it runs as root (like every OS5 web page) and shells out to
`bin/tailscale-ctl.sh` with validated, escaped arguments only.

Repository layout:

```
tailscale/               the app package
  apkg.rc                metadata shown in the App Store
  *.sh                   apkg lifecycle scripts
  bin/tailscale-ctl.sh   all logic: start/stop/login/update/rollback
  web/                   settings page (index.php, api.php, js, css)
build.sh                 builds .bin files with mksapkg-OS5
```

## Development

```
# Test the script directly on the NAS (after copying tailscale/ to Nas_Prog/tailscale)
sh /mnt/HD/HD_a2/Nas_Prog/tailscale/bin/tailscale-ctl.sh status

# Build locally (needs x86_64 Linux or Docker). On OpenSSL 3 the Blowfish
# signing needs the legacy provider: see the shim in .github/workflows/build.yml.
curl -fsSLo mksapkg-OS5 https://raw.githubusercontent.com/WDCommunity/wdpksrc/f72c74ad046ce44fe0a86452e14f5c0eff3226b8/mksapkg-OS5
chmod +x mksapkg-OS5 && ./build.sh MyCloudEX2Ultra

# Try changes without rebuilding: copy tailscale/ over the installed app
scp -r tailscale/. root@nas:/mnt/HD/HD_a2/Nas_Prog/tailscale/
```

The text on the app page comes from `tailscale/web/desc.template.html`; after
editing it run `python3 tools/gen-desc.py` to regenerate `desc.xml` for all
dashboard languages (CI checks that they match).

For a release: bump `Version:` in `tailscale/apkg.rc` (the page and API read it
from there), commit, tag `vX.Y.Z` and push the tag. CI refuses a tag that does
not match the version. Installing the new `.bin` over the old one is an upgrade
and keeps your data.

## Credits

- [Tailscale](https://tailscale.com) for the software and the static binaries.
- [WD Community / wdpksrc](https://github.com/WDCommunity/wdpksrc) for figuring
  out the OS5 package format and providing `mksapkg-OS5`, and for the `mycron`
  app that showed how embedded settings pages work.

The app icon is a generic dot grid drawn for this project, not Tailscale's logo.
Not affiliated with Western Digital or Tailscale Inc. Use at your own risk.

## License

MIT, see [LICENSE](LICENSE).
