# ==============================================================================
# Enterprise Cloud Migration Lab — All-in-One On-Premises Host & Guest Automation
# Script: setup-onprem-lab.ps1
#
# What this script does automatically on HV01:
#   1. STORAGE : Formats 128GB Data Disk (NTFS "VMStorage") and configures Hyper-V paths
#   2. NETWORK : Creates Internal Virtual Switch, sets 192.168.10.1 Gateway, and creates NAT
#   3. GUEST VMs: Downloads Ubuntu 22.04 LTS Base VHDX, creates differencing disks,
#                 provisions 4 Gen-2 VMs (DC01, APP01, DB01, FILE01), and starts them
# ==============================================================================

[CmdletBinding()]
param (
    [string]$SwitchName    = "vSwitch-Internal-NAT",
    [string]$NatGatewayIP  = "192.168.10.1",
    [int]$NatPrefixLength  = 24,
    [string]$NatSubnetCIDR = "192.168.10.0/24",
    [string]$NatName       = "OnPremNAT",
    [switch]$SkipDownload  = $false
)

$ErrorActionPreference = "Stop"

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "  Enterprise Cloud Migration Lab — Host & Guest Automation Setup  " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# STEP 1: Verify Administrator Privileges & Hyper-V Service
# ------------------------------------------------------------------------------
Write-Host "`n>>> [STEP 1/4] Verifying Host Prerequisites..." -ForegroundColor Yellow

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Throw "This script must be executed as Administrator in an elevated PowerShell session."
}

$vmms = Get-Service vmms -ErrorAction SilentlyContinue
if (-not $vmms -or $vmms.Status -ne "Running") {
    Throw "Hyper-V Virtual Machine Management Service (vmms) is not running. Please verify Hyper-V feature is installed and reboot the host."
}
Write-Host " [OK] Hyper-V Service (vmms) is Running." -ForegroundColor Green

# ------------------------------------------------------------------------------
# STEP 2: Configure Dedicated Storage (128GB Data Disk)
# ------------------------------------------------------------------------------
Write-Host "`n>>> [STEP 2/4] Configuring Dedicated VM Storage..." -ForegroundColor Yellow

# Detect unpartitioned RAW disk >= 100 GB
$rawDisk = Get-Disk | Where-Object { $_.PartitionStyle -eq "RAW" -and $_.Size -ge 100GB } | Select-Object -First 1
if ($rawDisk) {
    Write-Host " Found unpartitioned Data Disk $($rawDisk.Number) ($([math]::Round($rawDisk.Size / 1GB)) GB). Initializing as GPT..." -ForegroundColor Cyan
    Initialize-Disk -Number $rawDisk.Number -PartitionStyle GPT
    $partition = New-Partition -DiskNumber $rawDisk.Number -UseMaximumSize -AssignDriveLetter
    Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel "VMStorage" -Confirm:$false | Out-Null
    Write-Host " [OK] Disk initialized and formatted as 'VMStorage'." -ForegroundColor Green
}

# Dynamically discover drive letter
$vmVolume = Get-Volume -FileSystemLabel "VMStorage" -ErrorAction SilentlyContinue
$driveLetter = if ($vmVolume) { "$($vmVolume.DriveLetter):" } else { "C:" }
Write-Host " Storage Volume identified at: $driveLetter" -ForegroundColor Cyan

$storagePath = "$driveLetter\Hyper-V"
$vhdPath     = "$storagePath\Virtual Hard Disks"
$vmPath      = "$storagePath\Virtual Machines"

New-Item -ItemType Directory -Path $vhdPath -Force | Out-Null
New-Item -ItemType Directory -Path $vmPath -Force | Out-Null

Set-VMHost -VirtualHardDiskPath $vhdPath -VirtualMachinePath $vmPath
Write-Host " [OK] Hyper-V default paths configured at: $storagePath" -ForegroundColor Green

# ------------------------------------------------------------------------------
# STEP 3: Configure Virtual Switch and NAT Network
# ------------------------------------------------------------------------------
Write-Host "`n>>> [STEP 3/4] Configuring Virtual Switch and NAT Network..." -ForegroundColor Yellow

# 1. Create Internal Virtual Switch if not present
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
    Write-Host " [OK] Created Internal Virtual Switch: $SwitchName" -ForegroundColor Green
} else {
    Write-Host " [OK] Internal Virtual Switch '$SwitchName' already exists." -ForegroundColor Gray
}

# 2. Assign Host NAT Gateway IP Address
$natAdapter = Get-NetAdapter | Where-Object { $_.Name -like "*$SwitchName*" }
if (-not $natAdapter) {
    Throw "Failed to find network adapter for '$SwitchName'."
}

$existingIP = Get-NetIPAddress -InterfaceIndex $natAdapter.InterfaceIndex -IPAddress $NatGatewayIP -ErrorAction SilentlyContinue
if (-not $existingIP) {
    New-NetIPAddress -InterfaceIndex $natAdapter.InterfaceIndex -IPAddress $NatGatewayIP -PrefixLength $NatPrefixLength | Out-Null
    Write-Host " [OK] Assigned Gateway IP $NatGatewayIP/$NatPrefixLength to $($natAdapter.Name)" -ForegroundColor Green
} else {
    Write-Host " [OK] Gateway IP $NatGatewayIP already assigned." -ForegroundColor Gray
}

# 3. Create Windows NAT Object
if (-not (Get-NetNat -Name $NatName -ErrorAction SilentlyContinue)) {
    New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $NatSubnetCIDR | Out-Null
    Write-Host " [OK] Created NAT network '$NatName' for subnet $NatSubnetCIDR" -ForegroundColor Green
} else {
    Write-Host " [OK] NAT network '$NatName' already exists." -ForegroundColor Gray
}

# ------------------------------------------------------------------------------
# STEP 4: Provision Ubuntu Guest Virtual Machine Fleet
# ------------------------------------------------------------------------------
Write-Host "`n>>> [STEP 4/4] Provisioning 4 Ubuntu Guest Virtual Machines..." -ForegroundColor Yellow

$baseImagePath    = "$vhdPath\Ubuntu-22.04-Server-Base.vhdx"
$baseDownloadUrl  = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.vhdx"

# Download base image if missing
if (-not (Test-Path $baseImagePath)) {
    Write-Host " Downloading Ubuntu 22.04 LTS Base Cloud Image (approx. 500 MB)..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $baseDownloadUrl -OutFile $baseImagePath -UseBasicParsing
    Write-Host " [OK] Base image downloaded to $baseImagePath" -ForegroundColor Green
} else {
    Write-Host " [OK] Ubuntu base image already cached." -ForegroundColor Gray
}

# Define the 4 Target Guest VMs
$GuestFleet = @(
    @{ Name = "DC01";   RAM = 3GB; CPU = 2; IP = "192.168.10.10"; Role = "Samba AD DS & DNS" },
    @{ Name = "APP01";  RAM = 2GB; CPU = 1; IP = "192.168.10.20"; Role = "StreamFlix React & Node.js" },
    @{ Name = "DB01";   RAM = 3GB; CPU = 2; IP = "192.168.10.30"; Role = "PostgreSQL Database Engine" },
    @{ Name = "FILE01"; RAM = 2GB; CPU = 1; IP = "192.168.10.40"; Role = "Samba Media & File Storage" }
)

foreach ($vm in $GuestFleet) {
    $vmName   = $vm.Name
    $diffDisk = "$vhdPath\$vmName-OS.vhdx"

    if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
        Write-Host " [SKIP] VM '$vmName' already exists." -ForegroundColor Yellow
        continue
    }

    Write-Host " Creating Differencing Disk and VM: $vmName ($($vm.Role))..." -ForegroundColor Cyan

    # Fast Differencing Disk (shares parent base image, writes only deltas)
    New-VHD -ParentPath $baseImagePath -Path $diffDisk -Differencing | Out-Null

    # Create Generation-2 Virtual Machine
    New-VM -Name $vmName `
           -Generation 2 `
           -MemoryStartupBytes $vm.RAM `
           -VHDPath $diffDisk `
           -SwitchName $SwitchName `
           -Path $storagePath | Out-Null

    # Processor & Dynamic Memory
    Set-VMProcessor -VMName $vmName -Count $vm.CPU
    Set-VMMemory -VMName $vmName -DynamicMemoryEnabled $true -MinimumBytes 1GB -MaximumBytes $vm.RAM

    # Configure Secure Boot for Linux (Microsoft UEFI CA)
    Set-VMFirmware -VMName $vmName -EnableSecureBoot On -SecureBootTemplate "MicrosoftUEFICertificateAuthority"

    # Auto-start on host boot
    Set-VM -Name $vmName -AutomaticStartAction StartIfRunning

    Write-Host " [OK] Provisioned $vmName ($($vm.CPU) vCPU, $([math]::Round($vm.RAM / 1GB)) GB RAM)" -ForegroundColor Green
}

# ------------------------------------------------------------------------------
# STEP 5: Start Guest VMs and Display Status
# ------------------------------------------------------------------------------
Write-Host "`n>>> Starting all guest virtual machines..." -ForegroundColor Yellow
foreach ($vm in $GuestFleet) {
    $existing = Get-VM -Name $vm.Name -ErrorAction SilentlyContinue
    if ($existing -and $existing.State -ne "Running") {
        Start-VM -Name $vm.Name
        Write-Host " Started $($vm.Name)." -ForegroundColor Green
    }
}

Write-Host "`n==================================================================" -ForegroundColor Green
Write-Host "  Lab Deployment Complete! Virtual Machine Fleet Status:          " -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green
Get-VM | Select-Object Name, State, CPUUsage, MemoryAssigned, Uptime | Format-Table -AutoSize

Write-Host "`nInternal NAT Network:" -ForegroundColor Cyan
Get-NetNat -Name $NatName | Select-Object Name, InternalIPInterfaceAddressPrefix, Active | Format-Table -AutoSize
