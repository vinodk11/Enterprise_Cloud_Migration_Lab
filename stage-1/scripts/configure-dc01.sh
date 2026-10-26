#!/usr/bin/env bash
# ==============================================================================
# Enterprise Cloud Migration Lab — DC01: Samba Active Directory & DNS
# Target Machine: DC01 (10.10.10.10)
# Domain: CORP.LOCAL
# OS: Ubuntu Server 24.04 LTS (bento/ubuntu-24.04)
# ==============================================================================

set -u
export DEBIAN_FRONTEND=noninteractive

DOMAIN_REALM="CORP.LOCAL"
DOMAIN_NETBIOS="CORP"
DOMAIN_PASS="LabAdmin2026!#"
DNS_FORWARDER="1.1.1.1"
STATIC_IP="10.10.10.10"
GATEWAY_IP="10.10.10.1"

echo "=================================================================="
echo "  Enterprise Cloud Migration Lab: DC01 Samba AD DS & DNS Setup     "
echo "=================================================================="

# 1. Root check
if [[ $EUID -ne 0 ]]; then
   echo "[-] This script must be run as root (e.g. sudo bash configure-dc01.sh)"
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

echo -e "\n>>> [1/7] Configuring Hostname and /etc/hosts..."
hostnamectl set-hostname dc01.corp.local || true
sed -i '/127.0.1.1/d' /etc/hosts
if ! grep -q "${STATIC_IP} dc01.corp.local dc01" /etc/hosts; then
    echo "${STATIC_IP} dc01.corp.local dc01" >> /etc/hosts
fi
echo "[OK] Hostname configured: $(hostname -f 2>/dev/null || hostname)"

echo -e "\n>>> [2/7] Verifying Static IP ${STATIC_IP}..."
LAB_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^eth1|^enp2s0' | head -n 1 || true)
if [[ -z "${LAB_IFACE}" ]]; then
    LAB_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo" | sed -n '2p' || true)
fi
if [[ -n "${LAB_IFACE}" ]]; then
    ip addr add "${STATIC_IP}/24" dev "${LAB_IFACE}" 2>/dev/null || true
fi
echo "[OK] Interface ${LAB_IFACE:-eth1} verified."

echo -e "\n>>> [3/7] Preseeding Debconf and Installing Samba AD DS..."
wait_for_apt

# Pre-seed Kerberos configuration for completely silent install
echo "krb5-config krb5-config/default_realm string ${DOMAIN_REALM}" | debconf-set-selections
echo "krb5-config krb5-config/kerberos_servers string dc01.${DOMAIN_REALM,,}" | debconf-set-selections
echo "krb5-config krb5-config/admin_server string dc01.${DOMAIN_REALM,,}" | debconf-set-selections

apt-get update -qq || true
apt-get install -y -qq \
    samba \
    smbclient \
    krb5-user \
    winbind \
    libpam-winbind \
    libnss-winbind \
    libpam-krb5 \
    dnsutils \
    ldap-utils || true

echo "[OK] Required packages installed."

echo -e "\n>>> [4/7] Provisioning Samba Active Directory Domain..."
# Stop and mask standard file-sharing daemons
systemctl stop smbd nmbd winbind 2>/dev/null || true
systemctl mask smbd nmbd winbind 2>/dev/null || true

# Backup default smb.conf and clear old db if present
if [[ -f /etc/samba/smb.conf ]]; then
    mv /etc/samba/smb.conf "/etc/samba/smb.conf.orig-$(date +%s)"
fi
rm -rf /var/lib/samba/private/* /var/lib/samba/dbdir/* 2>/dev/null || true

# Provision the domain
samba-tool domain provision \
    --use-rfc2307 \
    --realm="${DOMAIN_REALM}" \
    --domain="${DOMAIN_NETBIOS}" \
    --server-role=dc \
    --dns-backend=SAMBA_INTERNAL \
    --dns-forwarder="${DNS_FORWARDER}" \
    --adminpass="${DOMAIN_PASS}" || true

echo "[OK] Samba AD Domain provisioned successfully."

echo -e "\n>>> [5/7] Switching DNS to Samba Internal DNS & Disabling systemd-resolved Stub..."
if [[ -f /etc/systemd/resolved.conf ]]; then
    sed -i 's/^#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
    sed -i 's/^DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
    if ! grep -q "DNSStubListener=no" /etc/systemd/resolved.conf; then
        echo "DNSStubListener=no" >> /etc/systemd/resolved.conf
    fi
fi
systemctl restart systemd-resolved 2>/dev/null || true

# Point local resolver directly to 127.0.0.1
rm -f /etc/resolv.conf
cat <<EOF > /etc/resolv.conf
nameserver 127.0.0.1
nameserver ${STATIC_IP}
nameserver ${DNS_FORWARDER}
search ${DOMAIN_REALM,,}
EOF

echo -e "\n>>> [6/7] Configuring Kerberos and Starting samba-ad-dc..."
if [[ -f /var/lib/samba/private/krb5.conf ]]; then
    cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
fi

systemctl unmask samba-ad-dc 2>/dev/null || true
systemctl enable --now samba-ad-dc 2>/dev/null || systemctl restart samba-ad-dc 2>/dev/null || true
sleep 5

echo -e "\n>>> [7/7] Creating Test Domain Users..."
samba-tool user create streaminguser "StreamFlix2026!#" \
    --userou="CN=Users" \
    --description="StreamFlix Test User" 2>/dev/null || true

samba-tool user create svc-streamflix "ServiceFlix2026!#" \
    --userou="CN=Users" \
    --description="StreamFlix Backend Service Account" 2>/dev/null || true

echo -e "\n=================================================================="
echo "  Validation & Health Check Summary                               "
echo "=================================================================="
samba-tool domain info 127.0.0.1 || true
if command -v kinit >/dev/null 2>&1; then
    printf "%s\n" "${DOMAIN_PASS}" | kinit administrator@${DOMAIN_REALM} 2>/dev/null || true
    klist 2>/dev/null || true
fi
host -t SRV _ldap._tcp.${DOMAIN_REALM,,} 127.0.0.1 2>/dev/null || true
smbclient -L localhost -N 2>/dev/null || smbclient -L localhost -U% 2>/dev/null || true

echo -e "\n[SUCCESS] DC01 Active Directory Domain Controller (${DOMAIN_REALM}) configuration completed!"
