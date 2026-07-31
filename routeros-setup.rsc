# =====================================================================
# MikroTik RB5009UPr - RouterOS 7.23.2 container setup
# Image: yourdockerhubuser/mosdns-adguard:latest  (arm64)
# Network plan:
#   LAN bridge      : 192.168.88.1/24 (default)
#   container bridge: 172.18.53.1/24
#   container veth  : 172.18.53.2
# =====================================================================

# ---------------------------------------------------------------
# STEP 0 - one-time prerequisites (do these manually first):
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

# Put the container bridge in the LAN list so the default filter rules treat
# it as trusted (LAN -> 172.18.53.2:3000 for the AGH UI, container -> WAN).
# Check it did NOT end up in the WAN list: the AGH web UI has no password.
/interface/list/member
add list=LAN interface=br-containers

# --- 3. NAT so the container can reach the internet ---
/ip/firewall/nat
add chain=srcnat src-address=172.18.53.0/24 action=masquerade \
    comment="containers outbound"

# --- 4. registry mirror - ONLY needed for online pulls; skip for tar import.
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
# dns= is important. Without it RouterOS builds the container's
# /etc/resolv.conf from /ip dns servers. If that points back at the
# container (see step 8) any unpinned upstream in mosdns.yaml resolves
# via AdGuard Home -> mosdns -> itself and hangs. Pin it externally so the
# container never depends on the router's resolver.
/container
add remote-image=yourdockerhubuser/mosdns-adguard:latest \
    interface=veth-dns \
    root-dir=usb1/containers/dns \
    mounts=dns-data \
    envlist=dns-env \
    dns=223.5.5.5,119.29.29.29 \
    start-on-boot=yes \
    logging=yes \
    comment="mosdns + AdGuard Home"

# Per-container limits (ram-high in step 4 is the GLOBAL default; this is
# the one that applies to this container).
/container
set [find comment~"mosdns"] memory-high=384M shm-size=64M

# Offline alternative to remote-image: download mosdns-adg.tar from the repo
# Releases page, scp it to usb1/, and swap the line above for:
#   add file=usb1/mosdns-adg.tar interface=veth-dns ... (rest identical)

# Watch pull progress:  /container/print   (status: extracting -> stopped)
# Then start it:        /container/start [find comment~"mosdns"]
# Logs:                 /log/print where topics~"container"

# --- 8. hand the DNS to your LAN ---
# Give DHCP clients the container as DNS server:
/ip/dhcp-server/network
set [find address="192.168.88.0/24"] dns-server=172.18.53.2

# The router itself must NOT use the container as its resolver. If it does,
# the router cannot resolve anything while the container is stopped (upgrades,
# or after the entrypoint gives up), and it closes a resolution loop through
# the container's own resolv.conf. Keep it external:
/ip/dns
set servers=223.5.5.5,119.29.29.29

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

# This only covers port 53. Chrome, Firefox and iOS will use DoH on 443 and
# bypass the whole pipeline. DoT is one line to close; DoH needs an IP list
# and is a losing battle, so it is left out.
/ip/firewall/filter
add chain=forward protocol=tcp dst-port=853 src-address=192.168.88.0/24 \
    action=drop comment="block DoT bypass"

# --- 10. AdGuard Home web UI ---
# From LAN, open:  http://172.18.53.2:3000
# It works immediately (no wizard) - SET A PASSWORD in Settings first!

# =====================================================================
# Upgrading later (new image = new mosdns/AGH + fresh CN rule lists):
#   /container/stop  [find comment~"mosdns"]
#   /container/remove [find comment~"mosdns"]
#   ...then repeat step 7. Your settings persist in /usb1/dns-data.
# =====================================================================

# =====================================================================
# OPTIONAL: auto-restart the container if it stops
# RouterOS has no container restart policy. The entrypoint restarts a
# crashed process internally, and only exits if a process keeps failing.
# This scheduler catches that case (and any external stop).
# =====================================================================
# VERIFY BEFORE TRUSTING THIS: force a failure (put a syntax error in
# /usb1/dns-data/mosdns/config.yaml), let the entrypoint burn through
# MAX_FAILS, then run /container print and read the actual status string.
# If it is not one of the values below, the watchdog will never fire and
# the container stays down - add whatever you see to the list.
/system/script
add name=dns-container-watchdog policy=read,write,test source={
    :foreach c in=[/container find where comment~"mosdns"] do={
        :local s [/container get $c status];
        :if ($s = "stopped" || $s = "error") do={
            :log warning ("dns container status=" . $s . ", restarting");
            /container start $c;
        }
    }
}
/system/scheduler
add name=dns-container-watchdog interval=5m on-event=dns-container-watchdog \
    policy=read,write,test \
    comment="restart DNS container if it stopped"

# NOTE: Docker HEALTHCHECK is ignored by RouterOS - it does not act on
# health status. The scheduler above is the only automatic recovery.
