#requires -RunAsAdministrator
#requires -Modules Hyper-V
<#
Enterprise Cloud Migration Lab - Hyper-V Ubuntu guest fleet
Windows PowerShell 5.1+

What this script does:
  1. Checks Hyper-V, storage, and SSH-key prerequisites.
  2. Downloads the Ubuntu 22.04 Azure cloud image and verifies its SHA256 checksum.
  3. Extracts the VHD and copies it to a non-sparse working file before Convert-VHD.
  4. Creates an internal Hyper-V switch and Windows NAT, without silently replacing conflicts.
  5. Builds cloud-init NoCloud ISOs using SSH public-key authentication (no embedded password).
  6. Creates DC01, APP01, DB01, and FILE01 using differencing disks.
  7. Starts DC01 only by default. Use -StartAll only after checking host capacity.

Run from elevated Windows PowerShell:
  .\new_setup_onprem_lab_fixed.ps1
  .\new_setup_onprem_lab_fixed.ps1 -StartAll

Keep the base VHDX file: all guest OS disks depend on it.
#>

[CmdletBinding()]
param(
    [string]$SwitchName = "vSwitch-Internal-NAT",
    [string]$NatName = "EnterpriseCloudMigrationLabNAT",
    [string]$NatGatewayIP = "192.168.10.1",
    [string]$GuestSubnet = "192.168.10.0/24",
    [string]$DefaultUser = "labadmin",
    [string]$SshPublicKeyPath = "$env:USERPROFILE\.ssh\onprem-lab-ed25519.pub",
    [switch]$StartAll
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Step([string]$Message) {
    Write-Host "`n>>> $Message" -ForegroundColor Cyan
}
function Write-Ok([string]$Message) {
    Write-Host "[OK] $Message" -ForegroundColor Green
}
function Stop-WithMessage([string]$Message) {
    throw $Message
}
function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Ensure-SshKey {
    param([string]$PublicKeyPath)
    if (Test-Path $PublicKeyPath) { return }

    $sshKeygen = Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue
    if (-not $sshKeygen) {
        Stop-WithMessage @"
SSH public key not found: $PublicKeyPath
Open Windows Settings > Optional Features and install OpenSSH Client, or create an Ed25519 key pair.
Then rerun this script with -SshPublicKeyPath 'C:\path\to\your-key.pub'.
"@
    }

    $sshDir = Split-Path -Parent $PublicKeyPath
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    $privateKeyPath = $PublicKeyPath -replace '\.pub$', ''
    if (Test-Path $privateKeyPath) {
        Stop-WithMessage "Private key exists but public key is missing: $privateKeyPath. Restore its .pub file or choose another -SshPublicKeyPath."
    }

    Write-Host "No SSH public key found. Creating an Ed25519 key pair." -ForegroundColor Yellow
    Write-Host "ssh-keygen may ask you to set a passphrase. Keep the private key secure." -ForegroundColor Yellow
    & $sshKeygen.Source -t ed25519 -C "enterprise-cloud-migration-lab" -f $privateKeyPath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $PublicKeyPath)) {
        Stop-WithMessage "SSH key generation failed. Create a key pair manually and rerun the script."
    }
}
function New-NonSparseCopy {
    param(
        [Parameter(Mandatory=$true)][string]$Source,
        [Parameter(Mandatory=$true)][string]$Destination
    )
    if (Test-Path $Destination) { Remove-Item $Destination -Force }
    $sourceInfo = Get-Item -LiteralPath $Source
    $driveName = ([IO.Path]::GetPathRoot($Destination)).TrimEnd('\').TrimEnd(':')
    $drive = Get-PSDrive -Name $driveName -ErrorAction Stop
    # A normal copy reads sparse holes as zeroes and writes them as allocated bytes.
    if ($drive.Free -lt ($sourceInfo.Length + 2GB)) {
        Stop-WithMessage ("Not enough free space to normalize the VHD. Source logical size is {0:N2} GB; free space is {1:N2} GB." -f ($sourceInfo.Length / 1GB), ($drive.Free / 1GB))
    }

    $inputStream = $null
    $outputStream = $null
    try {
        $inputStream = [IO.File]::Open($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $outputStream = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $buffer = New-Object byte[] (8MB)
        while (($read = $inputStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outputStream.Write($buffer, 0, $read)
        }
        $outputStream.Flush()
    }
    finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
    }
    if ((Get-Item $Destination).Length -ne $sourceInfo.Length) {
        Remove-Item $Destination -Force -ErrorAction SilentlyContinue
        Stop-WithMessage "The normalized VHD copy is incomplete; source and destination lengths differ."
    }
}
function New-CloudInitISO {
    param(
        [Parameter(Mandatory=$true)][string]$ISOPath,
        [Parameter(Mandatory=$true)][string]$Hostname,
        [Parameter(Mandatory=$true)][string]$IPAddress,
        [Parameter(Mandatory=$true)][string]$Gateway,
        [Parameter(Mandatory=$true)][string]$Username,
        [Parameter(Mandatory=$true)][string]$PublicKey
    )

    $tempDir = Join-Path $env:TEMP ("cidata-" + $Hostname)
    if (Test-Path $tempDir) { Remove-Item $tempDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    try {
        @"
instance-id: iid-$Hostname
local-hostname: $Hostname
"@ | Set-Content -LiteralPath (Join-Path $tempDir "meta-data") -Encoding ASCII

        # Use an SSH public key only; password authentication is disabled.
        $userData = @"
#cloud-config
hostname: $Hostname
manage_etc_hosts: true
users:
  - name: $Username
    gecos: Enterprise Cloud Migration Lab Administrator
    groups: [sudo, adm]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - $PublicKey
ssh_pwauth: false
disable_root: true
package_update: false
runcmd:
  - [systemctl, enable, --now, ssh]
"@
        $userData | Set-Content -LiteralPath (Join-Path $tempDir "user-data") -Encoding ASCII

        # Match either common Ubuntu NIC naming style (eth0 / ens160).
        $networkConfig = @"
version: 2
ethernets:
  labnic:
    match:
      name: "e*"
    dhcp4: false
    addresses:
      - $IPAddress/24
    routes:
      - to: default
        via: $Gateway
    nameservers:
      addresses: [1.1.1.1, 8.8.8.8]
"@
        $networkConfig | Set-Content -LiteralPath (Join-Path $tempDir "network-config") -Encoding ASCII

        if (Test-Path $ISOPath) { Remove-Item $ISOPath -Force }
        $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
        $fsi.ChooseImageDefaultsForMediaType(1) # CD-ROM
        $fsi.VolumeName = "cidata"
        $fsi.FileSystemsToCreate = 1 # ISO9660
        $root = $fsi.Root
        Get-ChildItem -LiteralPath $tempDir -File | ForEach-Object {
            $root.AddFile($_.Name, $_.FullName)
        }
        $resultImage = $fsi.CreateResultImage()
        $stream = $resultImage.ImageStream
        $fileStream = [IO.File]::Open($ISOPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $buffer = New-Object byte[] 65536
            while (($bytesRead = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $fileStream.Write($buffer, 0, $bytesRead)
            }
            $fileStream.Flush()
        }
        finally {
            $fileStream.Dispose()
            if ($stream -and ($stream -is [IDisposable])) { $stream.Dispose() }
        }
    }
    finally {
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path $ISOPath) -or (Get-Item $ISOPath).Length -lt 1MB) {
        Stop-WithMessage "Cloud-init ISO creation failed for $Hostname."
    }
}

# ---- Preflight ----
if (-not (Test-IsAdministrator)) {
    Stop-WithMessage "Run this script from an elevated PowerShell window (Run as Administrator)."
}
if (-not (Get-Command Get-VM -ErrorAction SilentlyContinue)) {
    Stop-WithMessage "Hyper-V PowerShell cmdlets are not available. Confirm Hyper-V is installed and this host supports it."
}
if ($DefaultUser -notmatch '^[a-z_][a-z0-9_-]*[$]?$') {
    Stop-WithMessage "DefaultUser must be a valid Linux username."
}
if ($GuestSubnet -ne "192.168.10.0/24") {
    Stop-WithMessage "This script currently defines guest addresses in 192.168.10.0/24. Keep GuestSubnet at its default unless you also update the fleet IPs and network config."
}

Ensure-SshKey -PublicKeyPath $SshPublicKeyPath
$publicKey = (Get-Content -LiteralPath $SshPublicKeyPath -Raw).Trim()
if ($publicKey -notmatch '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256)\s+\S+') {
    Stop-WithMessage "The SSH public key file does not look like a valid OpenSSH public key: $SshPublicKeyPath"
}

# Auto-detect VM storage volume labeled VMStorage; otherwise use F: if present, else C:.
$vmVolume = Get-Volume -FileSystemLabel "VMStorage" -ErrorAction SilentlyContinue |
    Where-Object { $_.DriveLetter } | Select-Object -First 1
if ($vmVolume) {
    $driveLetter = "$($vmVolume.DriveLetter):"
} elseif (Test-Path "F:\") {
    $driveLetter = "F:"
} else {
    $driveLetter = "C:"
}
$storagePath = Join-Path $driveLetter "Hyper-V"
$vhdPath = Join-Path $storagePath "Virtual Hard Disks"
$vmPath = Join-Path $storagePath "Virtual Machines"
New-Item -ItemType Directory -Path $vhdPath -Force | Out-Null
New-Item -ItemType Directory -Path $vmPath -Force | Out-Null

$baseImagePath = Join-Path $vhdPath "Ubuntu-22.04-Server-Base.vhdx"
$baseTarPath = Join-Path $vhdPath "ubuntu-22.04-azure.vhd.tar.gz"
$rawVhdPath = Join-Path $vhdPath "livecd.ubuntu-cpc.azure.vhd"
$normalizedVhdPath = Join-Path $vhdPath "livecd.ubuntu-cpc.azure.nonsparse.vhd"
$baseUrl = "https://cloud-images.ubuntu.com/jammy/current"
$downloadUrl = "$baseUrl/jammy-server-cloudimg-amd64-azure.vhd.tar.gz"
$checksumsUrl = "$baseUrl/SHA256SUMS"

Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host " Enterprise Cloud Migration Lab - Hyper-V Guest Provisioning" -ForegroundColor Cyan
Write-Host "==================================================================" -ForegroundColor Cyan
Write-Host "Storage root : $storagePath"
Write-Host "Switch       : $SwitchName"
Write-Host "NAT gateway  : $NatGatewayIP"
Write-Host "SSH key      : $SshPublicKeyPath"
Write-Host "Start all    : $([bool]$StartAll)"

# ---- Download and verify base image ----
if (-not (Test-Path $baseImagePath)) {
    Write-Step "Downloading Ubuntu 22.04 Azure cloud image"
    if (-not (Test-Path $baseTarPath)) {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $baseTarPath -UseBasicParsing
    }
    if (-not (Test-Path $baseTarPath) -or (Get-Item $baseTarPath).Length -lt 100MB) {
        Stop-WithMessage "Ubuntu archive is missing or unexpectedly small. Remove the incomplete archive and rerun."
    }

    Write-Step "Verifying downloaded archive SHA256"
    $checksumText = (Invoke-WebRequest -Uri $checksumsUrl -UseBasicParsing).Content
    $archiveName = [IO.Path]::GetFileName($downloadUrl)
    $escapedName = [regex]::Escape($archiveName)
    $checksumMatch = [regex]::Match($checksumText, "(?m)^([a-fA-F0-9]{64})\s+\*?$escapedName\s*$")
    if (-not $checksumMatch.Success) {
        Stop-WithMessage "Could not find $archiveName in Ubuntu's SHA256SUMS file. The script stopped rather than trusting an unverified download."
    }
    $expectedHash = $checksumMatch.Groups[1].Value.ToLowerInvariant()
    $actualHash = (Get-FileHash -LiteralPath $baseTarPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $expectedHash) {
        Stop-WithMessage "Ubuntu archive SHA256 mismatch. Do not use this archive. Delete it and rerun to download again."
    }
    Write-Ok "Ubuntu archive SHA256 verified."

    Write-Step "Extracting VHD archive"
    $tar = Get-Command tar.exe -ErrorAction SilentlyContinue
    if (-not $tar) { Stop-WithMessage "tar.exe is unavailable. Install a supported Windows version or extract the archive manually." }
    $tarEntries = & $tar.Source -tzf $baseTarPath
    if ($LASTEXITCODE -ne 0) { Stop-WithMessage "Could not list the Ubuntu archive. The archive may be corrupt." }
    $vhdEntry = @($tarEntries | Where-Object { $_ -match '\.vhd$' } | Select-Object -First 1)
    if ($vhdEntry.Count -eq 0) { Stop-WithMessage "No .vhd file was found in the Ubuntu archive." }
    & $tar.Source -xzf $baseTarPath -C $vhdPath
    if ($LASTEXITCODE -ne 0) { Stop-WithMessage "Ubuntu archive extraction failed." }

    if (-not (Test-Path $rawVhdPath)) {
        $extracted = Get-ChildItem -LiteralPath $vhdPath -Filter "*.vhd" -File |
            Where-Object { $_.Name -eq [IO.Path]::GetFileName($vhdEntry[0]) } |
            Select-Object -First 1
        if (-not $extracted) {
            Stop-WithMessage "Expected VHD '$($vhdEntry[0])' was not found after extraction. Inspect $vhdPath before rerunning."
        }
        $rawVhdPath = $extracted.FullName
    }

    Write-Step "Creating a normal (non-sparse) copy of the extracted VHD"
    New-NonSparseCopy -Source $rawVhdPath -Destination $normalizedVhdPath

    Write-Step "Converting normalized VHD to dynamic VHDX"
    Convert-VHD -Path $normalizedVhdPath -DestinationPath $baseImagePath -VHDType Dynamic
    if (-not (Test-Path $baseImagePath)) { Stop-WithMessage "Convert-VHD did not create the expected VHDX." }

    # Remove only temporary download/extraction files after successful conversion.
    Remove-Item $baseTarPath, $rawVhdPath, $normalizedVhdPath -Force -ErrorAction SilentlyContinue
    Write-Ok "Base VHDX created: $baseImagePath"
} else {
    $baseVhd = Get-VHD -Path $baseImagePath
    if ($baseVhd.VhdFormat -ne "VHDX") {
        Stop-WithMessage "Existing base image is not VHDX: $baseImagePath. Move it aside and rerun."
    }
    Write-Ok "Existing base image found: $baseImagePath"
}

# ---- Validate/create internal switch and NAT ----
Write-Step "Validating internal switch and NAT"
$existingSwitch = Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue
if ($existingSwitch) {
    if ($existingSwitch.SwitchType.ToString() -ne "Internal") {
        Stop-WithMessage "Switch '$SwitchName' exists but is not Internal. This script will not modify it."
    }
} else {
    New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
    Start-Sleep -Seconds 2
}
Write-Ok "Internal switch is ready."

$adapterAlias = "vEthernet ($SwitchName)"
$adapter = Get-NetAdapter -Name $adapterAlias -ErrorAction SilentlyContinue
if (-not $adapter) {
    Start-Sleep -Seconds 2
    $adapter = Get-NetAdapter -Name $adapterAlias -ErrorAction SilentlyContinue
}
if (-not $adapter) { Stop-WithMessage "Could not find host adapter '$adapterAlias' for the internal switch." }

$existingGateway = Get-NetIPAddress -InterfaceAlias $adapterAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -eq $NatGatewayIP } | Select-Object -First 1
$otherAddresses = @(Get-NetIPAddress -InterfaceAlias $adapterAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -ne $NatGatewayIP -and $_.IPAddress -notlike "169.254.*" })
if ($otherAddresses.Count -gt 0 -and -not $existingGateway) {
    Stop-WithMessage "Host adapter '$adapterAlias' already has another IPv4 address. Inspect it manually before adding $NatGatewayIP."
}
if (-not $existingGateway) {
    New-NetIPAddress -InterfaceAlias $adapterAlias -IPAddress $NatGatewayIP -PrefixLength 24 | Out-Null
}
Write-Ok "Host gateway IP is configured."

$nat = Get-NetNat -Name $NatName -ErrorAction SilentlyContinue
if ($nat) {
    if ($nat.InternalIPInterfaceAddressPrefix -ne $GuestSubnet) {
        Stop-WithMessage "NAT '$NatName' already exists with prefix '$($nat.InternalIPInterfaceAddressPrefix)', not '$GuestSubnet'."
    }
} else {
    $allNats = @(Get-NetNat -ErrorAction SilentlyContinue)
    if ($allNats.Count -gt 0) {
        $samePrefix = $allNats | Where-Object { $_.InternalIPInterfaceAddressPrefix -eq $GuestSubnet }
        if ($samePrefix) {
            Stop-WithMessage "A NAT for $GuestSubnet already exists under another name. Inspect Get-NetNat and update NatName rather than creating a duplicate."
        }
        Stop-WithMessage "Other Windows NAT instance(s) already exist. To avoid disrupting host networking, inspect Get-NetNat and resolve the conflict before continuing."
    }
    New-NetNat -Name $NatName -InternalIPInterfaceAddressPrefix $GuestSubnet | Out-Null
}
Write-Ok "Windows NAT is ready."

# ---- VM fleet ----
$Fleet = @(
    @{ Name = "DC01";   RAM = 3GB; CPU = 2; IP = "192.168.10.10"; Role = "Samba AD DS and DNS" },
    @{ Name = "APP01";  RAM = 2GB; CPU = 1; IP = "192.168.10.20"; Role = "StreamFlix React and Node.js" },
    @{ Name = "DB01";   RAM = 3GB; CPU = 2; IP = "192.168.10.30"; Role = "PostgreSQL" },
    @{ Name = "FILE01"; RAM = 2GB; CPU = 1; IP = "192.168.10.40"; Role = "Samba media and file storage" }
)

$hostMemoryGB = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
Write-Host "`nHost physical RAM: $hostMemoryGB GB" -ForegroundColor Yellow
Write-Host "The guest fleet has 10 GB of configured startup RAM. The script starts DC01 only unless -StartAll is supplied." -ForegroundColor Yellow

foreach ($vm in $Fleet) {
    $vmName = $vm.Name
    $diffDisk = Join-Path $vhdPath "$vmName-OS.vhdx"
    $cidataIso = Join-Path $vhdPath "$vmName-cidata.iso"

    $existingVM = Get-VM -Name $vmName -ErrorAction SilentlyContinue
    if ($existingVM) {
        Write-Host "[SKIP] $vmName already exists; leaving it unchanged." -ForegroundColor Yellow
        continue
    }

    Write-Step "Provisioning $vmName ($($vm.Role)) - $($vm.IP)"
    New-CloudInitISO -ISOPath $cidataIso -Hostname $vmName -IPAddress $vm.IP `
        -Gateway $NatGatewayIP -Username $DefaultUser -PublicKey $publicKey

    # If an earlier run stopped before creating the VM, clean up only this orphaned disk.
    if (Test-Path $diffDisk) { Remove-Item $diffDisk -Force }
    New-VHD -ParentPath $baseImagePath -Path $diffDisk -Differencing | Out-Null

    try {
        New-VM -Name $vmName -Generation 2 -MemoryStartupBytes $vm.RAM `
            -VHDPath $diffDisk -SwitchName $SwitchName -Path $vmPath | Out-Null
        Set-VMProcessor -VMName $vmName -Count $vm.CPU
        Set-VMMemory -VMName $vmName -DynamicMemoryEnabled $true `
            -MinimumBytes 1GB -MaximumBytes $vm.RAM
        Set-VMFirmware -VMName $vmName -EnableSecureBoot On `
            -SecureBootTemplate "MicrosoftUEFICertificateAuthority"
        Add-VMDvdDrive -VMName $vmName -Path $cidataIso | Out-Null
        Set-VM -Name $vmName -AutomaticStartAction StartIfRunning
        Write-Ok "$vmName created."
    } catch {
        Write-Error "Failed while configuring $vmName. Inspect Get-VM and the disk files before rerunning. Details: $_"
        throw
    }
}

# ---- Start conservatively ----
Write-Step "Starting guest VM(s)"
if ($StartAll) {
    foreach ($vm in $Fleet) {
        $current = Get-VM -Name $vm.Name -ErrorAction SilentlyContinue
        if ($current -and $current.State -ne "Running") {
            Start-VM -Name $vm.Name | Out-Null
            Write-Ok "$($vm.Name) started."
        }
    }
} else {
    $dc = Get-VM -Name "DC01" -ErrorAction SilentlyContinue
    if ($dc -and $dc.State -ne "Running") {
        Start-VM -Name "DC01" | Out-Null
        Write-Ok "DC01 started. Other guests were created but not started."
    } elseif ($dc) {
        Write-Ok "DC01 is already running."
    }
}

Write-Step "Fleet status"
Get-VM -Name @($Fleet | ForEach-Object { $_.Name }) -ErrorAction SilentlyContinue |
    Select-Object Name, State, CPUUsage, MemoryAssigned, Uptime |
    Format-Table -AutoSize

Write-Host "`nNext steps:" -ForegroundColor Yellow
Write-Host "  1. Wait 2-3 minutes for DC01's first cloud-init boot."
Write-Host "  2. Check VM console or use SSH from a machine with a route to 192.168.10.0/24."
Write-Host "  3. From the Hyper-V host, guest IPs are not automatically reachable just because NAT exists."
Write-Host "  4. Keep the base VHDX in place; the guest disks are differencing disks."
Write-Host "  5. No SSH/RDP/PostgreSQL/SMB ports have been exposed publicly."
