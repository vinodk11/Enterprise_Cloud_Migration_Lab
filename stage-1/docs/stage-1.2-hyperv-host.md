# Architecture Specification — Stage 1.2: Windows Server 2022 Hyper-V Host (HV01)

## 1. Overview & Objectives

Stage 1.2 deploys the simulated physical virtualization compute infrastructure on top of the Stage 1.1 foundational network:
1. **Azure Bastion (Option A)**: Secure, zero-public-IP remote management over TLS 443.
2. **Hyper-V Host Virtual Machine (`HV01`)**:
   - Azure VM Size: `Standard_D4s_v3` (4 vCPUs, 16 GiB RAM) in `centralus`.
   - Windows Server 2022 Datacenter Azure Edition.
   - Hardware-assisted nested virtualization enabled.
   - Attached to `snet-management` at static private IP `10.10.1.10`.
   - Dedicated 128 GiB Premium SSD data disk for guest VM virtual disks (`vhdx`).
   - Automated PowerShell installation of the Hyper-V role and RSAT management tools.

---

## 2. Infrastructure Diagram

```
+-----------------------------------------------------------------------------------------+
| Virtual Network: vnet-onprem-lab (10.10.0.0/16) in centralus                             |
|                                                                                         |
|  +---------------------------------------+   +---------------------------------------+  |
|  | Subnet: AzureBastionSubnet            |   | Subnet: snet-management               |  |
|  | CIDR: 10.10.2.0/26                    |   | CIDR: 10.10.1.0/24                    |  |
|  |                                       |   | NSG: nsg-onprem-lab                   |  |
|  | +-----------------------------------+ |   |                                       |  |
|  | | Azure Bastion: bas-onprem-lab     | |   | +-----------------------------------+ |  |
|  | | Public IP: pip-bastion-onprem     | |   | | NIC: nic-hv01 (Static: 10.10.1.10)| |  |
|  | | Ingress: HTTPS 443                | |   | | Accelerated Networking: Enabled   | |  |
|  | +-----------------+-----------------+ |   | +-----------------+-----------------+ |  |
|  +-------------------|-------------------+   +-------------------|-------------------+  |
|                      |                                           |                      |
|                      +====== Native Intra-VNet RDP (3389) =======+                      |
|                                                                  |                      |
|                                      +---------------------------v--------------------+ |
|                                      | Windows Server 2022 VM: vm-hv01 (HV01)         | |
|                                      | - Size: Standard_D4s_v5 (Nested Virtualization)| |
|                                      | - OS Disk: 128 GB Premium SSD                  | |
|                                      | - Data Disk: 128 GB Premium SSD (disk-hv01-vms)| |
|                                      | - Extension: Hyper-V & RSAT Feature Install    | |
|                                      +------------------------------------------------+ |
+-----------------------------------------------------------------------------------------+
```

---

## 3. Remote Access Model (Azure Bastion Enterprise Pattern)

* **Zero Public IP on Compute**:
  `HV01` has no public IP. The host is completely isolated from unsolicited internet scanners.
* **Native In-Browser RDP**:
  Administrators authenticate to Azure Portal and launch RDP sessions through an HTML5 canvas over HTTPS (TLS 443).
* **CLI Native Tunneling**:
  Administrators can also launch native MSTSC RDP sessions via Azure CLI:
  ```bash
  az network bastion rdp --name bas-onprem-lab --resource-group rg-onprem-lab --target-resource-id <HV01_RESOURCE_ID>
  ```

---

## 4. Hyper-V & Internal NAT Network Architecture

Because Azure Virtual Networks disallow promiscuous mode and MAC address spoofing on virtual NICs, Hyper-V uses an **Internal NAT Virtual Switch** for guest virtual machines:

* **Switch Name**: `vSwitch-Internal-NAT`
* **Internal NAT Subnet**: `192.168.10.0/24`
* **Host Gateway IP**: `192.168.10.1`

### Guest Virtual Machines Hosted on HV01 (Prepared for Stage 1.3)
1. **`DC01`** (`192.168.10.10`): Ubuntu 22.04 LTS (Samba AD DS / DNS Server)
2. **`APP01`** (`192.168.10.20`): Ubuntu 22.04 LTS (Nginx Web Application)
3. **`DB01`** (`192.168.10.30`): Ubuntu 22.04 LTS (PostgreSQL Database Engine)
4. **`FILE01`** (`192.168.10.40`): Ubuntu 22.04 LTS (Samba Enterprise File Share)
