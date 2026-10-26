#!/usr/bin/env bash
# ==============================================================================
# Enterprise Cloud Migration Lab — Turnkey Host Init Boot Script (Ubuntu 24.04)
# Target Host: Azure Ubuntu 24.04 LTS (HV01 / basevm)
# Execution: Runs as cloud-init custom_data / VM Extension / RunShellScript on initial boot
# Installs: KVM, QEMU, libvirt, Cockpit, Vagrant, vagrant-libvirt, Storage, Net
# ==============================================================================

set -u
export DEBIAN_FRONTEND=noninteractive

LOG_FILE="/var/log/host-init-boot.log"

# Helper: Wait for background apt / unattended-upgrades lock to clear
wait_for_apt() {
    local max_wait=300
    local waited=0

    # Stop background apt auto-update services that contest dpkg locks on fresh boot
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

run_host_init() {
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

    # Ensure target user exists with proper sudoers and known lab password
    if ! id -u "${TARGET_USER}" >/dev/null 2>&1; then
        echo "[*] Creating lab admin user: ${TARGET_USER}..."
        useradd -m -s /bin/bash "${TARGET_USER}" || true
    fi

    echo "${TARGET_USER}:LabAdmin2026!#" | chpasswd || true
    usermod -aG sudo "${TARGET_USER}" || true
    echo "${TARGET_USER} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/99-${TARGET_USER}"
    chmod 0440 "/etc/sudoers.d/99-${TARGET_USER}"
    echo "[OK] Target administrator user configured: ${TARGET_USER}"

    # Enable Password Authentication in SSH
    sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    sed -i 's/^#\?KbdInteractiveAuthentication .*/KbdInteractiveAuthentication yes/' /etc/ssh/sshd_config
    systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true

    # ==============================================================================
    # STEP 1: VERIFY HARDWARE VIRTUALIZATION
    # ==============================================================================
    echo -e "\n>>> [1/7] Verifying KVM Hardware Virtualization Extensions..."
    wait_for_apt
    apt-get update -qq || true
    apt-get install -y -qq cpu-checker || true

    if kvm-ok >/dev/null 2>&1; then
        echo "[OK] KVM hardware virtualization acceleration is supported and active."
    else
        echo "[!] Notice: kvm-ok check returned non-zero. Continuing with libvirt setup..."
    fi

    # ==============================================================================
    # STEP 2: INSTALL QEMU, KVM, AND LIBVIRT
    # ==============================================================================
    echo -e "\n>>> [2/7] Installing QEMU, KVM, and libvirt packages..."
    wait_for_apt
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
        net-tools \
        pkg-config || true

    systemctl enable --now libvirtd 2>/dev/null || true
    systemctl start libvirtd 2>/dev/null || true

    # Add target user to kvm and libvirt groups
    usermod -aG kvm,libvirt "${TARGET_USER}" || true
    echo "[OK] User '${TARGET_USER}' added to kvm and libvirt groups."

    # Wait for libvirtd socket to become responsive
    for i in {1..15}; do
        if virsh list >/dev/null 2>&1; then
            echo "[OK] libvirtd is responsive."
            break
        fi
        sleep 2
    done

    # ==============================================================================
    # STEP 3: INSTALL COCKPIT WEB CONSOLE & MACHINES EXTENSION
    # ==============================================================================
    echo -e "\n>>> [3/7] Installing Cockpit Web Console & Machines Extension..."
    wait_for_apt
    apt-get install -y -qq cockpit cockpit-machines || true
    systemctl enable --now cockpit.socket 2>/dev/null || true
    echo "[OK] Cockpit web console running on port 9090."

    # ==============================================================================
    # STEP 4: INSTALL VAGRANT AND VAGRANT-LIBVIRT PLUGIN
    # ==============================================================================
    echo -e "\n>>> [4/7] Installing HashiCorp Vagrant and vagrant-libvirt plugin..."
    if ! command -v vagrant >/dev/null 2>&1; then
        echo "[*] Adding HashiCorp repository..."
        wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg --yes 2>/dev/null || true
        echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/hashicorp.list >/dev/null || true
        wait_for_apt
        apt-get update -qq || true
        apt-get install -y -qq vagrant || true
    fi

    # Dependencies for vagrant-libvirt compilation
    wait_for_apt
    apt-get install -y -qq build-essential libxslt-dev libxml2-dev libvirt-dev zlib1g-dev ruby-dev pkg-config || true

    TARGET_HOME=$(eval echo "~${TARGET_USER}")
    if [[ -d "${TARGET_HOME}" ]]; then
        sudo -H -u "${TARGET_USER}" bash -c "
            export HOME='${TARGET_HOME}'
            export PKG_CONFIG_PATH=\"/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:\${PKG_CONFIG_PATH:-}\"
            export CONFIGURE_ARGS=\"with-libvirt-include=/usr/include/libvirt with-libvirt-lib=/usr/lib/x86_64-linux-gnu\"
            if ! vagrant plugin list 2>/dev/null | grep -q 'vagrant-libvirt'; then
                echo '[*] Installing vagrant-libvirt plugin for ${TARGET_USER}...'
                vagrant plugin install vagrant-libvirt || true
            else
                echo '[OK] vagrant-libvirt plugin is already installed for ${TARGET_USER}.'
            fi
        "
    fi

    # ==============================================================================
    # STEP 5: CONFIGURE STORAGE DISK & MOUNT (/mnt/vm-storage)
    # ==============================================================================
    echo -e "\n>>> [5/7] Configuring Dedicated VM Storage (/mnt/vm-storage)..."
    MOUNT_POINT="/mnt/vm-storage"
    mkdir -p "${MOUNT_POINT}"

    # Identify candidate data disk (/dev/disk/azure/scsi1/lun0, /dev/sdc, /dev/sdc1, etc.)
    TARGET_DEV=""
    for candidate in "/dev/disk/azure/scsi1/lun0" "/dev/sdc1" "/dev/sdc" "/dev/sdd" "/dev/nvme0n2" "/dev/nvme1n1"; do
        if [[ -b "${candidate}" ]]; then
            TARGET_DEV="${candidate}"
            break
        fi
    done

    if [[ -z "${TARGET_DEV}" ]]; then
        # Look for any unmounted disk >= 100GB
        CANDIDATE=$(lsblk -dpno NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null | grep "disk" | awk '$4 == "" && $2 ~ /^[1-9][0-9]{2}G/ {print $1}' | head -n 1 || true)
        if [[ -n "${CANDIDATE}" && -b "${CANDIDATE}" ]]; then
            TARGET_DEV="${CANDIDATE}"
        fi
    fi

    if [[ -n "${TARGET_DEV}" ]]; then
        echo "[*] Found data disk device: ${TARGET_DEV}"
        FS_TYPE=$(blkid -o value -s TYPE "${TARGET_DEV}" || true)
        if [[ -z "${FS_TYPE}" ]]; then
            echo "[*] Formatting ${TARGET_DEV} as ext4..."
            mkfs.ext4 -F -L vm-storage "${TARGET_DEV}" || true
        fi

        if ! mountpoint -q "${MOUNT_POINT}"; then
            mount "${TARGET_DEV}" "${MOUNT_POINT}" || true
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
        virsh pool-define-as --name vm-storage --type dir --target "${MOUNT_POINT}" || true
        virsh pool-build vm-storage 2>/dev/null || true
        virsh pool-start vm-storage || true
    fi
    virsh pool-autostart vm-storage || true
    virsh pool-refresh vm-storage || true
    echo "[OK] libvirt storage pool 'vm-storage' configured."

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

    virsh net-define "${NET_XML}" || true
    virsh net-start migration-lab || true
    virsh net-autostart migration-lab || true
    rm -f "${NET_XML}"
    echo "[OK] Network 'migration-lab' (10.10.10.0/24) active on virbr10."

    # Configure NAT Port Forwarding for Port 80 to APP01 (10.10.10.20:80)
    sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
    iptables -t nat -D PREROUTING -p tcp --dport 80 -j DNAT --to-destination 10.10.10.20:80 2>/dev/null || true
    iptables -t nat -C PREROUTING -i eth0 -p tcp --dport 80 -j DNAT --to-destination 10.10.10.20:80 2>/dev/null || \
      iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 80 -j DNAT --to-destination 10.10.10.20:80 || true
    iptables -t nat -C POSTROUTING -d 10.10.10.20 -p tcp --dport 80 -j MASQUERADE 2>/dev/null || \
      iptables -t nat -A POSTROUTING -d 10.10.10.20 -p tcp --dport 80 -j MASQUERADE || true
    iptables -C FORWARD -d 10.10.10.20 -p tcp --dport 80 -j ACCEPT 2>/dev/null || \
      iptables -I FORWARD 1 -d 10.10.10.20 -p tcp --dport 80 -j ACCEPT || true

    # ==============================================================================
    # STEP 7: PRE-DOWNLOAD BENTO/UBUNTU-24.04 VAGRANT BOX
    # ==============================================================================
    echo -e "\n>>> [7/7] Pre-caching bento/ubuntu-24.04 Vagrant Box..."
    if [[ -d "${TARGET_HOME}" ]]; then
        sudo -H -u "${TARGET_USER}" bash -c "
            export HOME='${TARGET_HOME}'
            if ! vagrant box list 2>/dev/null | grep -q 'bento/ubuntu-24.04'; then
                echo '[*] Downloading bento/ubuntu-24.04 (libvirt provider)...'
                vagrant box add bento/ubuntu-24.04 --provider libvirt || true
            else
                echo '[OK] bento/ubuntu-24.04 box is present.'
            fi
        "
    fi

    echo -e "\n=================================================================="
    echo "  Turnkey Host Init Boot Completed Successfully!                  "
    echo "  Finished at: $(date -u '+%Y-%m-%d %H:%M:%S UTC')                "
    echo "=================================================================="
}

# Run the installation and log to both stdout (for cloud-init / Azure RunShellScript) and LOG_FILE
run_host_init "$@" 2>&1 | tee -a "${LOG_FILE}"
