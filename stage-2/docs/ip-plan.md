# IP Addressing & Subnet Allocation Plan — Stage 2: AWS Landing Zone

## 1. Network Boundary Comparison

| Environment | Provider / Location | Network Space (CIDR) | Usable IPs | Role |
| :--- | :--- | :--- | :--- | :--- |
| **Simulated On-Premises** | Azure (`centralus`) | `10.10.0.0/16` | 65,536 | Source Datacenter |
| **Target Cloud Landing Zone** | AWS (`us-east-1`) | `10.20.0.0/16` | 65,536 | Migration Destination |

---

## 2. AWS Target VPC Subnet Segmentation (`vpc-target-landing-zone`)

All subnets are deployed across two Availability Zones (`us-east-1a` and `us-east-1b`) for High Availability (HA).

| Subnet Identifier | CIDR Prefix | Availability Zone | Routing / Gateway | Purpose / Target Workload |
| :--- | :--- | :--- | :--- | :--- |
| **`snet-public-1a`** | `10.20.1.0/24` | `us-east-1a` | `0.0.0.0/0 -> IGW` | Public ALB, Bastion host |
| **`snet-public-1b`** | `10.20.2.0/24` | `us-east-1b` | `0.0.0.0/0 -> IGW` | Multi-AZ Public ALB |
| **`snet-app-private-1a`** | `10.20.10.0/24` | `us-east-1a` | `0.0.0.0/0 -> NAT-GW` | Target StreamFlix App (ECS / EC2) |
| **`snet-app-private-1b`** | `10.20.11.0/24` | `us-east-1b` | `0.0.0.0/0 -> NAT-GW` | Multi-AZ App instances |
| **`snet-db-isolated-1a`** | `10.20.20.0/24` | `us-east-1a` | *No Internet Route* | Target RDS PostgreSQL (Primary) |
| **`snet-db-isolated-1b`** | `10.20.21.0/24` | `us-east-1b` | *No Internet Route* | Target RDS PostgreSQL (Standby) |
| **`snet-storage-1a`** | `10.20.30.0/24` | `us-east-1a` | `0.0.0.0/0 -> NAT-GW` | Target AWS EFS Mount Target (for FILE01) |

> [!NOTE]
> **AWS Reserved IP Allocation**:
> In every AWS VPC subnet, 5 IP addresses are reserved by AWS:
> - `.0`: Network address.
> - `.1`: VPC internal router.
> - `.2`: DNS resolver (`AmazonProvidedDNS`).
> - `.3`: Reserved for future AWS use.
> - `.255`: Subnet broadcast address (AWS does not support broadcast, but reserves the address).

---

## 3. Hybrid Cross-Cloud Routing Table Rules

| Source Route Table | Destination CIDR | Target Next-Hop | Description |
| :--- | :--- | :--- | :--- |
| **AWS Private App Subnets** | `10.10.0.0/16` | `vgw-xxxx` (Virtual Private Gateway) | Route to On-Premises Datacenter |
| **AWS Isolated DB Subnets** | `10.10.10.30/32` | `vgw-xxxx` (Virtual Private Gateway) | Direct replication route from on-prem DB01 |
| **On-Premises Hypervisor (HV01)** | `10.20.0.0/16` | `ipsec0` / StrongSwan Gateway | Route to AWS Target VPC |
