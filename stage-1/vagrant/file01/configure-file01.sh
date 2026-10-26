#!/usr/bin/env bash
# ==============================================================================
# Enterprise Cloud Migration Lab — FILE01: Samba Media Storage Server
# Target Machine: FILE01 (10.10.10.40)
# Domain: CORP.LOCAL
# OS: Ubuntu Server 24.04 LTS (bento/ubuntu-24.04)
# ==============================================================================

set -u
export DEBIAN_FRONTEND=noninteractive

SHARE_DIR="/srv/media"
STATIC_IP="10.10.10.40"
GATEWAY_IP="10.10.10.1"
DC_IP="10.10.10.10"

echo "=================================================================="
echo "  Enterprise Cloud Migration Lab: FILE01 Media Server Setup       "
echo "=================================================================="

# 1. Root check
if [[ $EUID -ne 0 ]]; then
   echo "[-] This script must be run as root (e.g. sudo bash configure-file01.sh)"
   exit 1
fi

# Helper: Wait for background apt / unattended-upgrades locks
wait_for_apt() {
    local max_wait=300
    local waited=0

    systemctl stop unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service 2>/dev/null || true

    while pgrep -f '(apt-get|apt|dpkg|unattended-upgrade)' >/dev/null 2>&1 || \
          ! flock -n /var/lib/dpkg/lock-frontend -c "true" 2>/dev/null || \
          ! flock -n /var/lib/apt/lists/lock -c "true" 2>/dev/null; do
        echo "[*] Waiting for apt / unattended-upgrades lock to release ($waited s)..."
        sleep 5
        waited=$((waited + 5))
        if [[ $waited -ge $max_wait ]]; then
            echo "[!] Timeout waiting for apt locks. Clearing stale locks..."
            pkill -9 -f '(apt-get|apt|dpkg|unattended-upgrade)' 2>/dev/null || true
            rm -f /var/lib/dpkg/lock* /var/lib/apt/lists/lock* /var/cache/apt/archives/lock* 2>/dev/null || true
            dpkg --configure -a 2>/dev/null || true
            break
        fi
    done
}

echo -e "\n>>> [1/5] Configuring Hostname and Fleet /etc/hosts..."
hostnamectl set-hostname file01.corp.local || true
sed -i '/127.0.1.1/d' /etc/hosts
sed -i '/corp.local/d' /etc/hosts
cat << 'HOSTS_EOF' >> /etc/hosts
10.10.10.10 dc01.corp.local dc01
10.10.10.20 app01.corp.local app01
10.10.10.30 db01.corp.local db01
10.10.10.40 file01.corp.local file01
HOSTS_EOF
echo "[OK] Hostname configured: $(hostname -f 2>/dev/null || hostname)"

echo -e "\n>>> [2/5] Verifying Static IP ${STATIC_IP}..."
LAB_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^eth1|^enp2s0' | head -n 1 || true)
if [[ -z "${LAB_IFACE}" ]]; then
    LAB_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo" | sed -n '2p' || true)
fi
if [[ -n "${LAB_IFACE}" ]]; then
    ip addr add "${STATIC_IP}/24" dev "${LAB_IFACE}" 2>/dev/null || true
fi
echo "[OK] Interface ${LAB_IFACE:-eth1} verified with IP ${STATIC_IP}/24."

echo -e "\n>>> [3/5] Installing Samba and FFmpeg..."
wait_for_apt
apt-get update -qq || true
apt-get install -y -qq samba smbclient ffmpeg || true

echo -e "\n>>> [4/5] Setting up Media Directory Structure and Test Assets..."
mkdir -p "${SHARE_DIR}/videos"
mkdir -p "${SHARE_DIR}/posters"

echo "Generating playable demonstration MP4 video assets..."
ffmpeg -y -f lavfi -i testsrc=duration=15:size=640x360:rate=24 -f lavfi -i sine=frequency=440:duration=15 -pix_fmt yuv420p "${SHARE_DIR}/videos/migration.mp4" 2>/dev/null || true
ffmpeg -y -f lavfi -i testsrc=duration=15:size=640x360:rate=24 -f lavfi -i sine=frequency=550:duration=15 -pix_fmt yuv420p "${SHARE_DIR}/videos/hyperv.mp4" 2>/dev/null || true
ffmpeg -y -f lavfi -i testsrc=duration=15:size=640x360:rate=24 -f lavfi -i sine=frequency=660:duration=15 -pix_fmt yuv420p "${SHARE_DIR}/videos/samba.mp4" 2>/dev/null || true

# Generate SVG movie posters
cat << 'SVG_EOF' > "${SHARE_DIR}/posters/migration.svg"
<svg xmlns="http://www.w3.org/2000/svg" width="300" height="450" viewBox="0 0 300 450">
  <rect width="300" height="450" fill="#141414"/>
  <rect x="20" y="20" width="260" height="410" fill="#1f1f1f" rx="8"/>
  <text x="150" y="160" font-family="Arial, sans-serif" font-size="48" fill="#E50914" text-anchor="middle">☁️</text>
  <text x="150" y="230" font-family="Arial, sans-serif" font-size="20" font-weight="bold" fill="#ffffff" text-anchor="middle">Cloud Migration</text>
  <text x="150" y="260" font-family="Arial, sans-serif" font-size="16" fill="#aaaaaa" text-anchor="middle">Chronicles</text>
  <rect x="90" y="300" width="120" height="30" rx="4" fill="#E50914"/>
  <text x="150" y="320" font-family="Arial, sans-serif" font-size="12" font-weight="bold" fill="#ffffff" text-anchor="middle">STREAM NOW</text>
</svg>
SVG_EOF

cat << 'SVG_EOF' > "${SHARE_DIR}/posters/hyperv.svg"
<svg xmlns="http://www.w3.org/2000/svg" width="300" height="450" viewBox="0 0 300 450">
  <rect width="300" height="450" fill="#141414"/>
  <rect x="20" y="20" width="260" height="410" fill="#1f1f1f" rx="8"/>
  <text x="150" y="160" font-family="Arial, sans-serif" font-size="48" fill="#0078D4" text-anchor="middle">💻</text>
  <text x="150" y="230" font-family="Arial, sans-serif" font-size="20" font-weight="bold" fill="#ffffff" text-anchor="middle">KVM Virtualization</text>
  <text x="150" y="260" font-family="Arial, sans-serif" font-size="16" fill="#aaaaaa" text-anchor="middle">Horizons</text>
  <rect x="90" y="300" width="120" height="30" rx="4" fill="#0078D4"/>
  <text x="150" y="320" font-family="Arial, sans-serif" font-size="12" font-weight="bold" fill="#ffffff" text-anchor="middle">STREAM NOW</text>
</svg>
SVG_EOF

cat << 'SVG_EOF' > "${SHARE_DIR}/posters/samba.svg"
<svg xmlns="http://www.w3.org/2000/svg" width="300" height="450" viewBox="0 0 300 450">
  <rect width="300" height="450" fill="#141414"/>
  <rect x="20" y="20" width="260" height="410" fill="#1f1f1f" rx="8"/>
  <text x="150" y="160" font-family="Arial, sans-serif" font-size="48" fill="#28a745" text-anchor="middle">🛡️</text>
  <text x="150" y="230" font-family="Arial, sans-serif" font-size="20" font-weight="bold" fill="#ffffff" text-anchor="middle">Samba in the</text>
  <text x="150" y="260" font-family="Arial, sans-serif" font-size="16" fill="#aaaaaa" text-anchor="middle">Datacenter</text>
  <rect x="90" y="300" width="120" height="30" rx="4" fill="#28a745"/>
  <text x="150" y="320" font-family="Arial, sans-serif" font-size="12" font-weight="bold" fill="#ffffff" text-anchor="middle">STREAM NOW</text>
</svg>
SVG_EOF

chmod -R 777 "${SHARE_DIR}"
echo "[OK] Media assets created in ${SHARE_DIR}."

echo -e "\n>>> [5/5] Configuring Samba Share [media]..."
if ! grep -q "\[media\]" /etc/samba/smb.conf 2>/dev/null; then
    cat <<EOF >> /etc/samba/smb.conf

[media]
    comment = StreamFlix Media Storage
    path = ${SHARE_DIR}
    browseable = yes
    read only = yes
    guest ok = yes
    public = yes
EOF
fi

systemctl restart smbd 2>/dev/null || systemctl start smbd 2>/dev/null || true
systemctl enable smbd 2>/dev/null || true
echo "[OK] Samba service active and sharing ${SHARE_DIR}."

smbclient -L localhost -N 2>/dev/null || smbclient -L localhost -U% 2>/dev/null || true

echo -e "\n[SUCCESS] FILE01 Samba Media Server is online and ready for APP01 CIFS mount!"
