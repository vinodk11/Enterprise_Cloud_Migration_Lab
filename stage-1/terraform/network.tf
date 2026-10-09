resource "azurerm_virtual_network" "onprem_vnet" {
  name                = var.vnet_name
  location            = azurerm_resource_group.onprem_rg.location
  resource_group_name = azurerm_resource_group.onprem_rg.name
  address_space       = var.vnet_address_space

  tags = var.tags
}

resource "azurerm_subnet" "management_subnet" {
  name                 = var.management_subnet_name
  resource_group_name  = azurerm_resource_group.onprem_rg.name
  virtual_network_name = azurerm_virtual_network.onprem_vnet.name
  address_prefixes     = var.management_subnet_prefix
}
