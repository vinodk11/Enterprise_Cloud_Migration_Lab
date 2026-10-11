# ==============================================================================
# Enterprise Cloud Migration Lab — Master Vagrant Hyper-V Deployer
# Script: Deploy-VagrantLab.ps1
# Runs on HV01 (Windows Server 2022 Hyper-V Host)
# ==============================================================================

[CmdletBinding()]
param(
    [string]$VagrantDir  = "F:\Hyper-V\Vagrant",
    [string]$VagrantHome = "F:\Hyper-V\.vagrant.d"
)

$ErrorActionPreference = "Stop"

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "  Enterprise Cloud Migration Lab: Vagrant Hyper-V Deployment     " -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan

# 1. Environment & PATH setup
$env:VAGRANT_HOME = $VagrantHome
[Environment]::SetEnvironmentVariable("VAGRANT_HOME", $VagrantHome, "Machine")
[Environment]::SetEnvironmentVariable("VAGRANT_HOME", $VagrantHome, "User")

$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
if (-not (Get-Command vagrant -ErrorAction SilentlyContinue)) {
    $vagrantBin = "C:\Program Files\HashiCorp\Vagrant\bin"
    if (Test-Path $vagrantBin) {
        $env:Path += ";$vagrantBin"
    } else {
        Throw "Vagrant executable not found in PATH or standard installation directory."
    }
}
Write-Host "[OK] Detected $(& vagrant --version)" -ForegroundColor Green

# 2. Directory initialization
if (-not (Test-Path $VagrantDir)) {
    New-Item -Path $VagrantDir -ItemType Directory -Force | Out-Null
}
if (-not (Test-Path $VagrantHome)) {
    New-Item -Path $VagrantHome -ItemType Directory -Force | Out-Null
}

# 3. Clean up any existing conflicting VMs
Write-Host "`n>>> [STEP 1/4] Checking existing VM status..." -ForegroundColor Yellow
$vmList = @("DC01", "APP01", "DB01", "FILE01")
foreach ($vmName in $vmList) {
    $existing = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Host " Stopping & Removing existing VM $vmName..." -ForegroundColor Gray
        Stop-VM -Name $vmName -TurnOff -Force -ErrorAction SilentlyContinue
        Remove-VM -Name $vmName -Force -ErrorAction SilentlyContinue
    }
}

# 4. Verify DHCP Scope & Static Reservations
Write-Host "`n>>> [STEP 2/4] Verifying DHCP Server Scope & Reservations..." -ForegroundColor Yellow
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

# 5. Write Vagrantfile
Write-Host "`n>>> [STEP 3/4] Preparing Vagrantfile..." -ForegroundColor Yellow
$vagrantfilePath = Join-Path $VagrantDir "Vagrantfile"
@'
Vagrant.configure("2") do |config|
  config.vm.box = "generic/ubuntu2204"

  # Disable default SMB synced folder to eliminate interactive credential prompts
  config.vm.synced_folder ".", "/vagrant", disabled: true

  # Base provisioning: ensure labadmin user exists, has sudo access, and password auth is enabled
  config.vm.provision "shell", inline: <<-SHELL
    set -e
    echo "[PROVISION] Setting up labadmin credentials..."
    if ! id -u labadmin >/dev/null 2>&1; then
      useradd -m -s /bin/bash labadmin
    fi
    echo 'labadmin:LabAdmin2026!#' | chpasswd
    usermod -aG sudo labadmin
    echo "labadmin ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/labadmin
    chmod 0440 /etc/sudoers.d/labadmin
    
    # Enable SSH password authentication for orchestration scripts
    sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    sed -i 's/^#\?KbdInteractiveAuthentication .*/KbdInteractiveAuthentication yes/' /etc/ssh/sshd_config
    systemctl reload ssh || systemctl restart ssh || systemctl restart sshd
    echo "[PROVISION] labadmin configuration complete."
  SHELL

  config.vm.define "dc01" do |dc|
    dc.vm.hostname = "DC01.corp.streamflix.lab"
    dc.vm.network "public_network", bridge: "vSwitch-Internal-NAT"
    dc.vm.provider "hyperv" do |v|
      v.vmname = "DC01"
      v.cpus = 2
      v.memory = 2048
      v.mac = "00155D100010"
      v.auto_start_action = "Nothing"
      v.auto_stop_action = "ShutDown"
    end
  end

  config.vm.define "app01" do |app|
    app.vm.hostname = "APP01.corp.streamflix.lab"
    app.vm.network "public_network", bridge: "vSwitch-Internal-NAT"
    app.vm.provider "hyperv" do |v|
      v.vmname = "APP01"
      v.cpus = 2
      v.memory = 2048
      v.mac = "00155D100020"
      v.auto_start_action = "Nothing"
      v.auto_stop_action = "ShutDown"
    end
  end

  config.vm.define "db01" do |db|
    db.vm.hostname = "DB01.corp.streamflix.lab"
    db.vm.network "public_network", bridge: "vSwitch-Internal-NAT"
    db.vm.provider "hyperv" do |v|
      v.vmname = "DB01"
      v.cpus = 2
      v.memory = 2048
      v.mac = "00155D100030"
      v.auto_start_action = "Nothing"
      v.auto_stop_action = "ShutDown"
    end
  end

  config.vm.define "file01" do |file|
    file.vm.hostname = "FILE01.corp.streamflix.lab"
    file.vm.network "public_network", bridge: "vSwitch-Internal-NAT"
    file.vm.provider "hyperv" do |v|
      v.vmname = "FILE01"
      v.cpus = 2
      v.memory = 2048
      v.mac = "00155D100040"
      v.auto_start_action = "Nothing"
      v.auto_stop_action = "ShutDown"
    end
  end
end
'@ | Set-Content -Path $vagrantfilePath -Encoding UTF8

Write-Host "[OK] Vagrantfile written to $vagrantfilePath" -ForegroundColor Green

# 6. Execute vagrant up
Write-Host "`n>>> [STEP 4/4] Provisioning VMs via Vagrant Hyper-V provider..." -ForegroundColor Cyan
Set-Location $VagrantDir
& vagrant up --provider hyperv

Write-Host "`n==================================================================" -ForegroundColor Green
Write-Host "  Vagrant VM Provisioning Finished. Validating Network Fleet...   " -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green
& vagrant status

$fleet = @(
    @{ Name = "DC01";   IP = "192.168.10.10" },
    @{ Name = "APP01";  IP = "192.168.10.20" },
    @{ Name = "DB01";   IP = "192.168.10.30" },
    @{ Name = "FILE01"; IP = "192.168.10.40" }
)

$allOnline = $true
foreach ($node in $fleet) {
    $ping = Test-Connection -ComputerName $node.IP -Count 2 -Quiet
    if ($ping) {
        Write-Host " [REACHABLE] $($node.Name) at $($node.IP)" -ForegroundColor Green
    } else {
        Write-Warning " [UNREACHABLE] $($node.Name) at $($node.IP)"
        $allOnline = $false
    }
}

if ($allOnline) {
    Write-Host "`n>>> All 4 Virtual Machines are ONLINE and REACHABLE on 192.168.10.0/24!" -ForegroundColor Green
    Write-Host ">>> Ready to proceed with Deploy-AllGuests.ps1 for workload configuration." -ForegroundColor Cyan
} else {
    Write-Warning "`n>>> Some VMs did not respond to ping. Check 'vagrant status' or Hyper-V manager."
}
