# ==============================================================================
# Enterprise Cloud Migration Lab — Prepare Local Ubuntu Base Image
# Script: Prepare-LocalBaseImage.ps1
#
# Extracts locally downloaded jammy-server-cloudimg-amd64-azure.vhd.tar.gz
# and converts it to Dynamic VHDX for Hyper-V Generation-2 VMs.
# ==============================================================================

[CmdletBinding()]
param (
    [string]$ArchivePath = "",
    [string]$DestinationVhdx = "F:\Hyper-V\Virtual Hard Disks\Ubuntu-Base.vhdx"
)

$ErrorActionPreference = "Stop"

# Auto-detect VM storage drive (F: or C:)
$vmVolume = Get-Volume -FileSystemLabel "VMStorage" -ErrorAction SilentlyContinue
$driveLetter = if ($vmVolume) { "$($vmVolume.DriveLetter):" } else { "F:" }
if (-not (Test-Path "$driveLetter\")) { $driveLetter = "C:" }

$destDir = "$driveLetter\Hyper-V\Virtual Hard Disks"
$targetVhdx = "$destDir\Ubuntu-Base.vhdx"
New-Item -ItemType Directory -Path $destDir -Force | Out-Null

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "  Preparing Local Ubuntu Base VHDX Image                          " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

# 1. Locate Archive if not provided
if (-not $ArchivePath -or -not (Test-Path $ArchivePath)) {
    $searchPaths = @(
        "C:\Users\labadmin\Downloads\jammy-server-cloudimg-amd64-azure.vhd.tar.gz",
        "$env:USERPROFILE\Downloads\jammy-server-cloudimg-amd64-azure.vhd.tar.gz",
        "$destDir\ubuntu-22.04-azure.vhd.tar.gz",
        "$PSScriptRoot\jammy-server-cloudimg-amd64-azure.vhd.tar.gz"
    )

    foreach ($p in $searchPaths) {
        if (Test-Path $p) {
            $ArchivePath = $p
            break
        }
    }
}

if (-not $ArchivePath -or -not (Test-Path $ArchivePath)) {
    Write-Host "[ERROR] Could not find downloaded Ubuntu archive!" -ForegroundColor Red
    Write-Host "Please ensure 'jammy-server-cloudimg-amd64-azure.vhd.tar.gz' is in C:\Users\labadmin\Downloads\" -ForegroundColor Yellow
    Throw "Archive file not found. Download it in Edge first."
}

Write-Host " Using Archive: $ArchivePath" -ForegroundColor Green
Write-Host " Target VHDX  : $targetVhdx" -ForegroundColor Green

# 2. Extract VHD
Write-Host "`n>>> Extracting VHD from archive..." -ForegroundColor Cyan
& tar.exe -xzf "$ArchivePath" -C "$destDir"

$extractedVhd = Get-ChildItem -Path $destDir -Filter "*.vhd" -File | Select-Object -First 1
if (-not $extractedVhd) {
    Throw "Extraction completed, but no .vhd file was found in $destDir."
}

# 3. Convert to Dynamic VHDX
Write-Host ">>> Converting $($extractedVhd.Name) to Dynamic VHDX..." -ForegroundColor Cyan
Convert-VHD -Path $extractedVhd.FullName -DestinationPath $targetVhdx -VHDType Dynamic

# 4. Clean up raw VHD
Write-Host ">>> Cleaning up raw temporary VHD..." -ForegroundColor Cyan
Remove-Item -Path $extractedVhd.FullName -Force -ErrorAction SilentlyContinue

Write-Host "`n==================================================================" -ForegroundColor Green
Write-Host "  [OK] Base VHDX Ready for Guest VM Fleet!                        " -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green
Get-Item $targetVhdx | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize
Write-Host "Next step: Run .\Deploy-FromLocalImage.ps1 to provision all 4 VMs!" -ForegroundColor Yellow
