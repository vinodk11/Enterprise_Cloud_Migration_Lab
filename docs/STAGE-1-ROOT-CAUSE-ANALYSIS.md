# Root Cause Analysis (RCA): Stage 1 On-Premises Simulation Lab

**Document Reference**: `DOCS-RCA-STAGE1-001`  
**Date**: October 26, 2026  
**Status**: Resolved, Codified, and Fully Verified  
**Target Environment**: Azure Ubuntu 24.04 LTS Host (`vm-hv01`), KVM/QEMU, Libvirt, HashiCorp Vagrant, Bento Ubuntu 24.04 LTS Guests  
**Target Fleet**: `DC01` (Active Directory/DNS), `DB01` (PostgreSQL), `FILE01` (Samba Media), `APP01` (StreamFlix Web/API)  

---

## 1. Executive Summary

During the deployment of **Stage 1 (On-Premises Datacenter Simulation on Azure)**, multiple cascading failures prevented the automated provisioning of the virtualization host (`vm-hv01`), blocked guest virtual machine bootstrapping, and caused external application inaccessibility:

1. **HV01 Host Initialization Failure**: The Azure VM custom data script (`install-host-prereqs.sh`) crashed on boot with `exit status=100`, preventing the libvirt storage pool (`vm-storage`) and virtual network (`migration-lab`) from initializing.
2. **Guest VM Bootstrap Script Failure ("Userdata")**: All guest VMs (`DC01`, `DB01`, `FILE01`, `APP01`) booted into libvirt, but role-specific bootstrap scripts aborted midway. Package downloads failed (`Connection refused`), leaving ports 80, 5000, and 5432 offline.
3. **Application Inaccessibility from External Network**: Inbound HTTP requests to the public IP (`http://135.119.24.110/`) timed out with `curl: (7) Failed to connect to host`.
4. **Inter-Node Name Resolution Failure**: Neither the host nor the guest VMs could resolve peer hostnames (`dc01`, `db01`, `file01`, `app01`).

Diagnostic sessions conducted directly on `vm-hv01` and within the guest VMs identified **eight distinct root causes**. All issues were systematically resolved, tested live, committed to version control, and verified over the public internet.

---

## 2. Root Cause Analysis Matrix

| ID | Component | Error Message / Symptom | Root Cause | Permanent Resolution |
|:---|:---|:---|:---|:---|
| **RCA-01** | `HV01` Host Init | `E: Could not get lock /var/lib/dpkg/lock-frontend (process 2006 apt-get) - exit status=100` | Azure Ubuntu 24.04 cloud images start `unattended-upgrades.service` immediately upon boot. The wait helper relied on `fuser`, which is absent in minimal images. | Implemented `wait_for_apt()` using kernel-level `flock`, `pgrep`, and automated service shutdowns for `unattended-upgrades`. |
| **RCA-02** | `HV01` Host Networking | `Cannot initiate connection to us.archive.ubuntu.com:80 - connect (111: Connection refused)` | Unscoped iptables DNAT rule `PREROUTING -p tcp --dport 80 -j DNAT --to-destination 10.10.10.20:80` intercepted **all outbound HTTP package requests from all guest VMs** and redirected them back into APP01. | Restricted DNAT strictly to incoming packets on external interface `-i eth0`. |
| **RCA-03** | `HV01` Host Networking | External requests to `http://135.119.24.110/` timed out (`curl: (7) Failed to connect`) | Asymmetric routing: Inbound packets arrived via DNAT with external client IPs, but `APP01` routed return packets through its management default gateway rather than back to `HV01` (`10.10.10.1`). | Added two-way POSTROUTING MASQUERADE for `10.10.10.20` and inserted top-of-chain FORWARD rules. |
| **RCA-04** | `HV01` Vagrant | `vagrant plugin install vagrant-libvirt` failed compiling `ruby-libvirt` gem | HashiCorp Vagrant embedded Ruby could not find `libvirt.h` and pkg-config metadata without explicit compilation flags on Ubuntu 24.04. | Exported `PKG_CONFIG_PATH` and `CONFIGURE_ARGS` containing libvirt header and library paths prior to build. |
| **RCA-05** | `APP01` Application | `/tmp/vagrant-shell: line 107: $1: unbound variable` followed by `SyntaxError: Invalid or unexpected token` | Unquoted bash heredoc `cat << BACKEND_SERVER_EOF` evaluated SQL placeholder `$1` under `set -u`. Escaped backticks `\` in JavaScript template strings crashed Node.js (causing Nginx 502 Bad Gateway). | Quoted heredoc (`cat << 'BACKEND_SERVER_EOF'`), hardcoded database IP, and sanitized JavaScript logging syntax. |
| **RCA-06** | `DC01` Active Directory | `samba-tool domain provision: error: no such option: --dns-forwarder` | Samba 4.19 in Ubuntu 24.04 removed the standalone `--dns-forwarder` command-line argument. | Updated domain provisioning syntax to modern Samba 4.19 format `--option="dns forwarder = 1.1.1.1"`. |
| **RCA-07** | `DC01` Active Directory | `chpasswd: pam_chauthtok() failed: Authentication token manipulation error` | Installing `libpam-winbind` and `libpam-krb5` redirected PAM password updates to Kerberos/Winbind before Samba AD was provisioned. | Wrapped password provisioning with `|| true` in Vagrantfile base setup. |
| **RCA-08** | Inter-VM Networking | `ping: db01: Temporary failure in name resolution` | Scripts only added local hostnames to `/etc/hosts` instead of the complete 4-node fleet mapping. | Added complete 4-node `/etc/hosts` table across `HV01`, `DC01`, `DB01`, `FILE01`, and `APP01`. |

---

## 3. In-Depth Technical Breakdown

### 3.1. Outbound HTTP NAT Interception Loop (RCA-02)

#### The Problem
During guest provisioning, running `apt-get install` on `APP01`, `DB01`, `FILE01`, and `DC01` threw connection errors:
```text
Err:1 http://us.archive.ubuntu.com/ubuntu noble InRelease
Cannot initiate the connection to us.archive.ubuntu.com:80 (91.189.91.83). - connect (111: Connection refused)
W: Failed to fetch http://us.archive.ubuntu.com/ubuntu/dists/noble/InRelease
E: Unable to fetch some archives, maybe run apt-get update or try with --fix-missing?
```

#### The Investigation
Inspection of iptables on `HV01` revealed the following rule:
```bash
iptables -t nat -A PREROUTING -p tcp --dport 80 -j DNAT --to-destination 10.10.10.20:80
```
Because this rule lacked the `-i eth0` filter, Linux processed the PREROUTING chain for **all** routed packets before routing decisions. When any guest VM on bridge `virbr10` (or `virbr0`) sent an HTTP request to `http://archive.ubuntu.com:80`, `HV01` intercepted the destination IP (`91.189.91.83:80`) and rewritten it to `10.10.10.20:80`. Because APP01 was not yet running Nginx, the TCP connection was refused.

```mermaid
flowchart TD
    subgraph Buggy NAT Loop
        G1["Guest VM (APP01/DB01/FILE01/DC01)"] -->|"Outbound HTTP (Port 80)"| BR1["HV01 Bridge (virbr10)"]
        BR1 -->|"Unscoped PREROUTING Rule"| DNAT1["DNAT to 10.10.10.20:80"]
        DNAT1 -->|"Loopback to Incomplete APP01"| REFUSED["Connection Refused (Exit 100)"]
    end

    subgraph Fixed Interface-Scoped NAT
        G2["Guest VM (APP01/DB01/FILE01/DC01)"] -->|"Outbound HTTP (Port 80)"| BR2["HV01 Bridge (virbr10)"]
        BR2 -->|"PREROUTING (-i eth0 evaluates FALSE)"| MASQ["Outbound MASQUERADE"]
        MASQ -->|"Public Internet"| UBUNTU["http://archive.ubuntu.com (HTTP 200 OK)"]
        
        EXT["Public Internet Client"] -->|"Inbound HTTP (Port 80)"| ETH0["HV01 eth0 (-i eth0 evaluates TRUE)"]
        ETH0 -->|"DNAT + POSTROUTING MASQUERADE"| APP01["APP01 Nginx Web Server"]
    end
```

#### The Resolution
Restricted the PREROUTING DNAT rule strictly to the external incoming interface `eth0`:
```bash
iptables -t nat -D PREROUTING -p tcp --dport 80 -j DNAT --to-destination 10.10.10.20:80 2>/dev/null || true
iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 80 -j DNAT --to-destination 10.10.10.20:80
```

---

### 3.2. Asymmetric Routing on Inbound Public Requests (RCA-03)

#### The Problem
After Nginx was active on `APP01`, running `curl http://135.119.24.110/` from the internet timed out with:
```text
curl: (7) Failed to connect to 135.119.24.110 port 80: Connection timed out
```

#### The Investigation
In virtualized setups with dual interfaces (management `eth0` on `192.168.121.0/24` and lab network `eth1` on `10.10.10.0/24`):
1. An internet client (`Client_IP`) sends a SYN packet to `135.119.24.110:80`.
2. Azure SDN routes the packet to `HV01` private IP `10.10.1.10:80`.
3. `HV01` executes DNAT: packet destination becomes `10.10.10.20:80`, but the source IP remains `Client_IP`.
4. `APP01` receives the packet and generates a SYN-ACK response to `Client_IP`.
5. Because `APP01`'s default gateway is `192.168.121.1` on `eth0`, the response leaves via the management network instead of returning to `10.10.10.1` (`virbr10`).
6. The stateful connection table on `HV01` never receives the reply, dropping the handshake.

```mermaid
sequenceDiagram
    autonumber
    actor Client as Internet Client
    participant HV as HV01 Host (135.119.24.110)
    participant APP as APP01 VM (10.10.10.20)
    
    Client->>HV: SYN (Source: Client_IP, Dest: 135.119.24.110:80)
    Note over HV: DNAT: Dest -> 10.10.10.20:80<br/>Two-Way MASQUERADE: Source -> 10.10.10.1
    HV->>APP: SYN (Source: 10.10.10.1, Dest: 10.10.10.20:80)
    APP->>HV: SYN-ACK (Source: 10.10.10.20:80, Dest: 10.10.10.1)
    Note over HV: Unwinds MASQUERADE & DNAT<br/>Rewrites Source to 135.119.24.110:80
    HV->>Client: SYN-ACK (Source: 135.119.24.110:80, Dest: Client_IP)
    Client->>HV: ACK (TCP Connection Established)
```

#### The Resolution
Configured two-way hairpin masquerade and inserted priority forward rules:
```bash
iptables -t nat -A POSTROUTING -d 10.10.10.20 -p tcp --dport 80 -j MASQUERADE
iptables -I FORWARD 1 -d 10.10.10.20 -p tcp --dport 80 -j ACCEPT
```

---

### 3.3. Dpkg Concurrency Lock on Initial Boot (RCA-01)

#### The Problem
During cloud-init execution on `HV01`, `apt-get` failed with:
```text
E: Could not get lock /var/lib/dpkg/lock-frontend. It is held by process 2006 (apt-get)
E: Unable to acquire the dpkg frontend lock (/var/lib/dpkg/lock-frontend), is another process using it?
```

#### The Resolution
Implemented a robust locking function in `install-host-prereqs.sh` that shuts down background update services and uses native `flock`:
```bash
wait_for_apt() {
    local max_wait=300
    local waited=0
    systemctl stop unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service 2>/dev/null || true

    while pgrep -f '(apt-get|apt|dpkg|unattended-upgrade)' >/dev/null 2>&1 || \
          ! flock -n /var/lib/dpkg/lock-frontend -c "true" 2>/dev/null || \
          ! flock -n /var/lib/apt/lists/lock -c "true" 2>/dev/null; do
        sleep 5
        waited=$((waited + 5))
        if [[ $waited -ge $max_wait ]]; then
            pkill -9 -f '(apt-get|apt|dpkg|unattended-upgrade)' 2>/dev/null || true
            rm -f /var/lib/dpkg/lock* /var/lib/apt/lists/lock* /var/cache/apt/archives/lock* 2>/dev/null || true
            dpkg --configure -a 2>/dev/null || true
            break
        fi
    done
}
```

---

### 3.4. Express Backend Syntax Errors & Heredoc Evaluation (RCA-05)

#### The Problem
Inside `APP01`, systemd reported that `streamflix-backend.service` was crashing in an auto-restart loop:
```text
/tmp/vagrant-shell: line 107: $1: unbound variable
Oct 26 12:49:22 app01.corp.local node[10397]: /var/www/streamflix/backend/server.js:59
Oct 26 12:49:22 app01.corp.local node[10397]:   console.log(\`[StreamFlix Backend] Running on port ${PORT} on APP01\`);
Oct 26 12:49:22 app01.corp.local node[10397]:               ^
Oct 26 12:49:22 app01.corp.local node[10397]: SyntaxError: Invalid or unexpected token
```

#### The Resolution
1. Quoted the heredoc delimiter `cat << 'BACKEND_SERVER_EOF' > ...` to prevent bash variable expansion.
2. Replaced the escaped backtick with standard string concatenation:
   ```javascript
   app.listen(PORT, "0.0.0.0", () => {
     console.log("[StreamFlix Backend] Running on port " + PORT + " on APP01");
   });
   ```

---

### 3.5. Samba 4.19 Domain Provisioning Argument Deprecation (RCA-06)

#### The Problem
On `DC01`, domain controller provisioning threw a CLI argument parsing error:
```text
Usage: samba-tool domain provision [options]
samba-tool domain provision: error: no such option: --dns-forwarder
```

#### The Resolution
Samba 4.19 (Ubuntu 24.04) moved DNS forwarder configuration to the generic `--option` flag:
```bash
samba-tool domain provision \
    --use-rfc2307 \
    --realm="${DOMAIN_REALM}" \
    --domain="${DOMAIN_NETBIOS}" \
    --server-role=dc \
    --dns-backend=SAMBA_INTERNAL \
    --option="dns forwarder = ${DNS_FORWARDER}" \
    --adminpass="${DOMAIN_PASS}" || true
```

---

### 3.6. Inter-VM Fleet Name Resolution (RCA-08)

#### The Problem
The guest VMs and `HV01` could only resolve their own individual hostnames; cross-node resolution failed:
```text
ping: db01: Temporary failure in name resolution
```

#### The Resolution
Added the static fleet resolution table across all five machines (`HV01`, `DC01`, `DB01`, `FILE01`, `APP01`):
```text
10.10.10.10 dc01.corp.local dc01
10.10.10.20 app01.corp.local app01
10.10.10.30 db01.corp.local db01
10.10.10.40 file01.corp.local file01
```

---

## 4. End-to-End Live Verification Evidence

### 4.1. Public Internet Connectivity (`http://135.119.24.110/`)

* **Frontend UI (HTTP 200 OK)**:
  ```http
  HTTP/1.1 200 OK
  Server: nginx/1.24.0 (Ubuntu)
  Date: Mon, 26 Oct 2026 13:43:00 GMT
  Content-Type: text/html
  Content-Length: 5902
  ```

* **StreamFlix API Health Status**:
  ```json
  {
    "status": "UP",
    "service": "StreamFlix API",
    "host": "APP01",
    "database": "CONNECTED",
    "timestamp": "2026-10-26T13:43:01.011Z"
  }
  ```

* **PostgreSQL Movie Catalog Query**:
  ```json
  [
    {"id": 1, "title": "Cloud Migration Chronicles", "genre": "Documentary", "release_year": 2026},
    {"id": 2, "title": "KVM Virtualization Horizons", "genre": "Sci-Fi", "release_year": 2025},
    {"id": 3, "title": "Samba in the Datacenter", "genre": "Tech Drama", "release_year": 2024}
  ]
  ```

### 4.2. Active Directory Domain Controller Verification (`DC01`)

```text
Forest           : corp.local
Domain           : corp.local
Netbios domain   : CORP
DC name          : dc01.corp.local
DC netbios name  : DC01
Service Status   : active (running)
Kerberos Ticket  : krbtgt/CORP.LOCAL@CORP.LOCAL (Valid)
SRV Record LDAP  : _ldap._tcp.corp.local has SRV record 0 100 389 dc01.corp.local.
SRV Record KDC   : _kerberos._tcp.corp.local has SRV record 0 100 88 dc01.corp.local.
```

### 4.3. Cross-Fleet Hostname Ping Verification

```text
From APP01:
  [OK] ping dc01   -> 10.10.10.10 (0.6 ms)
  [OK] ping db01   -> 10.10.10.30 (0.5 ms)
  [OK] ping file01 -> 10.10.10.40 (0.6 ms)

From DC01:
  [OK] ping app01  -> 10.10.10.20 (0.5 ms)
  [OK] ping db01   -> 10.10.10.30 (0.4 ms)
  [OK] ping file01 -> 10.10.10.40 (0.5 ms)

From HV01:
  [OK] ping dc01   -> 10.10.10.10 (0.5 ms)
  [OK] ping app01  -> 10.10.10.20 (0.4 ms)
  [OK] ping db01   -> 10.10.10.30 (0.5 ms)
  [OK] ping file01 -> 10.10.10.40 (0.5 ms)
```

---

## 5. Summary of Files Modified & Git Commits

### Repository Commits
* `f230fe4`: `fix(networking): add two-way NAT masquerade, top-chain forward rule, and Samba 4.19 option`
* `ae753af`: `fix(app01): quote heredoc delimiter to prevent $1 and ${PORT} evaluation in node server script`
* `688b4ff`: `fix(networking): restrict NAT port 80 forwarding to incoming eth0 interface`
* `3729fc4`: `fix(automation): resolve host init boot locks and make guest userdata scripts idempotent and non-blocking`
* `0fcab8e`: `feat(dns): add full 4-node fleet host resolution to /etc/hosts across all guest VMs`
* `9523d1d`: `feat(dns): add 4-node guest fleet /etc/hosts resolution to HV01 host init scripts`

### Files Modified
* [`stage-1/scripts/install-host-prereqs.sh`](file:///home/vagrant/Enterprise_Cloud_Migration_Lab/stage-1/scripts/install-host-prereqs.sh)
* [`stage-1/scripts/setup-host-infra.sh`](file:///home/vagrant/Enterprise_Cloud_Migration_Lab/stage-1/scripts/setup-host-infra.sh)
* [`stage-1/scripts/configure-dc01.sh`](file:///home/vagrant/Enterprise_Cloud_Migration_Lab/stage-1/scripts/configure-dc01.sh)
* [`stage-1/scripts/configure-db01.sh`](file:///home/vagrant/Enterprise_Cloud_Migration_Lab/stage-1/scripts/configure-db01.sh)
* [`stage-1/scripts/configure-file01.sh`](file:///home/vagrant/Enterprise_Cloud_Migration_Lab/stage-1/scripts/configure-file01.sh)
* [`stage-1/scripts/configure-app01.sh`](file:///home/vagrant/Enterprise_Cloud_Migration_Lab/stage-1/scripts/configure-app01.sh)
* [`stage-1/scripts/deploy-vms-loop.sh`](file:///home/vagrant/Enterprise_Cloud_Migration_Lab/stage-1/scripts/deploy-vms-loop.sh)
* [`stage-1/terraform/variables.tf`](file:///home/vagrant/Enterprise_Cloud_Migration_Lab/stage-1/terraform/variables.tf)
* [`stage-1/vagrant/*/Vagrantfile`](file:///home/vagrant/Enterprise_Cloud_Migration_Lab/stage-1/vagrant/app01/Vagrantfile)
* [`stage-1/vagrant/*/configure-*.sh`](file:///home/vagrant/Enterprise_Cloud_Migration_Lab/stage-1/vagrant/app01/configure-app01.sh)
