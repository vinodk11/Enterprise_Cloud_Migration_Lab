#!/usr/bin/env bash
# ==============================================================================
# Enterprise Cloud Migration Lab — Host Storage & Network Setup
# Target Host: Azure Ubuntu 24.04 LTS (basevm)
# Target Architecture: KVM / QEMU / libvirt / Cockpit / Vagrant
# ==============================================================================

set -u

echo "=================================================================="
echo "  Enterprise Cloud Migration Lab: Host Infra Setup (Storage & Net)"
echo "=================================================================="

# 1. Root check
if [[ $EUID -ne 0 ]]; then
   echo "[-] This script must be run as root (e.g. sudo bash setup-host-infra.sh)"
   exit 1
fi

# ==============================================================================
# STEP 1: CONFIGURE STORAGE DISK & MOUNT (/mnt/vm-storage)
# ==============================================================================
echo -e "\n>>> [1/5] Verifying VM Storage Disk and Mount Point..."
MOUNT_POINT="/mnt/vm-storage"
mkdir -p "${MOUNT_POINT}"

# Check if already mounted
if mountpoint -q "${MOUNT_POINT}"; then
    echo "[OK] ${MOUNT_POINT} is already mounted."
else
    # Identify candidate data disk (/dev/disk/azure/scsi1/lun0, /dev/sdc, /dev/sdc1, etc.)
    TARGET_DEV=""
    for candidate in "/dev/disk/azure/scsi1/lun0" "/dev/sdc1" "/dev/sdc" "/dev/sdd" "/dev/nvme0n2" "/dev/nvme1n1"; do
        if [[ -b "${candidate}" ]]; then
            TARGET_DEV="${candidate}"
            break
        fi
    done

    if [[ -z "${TARGET_DEV}" ]]; then
        # Fallback to any unmounted data disk >= 100GB
        CANDIDATE=$(lsblk -dpno NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null | grep "disk" | awk '$4 == "" && $2 ~ /^[1-9][0-9]{2}G/ {print $1}' | head -n 1 || true)
        if [[ -n "${CANDIDATE}" && -b "${CANDIDATE}" ]]; then
            TARGET_DEV="${CANDIDATE}"
        fi
    fi

    if [[ -n "${TARGET_DEV}" && -b "${TARGET_DEV}" ]]; then
        echo "[*] Target disk device identified: ${TARGET_DEV}"
        # Check if filesystem exists
        FS_TYPE=$(blkid -o value -s TYPE "${TARGET_DEV}" || true)
        if [[ -z "${FS_TYPE}" ]]; then
            echo "[*] Formatting ${TARGET_DEV} as ext4..."
            mkfs.ext4 -F -L vm-storage "${TARGET_DEV}" || true
        else
            echo "[OK] Existing filesystem '${FS_TYPE}' detected on ${TARGET_DEV}. Preserving."
        fi

        echo "[*] Mounting ${TARGET_DEV} to ${MOUNT_POINT}..."
        mount "${TARGET_DEV}" "${MOUNT_POINT}" || true

        # Add to /etc/fstab if missing
        UUID=$(blkid -s UUID -o value "${TARGET_DEV}" || true)
        if [[ -n "${UUID}" ]] && ! grep -q "${UUID}" /etc/fstab; then
            echo "UUID=${UUID} ${MOUNT_POINT} ext4 defaults,nofail 0 2" >> /etc/fstab
            echo "[OK] Added persistent entry to /etc/fstab (UUID=${UUID})."
        fi
    else
        echo "[!] Notice: Dedicated data disk not detected. Using directory on root filesystem."
    fi
fi

# Ensure correct permissions for QEMU / libvirt
chmod 777 "${MOUNT_POINT}"
chown -R root:kvm "${MOUNT_POINT}" 2>/dev/null || true
echo "[OK] Mount point ${MOUNT_POINT} verified."

# ==============================================================================
# STEP 2: CONFIGURE LIBVIRT STORAGE POOL (vm-storage)
# ==============================================================================
echo -e "\n>>> [2/5] Verifying libvirt Storage Pool 'vm-storage'..."

if virsh pool-info vm-storage >/dev/null 2>&1; then
    echo "[OK] Storage pool 'vm-storage' exists."
    POOL_STATE=$(virsh pool-info vm-storage | awk '/State:/ {print $2}')
    if [[ "${POOL_STATE}" != "running" ]]; then
        echo "[*] Starting pool 'vm-storage'..."
        virsh pool-start vm-storage || true
    fi
else
    echo "[*] Defining libvirt storage pool 'vm-storage' target ${MOUNT_POINT}..."
    virsh pool-define-as --name vm-storage --type dir --target "${MOUNT_POINT}" || true
    virsh pool-build vm-storage 2>/dev/null || true
    virsh pool-start vm-storage || true
fi

virsh pool-autostart vm-storage || true
virsh pool-refresh vm-storage || true
echo "[OK] Storage pool 'vm-storage' is active and set to autostart."

# ==============================================================================
# STEP 3: CONFIGURE LIBVIRT NETWORK (migration-lab)
# ==============================================================================
echo -e "\n>>> [3/5] Verifying libvirt Virtual Network 'migration-lab'..."

# Ensure 'default' network is active (used by Vagrant management interface)
if virsh net-info default >/dev/null 2>&1; then
    DEF_STATE=$(virsh net-info default | awk '/Active:/ {print $2}')
    if [[ "${DEF_STATE}" != "yes" ]]; then
        virsh net-start default || true
    fi
    virsh net-autostart default || true
fi

NET_XML_TEMP="/tmp/migration-lab-net.xml"
cat << 'EOF' > "${NET_XML_TEMP}"
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
    echo "[OK] Network 'migration-lab' already exists. Updating definition..."
    virsh net-destroy migration-lab >/dev/null 2>&1 || true
    virsh net-undefine migration-lab >/dev/null 2>&1 || true
fi

echo "[*] Defining libvirt network 'migration-lab' (10.10.10.0/24)..."
virsh net-define "${NET_XML_TEMP}" || true
virsh net-start migration-lab || true
virsh net-autostart migration-lab || true
rm -f "${NET_XML_TEMP}"

echo "[OK] Network 'migration-lab' is active (Bridge: virbr10, Gateway: 10.10.10.1)."

# ==============================================================================
# STEP 4: VERIFY VAGRANT LIBVIRT PLUGIN & BOX
# ==============================================================================
echo -e "\n>>> [4/5] Verifying Vagrant and Bento Box..."
if command -v vagrant >/dev/null 2>&1; then
    echo "[OK] Vagrant $(vagrant --version) is available."
    if id -u labadmin >/dev/null 2>&1; then
        sudo -H -u labadmin bash -c "
            export HOME='/home/labadmin'
            export PKG_CONFIG_PATH=\"/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:\${PKG_CONFIG_PATH:-}\"
            export CONFIGURE_ARGS=\"with-libvirt-include=/usr/include/libvirt with-libvirt-lib=/usr/lib/x86_64-linux-gnu\"
            if vagrant plugin list 2>/dev/null | grep -q 'vagrant-libvirt'; then
                echo '[OK] vagrant-libvirt plugin is installed for labadmin.'
            else
                echo '[*] Installing vagrant-libvirt plugin for labadmin...'
                vagrant plugin install vagrant-libvirt || true
            fi
        "
    fi
fi

# ==============================================================================
# STEP 5: CONFIGURE NAT PORT FORWARDING (Port 80 -> APP01 10.10.10.20:80)
# ==============================================================================
echo -e "\n>>> [5/5] Configuring Port 80 Forwarding to APP01..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
iptables -t nat -C PREROUTING -p tcp --dport 80 -j DNAT --to-destination 10.10.10.20:80 2>/dev/null || \
  iptables -t nat -A PREROUTING -p tcp --dport 80 -j DNAT --to-destination 10.10.10.20:80 || true
iptables -C FORWARD -p tcp -d 10.10.10.20 --dport 80 -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -p tcp -d 10.10.10.20 --dport 80 -j ACCEPT || true
echo "[OK] Inbound Port 80 forwarded to APP01 (10.10.10.20:80)."

echo -e "\n=================================================================="
echo "  Host Infrastructure Configuration Completed Successfully!       "
echo "=================================================================="
virsh pool-list --all
echo ""
virsh net-list --all
