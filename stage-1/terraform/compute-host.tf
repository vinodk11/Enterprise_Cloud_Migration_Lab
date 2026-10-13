# Stage 1.2 — Ubuntu 24.04 LTS KVM/QEMU Host (HV01)

# Primary Network Interface for HV01
resource "azurerm_network_interface" "hv01_nic" {
  name                           = "nic-hv01"
  location                       = azurerm_resource_group.onprem_rg.location
  resource_group_name            = azurerm_resource_group.onprem_rg.name
  accelerated_networking_enabled = true

  ip_configuration {
    name                          = "ipconfig-primary"
    subnet_id                     = azurerm_subnet.management_subnet.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.hv01_private_ip
  }

  tags = var.tags
}

# Auto-generate a secure random password if not explicitly supplied
resource "random_password" "hv01_admin_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
}

# Ubuntu 24.04 LTS Linux Virtual Machine (HV01)
resource "azurerm_linux_virtual_machine" "hv01" {
  name                            = var.hv01_vm_name
  computer_name                   = "hv01"
  location                        = azurerm_resource_group.onprem_rg.location
  resource_group_name             = azurerm_resource_group.onprem_rg.name
  size                            = var.vm_size
  admin_username                  = var.admin_username
  admin_password                  = coalesce(var.admin_password, random_password.hv01_admin_password.result)
  disable_password_authentication = false
  network_interface_ids           = [azurerm_network_interface.hv01_nic.id]

  # Init Boot Script (Cloud-Init custom_data)
  custom_data = filebase64("${path.module}/../scripts/install-host-prereqs.sh")

  os_disk {
    name                 = "osdisk-hv01"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 128
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  tags = var.tags
}

# Dedicated 128GB Managed Data Disk for KVM Guest QCOW2 storage
resource "azurerm_managed_disk" "hv01_data_disk" {
  name                 = "disk-hv01-vms"
  location             = azurerm_resource_group.onprem_rg.location
  resource_group_name  = azurerm_resource_group.onprem_rg.name
  storage_account_type = "Premium_LRS"
  create_option        = "Empty"
  disk_size_gb         = 128

  tags = var.tags
}

# Attach Data Disk to HV01 at LUN 0
resource "azurerm_virtual_machine_data_disk_attachment" "hv01_data_attach" {
  managed_disk_id    = azurerm_managed_disk.hv01_data_disk.id
  virtual_machine_id = azurerm_linux_virtual_machine.hv01.id
  lun                = 0
  caching            = "ReadWrite"
}
