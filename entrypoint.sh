#!/bin/sh
# Entrypoint: seed /data on first run, then supervise mosdns + AdGuard Home.
set -e

DATA=/data
MOSDNS_DIR="$DATA/mosdns"
AGH_DIR="$DATA/adguard"

mkdir -p "$MOSDNS_DIR/rules" "$AGH_DIR/work" "$AGH_DIR/conf"

# First-run: copy default configs (never overwritten afterwards,
# so your edits and AdGuard settings survive image upgrades)
[ -f "$MOSDNS_DIR/config.yaml" ]        || cp /opt/defaults/mosdns.yaml      "$MOSDNS_DIR/config.yaml"
[ -f "$AGH_DIR/conf/AdGuardHome.yaml" ] || cp /opt/defaults/AdGuardHome.yaml "$AGH_DIR/conf/AdGuardHome.yaml"

# Opt-in overwrite: set env OVERWRITE_MOSDNS_CONFIG=yes (and/or
# OVERWRITE_AGH_CONFIG=yes) to replace the live config with this image's
# default. The old file is backed up next to it first. Intended as a
# one-shot: set the env, restart once, then remove the env.
TS=$(date +%Y%m%d-%H%M%S)
if [ "$OVERWRITE_MOSDNS_CONFIG" = "yes" ] || [ "$OVERWRITE_MOSDNS_CONFIG" = "true" ]; then
    cp "$MOSDNS_DIR/config.yaml" "$MOSDNS_DIR/config.yaml.bak-$TS"
    cp /opt/defaults/mosdns.yaml "$MOSDNS_DIR/config.yaml"
    echo "[entrypoint] mosdns config REPLACED with image default (backup: config.yaml.bak-$TS)"
fi
if [ "$OVERWRITE_AGH_CONFIG" = "yes" ] || [ "$OVERWRITE_AGH_CONFIG" = "true" ]; then
    cp "$AGH_DIR/conf/AdGuardHome.yaml" "$AGH_DIR/conf/AdGuardHome.yaml.bak-$TS"
    cp /opt/defaults/AdGuardHome.yaml "$AGH_DIR/conf/AdGuardHome.yaml"
    echo "[entrypoint] AdGuard config REPLACED with image default (backup: AdGuardHome.yaml.bak-$TS)"
fi

# Notice (no action taken): live config differs from this image's default
if ! cmp -s "$MOSDNS_DIR/config.yaml" /opt/defaults/mosdns.yaml; then
    echo "[entrypoint] NOTICE: live mosdns config differs from image default."
    echo "[entrypoint]         If you have not customized it, the image may carry"
    echo "[entrypoint]         improvements. Set env OVERWRITE_MOSDNS_CONFIG=yes to adopt."
fi

# Rule lists ARE refreshed on every start — they are baked into each
# nightly image build, so pulling a new image = fresh CN lists.
cp /opt/defaults/rules/*.txt "$MOSDNS_DIR/rules/"

echo "[entrypoint] starting mosdns..."
mosdns start -d "$MOSDNS_DIR" -c "$MOSDNS_DIR/config.yaml" &
MOSDNS_PID=$!

echo "[entrypoint] starting AdGuard Home..."
AdGuardHome --no-check-update \
  -w "$AGH_DIR/work" \
  -c "$AGH_DIR/conf/AdGuardHome.yaml" &
AGH_PID=$!

term() {
  echo "[entrypoint] shutting down..."
  kill "$MOSDNS_PID" "$AGH_PID" 2>/dev/null
  wait
  exit 0
}
trap term TERM INT

# If either process dies, exit so RouterOS marks the container stopped
wait -n 2>/dev/null || wait
echo "[entrypoint] a process exited, stopping container"
kill "$MOSDNS_PID" "$AGH_PID" 2>/dev/null
exit 1
