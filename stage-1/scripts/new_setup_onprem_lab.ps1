# ==============================================================================
# Enterprise Cloud Migration Lab — Host & Guest OS Setup
# Script: new_setup_onprem_lab.ps1
# ==============================================================================

[CmdletBinding()]
param (
    [string]$SwitchName    = "vSwitch-Internal-NAT",
    [string]$NatGatewayIP  = "192.168.10.1",
    [string]$DefaultUser   = "labadmin",
    [string]$DefaultPass   = "LabAdmin2026!#"
)

$ErrorActionPreference = "Stop"

# Auto-detect VM storage drive (F: or C:)
$vmVolume = Get-Volume -FileSystemLabel "VMStorage" -ErrorAction SilentlyContinue
$driveLetter = if ($vmVolume) { "$($vmVolume.DriveLetter):" } else { "F:" }
if (-not (Test-Path "$driveLetter\")) { $driveLetter = "C:" }

$storagePath = "$driveLetter\Hyper-V"
$vhdPath     = "$storagePath\Virtual Hard Disks"
$vmPath      = "$storagePath\Virtual Machines"

New-Item -ItemType Directory -Path $vhdPath -Force | Out-Null
New-Item -ItemType Directory -Path $vmPath -Force | Out-Null

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "  Enterprise Cloud Migration Lab: Provisioning Guest VM Fleet     " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host " Storage Root : $storagePath" -ForegroundColor Cyan

# ------------------------------------------------------------------------------
# 1. Download & Prepare Base VHDX Image
# ------------------------------------------------------------------------------
$baseImagePath = "$vhdPath\Ubuntu-22.04-Server-Base.vhdx"
$baseTarPath   = "$vhdPath\ubuntu-22.04-azure.vhd.tar.gz"
$rawVhdPath    = "$vhdPath\livecd.ubuntu-cpc.azure.vhd"
$downloadUrl   = "https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64-azure.vhd.tar.gz"

if ((Test-Path $baseImagePath) -and ((Get-Item $baseImagePath).Length -lt 100MB)) {
    Write-Warning "Existing base image is corrupted or incomplete (<100MB). Removing..."
    Remove-Item $baseImagePath -Force -ErrorAction SilentlyContinue
}

if (-not (Test-Path $baseImagePath)) {
    Write-Host "`n>>> [1/3] Downloading Ubuntu 22.04 LTS Base Image (~670 MB)..." -ForegroundColor Cyan
    $ProgressPreference = 'SilentlyContinue'
    if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
        & curl.exe -L -o "$baseTarPath" "$downloadUrl"
    } else {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $baseTarPath -UseBasicParsing
    }

    Write-Host ">>> Extracting VHD from archive..." -ForegroundColor Cyan
    & tar.exe -xzf "$baseTarPath" -C "$vhdPath"

    Write-Host ">>> Converting to Hyper-V Gen-2 VHDX..." -ForegroundColor Cyan
    Convert-VHD -Path $rawVhdPath -DestinationPath $baseImagePath -VHDType Dynamic

    Remove-Item $baseTarPath, $rawVhdPath -Force -ErrorAction SilentlyContinue
    Write-Host ">>> [OK] Base image created at $baseImagePath" -ForegroundColor Green
} else {
    Write-Host "`n>>> [1/3] Base image ready at $baseImagePath" -ForegroundColor Green
}

# ------------------------------------------------------------------------------
# 2. Helper: Cloud-Init ISO Generation
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

    $tempDir = Join-Path $env:TEMP "cidata-$Hostname"
    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    $metaData = "instance-id: i-$Hostname`nlocal-hostname: $Hostname`n"
    Set-Content -Path (Join-Path $tempDir "meta-data") -Value $metaData -Encoding Ascii

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

    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.ChooseImageDefaultsForMediaType(1)
    $fsi.VolumeName = "cidata"
    $fsi.FileSystemsToCreate = 1
    $root = $fsi.Root
    Get-ChildItem -Path $tempDir | ForEach-Object { $root.AddTree($_.FullName, $false) }
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
# 3. Create and Boot the 4 Virtual Machines
# ------------------------------------------------------------------------------
Write-Host "`n>>> [2/3] Provisioning Generation-2 Guest VMs..." -ForegroundColor Yellow

$Fleet = @(
    @{ Name = "DC01";   RAM = 3GB; CPU = 2; IP = "192.168.10.10"; Role = "Samba AD DS & DNS" },
    @{ Name = "APP01";  RAM = 2GB; CPU = 1; IP = "192.168.10.20"; Role = "StreamFlix React & Node.js" },
    @{ Name = "DB01";   RAM = 3GB; CPU = 2; IP = "192.168.10.30"; Role = "PostgreSQL Database Engine" },
    @{ Name = "FILE01"; RAM = 2GB; CPU = 1; IP = "192.168.10.40"; Role = "Samba Media & File Storage" }
)

foreach ($vm in $Fleet) {
    $vmName   = $vm.Name
    $diffDisk = "$vhdPath\$vmName-OS.vhdx"
    $cidataIso = "$vhdPath\$vmName-cidata.iso"

    if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
        Write-Host " [SKIP] $vmName already exists." -ForegroundColor Yellow
        continue
    }

    Write-Host "`n --> Provisioning $vmName ($($vm.Role))..." -ForegroundColor Cyan
    Write-Host "     Building Cloud-Init ISO with IP $($vm.IP)..." -ForegroundColor Gray
    New-CloudInitISO -ISOPath $cidataIso -Hostname $vmName -IPAddress $vm.IP -Gateway $NatGatewayIP -Username $DefaultUser -Password $DefaultPass

    Write-Host "     Creating Differencing Disk..." -ForegroundColor Gray
    New-VHD -ParentPath $baseImagePath -Path $diffDisk -Differencing | Out-Null

    Write-Host "     Creating Generation-2 VM ($($vm.CPU) vCPU, $([math]::Round($vm.RAM / 1GB)) GB RAM)..." -ForegroundColor Gray
    New-VM -Name $vmName -Generation 2 -MemoryStartupBytes $vm.RAM -VHDPath $diffDisk -SwitchName $SwitchName -Path $vmPath | Out-Null

    Add-VMDvdDrive -VMName $vmName -Path $cidataIso | Out-Null
    Set-VMProcessor -VMName $vmName -Count $vm.CPU
    Set-VMMemory -VMName $vmName -DynamicMemoryEnabled $true -MinimumBytes 1GB -MaximumBytes $vm.RAM
    Set-VMFirmware -VMName $vmName -EnableSecureBoot On -SecureBootTemplate "MicrosoftUEFICertificateAuthority"
    Set-VM -Name $vmName -AutomaticStartAction StartIfRunning

    Write-Host "     Starting $vmName..." -ForegroundColor Gray
    Start-VM -Name $vmName
    Write-Host " [OK] $vmName is RUNNING!" -ForegroundColor Green
}

# ------------------------------------------------------------------------------
# 4. Fleet Status Summary
# ------------------------------------------------------------------------------
Write-Host "`n==================================================================" -ForegroundColor Green
Write-Host "  Virtual Machine Fleet Status                                    " -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green
Get-VM | Select-Object Name, State, CPUUsage, MemoryAssigned, Uptime | Format-Table -AutoSize
Write-Host "Cloud-Init OS initialization takes ~45-60s after initial boot." -ForegroundColor Yellow
