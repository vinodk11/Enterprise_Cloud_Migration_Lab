# ==============================================================================
# Enterprise Cloud Migration Lab — Provision VMs from Local Base Image
# Script: Deploy-FromLocalImage.ps1
#
# Assumes base image (Ubuntu-Base.vhdx or jammy-server-cloudimg-amd64-azure.vhd.tar.gz)
# is downloaded locally on the host. Zero internet downloads required!
# ==============================================================================

[CmdletBinding()]
param (
    [string]$LocalImagePath = "",
    [string]$SwitchName     = "vSwitch-Internal-NAT",
    [string]$NatGatewayIP   = "192.168.10.1",
    [string]$DefaultUser    = "labadmin",
    [string]$DefaultPass    = "LabAdmin2026!#"
)

$ErrorActionPreference = "Stop"

# 1. Resolve Storage Volumes and Paths
$vmVolume = Get-Volume -FileSystemLabel "VMStorage" -ErrorAction SilentlyContinue
$driveLetter = if ($vmVolume) { "$($vmVolume.DriveLetter):" } else { "F:" }
if (-not (Test-Path "$driveLetter\")) { $driveLetter = "C:" }

$storagePath = "$driveLetter\Hyper-V"
$vhdDir      = "$storagePath\Virtual Hard Disks"
$vmDir       = "$storagePath\Virtual Machines"

New-Item -ItemType Directory -Path $vhdDir -Force | Out-Null
New-Item -ItemType Directory -Path $vmDir -Force | Out-Null

$targetBaseVhdx = "$vhdDir\Ubuntu-Base.vhdx"

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "  Enterprise Cloud Migration Lab: Provision From Local Base Image " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host " Storage Root : $storagePath" -ForegroundColor Cyan
Write-Host " VHDX Target  : $targetBaseVhdx" -ForegroundColor Cyan

# 2. Locate or Prepare Base VHDX Image Locally
if (Test-Path $targetBaseVhdx) {
    Write-Host " [OK] Found existing base image: $targetBaseVhdx" -ForegroundColor Green
} elseif (Test-Path "$vhdDir\Ubuntu-22.04-Server-Base.vhdx") {
    $targetBaseVhdx = "$vhdDir\Ubuntu-22.04-Server-Base.vhdx"
    Write-Host " [OK] Found existing base image: $targetBaseVhdx" -ForegroundColor Green
} else {
    Write-Host "`n>>> Locating locally downloaded Ubuntu base image..." -ForegroundColor Cyan

    $candidateFiles = @()
    if ($LocalImagePath -and (Test-Path $LocalImagePath)) {
        $candidateFiles += (Get-Item $LocalImagePath)
    }

    $searchFolders = @(
        "C:\Users\labadmin\Downloads",
        "$env:USERPROFILE\Downloads",
        $vhdDir,
        $PSScriptRoot
    ) | Select-Object -Unique

    foreach ($folder in $searchFolders) {
        if (Test-Path $folder) {
            $candidateFiles += Get-ChildItem -Path $folder -File -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -like "*jammy*azure*.vhd.tar.gz" -or
                $_.Name -like "*ubuntu*azure*.vhd.tar.gz" -or
                $_.Name -like "*cloudimg*.tar.gz" -or
                $_.Name -like "*livecd*.vhd" -or
                $_.Name -like "*Ubuntu*.vhdx"
            }
        }
    }

    $foundArchive = $candidateFiles | Where-Object { $_.Extension -eq ".gz" -or $_.Name -like "*.tar.gz" } | Select-Object -First 1
    $foundVhd     = $candidateFiles | Where-Object { $_.Extension -eq ".vhd" } | Select-Object -First 1
    $foundVhdx    = $candidateFiles | Where-Object { $_.Extension -eq ".vhdx" } | Select-Object -First 1

    if ($foundVhdx) {
        Write-Host " [OK] Using discovered VHDX: $($foundVhdx.FullName)" -ForegroundColor Green
        Copy-Item -Path $foundVhdx.FullName -Destination $targetBaseVhdx -Force
    } elseif ($foundVhd) {
        Write-Host " >>> Converting discovered VHD ($($foundVhd.FullName)) to Dynamic VHDX..." -ForegroundColor Cyan
        Convert-VHD -Path $foundVhd.FullName -DestinationPath $targetBaseVhdx -VHDType Dynamic
        Write-Host " [OK] Converted to $targetBaseVhdx" -ForegroundColor Green
    } elseif ($foundArchive) {
        Write-Host " >>> Extracting archive: $($foundArchive.FullName)..." -ForegroundColor Cyan
        & tar.exe -xzf "$($foundArchive.FullName)" -C "$vhdDir"

        $extractedVhd = Get-ChildItem -Path $vhdDir -Filter "*.vhd" -File | Select-Object -First 1
        if (-not $extractedVhd) {
            Throw "Archive extracted but no .vhd file was found in $vhdDir."
        }

        Write-Host " >>> Converting $($extractedVhd.Name) to Dynamic VHDX ($targetBaseVhdx)..." -ForegroundColor Cyan
        Convert-VHD -Path $extractedVhd.FullName -DestinationPath $targetBaseVhdx -VHDType Dynamic
        Remove-Item -Path $extractedVhd.FullName -Force -ErrorAction SilentlyContinue
        Write-Host " [OK] Base image created at $targetBaseVhdx" -ForegroundColor Green
    } else {
        Write-Host "`n[ERROR] No local Ubuntu image found in Downloads or Hyper-V directories!" -ForegroundColor Red
        Write-Host "Please download the Ubuntu image inside Edge on HV01:" -ForegroundColor Yellow
        Write-Host "  URL: https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64-azure.vhd.tar.gz" -ForegroundColor White
        Write-Host "Save it to: C:\Users\labadmin\Downloads\" -ForegroundColor Yellow
        Write-Host "Then re-run this script: .\Deploy-FromLocalImage.ps1" -ForegroundColor Yellow
        Throw "Local base image not found. Please download the file first."
    }
}

# 3. Cloud-Init Helper Function
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
    routes:
      - to: default
        via: $Gateway
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

# 4. Provision the 4 Guest Virtual Machines
$Fleet = @(
    @{ Name = "DC01";   RAM = 3GB; CPU = 2; IP = "192.168.10.10"; Role = "Samba AD DS & DNS" },
    @{ Name = "APP01";  RAM = 2GB; CPU = 1; IP = "192.168.10.20"; Role = "StreamFlix React & Node.js" },
    @{ Name = "DB01";   RAM = 3GB; CPU = 2; IP = "192.168.10.30"; Role = "PostgreSQL Database Engine" },
    @{ Name = "FILE01"; RAM = 2GB; CPU = 1; IP = "192.168.10.40"; Role = "Samba Media & File Storage" }
)

Write-Host "`n==================================================================" -ForegroundColor Cyan
Write-Host "  Provisioning 4 Guest VMs using Differencing Disks               " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

foreach ($vm in $Fleet) {
    $vmName   = $vm.Name
    $diffDisk = "$vhdDir\$vmName-OS.vhdx"
    $cidataIso = "$vhdDir\$vmName-cidata.iso"

    if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
        Write-Host " [SKIP] $vmName already exists." -ForegroundColor Yellow
        continue
    }

    Write-Host "`n --> Provisioning $vmName ($($vm.Role))..." -ForegroundColor Cyan
    Write-Host "     Building Cloud-Init ISO with Static IP $($vm.IP)..." -ForegroundColor Gray
    New-CloudInitISO -ISOPath $cidataIso -Hostname $vmName -IPAddress $vm.IP -Gateway $NatGatewayIP -Username $DefaultUser -Password $DefaultPass

    Write-Host "     Creating Differencing Disk ($diffDisk)..." -ForegroundColor Gray
    New-VHD -ParentPath $targetBaseVhdx -Path $diffDisk -Differencing | Out-Null

    Write-Host "     Creating Gen-2 VM ($($vm.CPU) vCPU, $([math]::Round($vm.RAM / 1GB)) GB RAM)..." -ForegroundColor Gray
    New-VM -Name $vmName -Generation 2 -MemoryStartupBytes $vm.RAM -VHDPath $diffDisk -SwitchName $SwitchName -Path $vmDir | Out-Null

    Add-VMDvdDrive -VMName $vmName -Path $cidataIso | Out-Null
    Set-VMProcessor -VMName $vmName -Count $vm.CPU
    Set-VMMemory -VMName $vmName -DynamicMemoryEnabled $true -MinimumBytes 1GB -MaximumBytes $vm.RAM
    Set-VMFirmware -VMName $vmName -EnableSecureBoot On -SecureBootTemplate "MicrosoftUEFICertificateAuthority"
    Set-VM -Name $vmName -AutomaticStartAction StartIfRunning

    Write-Host "     Starting $vmName..." -ForegroundColor Gray
    Start-VM -Name $vmName
    Write-Host " [OK] $vmName is RUNNING!" -ForegroundColor Green
}

Write-Host "`n==================================================================" -ForegroundColor Green
Write-Host "  Virtual Machine Fleet Status                                    " -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green
Get-VM | Select-Object Name, State, CPUUsage, MemoryAssigned, Uptime | Format-Table -AutoSize
Write-Host "Cloud-Init OS initialization will complete within 45-60 seconds." -ForegroundColor Yellow
Write-Host "You can test connectivity with: Test-Connection -TargetName 192.168.10.10 -Count 2" -ForegroundColor Gray
