# Enterprise Cloud Migration Lab — Stages 6 through 9 Runbook

This runbook guides you step by step through configuring, deploying, and validating the simulated on-premises datacenter workloads across the 4 Hyper-V guest VMs.

---

## 1. Architecture & IP Allocation

| Hostname | IP Address | OS | Services / Roles | Orchestration Script |
|---|---|---|---|---|
| **`DC01`** | `192.168.10.10` | Ubuntu 22.04 LTS | Samba Active Directory (`CORP.STREAMFLIX.LAB`) & DNS | `configure-dc01.sh` |
| **`DB01`** | `192.168.10.30` | Ubuntu 22.04 LTS | PostgreSQL 14+ Database Engine (`streamflix_db`) | `configure-db01.sh` |
| **`FILE01`** | `192.168.10.40` | Ubuntu 22.04 LTS | Samba Media Storage Share (`/srv/media`) & MP4 assets | `configure-file01.sh` |
| **`APP01`** | `192.168.10.20` | Ubuntu 22.04 LTS | React Frontend, Express API (`:5000`), Nginx Proxy (`:80`) | `configure-app01.sh` |

* **Default Credentials for all VMs**:
  * Username: `labadmin`
  * Password: `LabAdmin2026!#`
* **Domain Realm**: `CORP.STREAMFLIX.LAB` (NetBIOS: `STREAMFLIX`)

---

## 2. Fast-Track Execution (Tomorrow's 1-Click Run)

Log in to `HV01` via **Azure Bastion** (or RDP), open an **Administrator PowerShell** window, and run:

```powershell
# 1. Pull the latest prepared scripts
cd C:\Lab
git pull origin main

# 2. Run the Master Guest Fleet Orchestrator
cd C:\Lab\stage-1\scripts
.\Deploy-AllGuests.ps1
```

`Deploy-AllGuests.ps1` automatically executes in dependency order:
1. Configures **`DC01`** (Samba Active Directory Domain Controller and DNS).
2. Configures **`DB01`** (PostgreSQL, users, schema, and sample movies).
3. Configures **`FILE01`** (Samba share, MP4 video streams, SVG posters).
4. Configures **`APP01`** (CIFS media mount, Express API service, React UI, Nginx).
5. Prints the live service health dashboard.

---

## 3. Individual Step-by-Step Execution (Alternative)

If you prefer deploying one server at a time to observe and test each stage:

### Step 3.1: Deploy DC01 (Identity & DNS)
```powershell
cd C:\Lab\stage-1\scripts
.\Deploy-AllGuests.ps1 -TargetVM "DC01"
```
*Validation on DC01*:
```bash
ssh labadmin@192.168.10.10
sudo samba-tool domain info 127.0.0.1
klist
```

### Step 3.2: Deploy DB01 (PostgreSQL Database)
```powershell
.\Deploy-AllGuests.ps1 -TargetVM "DB01"
```
*Validation on DB01*:
```bash
ssh labadmin@192.168.10.30
PGPASSWORD="StreamFlixPass2026!" psql -h 127.0.0.1 -U streamflix_user -d streamflix_db -c "SELECT * FROM movies;"
```

### Step 3.3: Deploy FILE01 (Media & File Storage)
```powershell
.\Deploy-AllGuests.ps1 -TargetVM "FILE01"
```
*Validation on FILE01*:
```bash
ssh labadmin@192.168.10.40
smbclient -L localhost -N
ls -la /srv/media/videos/
```

### Step 3.4: Deploy APP01 (StreamFlix Application)
```powershell
.\Deploy-AllGuests.ps1 -TargetVM "APP01"
```
*Validation on APP01*:
```bash
ssh labadmin@192.168.10.20
curl -s http://127.0.0.1:5000/api/health
curl -s http://127.0.0.1/api/movies
```

---

## 4. Phase 9: Verification & Health Audit

Run the automated health auditing suite from `HV01`:

```powershell
cd C:\Lab\stage-1\scripts
.\Test-LabHealth.ps1
```

### Viewing the Application
Open Edge or Chrome inside the Bastion session on `HV01`:
```text
http://192.168.10.20
```
* Click **Stream Video** on any title to test HTML5 video playback and HTTP 206 Partial Content range requests streaming from `FILE01` through Nginx.
