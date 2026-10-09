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
