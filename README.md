# Tailscale for WD My Cloud OS5

A third-party app that runs [Tailscale](https://tailscale.com) on Western Digital
My Cloud OS5 NAS devices (EX2 Ultra, PR2100, PR4100, EX4100, DL4100, EX2100,
DL2100, Mirror Gen2) with a settings page inside the My Cloud dashboard.


## What it does

- **Runs `tailscaled` as a proper OS5 app**: starts at boot, stops cleanly, and
  shows up under *Apps* like any other app. No more hooking into Plex's start
  script or editing files over SSH.
- **Settings page** right on the app's page (Apps → Tailscale), no extra click:
  - connect with an **auth key** (used once, never stored) or with a
    **browser login link**
  - see status: Tailscale IP, machine name, tailnet, health warnings
  - change **machine name**, **accept routes**, **MagicDNS**, **advertise
    routes**, **exit node**, **Tailscale SSH**, plus free-form extra flags
  - **update the Tailscale binaries in place** when a new release is out, with
    checksum verification and one-click **roll back** to the previous version.
    You never need to reinstall the app for a Tailscale update.
  - view the daemon log
- The Tailscale binaries are **downloaded on first start** from
  `pkgs.tailscale.com` for your CPU (arm, arm64, amd64), so the app package
  itself is tiny and always installs the current release.

## Install

1. Download the `.bin` for your model from the
   [latest release](https://github.com/la32094uf/mycloud-tailscale/releases).
2. My Cloud dashboard → **Apps** → **Install an app manually** → pick the file.
3. Open **Apps → Tailscale**, press **Start** if it is not running yet (first
   start downloads ~30 MB), paste an auth key from
   [Tailscale admin → Settings → Keys](https://login.tailscale.com/admin/settings/keys)
   and press **Connect**.

Your NAS needs internet access for the download and for Tailscale itself.

## Limitations

- WD's kernels ship without the iptables `nat` table and without loadable
  modules. The app detects this and runs Tailscale with `--netfilter-mode=off`
  (otherwise every start logs a health warning). Consequences on such devices:
  **exit node is not possible**, and advertised subnet routes work only without
  SNAT, so your router needs a static route for `100.64.0.0/10` pointing at the
  NAS. Plain device-to-device access to the NAS works fine.
- Tested on a My Cloud EX2 Ultra (OS 5.33). The other models are built from the
  same source but have not been tried; reports welcome.

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

`<volume>` is `/mnt/HD/HD_a2` on most models. Uninstalling the app keeps
`tailscale_conf` so a reinstall reconnects without a new login; delete that
folder by hand for a clean slate.

Everything the settings page does goes through one shell script, which you can
also use over SSH:

```
sh /mnt/HD/HD_a2/Nas_Prog/tailscale/bin/tailscale-ctl.sh status|start|stop|login <key>|update|rollback|log
```

The `tailscale` CLI itself is at `<volume>/Nas_Prog/tailscale_conf/bin/tailscale`
(use `--socket=/var/run/tailscale/tailscaled.sock`).

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

# Build locally (needs x86_64 Linux or Docker)
curl -fsSLo mksapkg-OS5 https://raw.githubusercontent.com/WDCommunity/wdpksrc/master/mksapkg-OS5
chmod +x mksapkg-OS5 && ./build.sh MyCloudEX2Ultra
```

Bump `Version:` in `tailscale/apkg.rc` for a new release, then tag `vX.Y.Z`.

## Credits

- [Tailscale](https://tailscale.com) for the software and the static binaries.
- [WD Community / wdpksrc](https://github.com/WDCommunity/wdpksrc) for figuring
  out the OS5 package format and providing `mksapkg-OS5`, and for the `mycron`
  app that showed how embedded settings pages work.

Not affiliated with Western Digital or Tailscale Inc. Use at your own risk.

## License

MIT, see [LICENSE](LICENSE).
