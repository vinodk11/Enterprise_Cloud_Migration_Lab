# ==============================================================================
# Script: setup-hyperv.ps1
# Purpose: Automated Hyper-V Storage, Virtual Switch, and NAT Gateway Setup on HV01
# Usage:
#   PowerShell -ExecutionPolicy Bypass -File .\setup-hyperv.ps1
# ==============================================================================

[CmdletBinding()]
param (
    [string]$SwitchName    = "vSwitch-Internal-NAT",
    [string]$NatGatewayIP  = "192.168.10.1",
    [int]$NatPrefixLength  = 24,
    [string]$NatSubnetCIDR = "192.168.10.0/24",
    [string]$NatName       = "OnPremNAT"
)

$ErrorActionPreference = "Stop"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Enterprise Cloud Migration Lab: Phase 3 Hyper-V Setup   " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. Administrator Check
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Throw "This script must be executed as Administrator in an elevated PowerShell session."
}

# 2. Check Hyper-V Role & Service Status
Write-Host "`n[1/5] Checking Hyper-V Role and Management Service..." -ForegroundColor Cyan
$hyperv = Get-WindowsFeature -Name Hyper-V
if ($hyperv.InstallState -ne "Installed") {
    Write-Host "Hyper-V role is not installed. Installing Hyper-V & RSAT tools..." -ForegroundColor Yellow
    Install-WindowsFeature -Name Hyper-V, RSAT-Hyper-V-Tools -IncludeManagementTools -Restart:$false
    Write-Warning "Hyper-V feature files installed. A host reboot is required before services can start."
    Write-Host "Restarting computer in 5 seconds..." -ForegroundColor Red
    Start-Sleep -Seconds 5
    Restart-Computer -Force
    exit 3010
}

$vmms = Get-Service vmms -ErrorAction SilentlyContinue
if (-not $vmms -or $vmms.Status -ne "Running") {
    Write-Warning "Hyper-V is installed but the 'vmms' service is not running (reboot pending)."
    Write-Host "Restarting computer in 5 seconds to activate the hypervisor kernel..." -ForegroundColor Red
    Start-Sleep -Seconds 5
    Restart-Computer -Force
    exit 3010
}
Write-Host "Hyper-V role and Virtual Machine Management Service (vmms) are active!" -ForegroundColor Green

# 3. Dynamic Storage Discovery & Formatting (No hardcoded drive letters)
Write-Host "`n[2/5] Inspecting attached disks and configuring dedicated VM storage..." -ForegroundColor Cyan
$rawDisk = Get-Disk | Where-Object { $_.PartitionStyle -eq "RAW" -and $_.Size -ge 100GB } | Select-Object -First 1

if ($rawDisk) {
    Write-Host "Found unpartitioned Disk $($rawDisk.Number) ($([math]::Round($rawDisk.Size / 1GB)) GB). Initializing as GPT..." -ForegroundColor Green
    Initialize-Disk -Number $rawDisk.Number -PartitionStyle GPT
    $partition = New-Partition -DiskNumber $rawDisk.Number -UseMaximumSize -AssignDriveLetter
    Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel "VMStorage" -Confirm:$false | Out-Null
    Write-Host "Formatted volume labeled 'VMStorage'." -ForegroundColor Green
}

$vmVolume = Get-Volume -FileSystemLabel "VMStorage" -ErrorAction SilentlyContinue
if ($vmVolume) {
    $driveLetter = "$($vmVolume.DriveLetter):"
    Write-Host "Dedicated VM storage drive located at: $driveLetter" -ForegroundColor Green
} else {
    $driveLetter = "C:"
    Write-Warning "Dedicated volume not found. Falling back to primary drive: $driveLetter"
}

$baseStoragePath = "$driveLetter\Hyper-V"
$vhdPath = "$baseStoragePath\Virtual Hard Disks"
$vmPath  = "$baseStoragePath\Virtual Machines"

New-Item -ItemType Directory -Path $vhdPath -Force | Out-Null
New-Item -ItemType Directory -Path $vmPath -Force | Out-Null

Set-VMHost -VirtualHardDiskPath $vhdPath -VirtualMachinePath $vmPath
Write-Host "Configured Hyper-V default storage: $baseStoragePath" -ForegroundColor Green

# 4. Create Internal Virtual Switch
Write-Host "`n[3/5] Configuring Internal Virtual Switch '$SwitchName'..." -ForegroundColor Cyan
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
    Write-Host "Created internal virtual switch '$SwitchName'." -ForegroundColor Green
} else {
    Write-Host "Internal virtual switch '$SwitchName' already exists." -ForegroundColor Yellow
}

# 5. Configure Host NAT Gateway IP Address
Write-Host "`n[4/5] Assigning Host Gateway IP $NatGatewayIP/$NatPrefixLength to virtual adapter..." -ForegroundColor Cyan
$natAdapter = Get-NetAdapter | Where-Object { $_.Name -like "*$SwitchName*" }
if (-not $natAdapter) {
    Throw "Unable to locate network adapter associated with '$SwitchName'."
}

$existingIP = Get-NetIPAddress -InterfaceIndex $natAdapter.InterfaceIndex -IPAddress $NatGatewayIP -ErrorAction SilentlyContinue
if (-not $existingIP) {
    New-NetIPAddress -InterfaceIndex $natAdapter.InterfaceIndex -IPAddress $NatGatewayIP -PrefixLength $NatPrefixLength | Out-Null
    Write-Host "Assigned IP $NatGatewayIP to '$($natAdapter.Name)'." -ForegroundColor Green
} else {
    Write-Host "IP $NatGatewayIP is already assigned to '$($natAdapter.Name)'." -ForegroundColor Yellow
}

# 6. Configure Windows NAT Object
Write-Host "`n[5/5] Configuring Windows NAT network '$NatName' for subnet $NatSubnetCIDR..." -ForegroundColor Cyan
if (-not (Get-NetNat -Name $NatName -ErrorAction SilentlyContinue)) {
    New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $NatSubnetCIDR | Out-Null
    Write-Host "Created NAT network '$NatName' for $NatSubnetCIDR." -ForegroundColor Green
} else {
    Write-Host "NAT network '$NatName' already exists." -ForegroundColor Yellow
}

# 7. Validation Output Table
Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host "  Phase 3 Hyper-V Setup Validation Summary                " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green

Write-Host "`n--- Hyper-V Service ---" -ForegroundColor Yellow
Get-Service vmms | Select-Object Name, Status, DisplayName | Format-Table -AutoSize

Write-Host "--- Virtual Switches ---" -ForegroundColor Yellow
Get-VMSwitch -Name $SwitchName | Select-Object Name, SwitchType | Format-Table -AutoSize

Write-Host "--- NAT Network Object ---" -ForegroundColor Yellow
Get-NetNat -Name $NatName | Select-Object Name, InternalIPInterfaceAddressPrefix, Active | Format-Table -AutoSize

Write-Host "--- NAT Gateway IP ---" -ForegroundColor Yellow
Get-NetIPAddress -InterfaceIndex $natAdapter.InterfaceIndex -AddressFamily IPv4 | Select-Object IPAddress, PrefixLength | Format-Table -AutoSize

Write-Host "Phase 3 configuration completed successfully!" -ForegroundColor Green
