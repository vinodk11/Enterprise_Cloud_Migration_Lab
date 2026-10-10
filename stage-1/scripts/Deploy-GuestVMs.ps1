# ==============================================================================
# Script: Deploy-GuestVMs.ps1
# Purpose: Provision Generation-2 Ubuntu Guest VMs on Hyper-V Host (HV01)
# ==============================================================================

[CmdletBinding()]
param (
    [string]$TargetVM = "ALL",  # Options: "TEST", "DC01", "APP01", "DB01", "FILE01", "ALL"
    [string]$SwitchName = "vSwitch-Internal-NAT",
    [switch]$StartVMs = $true
)

$ErrorActionPreference = "Stop"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Enterprise Cloud Migration Lab: Deploy Guest VMs        " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. Administrator Check
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Throw "This script must be executed as Administrator in an elevated PowerShell session."
}

# 2. Hyper-V Availability Check
$vmms = Get-Service vmms -ErrorAction SilentlyContinue
if (-not $vmms -or $vmms.Status -ne "Running") {
    Throw "Hyper-V Virtual Machine Management Service (vmms) is not running. Please reboot the host and rerun setup-hyperv.ps1."
}

# 3. Dynamic Storage Discovery
$vmVolume = Get-Volume -FileSystemLabel "VMStorage" -ErrorAction SilentlyContinue
$driveLetter = if ($vmVolume) { "$($vmVolume.DriveLetter):" } else { "C:" }
$storagePath = "$driveLetter\Hyper-V"
$vhdPath = "$storagePath\Virtual Hard Disks"
$baseImagePath = "$vhdPath\Ubuntu-22.04-Server-Base.vhdx"
$baseDownloadUrl = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.vhdx"

# 4. Check Free Disk Space
$freeSpaceGB = [math]::Round((Get-PSDrive -Name ($driveLetter.TrimEnd(':'))).Free / 1GB)
Write-Host "Available disk space on ${driveLetter}: ${freeSpaceGB} GB" -ForegroundColor Cyan
if ($freeSpaceGB -lt 15) {
    Throw "Insufficient free disk space on ${driveLetter}. At least 15 GB free is required."
}

# 5. Base Image Download
if (-not (Test-Path $baseImagePath)) {
    Write-Host "Downloading Ubuntu 22.04 LTS Base Cloud Image (approx. 500 MB)..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri $baseDownloadUrl -OutFile $baseImagePath -UseBasicParsing
    Write-Host "Base image downloaded successfully to $baseImagePath" -ForegroundColor Green
} else {
    Write-Host "Ubuntu base image already exists at $baseImagePath" -ForegroundColor Green
}

# 6. Define Guest Fleet Specification
$GuestFleet = @(
    @{ Name = "TEST-UBUNTU"; RAM = 2GB; CPU = 1; IP = "192.168.10.99"; Role = "Phase 4 Validation Guest" },
    @{ Name = "DC01";        RAM = 3GB; CPU = 2; IP = "192.168.10.10"; Role = "Samba AD DS and DNS" },
    @{ Name = "APP01";       RAM = 2GB; CPU = 1; IP = "192.168.10.20"; Role = "StreamFlix React & Node.js" },
    @{ Name = "DB01";        RAM = 3GB; CPU = 2; IP = "192.168.10.30"; Role = "PostgreSQL Database Engine" },
    @{ Name = "FILE01";      RAM = 2GB; CPU = 1; IP = "192.168.10.40"; Role = "Samba Media & File Storage" }
)

# Filter targets based on input parameter
if ($TargetVM -eq "TEST") {
    $DeployList = $GuestFleet | Where-Object { $_.Name -eq "TEST-UBUNTU" }
} elseif ($TargetVM -eq "ALL") {
    $DeployList = $GuestFleet | Where-Object { $_.Name -ne "TEST-UBUNTU" }
} else {
    $DeployList = $GuestFleet | Where-Object { $_.Name -eq $TargetVM }
}

if (-not $DeployList) {
    Throw "No matching VMs found for TargetVM '$TargetVM'."
}

# 7. Provision Selected Virtual Machines
foreach ($vm in $DeployList) {
    $vmName = $vm.Name
    $diffDisk = "$vhdPath\$vmName-OS.vhdx"

    Write-Host "`n--> Provisioning $vmName ($($vm.Role))..." -ForegroundColor Cyan

    if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
        Write-Host "VM '$vmName' already exists. Skipping creation." -ForegroundColor Yellow
        continue
    }

    # Create Fast Differencing Disk
    Write-Host "Creating Differencing Disk from parent base image..." -ForegroundColor Gray
    New-VHD -ParentPath $baseImagePath -Path $diffDisk -Differencing | Out-Null

    # Create Generation 2 VM
    Write-Host "Creating Generation-2 Virtual Machine ($($vm.CPU) vCPUs, $([math]::Round($vm.RAM / 1GB)) GB RAM)..." -ForegroundColor Gray
    New-VM -Name $vmName `
           -Generation 2 `
           -MemoryStartupBytes $vm.RAM `
           -VHDPath $diffDisk `
           -SwitchName $SwitchName `
           -Path $storagePath | Out-Null

    # CPU and Memory Configuration
    Set-VMProcessor -VMName $vmName -Count $vm.CPU
    Set-VMMemory -VMName $vmName -DynamicMemoryEnabled $true -MinimumBytes 1GB -MaximumBytes $vm.RAM

    # Configure Secure Boot for Linux (Microsoft UEFI Certificate Authority)
    Set-VMFirmware -VMName $vmName -EnableSecureBoot On -SecureBootTemplate "MicrosoftUEFICertificateAuthority"

    # Set Auto-Start Policy
    Set-VM -Name $vmName -AutomaticStartAction StartIfRunning

    Write-Host "VM '$vmName' provisioned successfully!" -ForegroundColor Green

    if ($StartVMs) {
        Write-Host "Starting '$vmName'..." -ForegroundColor Green
        Start-VM -Name $vmName
    }
}

# 8. Status Summary
Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host "  Current Virtual Machine Fleet Status                    " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
Get-VM | Select-Object Name, State, CPUUsage, MemoryAssigned, Uptime | Format-Table -AutoSize
