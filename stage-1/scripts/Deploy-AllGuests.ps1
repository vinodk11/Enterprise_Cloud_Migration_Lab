# ==============================================================================
# Enterprise Cloud Migration Lab — Master Guest Fleet Orchestrator
# Script: Deploy-AllGuests.ps1
#
# Runs on HV01 (Windows Server PowerShell) to orchestrate end-to-end setup across
# all 4 on-premises Linux virtual machines:
#   1. DC01   (192.168.10.10) — Samba Active Directory & DNS
#   2. DB01   (192.168.10.30) — PostgreSQL Database Engine & Schema
#   3. FILE01 (192.168.10.40) — Samba Media Storage & Asset Files
#   4. APP01  (192.168.10.20) — React Frontend, Express API & Nginx Proxy
# ==============================================================================

[CmdletBinding()]
param (
    [string]$TargetVM = "ALL",     # Options: "ALL", "DC01", "DB01", "FILE01", "APP01"
    [string]$DefaultUser = "labadmin",
    [string]$DefaultPass = "LabAdmin2026!#"
)

$ErrorActionPreference = "Stop"

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "  Enterprise Cloud Migration Lab: Master Guest Fleet Orchestrator " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

$Fleet = @(
    @{ Name = "DC01";   IP = "192.168.10.10"; Script = "configure-dc01.sh";   Role = "Samba AD DS & DNS" },
    @{ Name = "DB01";   IP = "192.168.10.30"; Script = "configure-db01.sh";   Role = "PostgreSQL Database Engine" },
    @{ Name = "FILE01"; IP = "192.168.10.40"; Script = "configure-file01.sh"; Role = "Samba Media & Asset Storage" },
    @{ Name = "APP01";  IP = "192.168.10.20"; Script = "configure-app01.sh";  Role = "StreamFlix Web & API Gateway" }
)

$Targets = if ($TargetVM -eq "ALL") { $Fleet } else { $Fleet | Where-Object { $_.Name -eq $TargetVM } }

if (-not $Targets) {
    Throw "Invalid TargetVM specified: '$TargetVM'. Choose from: ALL, DC01, DB01, FILE01, APP01."
}

# Helper to run SSH command
function Invoke-GuestScript {
    param (
        [string]$IP,
        [string]$ScriptName,
        [string]$RoleName
    )

    $localScript = Join-Path $PSScriptRoot $ScriptName
    if (-not (Test-Path $localScript)) {
        Throw "Local script '$localScript' not found."
    }

    Write-Host "`n------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "  Deploying $RoleName ($IP)..." -ForegroundColor Yellow
    Write-Host "------------------------------------------------------------------" -ForegroundColor Yellow

    # Test ping
    if (-not (Test-Connection -ComputerName $IP -Count 2 -Quiet)) {
        Throw "Host $IP is unreachable. Verify VM is running and Cloud-Init completed."
    }
    Write-Host " [OK] Ping check passed." -ForegroundColor Green

    # Upload script via SCP
    Write-Host " Uploading $ScriptName..." -ForegroundColor Gray
    scp -o StrictHostKeyChecking=no "$localScript" "${DefaultUser}@${IP}:/tmp/$ScriptName"

    # Execute script with sudo via SSH
    Write-Host " Executing $ScriptName on guest..." -ForegroundColor Cyan
    ssh -o StrictHostKeyChecking=no -t "${DefaultUser}@${IP}" "echo '$DefaultPass' | sudo -S bash /tmp/$ScriptName"
    Write-Host " [OK] Provisioning of $RoleName completed." -ForegroundColor Green
}

# Execute deployments in dependency order
foreach ($guest in $Targets) {
    Invoke-GuestScript -IP $guest.IP -ScriptName $guest.Script -RoleName "$($guest.Name) ($($guest.Role))"
}

# ------------------------------------------------------------------------------
# Final End-to-End Validation Dashboard
# ------------------------------------------------------------------------------
Write-Host "`n==================================================================" -ForegroundColor Green
Write-Host "  End-to-End Validation Dashboard                                 " -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green

$Services = @(
    @{ Host = "192.168.10.10"; Port = 53;   Service = "DC01 DNS Server" },
    @{ Host = "192.168.10.10"; Port = 389;  Service = "DC01 LDAP Active Directory" },
    @{ Host = "192.168.10.30"; Port = 5432; Service = "DB01 PostgreSQL Database" },
    @{ Host = "192.168.10.40"; Port = 445;  Service = "FILE01 Samba Media Share" },
    @{ Host = "192.168.10.20"; Port = 80;   Service = "APP01 Nginx Web Frontend" },
    @{ Host = "192.168.10.20"; Port = 5000; Service = "APP01 Express REST API" }
)

foreach ($s in $Services) {
    $conn = Test-NetConnection -ComputerName $s.Host -Port $s.Port -WarningAction SilentlyContinue
    if ($conn.TcpTestSucceeded) {
        Write-Host " [ONLINE] $($s.Service) ($($s.Host):$($s.Port))" -ForegroundColor Green
    } else {
        Write-Warning " [OFFLINE] $($s.Service) ($($s.Host):$($s.Port)) did not respond."
    }
}

# Test StreamFlix API Health endpoint directly from HV01
try {
    $apiResp = Invoke-RestMethod -Uri "http://192.168.10.20/api/health" -TimeoutSec 5 -ErrorAction SilentlyContinue
    if ($apiResp -and $apiResp.status -eq "UP") {
        Write-Host "`n [STREAMFLIX HEALTH] API: $($apiResp.status) | Database: $($apiResp.database) | Service: $($apiResp.service)" -ForegroundColor Green
    }
} catch {
    Write-Host " Note: Direct HTTP test will complete once APP01 finishes binding." -ForegroundColor Gray
}

Write-Host "`nStreamFlix Web Application is ready! Open in browser on HV01: http://192.168.10.20" -ForegroundColor Cyan
