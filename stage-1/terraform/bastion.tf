# Stage 1.2 — Azure Bastion Enterprise Remote Management (Option A)

# Azure requires the subnet to be strictly named "AzureBastionSubnet" with a minimum CIDR of /26
resource "azurerm_subnet" "bastion_subnet" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.onprem_rg.name
  virtual_network_name = azurerm_virtual_network.onprem_vnet.name
  address_prefixes     = var.bastion_subnet_prefix
}

# Standard Static Public IP required by Azure Bastion
resource "azurerm_public_ip" "bastion_pip" {
  name                = var.bastion_public_ip_name
  location            = azurerm_resource_group.onprem_rg.location
  resource_group_name = azurerm_resource_group.onprem_rg.name
  allocation_method   = "Static"
  sku                 = "Standard"

  tags = var.tags
}

# Azure Bastion Host providing zero-public-IP browser-based RDP & SSH over TLS 443
resource "azurerm_bastion_host" "onprem_bastion" {
  name                = var.bastion_host_name
  location            = azurerm_resource_group.onprem_rg.location
  resource_group_name = azurerm_resource_group.onprem_rg.name
  sku                 = "Basic"

  ip_configuration {
    name                 = "bastion-ip-config"
    subnet_id            = azurerm_subnet.bastion_subnet.id
    public_ip_address_id = azurerm_public_ip.bastion_pip.id
  }

  tags = var.tags
}
