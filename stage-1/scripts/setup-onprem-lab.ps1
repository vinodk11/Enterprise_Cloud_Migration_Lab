# ==============================================================================
# Enterprise Cloud Migration Lab — End-to-End Host & Guest OS Automation
# Script: setup-onprem-lab.ps1
#
# What this script executes end-to-end on HV01:
#   1. STORAGE     : Formats 128GB Data Disk (NTFS "VMStorage") & configures Hyper-V paths
#   2. NETWORK     : Creates Internal Switch, configures Gateway 192.168.10.1, & NAT 192.168.10.0/24
#   3. OS INSTALL  : Downloads Ubuntu 22.04 LTS Base VHDX and uses native Windows IMAPI2FS
#                    to build Cloud-Init NoCloud ISOs for each VM
#   4. PROVISION   : Creates Generation-2 VMs for DC01, APP01, DB01, FILE01 with differencing
#                    disks, attaches Cloud-Init ISOs, and boots them into full automated OS setup
# ==============================================================================

[CmdletBinding()]
param (
    [string]$SwitchName    = "vSwitch-Internal-NAT",
    [string]$NatGatewayIP  = "192.168.10.1",
    [int]$NatPrefixLength  = 24,
    [string]$NatSubnetCIDR = "192.168.10.0/24",
    [string]$NatName       = "OnPremNAT",
    [string]$DefaultUser   = "labadmin",
    [string]$DefaultPass   = "LabAdmin2026!#"
)

$ErrorActionPreference = "Stop"

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "  Enterprise Cloud Migration Lab: Host & Guest OS Automation      " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# HELPER: Generate Cloud-Init NoCloud ISO using Windows Native IMAPI2FS
# ------------------------------------------------------------------------------
function New-CloudInitISO {
    param (
        [string]$ISOPath,
        [string]$Hostname,
        [string]$IPAddress,
        [string]$Gateway = "192.168.10.1",
        [string]$Username = "labadmin",
        [string]$Password = "LabAdmin2026!#"
    )

    $tempDir = Join-Path $env:TEMP "cloudinit-$Hostname"
    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    # 1. meta-data
    $metaData = "instance-id: i-$Hostname`nlocal-hostname: $Hostname`n"
    Set-Content -Path (Join-Path $tempDir "meta-data") -Value $metaData -Encoding Ascii

    # 2. user-data
    $userData = @"
#cloud-config
users:
  - name: $Username
    groups: [sudo, adm]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    plain_text_passwd: $Password
chpasswd:
  list: |
    ${Username}:${Password}
  expire: false
ssh_pwauth: true
package_update: false
runcmd:
  - systemctl enable --now ssh
"@
    Set-Content -Path (Join-Path $tempDir "user-data") -Value $userData -Encoding Ascii

    # 3. network-config
    $networkConfig = @"
version: 2
ethernets:
  eth0:
    match:
      name: "eth*"
    dhcp4: false
    addresses:
      - $IPAddress/24
    gateway4: $Gateway
    nameservers:
      addresses:
        - 1.1.1.1
        - 8.8.8.8
"@
    Set-Content -Path (Join-Path $tempDir "network-config") -Value $networkConfig -Encoding Ascii

    # 4. Compile ISO using built-in Windows COM IMAPI2FS
    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.ChooseImageDefaultsForMediaType(1) # CD/DVD
    $fsi.VolumeName = "cidata"
    $fsi.FileSystemsToCreate = 1 # ISO 9660

    $root = $fsi.Root
    Get-ChildItem -Path $tempDir | ForEach-Object {
        $root.AddTree($_.FullName, $false)
    }

    $resultImage = $fsi.CreateResultImage()
    $stream = $resultImage.ImageStream

    if (Test-Path $ISOPath) { Remove-Item $ISOPath -Force }
    $fileStream = [System.IO.File]::OpenWrite($ISOPath)
    $buffer = New-Object byte[] 65536
    while (($bytesRead = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $fileStream.Write($buffer, 0, $bytesRead)
    }
    $fileStream.Close()
    Remove-Item $tempDir -Recurse -Force
}

# ------------------------------------------------------------------------------
# STEP 1: Verify Host Prerequisites
# ------------------------------------------------------------------------------
Write-Host "`n>>> [STEP 1/4] Verifying Host & Hyper-V Service..." -ForegroundColor Yellow
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) { Throw "Please run as Administrator in an elevated PowerShell session." }

$vmms = Get-Service vmms -ErrorAction SilentlyContinue
if (-not $vmms -or $vmms.Status -ne "Running") {
    Throw "Hyper-V service (vmms) is not running. Please reboot the host and rerun this script."
}
Write-Host " [OK] Hyper-V Service (vmms) is active." -ForegroundColor Green

# ------------------------------------------------------------------------------
# STEP 2: Configure Dedicated 128GB Data Disk for VM Storage
# ------------------------------------------------------------------------------
Write-Host "`n>>> [STEP 2/4] Configuring Storage Disks..." -ForegroundColor Yellow
$rawDisk = Get-Disk | Where-Object { $_.PartitionStyle -eq "RAW" -and $_.Size -ge 100GB } | Select-Object -First 1
if ($rawDisk) {
    Write-Host " Initializing Disk $($rawDisk.Number) ($([math]::Round($rawDisk.Size / 1GB)) GB) as GPT..." -ForegroundColor Cyan
    Initialize-Disk -Number $rawDisk.Number -PartitionStyle GPT
    $partition = New-Partition -DiskNumber $rawDisk.Number -UseMaximumSize -AssignDriveLetter
    Format-Volume -Partition $partition -FileSystem NTFS -NewFileSystemLabel "VMStorage" -Confirm:$false | Out-Null
    Write-Host " [OK] Formatted volume 'VMStorage'." -ForegroundColor Green
}

$vmVolume = Get-Volume -FileSystemLabel "VMStorage" -ErrorAction SilentlyContinue
$driveLetter = if ($vmVolume) { "$($vmVolume.DriveLetter):" } else { "C:" }
Write-Host " Storage Volume: $driveLetter" -ForegroundColor Cyan

$storagePath = "$driveLetter\Hyper-V"
$vhdPath     = "$storagePath\Virtual Hard Disks"
$vmPath      = "$storagePath\Virtual Machines"

New-Item -ItemType Directory -Path $vhdPath -Force | Out-Null
New-Item -ItemType Directory -Path $vmPath -Force | Out-Null
Set-VMHost -VirtualHardDiskPath $vhdPath -VirtualMachinePath $vmPath
Write-Host " [OK] Hyper-V Storage Paths configured: $storagePath" -ForegroundColor Green

# ------------------------------------------------------------------------------
# STEP 3: Configure Virtual Switch and NAT Network
# ------------------------------------------------------------------------------
Write-Host "`n>>> [STEP 3/4] Configuring Internal Switch & NAT Network..." -ForegroundColor Yellow
if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
    New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
}

$natAdapter = Get-NetAdapter | Where-Object { $_.Name -like "*$SwitchName*" }
if (-not (Get-NetIPAddress -InterfaceIndex $natAdapter.InterfaceIndex -IPAddress $NatGatewayIP -ErrorAction SilentlyContinue)) {
    New-NetIPAddress -InterfaceIndex $natAdapter.InterfaceIndex -IPAddress $NatGatewayIP -PrefixLength $NatPrefixLength | Out-Null
}

if (-not (Get-NetNat -Name $NatName -ErrorAction SilentlyContinue)) {
    New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $NatSubnetCIDR | Out-Null
}
Write-Host " [OK] NAT Network '$NatName' active ($NatSubnetCIDR) via Gateway $NatGatewayIP" -ForegroundColor Green

# ------------------------------------------------------------------------------
# STEP 4: Download Ubuntu Base & Provision 4 Guest VMs with Automated OS Setup
# ------------------------------------------------------------------------------
Write-Host "`n>>> [STEP 4/4] Provisioning 4 Ubuntu Guest Virtual Machines with Cloud-Init OS Automation..." -ForegroundColor Yellow

$baseImagePath   = "$vhdPath\Ubuntu-22.04-Server-Base.vhdx"
$baseDownloadUrl = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.vhdx"

if (-not (Test-Path $baseImagePath)) {
    Write-Host " Downloading Ubuntu 22.04 LTS Base Image (approx. 500 MB)..." -ForegroundColor Cyan
    Invoke-WebRequest -Uri $baseDownloadUrl -OutFile $baseImagePath -UseBasicParsing
    Write-Host " [OK] Base image downloaded to $baseImagePath" -ForegroundColor Green
}

$GuestFleet = @(
    @{ Name = "DC01";   RAM = 3GB; CPU = 2; IP = "192.168.10.10"; Role = "Samba AD DS & DNS" },
    @{ Name = "APP01";  RAM = 2GB; CPU = 1; IP = "192.168.10.20"; Role = "StreamFlix React & Node.js" },
    @{ Name = "DB01";   RAM = 3GB; CPU = 2; IP = "192.168.10.30"; Role = "PostgreSQL Database Engine" },
    @{ Name = "FILE01"; RAM = 2GB; CPU = 1; IP = "192.168.10.40"; Role = "Samba Media & File Storage" }
)

foreach ($vm in $GuestFleet) {
    $vmName   = $vm.Name
    $diffDisk = "$vhdPath\$vmName-OS.vhdx"
    $cidataIso = "$vhdPath\$vmName-cidata.iso"

    if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
        Write-Host " [SKIP] VM '$vmName' already exists." -ForegroundColor Yellow
        continue
    }

    Write-Host "`n --> Provisioning $vmName ($($vm.Role))..." -ForegroundColor Cyan

    # 1. Generate Cloud-Init Automated OS Setup ISO
    Write-Host "     Building Cloud-Init OS Automation ISO with IP $($vm.IP)..." -ForegroundColor Gray
    New-CloudInitISO -ISOPath $cidataIso -Hostname $vmName -IPAddress $vm.IP -Gateway $NatGatewayIP -Username $DefaultUser -Password $DefaultPass

    # 2. Create Fast Differencing Disk
    Write-Host "     Creating Differencing Disk..." -ForegroundColor Gray
    New-VHD -ParentPath $baseImagePath -Path $diffDisk -Differencing | Out-Null

    # 3. Create Generation-2 Virtual Machine
    Write-Host "     Creating Gen-2 VM ($($vm.CPU) vCPU, $([math]::Round($vm.RAM / 1GB)) GB RAM)..." -ForegroundColor Gray
    New-VM -Name $vmName -Generation 2 -MemoryStartupBytes $vm.RAM -VHDPath $diffDisk -SwitchName $SwitchName -Path $storagePath | Out-Null

    # 4. Attach Cloud-Init ISO as Virtual DVD Drive
    Add-VMDvdDrive -VMName $vmName -Path $cidataIso | Out-Null

    # 5. Processor, Dynamic Memory & Secure Boot
    Set-VMProcessor -VMName $vmName -Count $vm.CPU
    Set-VMMemory -VMName $vmName -DynamicMemoryEnabled $true -MinimumBytes 1GB -MaximumBytes $vm.RAM
    Set-VMFirmware -VMName $vmName -EnableSecureBoot On -SecureBootTemplate "MicrosoftUEFICertificateAuthority"
    Set-VM -Name $vmName -AutomaticStartAction StartIfRunning

    # 6. Boot VM into Automated OS Setup
    Start-VM -Name $vmName
    Write-Host " [OK] $vmName powered on! Cloud-init is automatically configuring hostname, static IP $($vm.IP), and user '$DefaultUser'." -ForegroundColor Green
}

# ------------------------------------------------------------------------------
# STEP 5: Final Status Summary
# ------------------------------------------------------------------------------
Write-Host "`n==================================================================" -ForegroundColor Green
Write-Host "  Deployment Complete! Guest Virtual Machine Fleet:               " -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green
Get-VM | Select-Object Name, State, CPUUsage, MemoryAssigned, Uptime | Format-Table -AutoSize

Write-Host "Default Login Credentials for all Guest VMs:" -ForegroundColor Cyan
Write-Host "  Username : $DefaultUser" -ForegroundColor White
Write-Host "  Password : $DefaultPass" -ForegroundColor White
Write-Host "`nNote: Cloud-init finishes OS initialization within 45-60 seconds of initial boot." -ForegroundColor Yellow
