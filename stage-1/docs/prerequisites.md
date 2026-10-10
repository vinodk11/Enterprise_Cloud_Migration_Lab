# Prerequisites & Subscription Assessment Specification

## 1. Tooling Requirements
* **Terraform**: `v1.16.x` or later (tested on `1.16.5` / `1.16.0`).
* **Azure CLI**: `2.91.x` or later.
* **Workstation OS**: Windows 11 (PowerShell 7/5.1) or Linux (Ubuntu 22.04+).

---

## 2. Azure Subscription & Regional Quotas
* **Target Region**: `centralus`
* **VM Family Quota**:
  * `standardDSv3Family`: 10 cores approved (`Standard_D4s_v3` consumes 4 cores).
  * `cores` (Total Regional Cores): 10 approved (`CurrentUsage: 0`).
* **Nested Virtualization**:
  * Hardware-assisted nested virtualization enabled on Intel Xeon processors (`Standard_D4s_v3`).

---

## 3. Cost Estimation & Budget Model

| Component | SKU / Type | Pricing (USD) | Notes |
| :--- | :--- | :--- | :--- |
| **HV01 VM** | `Standard_D4s_v3` (4 vCPU, 16 GB RAM) | ~$0.192 / hour | Incurs compute cost only while running. |
| **OS Disk** | 128 GB Premium SSD (P10) | ~$0.026 / day | Windows Server 2022 OS |
| **Data Disk** | 128 GB Premium SSD (P10) | ~$0.026 / day | Hyper-V Guest VHDXs |
| **Azure Bastion** | Basic SKU | ~$0.190 / hour | Zero-public-IP browser RDP proxy. |
| **VNet & NSG** | Standard | $0.00 (Free) | Azure foundational networking |

* **Total Running Cost (with Bastion)**: ~$0.38 / hour
* **Total Running Cost (without Bastion)**: ~$0.20 / hour
