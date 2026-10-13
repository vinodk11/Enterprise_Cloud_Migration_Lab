#!/usr/bin/env bash
# ==============================================================================
# Enterprise Cloud Migration Lab — Ubuntu 24.04 Host Prerequisites Installer
# Target Host: Azure Ubuntu 24.04 LTS (HV01 / basevm)
# Installs: KVM, QEMU, libvirt, Cockpit, Vagrant, vagrant-libvirt
# ==============================================================================

set -euo pipefail

echo "=================================================================="
echo "  Enterprise Cloud Migration Lab: Host Setup (Ubuntu 24.04)        "
echo "=================================================================="

# 1. Root check
if [[ $EUID -ne 0 ]]; then
   echo "[-] This script must be run as root (e.g. sudo bash install-host-prereqs.sh)"
   exit 1
fi

TARGET_USER="${SUDO_USER:-azureuser}"

echo -e "\n>>> [1/5] Checking CPU Hardware Virtualization..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq cpu-checker

if kvm-ok; then
    echo "[OK] KVM hardware virtualization acceleration is supported and enabled."
else
    echo "[!] Warning: kvm-ok did not return 0. Verify Azure Nested Virtualization is enabled on this VM size."
fi

echo -e "\n>>> [2/5] Installing QEMU, KVM, and libvirt packages..."
apt-get install -y -qq \
    qemu-kvm \
    libvirt-daemon-system \
    libvirt-clients \
    bridge-utils \
    virtinst \
    libguestfs-tools \
    git \
    curl \
    wget \
    jq

systemctl enable --now libvirtd || true
systemctl start libvirtd || true

# Add target user to kvm and libvirt groups
usermod -aG kvm,libvirt "${TARGET_USER}" || true
echo "[OK] User '${TARGET_USER}' added to kvm and libvirt groups."

echo -e "\n>>> [3/5] Installing Cockpit Web Console & Machines Extension..."
apt-get install -y -qq cockpit cockpit-machines
systemctl enable --now cockpit.socket
echo "[OK] Cockpit web console is running on port 9090 (https://<host-ip>:9090)."

echo -e "\n>>> [4/5] Installing Vagrant and vagrant-libvirt plugin..."
# Check if Vagrant is installed
if ! command -v vagrant >/dev/null 2>&1; then
    echo "[*] Installing HashiCorp Vagrant..."
    wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg --yes
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list
    apt-get update -qq
    apt-get install -y -qq vagrant
fi

echo "[OK] Vagrant $(vagrant --version) installed."

# Dependencies for vagrant-libvirt plugin compilation
apt-get install -y -qq build-essential libxslt-dev libxml2-dev libvirt-dev zlib1g-dev ruby-dev

# Install plugin as target user
sudo -u "${TARGET_USER}" bash -c '
    if ! vagrant plugin list | grep -q "vagrant-libvirt"; then
        echo "[*] Installing vagrant-libvirt plugin..."
        vagrant plugin install vagrant-libvirt
    else
        echo "[OK] vagrant-libvirt plugin is already installed."
    fi
'

echo -e "\n>>> [5/5] Pre-caching bento/ubuntu-24.04 Vagrant Box..."
sudo -u "${TARGET_USER}" bash -c '
    if ! vagrant box list | grep -q "bento/ubuntu-24.04"; then
        echo "[*] Downloading bento/ubuntu-24.04 (libvirt provider)..."
        vagrant box add bento/ubuntu-24.04 --provider libvirt || true
    else
        echo "[OK] bento/ubuntu-24.04 box is present."
    fi
'

echo -e "\n=================================================================="
echo "  Host Prerequisites Installation Complete!                      "
echo "  Next Step: Run ./deploy-vms-loop.sh to launch the 4 lab VMs.    "
echo "=================================================================="
