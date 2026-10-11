# ==============================================================================
# Enterprise Cloud Migration Lab — Prerequisites Installer
# Script: Install-VagrantAndGit.ps1
# Runs on HV01 (Windows Server 2022 Hyper-V Host) as Administrator
#
# Automatically downloads and silently installs:
#   1. Git for Windows & Git Bash (https://git-scm.com)
#   2. HashiCorp Vagrant (https://www.vagrantup.com)
# ==============================================================================

[CmdletBinding()]
param(
    [string]$GitVersion = "2.44.0",
    [string]$VagrantVersion = "2.4.1",
    [string]$DownloadDir = "$env:TEMP\LabInstallers"
)

$ErrorActionPreference = "Stop"

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "  Enterprise Cloud Migration Lab: Install Vagrant & Git Bash      " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

if (-not (Test-Path $DownloadDir)) {
    New-Item -Path $DownloadDir -ItemType Directory -Force | Out-Null
}

# ------------------------------------------------------------------------------
# 1. Install Git for Windows & Git Bash
# ------------------------------------------------------------------------------
Write-Host "`n>>> [1/3] Checking Git for Windows & Git Bash..." -ForegroundColor Yellow

$gitInstalled = Get-Command git.exe -ErrorAction SilentlyContinue
if ($gitInstalled -or (Test-Path "C:\Program Files\Git\cmd\git.exe")) {
    $currentGitVer = & "C:\Program Files\Git\cmd\git.exe" --version
    Write-Host " [OK] Git is already installed: $currentGitVer" -ForegroundColor Green
} else {
    $gitInstaller = Join-Path $DownloadDir "Git-Installer.exe"
    $gitUrl = "https://github.com/git-for-windows/git/releases/download/v$($GitVersion).windows.1/Git-$($GitVersion)-64-bit.exe"

    if (-not (Test-Path $gitInstaller)) {
        Write-Host " Downloading Git for Windows $GitVersion installer..." -ForegroundColor Gray
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            & curl.exe -L -o $gitInstaller $gitUrl
        } else {
            Invoke-WebRequest -Uri $gitUrl -OutFile $gitInstaller -UseBasicParsing
        }
    }

    Write-Host " Running silent installation of Git Bash..." -ForegroundColor Cyan
    $proc = Start-Process -FilePath $gitInstaller -ArgumentList "/VERYSILENT /NORESTART /NOCANCEL /SP-" -Wait -PassThru
    Write-Host " [OK] Git for Windows installed successfully (Exit Code: $($proc.ExitCode))." -ForegroundColor Green
}

# ------------------------------------------------------------------------------
# 2. Install HashiCorp Vagrant
# ------------------------------------------------------------------------------
Write-Host "`n>>> [2/3] Checking HashiCorp Vagrant..." -ForegroundColor Yellow

$vagrantInstalled = Get-Command vagrant.exe -ErrorAction SilentlyContinue
if ($vagrantInstalled -or (Test-Path "C:\Program Files\HashiCorp\Vagrant\bin\vagrant.exe")) {
    $currentVagrantVer = & "C:\Program Files\HashiCorp\Vagrant\bin\vagrant.exe" --version
    Write-Host " [OK] Vagrant is already installed: $currentVagrantVer" -ForegroundColor Green
} else {
    $vagrantMsi = Join-Path $DownloadDir "vagrant.msi"
    $vagrantUrl = "https://releases.hashicorp.com/vagrant/$($VagrantVersion)/vagrant_$($VagrantVersion)_windows_amd64.msi"

    if (-not (Test-Path $vagrantMsi)) {
        Write-Host " Downloading Vagrant $VagrantVersion installer..." -ForegroundColor Gray
        if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
            & curl.exe -L -o $vagrantMsi $vagrantUrl
        } else {
            Invoke-WebRequest -Uri $vagrantUrl -OutFile $vagrantMsi -UseBasicParsing
        }
    }

    Write-Host " Running silent MSI installation of Vagrant..." -ForegroundColor Cyan
    $proc = Start-Process msiexec.exe -ArgumentList "/i `"$vagrantMsi`" /quiet /norestart" -Wait -PassThru
    Write-Host " [OK] Vagrant installed successfully (Exit Code: $($proc.ExitCode))." -ForegroundColor Green
}

# ------------------------------------------------------------------------------
# 3. Refresh PATH and Verify Commands
# ------------------------------------------------------------------------------
Write-Host "`n>>> [3/3] Refreshing environment PATH and validating..." -ForegroundColor Yellow

$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

$gitCmd = "C:\Program Files\Git\cmd\git.exe"
$gitBash = "C:\Program Files\Git\bin\bash.exe"
$vagrantCmd = "C:\Program Files\HashiCorp\Vagrant\bin\vagrant.exe"

if (Test-Path $gitCmd) {
    Write-Host " [VERIFIED] Git CLI:     $(& $gitCmd --version)" -ForegroundColor Green
} else {
    Write-Warning " [!] Git command not found at expected path."
}

if (Test-Path $gitBash) {
    $bashVer = (& $gitBash --version | Select-Object -First 1)
    Write-Host " [VERIFIED] Git Bash:    $bashVer" -ForegroundColor Green
} else {
    Write-Warning " [!] Git Bash not found at expected path."
}

if (Test-Path $vagrantCmd) {
    Write-Host " [VERIFIED] Vagrant CLI: $(& $vagrantCmd --version)" -ForegroundColor Green
} else {
    Write-Warning " [!] Vagrant command not found at expected path."
}

Write-Host "`n==================================================================" -ForegroundColor Green
Write-Host "  Prerequisites Ready! You can now run Deploy-VmsLoop.ps1         " -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green
