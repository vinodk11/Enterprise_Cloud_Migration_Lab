# Network Security Group for the On-Premises Simulation Lab
# Default Azure rules already enforce:
# - AllowVNetInBound (Priority 65000): Allows internal subnet-to-subnet traffic
# - AllowAzureLoadBalancerInBound (Priority 65001): Allows Azure health probes
# - DenyAllInBound (Priority 65500): Blocks all unsolicited inbound traffic from the public Internet
#
# No public IPs, RDP (3389), or SSH (22) rules are permitted to be exposed to the public Internet.
# Future administration will be performed via Azure Bastion or private VPN gateway.

resource "azurerm_network_security_group" "onprem_nsg" {
  name                = var.nsg_name
  location            = azurerm_resource_group.onprem_rg.location
  resource_group_name = azurerm_resource_group.onprem_rg.name

  tags = var.tags
}

# Associate the Network Security Group with the Management Subnet
resource "azurerm_subnet_network_security_group_association" "management_nsg_assoc" {
  subnet_id                 = azurerm_subnet.management_subnet.id
  network_security_group_id = azurerm_network_security_group.onprem_nsg.id
}
