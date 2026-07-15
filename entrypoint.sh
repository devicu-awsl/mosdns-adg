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
