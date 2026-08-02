# mosdns + AdGuard Home for MikroTik RouterOS

A self-updating DNS container for the MikroTik RB5009 (arm64, RouterOS 7.23.x): AdGuard Home for ad-blocking + web UI, mosdns v5 for CN/foreign split resolution, rebuilt automatically with the latest upstream releases.

## Credits

- Based on the idea of **alickale**'s combined image: https://hub.docker.com/r/alickale/mosdns-adguard (no longer updated — this repo is a maintained replacement)
- Split-routing rule lists by **Loyalsoldier**: https://github.com/Loyalsoldier/v2ray-rules-dat and https://github.com/Loyalsoldier/geoip — built from data by [@v2fly/domain-list-community](https://github.com/v2fly/domain-list-community), [@felixonmars/dnsmasq-china-list](https://github.com/felixonmars/dnsmasq-china-list), and [@17mon/china_ip_list](https://github.com/17mon/china_ip_list)
- Core software: [IrineSistiana/mosdns](https://github.com/IrineSistiana/mosdns), [AdguardTeam/AdGuardHome](https://github.com/AdguardTeam/AdGuardHome)

## How it works

```
LAN clients (192.168.88.0/24, DHCP from RB5009)
        |  port 53
        v
AdGuard Home  --  ad/tracker/malware filtering + web UI :3000
        |  upstream 127.0.0.1:5335
        v
mosdns v5     --  split DNS (API :8080)
        |-- local/internal names -> NXDOMAIN, never leave the router
        |-- Apple                -> three-way split (see below)
        |-- GFW list domains     -> remote
        |-- CN domains           -> AliDNS / DNSPod / 360, DoT pipelined + DoH
        \-- everything else      -> Cloudflare / Google / Quad9 / OpenDNS DoH
                                    (prefer_ipv4, private-IP answers rejected)
```


GitHub Actions (weekly + manual + on push) resolves the **latest** mosdns and AdGuard Home releases, bakes in fresh CN rule lists, then:

- pushes the arm64 image to GHCR (`ghcr.io/<you>/<repo>`)
- publishes a **GitHub Release** with `mosdns-adg.tar` attached — the offline-import file for RouterOS

Updating the router = download the latest release tar, re-add the container. Your settings live in the mounted `/data` volume and survive upgrades.

### Release versioning: `vX.Y.Z`

- **`X.Y` = your config version.** Bump `BASE_VERSION` in `.github/workflows/build.yml` by hand whenever you change `config/*.yaml`. This is the signal that there is something worth adopting on the router.
- **`Z` = upstream version.** Managed automatically: +1 whenever mosdns, AdGuard Home or the CN rule lists change, reset to 0 when you bump `X.Y`.

So `v1.1.4` -> `v1.1.5` is binaries/rules only, nothing to do but re-import. `v1.1.x` -> `v1.2.0` means the default configs changed.

### Rule lists are processed at build time

`scripts/build-rules.py` runs inside the Docker build, never on the router:

1. merges `direct-list` + `apple-cn` into one CN set, dropping entries already covered by a broader suffix rule
2. **reduces the proxy list from ~27,000 entries to ~460** - since the last branch already sends everything unmatched to the remote pool, a proxy entry can only change an outcome where it overlaps the CN set. Routing behaviour is identical; the RB5009 just stops holding 26k pointless domains in RAM. The unreduced list is shipped alongside as `geosite_proxy_full.txt` for cn-first mode.
3. writes `geoip_cn.txt`, only needed if you enable cn-first mode

The build log prints the entry counts on every run. `RULES_VERSION` is passed as a build-arg purely to bust the Docker layer cache - without it a weekly build with unchanged binaries would silently ship stale lists.

## Fresh install 
> First time — configs come from this repo.

On first boot the container seeds `usb1/dns-data` with the default configs from `config/` in this repo (baked into the image). After that, those live copies are yours.

1. **One-time prep** — see `routeros-setup.rsc`: install the `container` package (Extra packages, arm64, matching your ROS version), enable `device-mode container=yes` (requires pressing the physical reset button), plug in a USB drive formatted ext4 (`usb1`). Create the veth, bridge, NAT rule, `dns-data` mount and `dns-env` envlist from the script.
2. **Get the image** — repo → Releases → Latest → download `mosdns-adg.tar`, then upload it to the router:
   ```
   scp mosdns-adg.tar admin@192.168.88.1:usb1/
   ```
3. **Create and start the container**:
   ```
   /container add file=usb1/mosdns-adg.tar interface=veth-dns \
       root-dir=usb1/containers/dns mounts=dns-data envlist=dns-env \
       start-on-boot=yes logging=yes comment="mosdns + AdGuard Home"
   /container set [find comment~"mosdns"] memory-high=384M shm-size=64M
   /container start [find comment~"mosdns"]
   ```
   The tar can be deleted from `usb1/` once the container is running.
4. **Point the LAN at it** — set `dns-server=172.18.53.2` on the DHCP network (in the `.rsc`), plus the optional dst-nat rules for devices with hardcoded DNS. Keep the router's own `/ip dns servers` on an external resolver (e.g. `223.5.5.5`) to avoid a chicken-and-egg during upgrades.
5. **Set an AdGuard Home password** — http://172.18.53.2:3000 works immediately with **no auth**; fix that first.

## Normal upgrade 
> Configs on your router stay as they are.

An upgrade replaces only the binaries and the bundled CN rule lists. Your configs and AdGuard settings in `usb1/dns-data` are **never modified**.

1. Download the latest release `mosdns-adg.tar`, upload to `usb1/` (overwrite the old one if present).
2. Recreate the container (RouterOS has no in-place pull):
   ```
   /container stop   [find comment~"mosdns"]
   /container remove [find comment~"mosdns"]
   ```
   …then repeat step 3 of the fresh install. `root-dir` is disposable; `usb1/dns-data` is sacred.
3. Check the log: `/log print where topics~"container"`. If the image ships a **newer default config** than the one live on your router, a NOTICE line appears — see the next section to adopt it (optional; ignoring it is always safe).

**Did the default configs change?** Two ways to tell: the version (`X.Y` unchanged = configs unchanged), and the release notes, which state the last-modified commit for `config/mosdns.yaml` and `config/AdGuardHome.yaml`.

### Alternative: pull via registry mirror

If you make the image public (GHCR package visibility → public, or push to Docker Hub), RouterOS can pull it directly. In mainland China set a Docker registry mirror first — replace with **your own** mirror address (e.g. a personal endpoint like `xxxxxxxx.xuanyuan.run` from https://xuanyuan.run — each user has their own key, don't share it):

```
/container/config set registry-url=https://<your-key>.xuanyuan.run tmpdir=usb1/pull
/container add remote-image=ghcr.io/<you>/<repo>:latest interface=veth-dns ...
```

## Why Apple domains are split three ways

Apple runs parallel infrastructure in China, and "which one should I get" has a different answer per service. `config/mosdns.yaml` therefore sorts Apple domains into four sets:

| Set | Goes to | Why |
|---|---|---|
| `apple_intl_host` | Cloudflare only | Apple TV+ / Music streaming (`music.apple.com`, `tv.apple.com`, the itunes audio hosts). Forces Apple's **international** media edge instead of the China CDN. Changes which CDN serves you, **not** your Apple ID region or catalog. |
| `apple_intl` | remote pool | Fitness+, Arcade, games - resolve abroad so DNS answers match a proxied egress. |
| `apple_relay` | remote pool | iCloud Private Relay setup/egress + Apple DoH. These **must** resolve to genuine Apple/relay IPs or Private Relay silently fails to come up. Matched *before* `apple_direct` so the `aaplimg.com` relay host escapes the China bucket. |
| `apple_direct` | China DNS | `apple.com.cn`, `icloud.com.cn`, `mzstatic.com` (artwork - identical worldwide and much faster from the CN CDN), `aaplimg.com`. |

`music.apple.com` is a **suffix** match on purpose, so `amp-api.music.apple.com` (the app/web API) follows the same path as playback. Using `full:` there would leave the API on China DNS and split the service across two CDNs.

Pairs best with a proxy. Without one, international Apple edges can be slower from Shanghai than the China CDN - if Music feels worse after switching, move those entries back to `apple_direct`.

## Local names, and DNS rebinding

Two protections that are easy to confuse with ad-blocking but are not:

- **`local_domains`** - `.lan`, `.home.arpa`, `.local`, the private `in-addr.arpa` reverse zones, and router admin domains (`tplogin.cn`, `tplinkwifi.net`, ...) are answered NXDOMAIN immediately, before the cache. Otherwise every `nas.lan` lookup travels to AliDNS, leaks your internal naming, and returns NXDOMAIN anyway. AdGuard Home is also set to answer private PTR locally (`use_private_ptr_resolvers: false`) so reverse lookups for `192.168.88.x` never leave the router either.
- **`private_ip`** - a public resolver answering with a LAN address is either a hijacking ISP or a rebinding attack aimed at the router / AdGuard UI. Such answers are rejected on all three forwarding paths.

Rejecting a name only stops the **leak**. To actually reach a device by name, add a DNS rewrite in AdGuard Home (Filters -> DNS rewrites), e.g. `tplogin.cn` -> your AP's IP.

**Exception, and it matters:** `plex.direct` and `ui.direct` are real public zones that legitimately return private addresses (Plex hands out `192-168-88-10.<hash>.plex.direct` so a browser gets valid TLS on the LAN). They are listed in `rebind_ok` and skip the private-IP check. Do not move them into `local_domains` - rejecting them breaks local Plex playback just as thoroughly.

## Optional: cn-first default branch

The default final branch is `seq_remote`: anything not explicitly matched goes abroad, so no CN resolver ever sees an unlisted domain. The alternative, `seq_default_cn_first`, tries the domestic pool first and keeps the answer only if it lands on a CN IP - better CDN proximity for Chinese sites missing from `direct-list`, at the cost of showing every unknown domain to a CN resolver.

To enable it, uncomment **all four** of `geoip_cn`, `seq_china_probe`, `seq_default_cn_first`, switch the last line of `main`, **and** point `geosite_proxy` at `geosite_proxy_full.txt` - the reduced proxy list is only valid while the default is `seq_remote`.

## Endpoints (container IP 172.18.53.2)

| Port | Service |
|---|---|
| 53 | AdGuard Home DNS (what clients use) |
| 3000 | AGH web UI + REST API — **no password by default, set one immediately** |
| 5335 | mosdns resolver (direct testing) |
| 8080 | mosdns API: `/metrics`, `/plugins/cache/flush`, `/plugins/cache/dump` |

## Customizing

| What | Where |
|---|---|
| mosdns routing/upstreams | `/data/mosdns/config.yaml` on the USB drive → restart container |
| AdGuard filters/settings | web UI (persisted in `/data/adguard/conf/`) |
| Defaults baked into image | `config/` in this repo |
| Build schedule | cron in `.github/workflows/build.yml` - weekly, Monday 03:17 Beijing (`"17 19 * * *"` for daily) |
| Config version | `BASE_VERSION` in `.github/workflows/build.yml` |
| Rule list processing | `scripts/build-rules.py` |
| Ad / malware blocklists | AdGuard Home UI only - deliberately **not** in `mosdns.yaml` |

If you run a proxy (clash / sing-box), point `forward_remote` in `mosdns.yaml` at its DNS port instead of raw DoH — see comments in the file. Keep AGH *Fallback DNS* **empty** to avoid leaks.

## Troubleshooting

- **Container starts then stops** — check `/log print where topics~"container"`; usually a bad config edit in `/data/mosdns/config.yaml`.
- **Foreign domains time out** — DoH being throttled; switch `forward_remote` to your proxy's DNS.
- **Instant crash-loop after tar import** — wrong architecture: the tar must be built `--platform linux/arm64` for the RB5009.
- **GHCR push 403 in Actions** — repo Settings → Actions → General → Workflow permissions → Read and write.
- **Actions fails on the download step, log shows a version of `null`** — GitHub API rate limit; the workflow guards against this and aborts early. Re-run the job.
- **`refusing to allow a Personal Access Token to create or update workflow`** — your push token lacks `workflow` scope. Use SSH, or regenerate the token with that box ticked.
- **Local Plex stopped working on the LAN** — something removed `plex.direct` from `rebind_ok`, so the private-IP check is rejecting its answers.
- **A site returns NXDOMAIN unexpectedly** — if its upstream answers with `0.0.0.0`/`127.0.0.1` (some resolvers do this for domains they block), the rebinding rule converts that to NXDOMAIN. Functionally the same, but worth knowing while debugging.
- **Container runs but DNS is dead** — check the log for repeated `WARNING: mosdns died`. After 5 failures the entrypoint stops the container; the optional watchdog scheduler in `routeros-setup.rsc` restarts it ~5 min later.

## Supervision and recovery

RouterOS has **no container restart policy**, and it ignores Docker `HEALTHCHECK`. Recovery is therefore two layers:

1. The entrypoint polls both processes and restarts whichever dies. After 5 failures of the same process (counter resets after 30 min of stability) it stops the container, so a genuinely broken config is visible rather than crash-looping.
2. The optional scheduler in `routeros-setup.rsc` restarts a stopped container every 5 minutes, turning that give-up into a backoff.

**Verify layer 2 before trusting it:** put a syntax error in `/usb1/dns-data/mosdns/config.yaml`, let the entrypoint burn through its 5 failures, then run `/container print` and read the actual status string. If it is not `stopped` or `error`, add whatever you see to the watchdog's match list.

## Adopting new default configs after an upgrade

Your live configs in `usb1/dns-data` are **never** touched by upgrades. When a new image ships an improved default config (the container log prints a NOTICE if yours differs), adopt it like this — your old file is backed up automatically as `*.bak-<timestamp>`:

```
/container/envs add name=dns-env key=OVERWRITE_MOSDNS_CONFIG value=yes
/container restart [find comment~"mosdns"]
/container/envs remove [find key=OVERWRITE_MOSDNS_CONFIG]
```

(`OVERWRITE_AGH_CONFIG=yes` does the same for AdGuard Home — rarely wanted, since that file holds your UI settings.) Remove the env afterwards, otherwise every restart overwrites again. Re-apply your customizations (e.g. proxy DNS upstream) from the backup if you had any.
