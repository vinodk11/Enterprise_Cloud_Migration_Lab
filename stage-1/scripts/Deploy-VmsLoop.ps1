# ==============================================================================
# Enterprise Cloud Migration Lab — Master Sequential Fleet Deployer
# Script: Deploy-VmsLoop.ps1
# Runs on HV01 (Windows Server 2022 Hyper-V Host)
#
# Deploys 4 isolated VMs sequentially, each from its own dedicated directory:
#   1. F:\Hyper-V\Vagrant\dc01   -> Samba Active Directory & DNS (192.168.10.10)
#   2. F:\Hyper-V\Vagrant\db01   -> PostgreSQL Database Engine    (192.168.10.30)
#   3. F:\Hyper-V\Vagrant\file01 -> Samba Media Asset Share       (192.168.10.40)
#   4. F:\Hyper-V\Vagrant\app01  -> StreamFlix Web & API Gateway  (192.168.10.20)
# ==============================================================================

[CmdletBinding()]
param(
    [string]$VagrantBaseDir = "",
    [string]$VagrantHome    = "",
    [string]$TargetVM       = "ALL"  # Options: ALL, dc01, db01, file01, app01
)

$ErrorActionPreference = "Stop"

# Auto-detect best storage path
if (-not $VagrantBaseDir) {
    if (Test-Path "F:\") {
        $VagrantBaseDir = "F:\Hyper-V\Vagrant"
    } else {
        $repoVagrant = Join-Path $PSScriptRoot "..\vagrant"
        if (Test-Path $repoVagrant) {
            $VagrantBaseDir = (Resolve-Path $repoVagrant).Path
        } else {
            $VagrantBaseDir = "C:\Hyper-V\Vagrant"
        }
    }
}

if (-not $VagrantHome) {
    if (Test-Path "F:\") {
        $VagrantHome = "F:\Hyper-V\.vagrant.d"
    } else {
        $VagrantHome = "$env:USERPROFILE\.vagrant.d"
    }
}

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "  Enterprise Cloud Migration Lab: Sequential VM Fleet Deployer    " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

# 1. Environment & PATH setup
$env:VAGRANT_HOME = $VagrantHome
[Environment]::SetEnvironmentVariable("VAGRANT_HOME", $VagrantHome, "Machine")
[Environment]::SetEnvironmentVariable("VAGRANT_HOME", $VagrantHome, "User")

$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
if (-not (Get-Command vagrant -ErrorAction SilentlyContinue)) {
    $vagrantBins = @("C:\Program Files\Vagrant\bin", "C:\Program Files\HashiCorp\Vagrant\bin")
    foreach ($bin in $vagrantBins) {
        if (Test-Path $bin) { $env:Path += ";$bin" }
    }
}
if (-not (Get-Command vagrant -ErrorAction SilentlyContinue)) {
    Throw "Vagrant executable not found in PATH. Please run Install-VagrantAndGit.ps1 first."
}
Write-Host "[OK] Using $(& vagrant --version)" -ForegroundColor Green

# 2. Host Prerequisites: DHCP Role & Virtual Switch
Write-Host "`n>>> [STEP 1/3] Verifying Host Hyper-V Switch & DHCP Role..." -ForegroundColor Yellow

# Ensure DHCP role is installed
if (-not (Get-Command Get-DhcpServerv4Scope -ErrorAction SilentlyContinue)) {
    Write-Host " Installing Windows DHCP Server Feature..." -ForegroundColor Cyan
    Install-WindowsFeature DHCP -IncludeManagementTools | Out-Null
    netsh dhcp add securitygroups | Out-Null
    Restart-Service dhcpserver -ErrorAction SilentlyContinue
}

# Ensure Internal Virtual Switch exists
$switch = Get-VMSwitch -Name "vSwitch-Internal-NAT" -ErrorAction SilentlyContinue
if (-not $switch) {
    Write-Host " Creating Internal VMSwitch 'vSwitch-Internal-NAT'..." -ForegroundColor Cyan
    New-VMSwitch -Name "vSwitch-Internal-NAT" -SwitchType Internal | Out-Null
}

$adapter = Get-NetAdapter | Where-Object { $_.Name -like "*vSwitch-Internal-NAT*" }
if ($adapter) {
    $ip = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress 192.168.10.1 -ErrorAction SilentlyContinue
    if (-not $ip) {
        Write-Host " Assigning Gateway IP 192.168.10.1 to vSwitch-Internal-NAT..." -ForegroundColor Cyan
        New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress 192.168.10.1 -PrefixLength 24 | Out-Null
    }
}

$nat = Get-NetNat -Name "OnPremNAT" -ErrorAction SilentlyContinue
if (-not $nat) {
    Write-Host " Configuring NAT Network 'OnPremNAT' (192.168.10.0/24)..." -ForegroundColor Cyan
    New-NetNat -Name "OnPremNAT" -InternalIPInterfaceAddressPrefix 192.168.10.0/24 | Out-Null
}

# Verify DHCP Server Scope & Reservations
$scope = Get-DhcpServerv4Scope -ScopeId 192.168.10.0 -ErrorAction SilentlyContinue
if (-not $scope) {
    Write-Host " Configuring DHCP scope 192.168.10.0/24..." -ForegroundColor Cyan
    Add-DhcpServerv4Scope -Name "OnPremNAT" -StartRange 192.168.10.100 -EndRange 192.168.10.200 -SubnetMask 255.255.255.0 -State Active
    Set-DhcpServerv4OptionValue -ScopeId 192.168.10.0 -Router 192.168.10.1 -DnsServer 1.1.1.1, 8.8.8.8
}

$reservations = @(
    @{ IP = "192.168.10.10"; MAC = "00-15-5D-10-00-10"; Name = "DC01" },
    @{ IP = "192.168.10.20"; MAC = "00-15-5D-10-00-20"; Name = "APP01" },
    @{ IP = "192.168.10.30"; MAC = "00-15-5D-10-00-30"; Name = "DB01" },
    @{ IP = "192.168.10.40"; MAC = "00-15-5D-10-00-40"; Name = "FILE01" }
)

$existingReservations = Get-DhcpServerv4Reservation -ScopeId 192.168.10.0 -ErrorAction SilentlyContinue
foreach ($res in $reservations) {
    $found = $existingReservations | Where-Object { $_.IPAddress.IPAddressToString -eq $res.IP }
    if (-not $found) {
        Add-DhcpServerv4Reservation -ScopeId 192.168.10.0 -IPAddress $res.IP -ClientId $res.MAC -Name $res.Name
    }
}
Write-Host "[OK] DHCP Server scope and reservations verified active." -ForegroundColor Green

# 3. Fleet Definition in Dependency Order
$fleet = @(
    @{ Name = "dc01";   VMName = "DC01";   IP = "192.168.10.10"; Role = "Samba AD DS & DNS";              Ports = @(53, 389) },
    @{ Name = "db01";   VMName = "DB01";   IP = "192.168.10.30"; Role = "PostgreSQL Database Engine";     Ports = @(5432) },
    @{ Name = "file01"; VMName = "FILE01"; IP = "192.168.10.40"; Role = "Samba Media & Asset Storage";    Ports = @(445) },
    @{ Name = "app01";  VMName = "APP01";  IP = "192.168.10.20"; Role = "StreamFlix Web & API Gateway";   Ports = @(80, 5000) }
)

$deployQueue = if ($TargetVM -eq "ALL") { $fleet } else { $fleet | Where-Object { $_.Name -eq $TargetVM.ToLower() } }

if (-not $deployQueue) {
    Throw "Invalid TargetVM specified: '$TargetVM'. Choose from: ALL, dc01, db01, file01, app01."
}

# 4. Sequential Loop Deployment
Write-Host "`n>>> [STEP 2/3] Provisioning Virtual Machines Sequentially..." -ForegroundColor Yellow

$results = @()
$stepNum = 1
$totalSteps = $deployQueue.Count

foreach ($node in $deployQueue) {
    $nodeDir = Join-Path $VagrantBaseDir $node.Name
    Write-Host "`n==================================================================" -ForegroundColor Cyan
    Write-Host "  [$stepNum/$totalSteps] Deploying $($node.VMName) ($($node.Role))" -ForegroundColor Cyan
    Write-Host "  Directory: $nodeDir | Target IP: $($node.IP)" -ForegroundColor Cyan
    Write-Host "==================================================================" -ForegroundColor Cyan

    if (-not (Test-Path $nodeDir)) {
        Throw "VM directory '$nodeDir' does not exist."
    }

    Set-Location $nodeDir

    # Execute vagrant up with hyperv provider
    Write-Host " Launching vagrant up --provider hyperv..." -ForegroundColor Yellow
    & vagrant up --provider hyperv

    # Verify Ping
    Write-Host " Validating network reachability to $($node.IP)..." -ForegroundColor Yellow
    $pingSuccess = $false
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        if (Test-Connection -ComputerName $node.IP -Count 1 -Quiet) {
            $pingSuccess = $true
            break
        }
        Start-Sleep -Seconds 3
    }

    if ($pingSuccess) {
        Write-Host " [ONLINE] $($node.VMName) reachable at $($node.IP)" -ForegroundColor Green
    } else {
        Write-Warning " [WARNING] $($node.VMName) did not respond to ping at $($node.IP)"
    }

    # Verify Service Ports
    $portResults = @()
    foreach ($p in $node.Ports) {
        $conn = Test-NetConnection -ComputerName $node.IP -Port $p -WarningAction SilentlyContinue
        $portResults += "$($p):$($conn.TcpTestSucceeded)"
        if ($conn.TcpTestSucceeded) {
            Write-Host " [PORT OK] Port $p is listening on $($node.IP)" -ForegroundColor Green
        } else {
            Write-Warning " [PORT WAIT] Port $p is not responding yet on $($node.IP)"
        }
    }

    $results += [PSCustomObject]@{
        Name    = $node.VMName
        Role    = $node.Role
        IP      = $node.IP
        Ping    = if ($pingSuccess) { "ONLINE" } else { "OFFLINE" }
        Ports   = ($portResults -join ", ")
    }

    $stepNum++
}

# 5. Final Dashboard
Write-Host "`n==================================================================" -ForegroundColor Green
Write-Host "  Enterprise Cloud Migration Lab: Final Deployment Summary       " -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green
$results | Format-Table -AutoSize
