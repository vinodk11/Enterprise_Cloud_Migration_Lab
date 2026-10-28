# Architecture Specification — Stage 2: Cross-Cloud Hybrid Connectivity & Target Landing Zone

## 1. Executive Summary & Educational Objectives

In an enterprise cloud migration, workloads cannot simply be copied over the public internet. Moving relational databases (e.g., PostgreSQL on `DB01`), media file shares (`FILE01`), and domain controllers (`DC01`) requires a private, encrypted, enterprise-grade network interconnect.

**Stage 2** establishes:
1. **The Target Cloud Landing Zone (AWS)**: A secure, multi-tier Virtual Private Cloud (VPC) adhering to the AWS Well-Architected Framework.
2. **Hybrid Network Connectivity**: An encrypted IPsec Site-to-Site (S2S) tunnel bridging the simulated on-premises datacenter (`10.10.0.0/16`) on Azure with the target AWS VPC (`10.20.0.0/16`).
3. **Cross-Cloud Routing & Security Boundary**: Route table propagation, Network ACLs, and Security Groups allowing uninterrupted private communication across clouds without public exposure.

---

## 2. High-Level Hybrid Architecture Diagram

```
+--------------------------------------------------------------------------------------------------+
| SIMULATED ON-PREMISES DATACENTER (AZURE)           | TARGET MIGRATION LANDING ZONE (AWS)         |
| Region: Central US                                 | Region: us-east-1                           |
| Address Space: 10.10.0.0/16                        | Address Space: 10.20.0.0/16                 |
|                                                    |                                             |
| +------------------------------------------------+ | +-----------------------------------------+ |
| | Management Subnet: 10.10.1.0/24                | | | Public Subnets: 10.20.1.0/24, 10.20.2.0 | |
| |  HV01 Hypervisor Host: 10.10.1.10              | | |  - Internet Gateway (IGW)               | |
| |  Public Static IP: 135.119.24.110              | | |  - NAT Gateway / Bastion                | |
| +------------------------------------------------+ | +-----------------------------------------+ |
|                        |                           |                      |                      |
| +------------------------------------------------+ | +-----------------------------------------+ |
| | Guest VM Fleet (virbr1): 10.10.10.0/24         | | | Private App Subnets: 10.20.10.0/24      | |
| |  - DC01   (AD / DNS)    : 10.10.10.10          | | |  - Target App Tier (ECS / EC2)          | |
| |  - APP01  (Nginx / Node): 10.10.10.20          | | +-----------------------------------------+ |
| |  - DB01   (PostgreSQL)  : 10.10.10.30          | |                      |                      |
| |  - FILE01 (Samba CIFS)  : 10.10.10.40          | | +-----------------------------------------+ |
| +------------------------------------------------+ | | Isolated DB Subnets: 10.20.20.0/24       | |
|                        |                           | |  - Target RDS PostgreSQL / Aurora       | |
|                        v                           | +-----------------------------------------+ |
|           [IPsec S2S VPN Endpoint]                 |                      ^                      |
|             (IKEv2 / AES-256)                      |                      |                      |
|                        |                           |                      |                      |
|                        +===========================+======================+                      |
|                               Encrypted IPsec Tunnel Over WAN                                    |
|                             Route: 10.10.0.0/16 <-> 10.20.0.0/16                                 |
+--------------------------------------------------------------------------------------------------+
```

---

## 3. Core Architectural Concepts

### 3.1 Non-Overlapping RFC 1918 CIDR Strategy
The #1 failure mode in cloud migrations is **IP address space overlap**. If the on-premises datacenter uses `10.0.0.0/16` and the cloud VPC is also created with `10.0.0.0/16`, standard Layer 3 IP routing breaks down because routers cannot determine where to deliver packets.
* **On-Premises Allocation**: `10.10.0.0/16`
* **Target AWS Allocation**: `10.20.0.0/16`
* **Result**: Zero route collisions. Packets destined for `10.20.x.x` are routed through the VPN tunnel, and return packets destined for `10.10.x.x` are routed back seamlessly.

### 3.2 3-Tier Subnet Segmentation (Defense-in-Depth)
1. **Public Ingress Tier (`10.20.1.0/24`, `10.20.2.0/24`)**:
   - Direct route to the Internet Gateway (`0.0.0.0/0 -> igw-xxx`).
   - Hosts public entrypoints (ALB, API Gateways).
2. **Private Application Tier (`10.20.10.0/24`, `10.20.11.0/24`)**:
   - Outbound internet traffic routed through NAT Gateway.
   - Strictly no inbound access from the public internet.
   - Directly reachable from On-Premises `10.10.0.0/16` via VPN.
3. **Isolated Database Tier (`10.20.20.0/24`, `10.20.21.0/24`)**:
   - Zero internet route (no IGW, no NAT Gateway).
   - Only accessible from Application Subnets and On-Premises `DB01` (for migration replication).

---

## 4. Phase 2 Roadmap & Step Breakdown

To ensure deep learning and verification at each milestone, Stage 2 is executed in 5 discrete steps:

* **Step 1: Target Cloud Architecture & IP Network Design** *(Current)*
  - CIDR block allocation, subnet topology, and routing requirements design.
* **Step 2: Terraform Landing Zone Deployment**
  - Infrastructure as Code deploying AWS VPC, Multi-AZ Subnets, Route Tables, and Security Groups.
* **Step 3: Hybrid Connectivity Provisioning (IPsec S2S VPN)**
  - Customer Gateway (CGW), Virtual Private Gateway (VGW) / VPN Connection with IKEv2 Phase 1 & Phase 2 cryptographic proposals.
* **Step 4: Cross-Cloud Routing & Bidirectional Verification**
  - Route propagation and ICMP/TCP ping/curl validation across AWS private subnets and On-Prem VMs.
* **Step 5: Hybrid DNS Integration**
  - Configuring Route 53 Resolver Endpoints to seamlessly forward `corp.local` queries to `DC01` (`10.10.10.10`).
