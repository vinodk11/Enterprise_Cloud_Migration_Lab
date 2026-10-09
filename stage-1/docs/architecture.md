# Architecture Specification — Stage 1: Simulated On-Premises Datacenter on Azure

## 1. Executive Summary

This architecture implements a high-fidelity, simulated on-premises enterprise datacenter hosted inside Microsoft Azure. It serves as the baseline legacy environment for an end-to-end cloud migration project (migrating legacy workloads to AWS or Azure Cloud).

Stage 1.1 establishes the **Foundational Azure Networking & Security Boundary** via Infrastructure as Code (Terraform).

---

## 2. High-Level Architecture Diagram

```
+-----------------------------------------------------------------------------------+
| Microsoft Azure Region: eastus (Configurable)                                     |
| Resource Group: rg-onprem-lab                                                     |
|                                                                                   |
|  +-----------------------------------------------------------------------------+  |
|  | Virtual Network: vnet-onprem-lab (10.10.0.0/16)                             |  |
|  |                                                                             |  |
|  |   +-----------------------------------------------------------------------+ |  |
|  |   | Management Subnet: snet-management (10.10.1.0/24)                    | |  |
|  |   | NSG: nsg-onprem-lab (Strict Zero-Public-Inbound Policy)                | |  |
|  |   |                                                                       | |  |
|  |   |   +-----------------------------------------------------------------+ | |  |
|  |   |   | [Stage 1.2+ Future Component]                                   | | |  |
|  |   |   | Hyper-V Host: HV01 (Windows Server 2022 Datacenter)             | | |  |
|  |   |   | Private IP: 10.10.1.10                                          | | |  |
|  |   |   | Nested Virtualization Host (e.g., Standard_D8s_v5)              | | |  |
|  |   |   |                                                                 | | |  |
|  |   |   |   Internal NAT Virtual Switch: 192.168.10.0/24                  | | |  |
|  |   |   |   +-----------------------------------------------------------+ | | |  |
|  |   |   |   | DC01   - Ubuntu 22.04 LTS (Samba Active Directory & DNS)  | | | |  |
|  |   |   |   | APP01  - Ubuntu 22.04 LTS (Nginx Web Application Reverse)  | | | |  |
|  |   |   |   | DB01   - Ubuntu 22.04 LTS (PostgreSQL Database Engine)    | | | |  |
|  |   |   |   | FILE01 - Ubuntu 22.04 LTS (Samba Enterprise File Share)   | | | |  |
|  |   |   |   +-----------------------------------------------------------+ | | |  |
|  |   |   +-----------------------------------------------------------------+ | |  |
|  |   +-----------------------------------------------------------------------+ |  |
|  |                                                                             |  |
|  |   +-----------------------------------------------------------------------+ |  |
|  |   | [Future Subnet] GatewaySubnet: 10.10.255.0/27 (IPsec S2S VPN to AWS)  | |  |
|  |   +-----------------------------------------------------------------------+ |  |
|  |   +-----------------------------------------------------------------------+ |  |
|  |   | [Future Subnet] AzureBastionSubnet: 10.10.2.0/26 (Secure Admin RDP)   | |  |
|  |   +-----------------------------------------------------------------------+ |  |
|  +-----------------------------------------------------------------------------+  |
+-----------------------------------------------------------------------------------+
```

---

## 3. Stage 1.1 Scope & Delivered Resources

Stage 1.1 delivers strictly the networking foundation:

1. **Resource Group (`rg-onprem-lab`)**:
   - Central lifecycle container for all simulated on-premises resources.
2. **Virtual Network (`vnet-onprem-lab`)**:
   - RFC 1918 Address space: `10.10.0.0/16` (65,536 total addresses).
   - Carefully planned to avoid CIDR overlap with target AWS migration VPCs (e.g., AWS VPC `10.20.0.0/16` or `172.16.0.0/16`).
3. **Management Subnet (`snet-management`)**:
   - Prefix: `10.10.1.0/24` (251 usable Azure IP addresses, as Azure reserves 5 IPs per subnet: `.0`, `.1`, `.2`, `.3`, and `.255`).
4. **Network Security Group (`nsg-onprem-lab`)**:
   - Attached directly to `snet-management`.
   - Enforces zero unsolicited inbound access from the public internet.
   - Blocks RDP (3389) and SSH (22) from the internet. No public IP addresses are provisioned.

---

## 4. Nested Virtualization & Future Hyper-V Constraints

In subsequent stages (Stage 1.2+), an Azure Windows VM will act as the on-premises virtualization hypervisor (`HV01`) running Ubuntu guest VMs:

* **Nested Virtualization Requirements**:
  - Azure supports nested virtualization on specific VM families (v3, v4, v5 series) such as `Standard_D4s_v5`, `Standard_D8s_v5`, `Standard_E4s_v5`, etc.
  - The VM size must use Intel or AMD processors with nested virtualization support enabled in the hypervisor.
* **Networking Topology for Guest VMs**:
  - Azure virtual networks do not support promiscuous mode or MAC address spoofing directly on virtual network adapters.
  - Therefore, the Hyper-V host will leverage an **Internal NAT Virtual Switch** (e.g., `192.168.10.0/24`) with IP forwarding and NAT routing rules on the Windows Server host, allowing guest VMs to communicate out through the host's primary Azure NIC.

---

## 5. Security Architecture & Administration Strategy

* **Zero Public IP Footprint**:
  - Neither the subnet nor any future VM will have direct public IP addresses attached.
* **Administration Options for Future Stages**:
  1. **Azure Bastion**: Fully managed PaaS proxy providing browser-based RDP/SSH directly over TLS 443 without public IPs.
  2. **Point-to-Site (P2S) VPN**: Dedicated WireGuard/OpenVPN tunnel connecting the administrator workstation to `vnet-onprem-lab`.
  3. **Site-to-Site (S2S) VPN**: IPsec tunnel connecting the simulated on-premise datacenter to AWS Transit Gateway / Virtual Private Gateway.

---

## 6. Difference: Network Security Group (NSG) vs. Route Table (UDR)

| Architectural Feature | Network Security Group (NSG) | Route Table (User Defined Route - UDR) |
| :--- | :--- | :--- |
| **OSI Layer** | Layer 3 & 4 (Stateful Packet Filter / Firewall) | Layer 3 (Routing & Next-Hop Decision Engine) |
| **Primary Function** | Permits or denies traffic based on 5-tuple (Source IP, Source Port, Dest IP, Dest Port, Protocol). | Dictates **where** packets travel (e.g., to Internet, Virtual Appliance, VNet Gateway, or None). |
| **Default Behavior** | Statefully evaluates rules by priority (lower number = higher priority). Allows intra-VNet, denies public ingress. | System default routes forward intra-VNet locally and outbound traffic directly to the Internet. |
| **Role in Migration** | Restricts which workloads and management ports can communicate with each other. | Directs cross-cloud migration traffic across the VPN Gateway or Virtual Appliance tunnel to AWS. |
