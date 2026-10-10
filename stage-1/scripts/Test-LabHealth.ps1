# ==============================================================================
# Enterprise Cloud Migration Lab — End-to-End Health & Validation Suite
# Script: Test-LabHealth.ps1
#
# Runs on HV01 (Windows Server PowerShell) to audit all services across the 4 VMs:
#   - DC01   (192.168.10.10) — DNS & Active Directory
#   - APP01  (192.168.10.20) — React UI & Express API
#   - DB01   (192.168.10.30) — PostgreSQL Database
#   - FILE01 (192.168.10.40) — Samba Media Storage
# ==============================================================================

[CmdletBinding()]
param ()

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "  Enterprise Cloud Migration Lab: Health Check Audit Suite        " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

$Results = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-TestResult {
    param ($Tier, $HostIP, $Port, $CheckName, $Status, $Details)
    $Results.Add([PSCustomObject]@{
        Tier      = $Tier
        Host      = $HostIP
        Port      = $Port
        Check     = $CheckName
        Status    = $Status
        Details   = $Details
    })
}

# 1. ICMP Ping Connectivity
$Fleet = @(
    @{ Name = "DC01";   IP = "192.168.10.10" },
    @{ Name = "APP01";  IP = "192.168.10.20" },
    @{ Name = "DB01";   IP = "192.168.10.30" },
    @{ Name = "FILE01"; IP = "192.168.10.40" }
)

Write-Host "`n[1/5] Auditing Network Connectivity (ICMP)..." -ForegroundColor Yellow
foreach ($node in $Fleet) {
    $ping = Test-Connection -ComputerName $node.IP -Count 1 -Quiet
    if ($ping) {
        Add-TestResult -Tier $node.Name -HostIP $node.IP -Port "ICMP" -CheckName "Network Ping" -Status "PASS" -Details "Host reachable"
    } else {
        Add-TestResult -Tier $node.Name -HostIP $node.IP -Port "ICMP" -CheckName "Network Ping" -Status "FAIL" -Details "Host unreachable"
    }
}

# 2. Port Listening Audits
Write-Host "`n[2/5] Auditing TCP Listening Endpoints..." -ForegroundColor Yellow
$Ports = @(
    @{ Tier = "DC01";   IP = "192.168.10.10"; Port = 53;   Name = "DNS Resolver" },
    @{ Tier = "DC01";   IP = "192.168.10.10"; Port = 389;  Name = "LDAP Directory" },
    @{ Tier = "DC01";   IP = "192.168.10.10"; Port = 88;   Name = "Kerberos KDC" },
    @{ Tier = "DB01";   IP = "192.168.10.30"; Port = 5432; Name = "PostgreSQL DB" },
    @{ Tier = "FILE01"; IP = "192.168.10.40"; Port = 445;  Name = "SMB File Server" },
    @{ Tier = "APP01";  IP = "192.168.10.20"; Port = 80;   Name = "Nginx Web Port" },
    @{ Tier = "APP01";  IP = "192.168.10.20"; Port = 5000; Name = "Express API Port" }
)

foreach ($p in $Ports) {
    $conn = Test-NetConnection -ComputerName $p.IP -Port $p.Port -WarningAction SilentlyContinue
    if ($conn.TcpTestSucceeded) {
        Add-TestResult -Tier $p.Tier -HostIP $p.IP -Port $p.Port -CheckName $p.Name -Status "PASS" -Details "TCP Port Open"
    } else {
        Add-TestResult -Tier $p.Tier -HostIP $p.IP -Port $p.Port -CheckName $p.Name -Status "FAIL" -Details "TCP Port Closed/Unresponsive"
    }
}

# 3. DNS Resolution Audit
Write-Host "`n[3/5] Auditing DNS Name Resolution via DC01..." -ForegroundColor Yellow
try {
    $dns = Resolve-DnsName -Name "corp.streamflix.lab" -Server "192.168.10.10" -ErrorAction Stop
    Add-TestResult -Tier "DC01" -HostIP "192.168.10.10" -Port 53 -CheckName "Domain DNS Query" -Status "PASS" -Details "Resolved to $($dns.IPAddress)"
} catch {
    Add-TestResult -Tier "DC01" -HostIP "192.168.10.10" -Port 53 -CheckName "Domain DNS Query" -Status "WARN" -Details $_.Exception.Message
}

# 4. StreamFlix API Health & Database Audit
Write-Host "`n[4/5] Auditing StreamFlix Application Health..." -ForegroundColor Yellow
try {
    $api = Invoke-RestMethod -Uri "http://192.168.10.20/api/health" -TimeoutSec 5 -ErrorAction Stop
    $dbStatus = if ($api.database -eq "CONNECTED") { "PASS" } else { "FAIL" }
    Add-TestResult -Tier "APP01" -HostIP "192.168.10.20" -Port 5000 -CheckName "StreamFlix Health Endpoint" -Status $dbStatus -Details "API: $($api.status) | Database: $($api.database)"
} catch {
    Add-TestResult -Tier "APP01" -HostIP "192.168.10.20" -Port 5000 -CheckName "StreamFlix Health Endpoint" -Status "FAIL" -Details $_.Exception.Message
}

# 5. Media Video Streaming Byte-Range Audit
Write-Host "`n[5/5] Auditing HTTP 206 Byte-Range Video Delivery..." -ForegroundColor Yellow
try {
    $httpReq = [System.Net.HttpWebRequest]::Create("http://192.168.10.20/media/videos/migration.mp4")
    $httpReq.AddRange(0, 1024)
    $httpResp = $httpReq.GetResponse()
    if ($httpResp.StatusCode -eq "PartialContent") {
        Add-TestResult -Tier "APP01" -HostIP "192.168.10.20" -Port 80 -CheckName "HTTP 206 Video Streaming" -Status "PASS" -Details "HTTP 206 Partial Content range requests supported"
    } else {
        Add-TestResult -Tier "APP01" -HostIP "192.168.10.20" -Port 80 -CheckName "HTTP 206 Video Streaming" -Status "WARN" -Details "Returned $($httpResp.StatusCode)"
    }
    $httpResp.Close()
} catch {
    Add-TestResult -Tier "APP01" -HostIP "192.168.10.20" -Port 80 -CheckName "HTTP 206 Video Streaming" -Status "WARN" -Details $_.Exception.Message
}

# Output Summary Table
Write-Host "`n==================================================================" -ForegroundColor Green
Write-Host "  Audit Results Summary Table                                     " -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green
$Results | Format-Table -AutoSize
