variable "azure_region" {
  type        = string
  description = "The Azure region where all foundational networking resources will be deployed."
  default     = "eastus"
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
    Stage       = "1.1"
  }
}
