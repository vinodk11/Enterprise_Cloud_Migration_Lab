# Stage 1.2 — Windows Server 2022 Hyper-V Host (HV01)

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

# Windows Server 2022 Hyper-V Host Virtual Machine
resource "azurerm_windows_virtual_machine" "hv01" {
  name                  = var.hv01_vm_name
  computer_name         = "HV01"
  location              = azurerm_resource_group.onprem_rg.location
  resource_group_name   = azurerm_resource_group.onprem_rg.name
  size                  = var.vm_size
  admin_username        = var.admin_username
  admin_password        = coalesce(var.admin_password, random_password.hv01_admin_password.result)
  network_interface_ids = [azurerm_network_interface.hv01_nic.id]

  os_disk {
    name                 = "osdisk-hv01"
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 128
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-azure-edition"
    version   = "latest"
  }

  tags = var.tags
}

# Dedicated 128GB Managed Data Disk for Hyper-V Guest VHDX storage
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
  virtual_machine_id = azurerm_windows_virtual_machine.hv01.id
  lun                = 0
  caching            = "ReadWrite"
}

# Custom Script Extension to install Hyper-V and RSAT tools
resource "azurerm_virtual_machine_extension" "hv01_hyperv_feature" {
  name                 = "Install-HyperV-Feature"
  virtual_machine_id   = azurerm_windows_virtual_machine.hv01.id
  publisher            = "Microsoft.Compute"
  type                 = "CustomScriptExtension"
  type_handler_version = "1.10"

  settings = <<SETTINGS
    {
        "commandToExecute": "powershell.exe -ExecutionPolicy Unrestricted -Command \"Install-WindowsFeature -Name Hyper-V, RSAT-Hyper-V-Tools -IncludeManagementTools\""
    }
SETTINGS

  tags = var.tags

  depends_on = [
    azurerm_virtual_machine_data_disk_attachment.hv01_data_attach
  ]
}
