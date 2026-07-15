# =====================================================================
# MikroTik RB5009UPr — RouterOS 7.23.2 container setup
# Image: yourdockerhubuser/mosdns-adguard:latest  (arm64)
# Network plan:
#   LAN bridge      : 192.168.88.1/24 (default)
#   container bridge: 172.18.53.1/24
#   container veth  : 172.18.53.2
# =====================================================================

# ---------------------------------------------------------------
# STEP 0 — one-time prerequisites (do these manually first):
#   1. Download "Extra packages" for arm64 v7.23.2 from mikrotik.com,
#      upload container-7.23.2-arm64.npk to the router, reboot.
#   2. Enable container device-mode (REQUIRES pressing the physical
#      reset/mode button within 5 minutes after running):
#        /system/device-mode/update container=yes
#   3. STRONGLY recommended: plug a USB3 SSD/flash drive into the RB5009
#      (internal NAND is only 1 GB). It appears as usb1.
#      Format if needed:  /disk format-drive usb1 file-system=ext4
# ---------------------------------------------------------------

# --- 1. veth interface for the container ---
/interface/veth
add name=veth-dns address=172.18.53.2/24 gateway=172.18.53.1

# --- 2. dedicated bridge for containers ---
/interface/bridge
add name=br-containers
/ip/address
add address=172.18.53.1/24 interface=br-containers
/interface/bridge/port
add bridge=br-containers interface=veth-dns

# --- 3. NAT so the container can reach the internet ---
/ip/firewall/nat
add chain=srcnat src-address=172.18.53.0/24 action=masquerade \
    comment="containers outbound"

# --- 4. registry mirror — ONLY needed for online pulls; skip for tar import.
#     Replace <your-key> with YOUR personal xuanyuan.run endpoint (do not share it).
/container/config
set registry-url=https://<your-key>.xuanyuan.run \
    tmpdir=usb1/pull ram-high=384M

# --- 5. persistent /data mount (survives image upgrades) ---
/container/mounts
add name=dns-data src=/usb1/dns-data dst=/data

# --- 6. environment ---
/container/envs
add name=dns-env key=TZ value=Asia/Shanghai

# --- 7. the container itself ---
/container
add remote-image=yourdockerhubuser/mosdns-adguard:latest \
    interface=veth-dns \
    root-dir=usb1/containers/dns \
    mounts=dns-data \
    envlist=dns-env \
    start-on-boot=yes \
    logging=yes \
    comment="mosdns + AdGuard Home"

# Watch pull progress:  /container/print   (status: extracting -> stopped)
# Then start it:        /container/start [find comment~"mosdns"]
# Logs:                 /log/print where topics~"container"

# --- 8. hand the DNS to your LAN ---
# Give DHCP clients the container as DNS server:
/ip/dhcp-server/network
set [find address="192.168.88.0/24"] dns-server=172.18.53.2

# Let the router itself use it too:
/ip/dns
set servers=172.18.53.2

# --- 9. (optional but recommended) hijack hardcoded DNS ---
# Some devices (TVs, IoT) ignore DHCP and use 8.8.8.8 directly.
# Redirect all outbound port-53 traffic to the container:
/ip/firewall/nat
add chain=dstnat protocol=udp dst-port=53 src-address=192.168.88.0/24 \
    dst-address=!172.18.53.2 action=dst-nat to-addresses=172.18.53.2 \
    comment="hijack DNS udp"
add chain=dstnat protocol=tcp dst-port=53 src-address=192.168.88.0/24 \
    dst-address=!172.18.53.2 action=dst-nat to-addresses=172.18.53.2 \
    comment="hijack DNS tcp"

# --- 10. AdGuard Home web UI ---
# From LAN, open:  http://172.18.53.2:3000
# It works immediately (no wizard) — SET A PASSWORD in Settings first!

# =====================================================================
# Upgrading later (new image = new mosdns/AGH + fresh CN rule lists):
#   /container/stop  [find comment~"mosdns"]
#   /container/remove [find comment~"mosdns"]
#   ...then repeat step 7. Your settings persist in /usb1/dns-data.
# =====================================================================
