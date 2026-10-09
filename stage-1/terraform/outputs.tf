output "resource_group_name" {
  description = "The name of the resource group."
  value       = azurerm_resource_group.onprem_rg.name
}

output "resource_group_location" {
  description = "The Azure region where the resource group was created."
  value       = azurerm_resource_group.onprem_rg.location
}

output "vnet_name" {
  description = "The name of the simulated on-premises Virtual Network."
  value       = azurerm_virtual_network.onprem_vnet.name
}

output "vnet_id" {
  description = "The Azure Resource Manager ID of the Virtual Network."
  value       = azurerm_virtual_network.onprem_vnet.id
}

output "vnet_address_space" {
  description = "The allocated CIDR address space for the Virtual Network."
  value       = azurerm_virtual_network.onprem_vnet.address_space
}

output "management_subnet_name" {
  description = "The name of the management subnet."
  value       = azurerm_subnet.management_subnet.name
}

output "management_subnet_id" {
  description = "The Azure Resource Manager ID of the management subnet."
  value       = azurerm_subnet.management_subnet.id
}

output "management_subnet_prefix" {
  description = "The address prefix allocated to the management subnet."
  value       = azurerm_subnet.management_subnet.address_prefixes
}

output "nsg_name" {
  description = "The name of the Network Security Group."
  value       = azurerm_network_security_group.onprem_nsg.name
}

output "nsg_id" {
  description = "The Azure Resource Manager ID of the Network Security Group."
  value       = azurerm_network_security_group.onprem_nsg.id
}

output "bastion_host_name" {
  description = "Name of the Azure Bastion host."
  value       = azurerm_bastion_host.onprem_bastion.name
}

output "bastion_public_ip" {
  description = "Public IP address allocated to the Azure Bastion host."
  value       = azurerm_public_ip.bastion_pip.ip_address
}

output "hv01_vm_id" {
  description = "The Azure Resource Manager ID of the HV01 Windows VM."
  value       = azurerm_windows_virtual_machine.hv01.id
}

output "hv01_computer_name" {
  description = "The internal Windows computer name for the Hyper-V host."
  value       = azurerm_windows_virtual_machine.hv01.computer_name
}

output "hv01_private_ip" {
  description = "The static private IP address of the HV01 Hyper-V host."
  value       = azurerm_windows_virtual_machine.hv01.private_ip_address
}

output "hv01_admin_username" {
  description = "Administrator username for the HV01 Windows host."
  value       = azurerm_windows_virtual_machine.hv01.admin_username
}

output "hv01_admin_password" {
  description = "Administrator password for the HV01 Windows host (sensitive)."
  value       = azurerm_windows_virtual_machine.hv01.admin_password
  sensitive   = true
}

