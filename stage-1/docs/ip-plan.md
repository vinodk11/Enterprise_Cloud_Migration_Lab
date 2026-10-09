# IP Addressing & Subnet Allocation Plan — Enterprise Migration Lab

## 1. Simulated On-Premises Azure VNet (`vnet-onprem-lab`)

* **Allocated CIDR Block**: `10.10.0.0/16` (65,536 addresses)
* **Target Non-Overlapping AWS Migration VPC**: `10.20.0.0/16` (Ensures conflict-free Site-to-Site VPN routing)

---

## 2. Azure VNet Subnet Segmentation

| Subnet Name | CIDR Prefix | Total IPs | Usable IPs | Purpose / Workload | Stage |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **`snet-management`** | `10.10.1.0/24` | 256 | 251 | Hyper-V Host (`HV01`), Administrative infrastructure | **Stage 1.1 (Current)** |
| **`AzureBastionSubnet`** | `10.10.2.0/26` | 64 | 59 | Azure Bastion Host for secure browser RDP | Stage 1.2 (Future) |
| **`GatewaySubnet`** | `10.10.255.0/27`| 32 | 27 | Azure Virtual Network Gateway for S2S VPN to AWS | Stage 2 (Future) |
| *Reserved Subnets* | `10.10.3.0/24` – `10.10.254.0/24` | ~64,000 | - | Reserved for multi-tier simulated on-premises expansion | Future |

> [!NOTE]
> **Azure Reserved IP Rule**: In every Azure subnet, Azure reserves the first 4 and last 1 IP addresses (total 5):
> - `x.x.x.0`: Network address.
> - `x.x.x.1`: Azure default gateway router.
> - `x.x.x.2`, `x.x.x.3`: Azure DNS mapping.
> - `x.x.x.255`: Subnet broadcast address.

---

## 3. Host and Hyper-V IP Allocations (`snet-management`)

| Node Name | Interface | IP Address | MAC / Interface Type | Notes |
| :--- | :--- | :--- | :--- | :--- |
| **Azure Gateway** | Default Gateway | `10.10.1.1` | Virtual Router | Azure Default Gateway |
| **HV01 (Host)** | Primary Azure NIC | `10.10.1.10` | Static Private IP | Windows Server 2022 Hyper-V Host |

---

## 4. Hyper-V Internal NAT Subnet (`vSwitch-Internal-NAT`)

Because Azure virtual networks do not support MAC spoofing or promiscuous mode on virtual NICs, guest VMs running on `HV01` reside on an **Internal Hyper-V Virtual Switch** configured with Windows NAT:

* **Internal Network CIDR**: `192.168.10.0/24`
* **Host Gateway (vEthernet NAT)**: `192.168.10.1`

### Guest Virtual Machine IP Plan

| Hostname | Role / Operating System | Internal IP | Subnet Mask | Gateway | Primary DNS |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **HV01 Gateway** | Windows NAT Virtual Adapter | `192.168.10.1` | `255.255.255.0` | N/A | Host DNS |
| **DC01** | Ubuntu 22.04 LTS (Samba AD / DNS) | `192.168.10.10` | `255.255.255.0` | `192.168.10.1` | `127.0.0.1` (Self) |
| **APP01** | Ubuntu 22.04 LTS (Nginx Web App) | `192.168.10.20` | `255.255.255.0` | `192.168.10.1` | `192.168.10.10` (DC01) |
| **DB01** | Ubuntu 22.04 LTS (PostgreSQL DB) | `192.168.10.30` | `255.255.255.0` | `192.168.10.1` | `192.168.10.10` (DC01) |
| **FILE01** | Ubuntu 22.04 LTS (Samba Enterprise Share) | `192.168.10.40` | `255.255.255.0` | `192.168.10.1` | `192.168.10.10` (DC01) |
