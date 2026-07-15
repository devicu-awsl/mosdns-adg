# mosdns + AdGuard Home for MikroTik RouterOS

A self-updating replacement for `alickale/mosdns-adguard`, built for the RB5009 (arm64) running RouterOS 7.23.x containers.

## How it works

```
LAN clients (192.168.88.0/24, DHCP from RB5009)
        │  port 53
        ▼
AdGuard Home  ──  ad/tracker filtering + web UI on :3000
        │  upstream 127.0.0.1:5335
        ▼
mosdns v5     ──  split DNS
        ├── CN domains  → 223.5.5.5 / 119.29.29.29 (UDP)
        └── everything else → DoH 1.1.1.1 / 8.8.8.8
```

GitHub Actions rebuilds the image **every night at 03:17 Beijing time**, always pulling:

- the latest `IrineSistiana/mosdns` release (currently v5.3.4)
- the latest stable `AdguardTeam/AdGuardHome` release
- fresh China domain/IP lists from `Loyalsoldier/v2ray-rules-dat` and `Loyalsoldier/geoip`

So "update everything" on the router is just: pull the new image, recreate the container. Your settings live in the mounted `/data` volume and survive upgrades.

## Setup — 3 steps

### 1. Fork / create the repo

Put these files in a GitHub repo, then:

1. Edit `.github/workflows/build.yml` → change `DOCKERHUB_IMAGE` to `<your-dockerhub-user>/mosdns-adguard`.
2. Repo → Settings → Secrets and variables → Actions, add:
   - `DOCKERHUB_USERNAME` — your Docker Hub username
   - `DOCKERHUB_TOKEN` — a Docker Hub access token (hub.docker.com → Account Settings → Security)
3. Go to the Actions tab and run the workflow manually once (`workflow_dispatch`).

The image is pushed to **Docker Hub** (so the `xuanyuan.run` mirror can serve it to your router in Shanghai) and to GHCR as a backup.

### 2. Configure the RB5009

Run the commands in `routeros-setup.rsc` (read the STEP 0 notes first — you need the container `.npk` package installed and `device-mode container=yes` enabled, which requires pressing the physical reset button).

Key Shanghai-specific line:

```
/container/config set registry-url=https://21ghhr9qtgn436pf4s.xuanyuan.run tmpdir=usb1/pull
```

**Storage warning:** the RB5009's internal NAND is 1 GB. The image is ~70 MB but query logs and filter lists grow — use a USB drive (`usb1`) for `root-dir`, `tmpdir`, and the `/data` mount. If you must use NAND, disable the AdGuard query log.

### 3. Point the LAN at it

Included in the `.rsc`: set `dns-server=172.18.53.2` on the DHCP network, plus optional dst-nat rules to hijack devices with hardcoded DNS.

Web UI: `http://172.18.53.2:3000` — it boots pre-configured with **no password**. Set one immediately in Settings.

## Customizing

| What | Where |
|---|---|
| mosdns routing/upstreams | edit `/data/mosdns/config.yaml` on the USB drive, restart container |
| AdGuard filters/settings | web UI (persisted to `/data/adguard/conf/AdGuardHome.yaml`) |
| Default configs baked into image | `config/` in this repo |
| Build schedule | cron in `.github/workflows/build.yml` |

If you run a proxy (clash / sing-box / etc.), point `forward_remote` in `mosdns.yaml` at its DNS port instead of raw DoH — see the comments in the file. DoH to `1.1.1.1`/`8.8.8.8` from Shanghai works most of the time but can be throttled or blocked during sensitive periods.

## Upgrading on the router

```
/container/stop [find comment~"mosdns"]
/container/remove [find comment~"mosdns"]
/container add remote-image=<you>/mosdns-adguard:latest interface=veth-dns \
    root-dir=usb1/containers/dns mounts=dns-data envlist=dns-env \
    start-on-boot=yes logging=yes comment="mosdns + AdGuard Home"
```

(RouterOS has no `docker pull`-in-place; remove + re-add re-pulls. `/data` is untouched.)

## Troubleshooting

- **Pull stuck at 0%** — mirror issue. Try again, or temporarily switch `registry-url` to another mirror. Check `/log/print where topics~"container"`.
- **Container starts then stops** — usually a port conflict or bad config; check logs. Make sure the router's own DNS service isn't bound in a way that conflicts (the container has its own IP, so normally fine).
- **Foreign domains time out** — DoH being interfered with; switch `forward_remote` to your proxy's DNS.
- **`wait: -n` error in logs** — harmless on very old busybox; the fallback `wait` still works.
