# mosdns + AdGuard Home for MikroTik RouterOS

A self-updating DNS container for the MikroTik RB5009 (arm64, RouterOS 7.23.x): AdGuard Home for ad-blocking + web UI, mosdns v5 for CN/foreign split resolution, rebuilt automatically with the latest upstream releases.

## Credits

- Based on the idea of **alickale**'s combined image: https://hub.docker.com/r/alickale/mosdns-adguard (no longer updated — this repo is a maintained replacement)
- Split-routing rule lists by **Loyalsoldier**: https://github.com/Loyalsoldier/v2ray-rules-dat and https://github.com/Loyalsoldier/geoip


## How it works

```
LAN clients (192.168.88.0/24, DHCP from RB5009)
        │  port 53
        ▼
AdGuard Home  ──  ad/tracker filtering + web UI :3000
        │  upstream 127.0.0.1:5335
        ▼
mosdns v5     ──  split DNS (API :8080)
        ├── CN domains  → 223.5.5.5 / 119.29.29.29 (UDP)
        └── everything else → DoH 1.1.1.1 / 8.8.8.8 (prefer_ipv4)
```

GitHub Actions (weekly + manual + on push) resolves the **latest** mosdns and AdGuard Home releases, bakes in fresh CN rule lists, then:

- pushes the arm64 image to GHCR (`ghcr.io/<you>/<repo>`)
- publishes a **GitHub Release** with `mosdns-adg.tar` attached — the offline-import file for RouterOS

Updating the router = download the latest release tar, re-add the container. Your settings live in the mounted `/data` volume and survive upgrades.

## Install on the RB5009

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

### Alternative: pull via registry mirror

If you make the image public (GHCR package visibility → public, or push to Docker Hub), RouterOS can pull it directly. In mainland China set a Docker registry mirror first — replace with **your own** mirror address (e.g. a personal endpoint like `xxxxx.xuanyuan.run` from https://xuanyuan.run — each user has their own key, don't share it):

```
/container/config set registry-url=https://<your-key>.xuanyuan.run tmpdir=usb1/pull
/container add remote-image=<dockerhub-user>/mosdns-adguard:latest interface=veth-dns ...
```

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
| Build schedule | cron in `.github/workflows/build.yml` (weekly by default) |

If you run a proxy (clash / sing-box), point `forward_remote` in `mosdns.yaml` at its DNS port instead of raw DoH — see comments in the file. Keep AGH *Fallback DNS* **empty** to avoid leaks.

## Upgrading

Download the new release tar, upload to `usb1/`, then:

```
/container stop   [find comment~"mosdns"]
/container remove [find comment~"mosdns"]
```

…and repeat install step 3. `root-dir` is disposable; `usb1/dns-data` (your settings) is never touched.

## Troubleshooting

- **Container starts then stops** — check `/log print where topics~"container"`; usually a bad config edit in `/data/mosdns/config.yaml`.
- **Foreign domains time out** — DoH being throttled; switch `forward_remote` to your proxy's DNS.
- **Instant crash-loop after tar import** — wrong architecture: the tar must be built `--platform linux/arm64` for the RB5009.
- **GHCR push 403 in Actions** — repo Settings → Actions → General → Workflow permissions → Read and write.
