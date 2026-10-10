# ==============================================================================
# Enterprise Cloud Migration Lab — Phase 6: Orchestrate DC01 Setup from HV01
# Script: Deploy-DC01-AD.ps1
#
# Runs on HV01 (PowerShell) to trigger automated configuration on DC01 (192.168.10.10)
# ==============================================================================

[CmdletBinding()]
param (
    [string]$TargetIP  = "192.168.10.10",
    [string]$Username  = "labadmin",
    [string]$Password  = "LabAdmin2026!#"
)

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "  Phase 6: Triggering Samba AD DS & DNS Configuration on DC01    " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

# 1. Test Network Connectivity
Write-Host "`n>>> [1/3] Checking connectivity to DC01 ($TargetIP)..." -ForegroundColor Yellow
$ping = Test-Connection -ComputerName $TargetIP -Count 2 -Quiet
if (-not $ping) {
    Throw "Cannot reach DC01 at $TargetIP. Please verify that the VM is running and Cloud-Init finished."
}
Write-Host " [OK] DC01 responds to ping." -ForegroundColor Green

# 2. Upload and Execute Configuration Script via SSH
$scriptPath = Join-Path $PSScriptRoot "configure-dc01.sh"
if (-not (Test-Path $scriptPath)) {
    Throw "configure-dc01.sh not found in $PSScriptRoot."
}

Write-Host "`n>>> [2/3] Uploading and executing configure-dc01.sh on DC01..." -ForegroundColor Yellow
Write-Host " Connecting via SSH (labadmin@$TargetIP)..." -ForegroundColor Gray

# Use native Windows OpenSSH to copy and run
scp -o StrictHostKeyChecking=no "$scriptPath" "${Username}@${TargetIP}:/tmp/configure-dc01.sh"
ssh -o StrictHostKeyChecking=no -t "${Username}@${TargetIP}" "echo '$Password' | sudo -S bash /tmp/configure-dc01.sh"

# 3. Port & Service Validation from Host
Write-Host "`n>>> [3/3] Validating Active Directory & DNS Services on DC01..." -ForegroundColor Yellow
$ports = @(
    @{ Port = 53;  Name = "DNS" },
    @{ Port = 88;  Name = "Kerberos" },
    @{ Port = 389; Name = "LDAP" },
    @{ Port = 445; Name = "SMB/Active Directory" }
)

foreach ($p in $ports) {
    $conn = Test-NetConnection -ComputerName $TargetIP -Port $p.Port -WarningAction SilentlyContinue
    if ($conn.TcpTestSucceeded) {
        Write-Host " [ONLINE] Port $($p.Port) ($($p.Name)) is OPEN" -ForegroundColor Green
    } else {
        Write-Warning " Port $($p.Port) ($($p.Name)) did not respond."
    }
}

Write-Host "`n[SUCCESS] DC01 Active Directory & DNS setup completed successfully!" -ForegroundColor Green
