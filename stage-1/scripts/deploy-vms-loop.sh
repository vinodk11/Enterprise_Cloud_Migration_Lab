#!/usr/bin/env bash
# ==============================================================================
# Enterprise Cloud Migration Lab — Master Sequential Deployment Orchestrator
# Target Platform: Ubuntu 24.04 Host (KVM / QEMU / libvirt / Vagrant)
# Sequence: DC01 (AD/DNS) -> DB01 (Postgres) -> FILE01 (SMB) -> APP01 (Web/API)
# ==============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAGRANT_ROOT="$(cd "${SCRIPT_DIR}/../vagrant" && pwd)"

# ANSI Color codes
BOLD="\033[1m"
GREEN="\033[32m"
YELLOW="\033[33m"
CYAN="\033[36m"
RED="\033[31m"
RESET="\033[0m"

echo -e "${BOLD}${CYAN}==================================================================${RESET}"
echo -e "${BOLD}${CYAN}  Enterprise Cloud Migration Lab: Sequential VM Deployment Loop    ${RESET}"
echo -e "${BOLD}${CYAN}  Hypervisor: KVM/QEMU | Provider: libvirt | OS: Ubuntu 24.04     ${RESET}"
echo -e "${BOLD}${CYAN}==================================================================${RESET}"

# ------------------------------------------------------------------------------
# STEP 0: HOST PREREQUISITES VERIFICATION
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}${YELLOW}>>> [STEP 0/4] Verifying Host Hyper-V/KVM & libvirt Infrastructure...${RESET}"

if [[ -f "${SCRIPT_DIR}/setup-host-infra.sh" ]]; then
    echo -e "${CYAN}[*] Checking Host Storage & Network status...${RESET}"
    sudo bash "${SCRIPT_DIR}/setup-host-infra.sh" || true
fi

# Verify Libvirt Storage Pool
if virsh pool-info vm-storage >/dev/null 2>&1; then
    echo -e "${GREEN}[OK] Storage pool 'vm-storage' is active.${RESET}"
else
    echo -e "${YELLOW}[!] Warning: libvirt storage pool 'vm-storage' not detected. Vagrant will attempt creation.${RESET}"
fi

# Verify Libvirt Network
if virsh net-info migration-lab >/dev/null 2>&1; then
    echo -e "${GREEN}[OK] Network 'migration-lab' is active.${RESET}"
else
    echo -e "${YELLOW}[!] Warning: libvirt network 'migration-lab' not detected. Vagrant will attempt creation.${RESET}"
fi

# ------------------------------------------------------------------------------
# VM FLEET DEFINITIONS
# ------------------------------------------------------------------------------
declare -A VM_IPS=(
    ["dc01"]="10.10.10.10"
    ["db01"]="10.10.10.30"
    ["file01"]="10.10.10.40"
    ["app01"]="10.10.10.20"
)

declare -A VM_ROLES=(
    ["dc01"]="Active Directory Domain Controller & DNS (corp.local)"
    ["db01"]="PostgreSQL Database Server (streamflix_db)"
    ["file01"]="Samba Media Storage Server (SMB/CIFS)"
    ["app01"]="StreamFlix Web Application, Express API & Nginx"
)

declare -A VM_PORTS=(
    ["dc01"]="53 88 389 445"
    ["db01"]="5432"
    ["file01"]="139 445"
    ["app01"]="80 5000"
)

# Support running specific VMs via command line arguments, or all by default
if [[ $# -gt 0 ]]; then
    ORDERED_VMS=("$@")
else
    ORDERED_VMS=("dc01" "db01" "file01" "app01")
fi

# Helper function to test TCP port connectivity
check_port() {
    local host="$1"
    local port="$2"
    local timeout=2
    if timeout "${timeout}" bash -c "</dev/tcp/${host}/${port}" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# ------------------------------------------------------------------------------
# SEQUENTIAL DEPLOYMENT LOOP
# ------------------------------------------------------------------------------
STEP_NUM=1
TOTAL_STEPS=${#ORDERED_VMS[@]}

for vm in "${ORDERED_VMS[@]}"; do
    vm_dir="${VAGRANT_ROOT}/${vm}"
    ip="${VM_IPS[$vm]:-unknown}"
    role="${VM_ROLES[$vm]:-custom}"
    ports="${VM_PORTS[$vm]:-}"

    echo -e "\n${BOLD}${CYAN}------------------------------------------------------------------${RESET}"
    echo -e "${BOLD}${CYAN}>>> [STEP ${STEP_NUM}/${TOTAL_STEPS}] Deploying ${vm^^} (${ip}) — ${role}${RESET}"
    echo -e "${BOLD}${CYAN}------------------------------------------------------------------${RESET}"

    if [[ ! -d "${vm_dir}" ]]; then
        echo -e "${RED}[-] Directory not found: ${vm_dir}. Skipping.${RESET}"
        STEP_NUM=$((STEP_NUM + 1))
        continue
    fi

    cd "${vm_dir}"

    # Check if VM is already active
    IS_RUNNING=$(vagrant status --machine-readable 2>/dev/null | grep ",state,running" || true)
    if [[ -n "${IS_RUNNING}" ]]; then
        echo -e "${GREEN}[OK] ${vm^^} is already running in libvirt.${RESET}"
        echo -e "${CYAN}[*] Running 'vagrant provision' to ensure guest bootstrap scripts are applied...${RESET}"
        vagrant provision || true
    else
        echo -e "${CYAN}[*] Starting ${vm^^} using 'vagrant up --provider=libvirt'...${RESET}"
        if vagrant up --provider=libvirt; then
            echo -e "${GREEN}[OK] 'vagrant up' for ${vm^^} completed.${RESET}"
        else
            echo -e "${YELLOW}[!] 'vagrant up' reported non-zero exit for ${vm^^}. Running 'vagrant provision' fallback...${RESET}"
            vagrant provision || true
        fi
    fi

    echo -e "\n${CYAN}[*] Validating ${vm^^} (${ip}) connectivity...${RESET}"
    
    # 1. ICMP Ping check (up to 20s)
    PING_SUCCESS=false
    for i in {1..10}; do
        if ping -c 1 -W 2 "${ip}" >/dev/null 2>&1; then
            PING_SUCCESS=true
            echo -e "${GREEN}[OK] ICMP Ping to ${ip} succeeded.${RESET}"
            break
        fi
        sleep 2
    done

    if [[ "${PING_SUCCESS}" != "true" ]]; then
        echo -e "${YELLOW}[*] ICMP ping to ${ip} did not reply. Checking TCP ports...${RESET}"
    fi

    # 2. Port check
    for p in ${ports}; do
        PORT_OK=false
        for i in {1..6}; do
            if check_port "${ip}" "${p}"; then
                PORT_OK=true
                echo -e "${GREEN}[OK] Port ${p} is LISTENING on ${ip}.${RESET}"
                break
            fi
            sleep 2
        done
        if [[ "${PORT_OK}" != "true" ]]; then
            echo -e "${YELLOW}[*] Port ${p} on ${ip} not yet answering (service may still be initializing).${RESET}"
        fi
    done

    cd "${SCRIPT_DIR}"
    STEP_NUM=$((STEP_NUM + 1))
done

# ------------------------------------------------------------------------------
# FINAL COMPREHENSIVE FLEET HEALTH VALIDATION
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}${CYAN}==================================================================${RESET}"
echo -e "${BOLD}${CYAN}  Enterprise Cloud Migration Lab: Fleet Validation Summary        ${RESET}"
echo -e "${BOLD}${CYAN}==================================================================${RESET}"

printf "${BOLD}%-10s %-15s %-12s %-25s %-10s${RESET}\n" "VM" "IP Address" "Ping" "Listening Ports" "Status"
printf "%-10s %-15s %-12s %-25s %-10s\n" "----------" "---------------" "------------" "-------------------------" "----------"

for vm in "dc01" "db01" "file01" "app01"; do
    ip="${VM_IPS[$vm]}"
    ports="${VM_PORTS[$vm]}"
    
    # Ping status
    if ping -c 1 -W 1 "${ip}" >/dev/null 2>&1; then
        ping_stat="OK"
    else
        ping_stat="FAIL"
    fi

    # Port status
    port_results=()
    for p in ${ports}; do
        if check_port "${ip}" "${p}"; then
            port_results+=("${p}:OK")
        else
            port_results+=("${p}:WAIT")
        fi
    done

    port_str="${port_results[*]}"
    if [[ "${ping_stat}" == "OK" ]]; then
        stat_color="${GREEN}ONLINE${RESET}"
    else
        stat_color="${YELLOW}OFFLINE/WAIT${RESET}"
    fi

    printf "%-10s %-15s %-12s %-25s " "${vm^^}" "${ip}" "${ping_stat}" "${port_str}"
    echo -e "${stat_color}"
done

echo -e "\n${BOLD}${CYAN}--- Application End-to-End Health Verification ---${RESET}"
echo -n "Querying StreamFlix API (/api/health on APP01 10.10.10.20): "
API_RES=$(curl -s --connect-timeout 3 "http://10.10.10.20/api/health" 2>/dev/null || echo "WAITING_FOR_APP01")
echo -e "${GREEN}${API_RES}${RESET}"

echo -e "\n${BOLD}${GREEN}Deployment run completed!${RESET}"
