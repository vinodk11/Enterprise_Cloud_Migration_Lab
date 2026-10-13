#!/usr/bin/env bash
# ==============================================================================
# Enterprise Cloud Migration Lab — FILE01: Samba Media Storage Server
# Target Machine: FILE01 (10.10.10.40)
# Domain: CORP.LOCAL
# OS: Ubuntu Server 24.04 LTS (bento/ubuntu-24.04)
# ==============================================================================

set -euo pipefail

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

echo -e "\n>>> [1/5] Configuring Hostname and /etc/hosts..."
hostnamectl set-hostname file01.corp.local
sed -i '/127.0.1.1/d' /etc/hosts
if ! grep -q "${STATIC_IP} file01.corp.local file01" /etc/hosts; then
    echo "${STATIC_IP} file01.corp.local file01" >> /etc/hosts
fi
echo "[OK] Hostname configured: $(hostname -f)"

echo -e "\n>>> [2/5] Binding Static IP ${STATIC_IP} via Netplan..."
LAB_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^eth1|^enp2s0' | head -n 1 || true)
if [[ -z "${LAB_IFACE}" ]]; then
    LAB_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo" | sed -n '2p' || true)
fi

if [[ -n "${LAB_IFACE}" ]]; then
    cat <<EOF > /etc/netplan/60-migration-lab.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    ${LAB_IFACE}:
      addresses:
        - ${STATIC_IP}/24
      nameservers:
        addresses: [${DC_IP}, 1.1.1.1]
EOF
    chmod 600 /etc/netplan/60-migration-lab.yaml
    netplan apply || true
    echo "[OK] Netplan configured on interface ${LAB_IFACE} with IP ${STATIC_IP}/24."
fi
ip addr add "${STATIC_IP}/24" dev "${LAB_IFACE:-eth1}" 2>/dev/null || true

echo -e "\n>>> [3/5] Installing Samba and FFmpeg..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq samba smbclient ffmpeg

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
if ! grep -q "\[media\]" /etc/samba/smb.conf; then
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

systemctl restart smbd
systemctl enable smbd
echo "[OK] Samba service active and sharing ${SHARE_DIR}."

smbclient -L localhost -N

echo -e "\n[SUCCESS] FILE01 Samba Media Server is online and ready for APP01 CIFS mount!"
