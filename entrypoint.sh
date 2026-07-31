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
# Copy only what actually differs: /data is a USB stick, and if the
# container ends up in a give-up/watchdog-restart cycle this would
# otherwise rewrite several MB every few minutes for no reason.
for f in /opt/defaults/rules/*.txt; do
    dst="$MOSDNS_DIR/rules/$(basename "$f")"
    cmp -s "$f" "$dst" || cp "$f" "$dst"
done

start_mosdns() {
    mosdns start -d "$MOSDNS_DIR" -c "$MOSDNS_DIR/config.yaml" &
    MOSDNS_PID=$!
    echo "[entrypoint] mosdns started (pid $MOSDNS_PID)"
}

start_agh() {
    AdGuardHome --no-check-update \
      -w "$AGH_DIR/work" \
      -c "$AGH_DIR/conf/AdGuardHome.yaml" &
    AGH_PID=$!
    echo "[entrypoint] AdGuard Home started (pid $AGH_PID)"
}

start_mosdns
start_agh

term() {
    echo "[entrypoint] shutting down..."
    RUNNING=0
    # `|| true` matters: under `set -e`, killing an already-dead PID returns
    # non-zero and the script would exit 1 before reaching `exit 0` — making
    # a clean stop look identical to the give-up path below.
    kill "$MOSDNS_PID" "$AGH_PID" 2>/dev/null || true
    exit 0
}
trap term TERM INT

# ---- supervisor ----------------------------------------------------------
# Poll both PIDs and restart whichever dies. Deliberately NOT using
# `wait -n`: it is unreliable here (busybox support varies, and a child
# exiting non-zero makes `wait -n || wait` block forever on the survivor),
# which would leave a half-dead container running with no DNS.
#
# RouterOS has no container restart policy, so recovering in-process is
# the only way a crash self-heals. If a process keeps dying we exit
# non-zero so the container stops and the failure is visible in
# /container print. With the watchdog scheduler from routeros-setup.rsc
# installed this is not really "giving up" — it is a ~5 minute backoff,
# after which the whole container is started again.

RUNNING=1
MOSDNS_FAILS=0
AGH_FAILS=0
MAX_FAILS=5          # give up after this many restarts of the same process
WINDOW_RESET=1800    # seconds of stability before the counter resets
LAST_FAIL=0

while [ "$RUNNING" = "1" ]; do
    # Background the sleep and wait on it. A plain `sleep 5` is NOT
    # interruptible: POSIX sh finishes the running command before servicing
    # a trap, so /container stop would sit for up to 5s before shutdown even
    # began (measured ~4.5s). `wait` is interruptible; this drops it to ~0.
    sleep 5 & SLEEP_PID=$!
    wait "$SLEEP_PID" 2>/dev/null || true

    NOW=$(date +%s)

    # reset failure counters after a long stable period
    if [ "$LAST_FAIL" -ne 0 ] && [ $((NOW - LAST_FAIL)) -gt "$WINDOW_RESET" ]; then
        MOSDNS_FAILS=0
        AGH_FAILS=0
        LAST_FAIL=0
    fi

    if ! kill -0 "$MOSDNS_PID" 2>/dev/null; then
        MOSDNS_FAILS=$((MOSDNS_FAILS + 1))
        LAST_FAIL=$NOW
        echo "[entrypoint] WARNING: mosdns died (failure $MOSDNS_FAILS/$MAX_FAILS)"
        if [ "$MOSDNS_FAILS" -ge "$MAX_FAILS" ]; then
            echo "[entrypoint] mosdns keeps failing - check /data/mosdns/config.yaml. Stopping container."
            kill "$AGH_PID" 2>/dev/null
            exit 1
        fi
        start_mosdns
    fi

    if ! kill -0 "$AGH_PID" 2>/dev/null; then
        AGH_FAILS=$((AGH_FAILS + 1))
        LAST_FAIL=$NOW
        echo "[entrypoint] WARNING: AdGuard Home died (failure $AGH_FAILS/$MAX_FAILS)"
        if [ "$AGH_FAILS" -ge "$MAX_FAILS" ]; then
            echo "[entrypoint] AdGuard Home keeps failing - check /data/adguard/conf/. Stopping container."
            kill "$MOSDNS_PID" 2>/dev/null
            exit 1
        fi
        start_agh
    fi
done
