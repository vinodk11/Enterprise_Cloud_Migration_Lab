# Enterprise Cloud Migration Lab

## Project Overview

The **Enterprise Cloud Migration Lab** is an enterprise-grade, multi-stage cloud migration portfolio project designed to demonstrate the complete lifecycle of assessing, planning, interconnecting, and migrating an on-premises enterprise datacenter to the cloud (AWS or Azure).

To deliver a realistic migration experience without physical server hardware, this project creates a high-fidelity **simulated on-premises datacenter hosted in Microsoft Azure**, interconnects it with AWS via an encrypted IPsec Site-to-Site VPN, and executes live migrations using modern enterprise migration tools and methodologies.

---

## Stage Roadmap

* **Stage 1.1 (Current)**: Foundational Azure Networking & Security Boundary (Terraform).
* **Stage 1.2**: Windows Server 2022 Hyper-V Host (`HV01`) with Nested Virtualization.
* **Stage 1.3**: Provisioning Ubuntu Enterprise Guest VMs (`DC01`, `APP01`, `DB01`, `FILE01`).
* **Stage 2.0**: Cross-Cloud Hybrid Connectivity (Azure S2S VPN ⮂ AWS Transit Gateway).
* **Stage 3.0+**: Discovery, Assessment & Workload Migration to AWS (Database, Application, File Share, Directory Services).

---

## Stage 1.1 Scope — Azure Foundational Networking

Stage 1.1 deploys the fundamental, immutable networking backbone on Microsoft Azure using Terraform:
1. **Resource Group**: `rg-onprem-lab`
2. **Virtual Network**: `vnet-onprem-lab` (`10.10.0.0/16`)
3. **Management Subnet**: `snet-management` (`10.10.1.0/24`)
4. **Network Security Group**: `nsg-onprem-lab` (Zero public ingress)
5. **Subnet-NSG Association**: Secures `snet-management`

---

## Repository Structure

```text
onprem-cloud-migration-lab/
├── README.md
├── .gitignore
└── stage-1/
    ├── terraform/
    │   ├── versions.tf               # Terraform & AzureRM provider constraints
    │   ├── provider.tf               # Provider initialization
    │   ├── variables.tf              # Parameterized inputs (region, CIDRs, tags)
    │   ├── resource-group.tf         # Azure Resource Group resource
    │   ├── network.tf                # VNet and Management Subnet definitions
    │   ├── security.tf               # NSG and Subnet association
    │   ├── outputs.tf                # Resource IDs and configuration outputs
    │   ├── terraform.tfvars.example  # Customizable variables template
    │   └── .gitignore                # State & credential ignore rules
    └── docs/
        ├── architecture.md           # Deep-dive architecture specification
        └── ip-plan.md                # Comprehensive IP addressing schedule
```

---

## Step-by-Step Implementation Guide

### Step 1 — Prerequisites & Authentication

#### 1.1 Verify Tools Installation
Run from your terminal (Windows PowerShell or Linux/macOS Bash):

* **PowerShell**:
  ```powershell
  terraform version
  az version
  ```

* **Bash**:
  ```bash
  terraform version
  az version
  ```

#### 1.2 Authenticate with Microsoft Azure
Authenticate your CLI session against Azure:
```bash
az login
```
*(On Windows, this launches your default browser. In headless environments, use `az login --use-device-code`)*.

#### 1.3 Verify and Select Azure Subscription
List available subscriptions:
```bash
az account list --output table
```

If you have multiple subscriptions, select the intended subscription ID:
```bash
az account set --subscription "<YOUR_SUBSCRIPTION_ID>"
```

Confirm the active subscription:
```bash
az account show --output table
```

#### 1.4 Check Regional SKU Availability (for Future Hyper-V Host)
Before deploying, verify that your chosen Azure region supports nested virtualization VM sizes (e.g., `Standard_D4s_v5` or `Standard_D8s_v5`):
```bash
az vm list-skus --location eastus --size Standard_D4s_v5 --output table
```

---

### Step 2 — Terraform Deployment

Navigate to the Stage 1.1 Terraform directory:
```bash
cd stage-1/terraform
```

#### 2.1 Initialize Terraform
Downloads the required `azurerm` provider plugin:
```bash
terraform init
```

#### 2.2 Format and Validate Code
```bash
terraform fmt -recursive
terraform validate
```
Expected output: `Success! The configuration is valid.`

#### 2.3 Review Execution Plan
```bash
terraform plan
```
Verify that Terraform proposes **4 resources to add**:
1. `azurerm_resource_group.onprem_rg`
2. `azurerm_virtual_network.onprem_vnet`
3. `azurerm_subnet.management_subnet`
4. `azurerm_network_security_group.onprem_nsg`
5. `azurerm_subnet_network_security_group_association.management_nsg_assoc`

#### 2.4 Apply the Configuration
```bash
terraform apply
```
Type `yes` when prompted to execute the deployment.

---

### Step 3 — Validation

#### 3.1 Verify via Terraform Outputs
```bash
terraform output
```

#### 3.2 Verify via Azure CLI
Confirm resources exist in the resource group:
```bash
# Check Resource Group
az group show --name rg-onprem-lab --output table

# Check Virtual Network & Subnet
az network vnet show --resource-group rg-onprem-lab --name vnet-onprem-lab --query "{AddressSpace:addressSpace.addressPrefixes, Subnets:subnets[].name}" --output json

# Check Subnet and Associated NSG
az network vnet subnet show --resource-group rg-onprem-lab --vnet-name vnet-onprem-lab --name snet-management --query "{SubnetCIDR:addressPrefix, NSG:networkSecurityGroup.id}" --output json
```

---

### Step 4 — Cost & Cleanup

* **Stage 1.1 Cost**:
  - Azure Resource Groups, Virtual Networks, Subnets, and Network Security Groups are **100% free of charge**.
  - No computing VMs, public IPs, or virtual gateways are provisioned in this stage.
* **Teardown Command**:
  When you are ready to tear down Stage 1.1:
  ```bash
  terraform destroy
  ```
  > [!WARNING]
  > Do not destroy the resource group in later stages if other shared state or dependent resources are hosted within it.
