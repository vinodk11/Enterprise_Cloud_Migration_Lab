#!/usr/bin/env bash
# ==============================================================================
# Enterprise Cloud Migration Lab — DC01: Samba Active Directory & DNS
# Target Machine: DC01 (10.10.10.10)
# Domain: CORP.LOCAL
# OS: Ubuntu Server 24.04 LTS (bento/ubuntu-24.04)
# ==============================================================================

set -euo pipefail

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

echo -e "\n>>> [1/7] Configuring Hostname and /etc/hosts..."
hostnamectl set-hostname dc01.corp.local
sed -i '/127.0.1.1/d' /etc/hosts
if ! grep -q "${STATIC_IP} dc01.corp.local dc01" /etc/hosts; then
    echo "${STATIC_IP} dc01.corp.local dc01" >> /etc/hosts
fi
echo "[OK] Hostname configured: $(hostname -f)"

echo -e "\n>>> [2/7] Binding Static IP ${STATIC_IP} via Netplan..."
# Match the lab interface by MAC or second interface
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
        addresses: [127.0.0.1, ${STATIC_IP}, ${DNS_FORWARDER}]
EOF
    chmod 600 /etc/netplan/60-migration-lab.yaml
    netplan apply || true
    echo "[OK] Netplan configured on interface ${LAB_IFACE} with IP ${STATIC_IP}/24."
fi

# Ensure runtime IP is present
ip addr add "${STATIC_IP}/24" dev "${LAB_IFACE:-eth1}" 2>/dev/null || true

echo -e "\n>>> [3/7] Disabling systemd-resolved port 53 listener..."
# systemd-resolved listens on 127.0.0.53:53 by default, which conflicts with Samba internal DNS
if [[ -f /etc/systemd/resolved.conf ]]; then
    sed -i 's/^#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
    sed -i 's/^DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
    if ! grep -q "DNSStubListener=no" /etc/systemd/resolved.conf; then
        echo "DNSStubListener=no" >> /etc/systemd/resolved.conf
    fi
fi
systemctl restart systemd-resolved || true

echo -e "\n>>> [4/7] Installing Samba AD DS and Kerberos packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
    samba \
    smbclient \
    krb5-user \
    winbind \
    libpam-winbind \
    libnss-winbind \
    libpam-krb5 \
    dnsutils \
    ldap-utils

echo "[OK] Required packages installed."

echo -e "\n>>> [5/7] Provisioning Samba Active Directory Domain..."
# Stop and mask standard file-sharing daemons (Samba AD uses samba-ad-dc)
systemctl stop smbd nmbd winbind || true
systemctl mask smbd nmbd winbind || true

# Backup default smb.conf
if [[ -f /etc/samba/smb.conf ]]; then
    mv /etc/samba/smb.conf "/etc/samba/smb.conf.orig-$(date +%s)"
fi

# Provision the domain
samba-tool domain provision \
    --use-rfc2307 \
    --realm="${DOMAIN_REALM}" \
    --domain="${DOMAIN_NETBIOS}" \
    --server-role=dc \
    --dns-backend=SAMBA_INTERNAL \
    --dns-forwarder="${DNS_FORWARDER}" \
    --adminpass="${DOMAIN_PASS}"

echo "[OK] Samba AD Domain provisioned successfully."

echo -e "\n>>> [6/7] Configuring Kerberos, DNS, and Starting Service..."
# Use Samba's generated Kerberos configuration
if [[ -f /var/lib/samba/private/krb5.conf ]]; then
    cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
fi

# Point local resolver to Samba internal DNS
rm -f /etc/resolv.conf
cat <<EOF > /etc/resolv.conf
nameserver 127.0.0.1
nameserver ${STATIC_IP}
nameserver ${DNS_FORWARDER}
search ${DOMAIN_REALM,,}
EOF

# Start samba-ad-dc
systemctl unmask samba-ad-dc || true
systemctl enable --now samba-ad-dc
sleep 5

echo -e "\n>>> [7/7] Creating Test Domain Users..."
samba-tool user create streaminguser "StreamFlix2026!#" \
    --userou="CN=Users" \
    --description="StreamFlix Test User" || true

samba-tool user create svc-streamflix "ServiceFlix2026!#" \
    --userou="CN=Users" \
    --description="StreamFlix Backend Service Account" || true

echo -e "\n=================================================================="
echo "  Validation & Health Check Summary                               "
echo "=================================================================="
samba-tool domain info 127.0.0.1
echo "${DOMAIN_PASS}" | kinit administrator@${DOMAIN_REALM}
klist
host -t SRV _ldap._tcp.${DOMAIN_REALM,,} 127.0.0.1 || true
smbclient -L localhost -U%

echo -e "\n[SUCCESS] DC01 Active Directory Domain Controller (${DOMAIN_REALM}) is online and healthy!"
