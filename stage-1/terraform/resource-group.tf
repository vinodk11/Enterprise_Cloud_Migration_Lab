resource "azurerm_resource_group" "onprem_rg" {
  name     = var.resource_group_name
  location = var.azure_region

  tags = var.tags
}
