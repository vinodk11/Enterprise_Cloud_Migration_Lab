variable "azure_region" {
  type        = string
  description = "The Azure region where all foundational networking resources will be deployed."
  default     = "centralus"
}

variable "resource_group_name" {
  type        = string
  description = "Name of the resource group simulating the on-premises datacenter environment."
  default     = "rg-onprem-lab"
}

variable "vnet_name" {
  type        = string
  description = "Name of the Virtual Network simulating the on-premises network boundary."
  default     = "vnet-onprem-lab"
}

variable "vnet_address_space" {
  type        = list(string)
  description = "The address space CIDR block for the on-premises virtual network."
  default     = ["10.10.0.0/16"]
}

variable "management_subnet_name" {
  type        = string
  description = "Name of the management subnet for host and administration infrastructure."
  default     = "snet-management"
}

variable "management_subnet_prefix" {
  type        = list(string)
  description = "Address prefix CIDR block for the management subnet."
  default     = ["10.10.1.0/24"]
}

variable "nsg_name" {
  type        = string
  description = "Name of the Network Security Group securing the management subnet."
  default     = "nsg-onprem-lab"
}

variable "tags" {
  type        = map(string)
  description = "Standard enterprise resource tags for cost tracking, environment categorization, and governance."
  default = {
    Environment = "OnPrem-Simulation"
    Project     = "Enterprise-Cloud-Migration-Lab"
    ManagedBy   = "Terraform"
    Stage       = "1.2"
  }
}

variable "bastion_subnet_prefix" {
  type        = list(string)
  description = "Address prefix CIDR block for AzureBastionSubnet."
  default     = ["10.10.2.0/26"]
}

variable "bastion_public_ip_name" {
  type        = string
  description = "Name of the Public IP for Azure Bastion."
  default     = "pip-bastion-onprem"
}

variable "bastion_host_name" {
  type        = string
  description = "Name of the Azure Bastion Host."
  default     = "bas-onprem-lab"
}

variable "hv01_vm_name" {
  type        = string
  description = "Name of the Hyper-V host virtual machine resource in Azure."
  default     = "vm-hv01"
}

variable "hv01_private_ip" {
  type        = string
  description = "Static private IP address for HV01 within snet-management."
  default     = "10.10.1.10"
}

variable "vm_size" {
  type        = string
  description = "Azure VM size supporting nested virtualization."
  default     = "Standard_D4s_v5"
}

variable "admin_username" {
  type        = string
  description = "Administrator username for the Windows Server VM."
  default     = "labadmin"
}

variable "admin_password" {
  type        = string
  description = "Administrator password for the Windows Server VM (leave null to auto-generate)."
  default     = null
  sensitive   = true
}

