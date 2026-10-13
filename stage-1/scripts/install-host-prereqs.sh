#!/usr/bin/env bash
# ==============================================================================
# Enterprise Cloud Migration Lab — Turnkey Host Init Boot Script (Ubuntu 24.04)
# Target Host: Azure Ubuntu 24.04 LTS (HV01 / basevm)
# Execution: Runs as cloud-init custom_data / VM Extension on initial boot
# Installs: KVM, QEMU, libvirt, Cockpit, Vagrant, vagrant-libvirt, Storage, Net
# ==============================================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

LOG_FILE="/var/log/host-init-boot.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "=================================================================="
echo "  Enterprise Cloud Migration Lab: Host Init Boot Provisioning      "
echo "  Started at: $(date -u '+%Y-%m-%d %H:%M:%S UTC')                 "
echo "=================================================================="

# 1. Root check
if [[ $EUID -ne 0 ]]; then
   echo "[-] This script must be run as root."
   exit 1
fi

# Determine target administrator user
TARGET_USER="${1:-${SUDO_USER:-}}"
if [[ -z "${TARGET_USER}" ]]; then
    if id -u labadmin >/dev/null 2>&1; then
        TARGET_USER="labadmin"
    elif id -u azureuser >/dev/null 2>&1; then
        TARGET_USER="azureuser"
    else
        FIRST_USER=$(awk -F: '$3 >= 1000 && $3 < 60000 {print $1; exit}' /etc/passwd || true)
        TARGET_USER="${FIRST_USER:-labadmin}"
    fi
fi

# Ensure target user exists with proper sudoers and password
if ! id -u "${TARGET_USER}" >/dev/null 2>&1; then
    echo "[*] Creating lab admin user: ${TARGET_USER}..."
    useradd -m -s /bin/bash "${TARGET_USER}"
    echo "${TARGET_USER}:LabAdmin2026!#" | chpasswd
    usermod -aG sudo "${TARGET_USER}"
fi

echo "${TARGET_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/99-${TARGET_USER}"
chmod 0440 "/etc/sudoers.d/99-${TARGET_USER}"
echo "[OK] Target administrator user configured: ${TARGET_USER}"

# Enable Password Authentication in SSH
sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?KbdInteractiveAuthentication .*/KbdInteractiveAuthentication yes/' /etc/ssh/sshd_config
systemctl reload ssh || systemctl restart ssh || true

# ==============================================================================
# STEP 1: VERIFY HARDWARE VIRTUALIZATION
# ==============================================================================
echo -e "\n>>> [1/7] Verifying KVM Hardware Virtualization Extensions..."
apt-get update -qq
apt-get install -y -qq cpu-checker

if kvm-ok; then
    echo "[OK] KVM hardware virtualization acceleration is supported and active."
else
    echo "[!] Notice: kvm-ok returned non-zero. Nested virtualization will run with software emulation fallback if unavailable."
fi

# ==============================================================================
# STEP 2: INSTALL QEMU, KVM, AND LIBVIRT
# ==============================================================================
echo -e "\n>>> [2/7] Installing QEMU, KVM, and libvirt packages..."
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
    jq \
    net-tools

systemctl enable --now libvirtd || true
systemctl start libvirtd || true

# Add target user to kvm and libvirt groups
usermod -aG kvm,libvirt "${TARGET_USER}" || true
echo "[OK] User '${TARGET_USER}' added to kvm and libvirt groups."

# ==============================================================================
# STEP 3: INSTALL COCKPIT WEB CONSOLE & MACHINES EXTENSION
# ==============================================================================
echo -e "\n>>> [3/7] Installing Cockpit Web Console & Machines Extension..."
apt-get install -y -qq cockpit cockpit-machines
systemctl enable --now cockpit.socket
echo "[OK] Cockpit web console running on port 9090."

# ==============================================================================
# STEP 4: INSTALL VAGRANT AND VAGRANT-LIBVIRT PLUGIN
# ==============================================================================
echo -e "\n>>> [4/7] Installing HashiCorp Vagrant and vagrant-libvirt plugin..."
if ! command -v vagrant >/dev/null 2>&1; then
    echo "[*] Adding HashiCorp repository..."
    wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg --yes
    echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list
    apt-get update -qq
    apt-get install -y -qq vagrant
fi
echo "[OK] Installed Vagrant $(vagrant --version)."

# Install plugin build dependencies
apt-get install -y -qq build-essential libxslt-dev libxml2-dev libvirt-dev zlib1g-dev ruby-dev

# Install vagrant-libvirt plugin under target user environment
TARGET_HOME=$(eval echo "~${TARGET_USER}")
sudo -H -u "${TARGET_USER}" bash -c "
    export HOME='${TARGET_HOME}'
    if ! vagrant plugin list 2>/dev/null | grep -q 'vagrant-libvirt'; then
        echo '[*] Installing vagrant-libvirt plugin...'
        vagrant plugin install vagrant-libvirt
    else
        echo '[OK] vagrant-libvirt plugin is already installed.'
    fi
"

# ==============================================================================
# STEP 5: CONFIGURE STORAGE DISK & MOUNT (/mnt/vm-storage)
# ==============================================================================
echo -e "\n>>> [5/7] Configuring Dedicated VM Storage (/mnt/vm-storage)..."
MOUNT_POINT="/mnt/vm-storage"
mkdir -p "${MOUNT_POINT}"

# Identify candidate data disk (/dev/sdc, /dev/sdc1, or LUN 0)
TARGET_DEV=""
for candidate in "/dev/disk/azure/scsi1/lun0" "/dev/sdc1" "/dev/sdc" "/dev/sdd" "/dev/nvme1n1"; do
    if [[ -b "${candidate}" ]]; then
        TARGET_DEV="${candidate}"
        break
    fi
done

if [[ -n "${TARGET_DEV}" ]]; then
    echo "[*] Found data disk device: ${TARGET_DEV}"
    FS_TYPE=$(blkid -o value -s TYPE "${TARGET_DEV}" || true)
    if [[ -z "${FS_TYPE}" ]]; then
        echo "[*] Formatting ${TARGET_DEV} as ext4..."
        mkfs.ext4 -F -L vm-storage "${TARGET_DEV}"
    fi

    if ! mountpoint -q "${MOUNT_POINT}"; then
        mount "${TARGET_DEV}" "${MOUNT_POINT}"
    fi

    UUID=$(blkid -s UUID -o value "${TARGET_DEV}" || true)
    if [[ -n "${UUID}" ]] && ! grep -q "${UUID}" /etc/fstab; then
        echo "UUID=${UUID} ${MOUNT_POINT} ext4 defaults,nofail 0 2" >> /etc/fstab
    fi
else
    echo "[!] Notice: Dedicated data disk device not found. Using local directory."
fi

chmod 777 "${MOUNT_POINT}"
chown -R root:kvm "${MOUNT_POINT}" 2>/dev/null || true

# Configure libvirt pool 'vm-storage'
if virsh pool-info vm-storage >/dev/null 2>&1; then
    POOL_STATE=$(virsh pool-info vm-storage | awk '/State:/ {print $2}')
    if [[ "${POOL_STATE}" != "running" ]]; then
        virsh pool-start vm-storage || true
    fi
else
    virsh pool-define-as --name vm-storage --type dir --target "${MOUNT_POINT}"
    virsh pool-build vm-storage 2>/dev/null || true
    virsh pool-start vm-storage
fi
virsh pool-autostart vm-storage
virsh pool-refresh vm-storage
echo "[OK] libvirt storage pool 'vm-storage' active."

# ==============================================================================
# STEP 6: CONFIGURE LIBVIRT NETWORK (migration-lab)
# ==============================================================================
echo -e "\n>>> [6/7] Configuring libvirt Virtual Network 'migration-lab'..."
# Ensure default network is running
if virsh net-info default >/dev/null 2>&1; then
    DEF_STATE=$(virsh net-info default | awk '/Active:/ {print $2}')
    if [[ "${DEF_STATE}" != "yes" ]]; then
        virsh net-start default || true
    fi
    virsh net-autostart default || true
fi

NET_XML="/tmp/migration-lab-net.xml"
cat << 'EOF' > "${NET_XML}"
<network>
  <name>migration-lab</name>
  <forward mode='nat'/>
  <bridge name='virbr10' stp='on' delay='0'/>
  <ip address='10.10.10.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='10.10.10.100' end='10.10.10.200'/>
      <host mac='52:54:00:10:10:10' name='dc01' ip='10.10.10.10'/>
      <host mac='52:54:00:10:10:20' name='app01' ip='10.10.10.20'/>
      <host mac='52:54:00:10:10:30' name='db01' ip='10.10.10.30'/>
      <host mac='52:54:00:10:10:40' name='file01' ip='10.10.10.40'/>
    </dhcp>
  </ip>
</network>
EOF

if virsh net-info migration-lab >/dev/null 2>&1; then
    virsh net-destroy migration-lab >/dev/null 2>&1 || true
    virsh net-undefine migration-lab >/dev/null 2>&1 || true
fi

virsh net-define "${NET_XML}"
virsh net-start migration-lab
virsh net-autostart migration-lab
rm -f "${NET_XML}"
echo "[OK] Network 'migration-lab' (10.10.10.0/24) active on virbr10."

# ==============================================================================
# STEP 7: PRE-DOWNLOAD BENTO/UBUNTU-24.04 VAGRANT BOX
# ==============================================================================
echo -e "\n>>> [7/7] Pre-caching bento/ubuntu-24.04 Vagrant Box..."
sudo -H -u "${TARGET_USER}" bash -c "
    export HOME='${TARGET_HOME}'
    if ! vagrant box list 2>/dev/null | grep -q 'bento/ubuntu-24.04'; then
        echo '[*] Downloading bento/ubuntu-24.04 (libvirt provider)...'
        vagrant box add bento/ubuntu-24.04 --provider libvirt || true
    else
        echo '[OK] bento/ubuntu-24.04 box is present.'
    fi
"

echo -e "\n=================================================================="
echo "  Turnkey Host Init Boot Completed Successfully!                  "
echo "  Finished at: $(date -u '+%Y-%m-%d %H:%M:%S UTC')                "
echo "=================================================================="
