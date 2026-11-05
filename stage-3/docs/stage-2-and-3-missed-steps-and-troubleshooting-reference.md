# Enterprise Cloud Migration Reference: Stage 2 & Stage 3 Critical Configurations, Missed Steps, and Troubleshooting Guide

**Document ID**: REF-STAGE2-STAGE3-TROUBLESHOOTING-20261105  
**Target Audience**: Cloud Migration Engineers, Solutions Architects, DevOps/Site Reliability Engineers  
**Project**: Enterprise Cloud Migration Lab (StreamFlix Application Suite)  
**Scope**: Site-to-Site VPN Interconnect, Linux KVM/Libvirt Virtual Bridge Firewalls, AWS DMS Replication Endpoints, PostgreSQL 16 Logical Replication & Security Controls  
**Purpose**: Comprehensive reference and future blueprint detailing the root causes, symptoms, and step-by-step solutions for every issue encountered across Stage 2 and Stage 3.

---

## 1. Quick Reference Matrix (Missed Steps vs. Resulting Errors)

| Phase & Step | Configuration Missed | Resulting Error / Symptom | Root Cause / Underlying Mechanism | Permanent Solution |
| :--- | :--- | :--- | :--- | :--- |
| **Stage 2: Step 1.4** | AWS VPC Route Table missing route to on-prem | Source Endpoint Test: `timeout expired / Read timed out` | Route table for the DMS replication subnet lacked a route for `10.10.0.0/16` targeting `vgw`. Packets were dropped inside AWS. | Injected static route `10.10.0.0/16` -> `vgw` on all private and database route tables. |
| **Stage 2: Step 2.3** | StrongSwan ESP proposal lacked Diffie-Hellman PFS | `NO_PROPOSAL_CHOSEN notify, no CHILD_SA built` | StrongSwan established IKE_SA (Phase 1), but AWS VPN required DH Group 14 (`modp2048`) for ESP (Phase 2). No encryption tunnel installed. | Added `aes256-sha256-modp2048` to `esp=` parameter in `/etc/ipsec.conf`. |
| **Stage 2: Step 2.5** | KVM Libvirt firewall blocking external traffic to VMs | Source Endpoint Test: `timeout expired / Read timed out` | Libvirt installs a default `-o virbr10 -j REJECT` rule that drops all new incoming connections arriving from external interfaces to guest VMs. | Added `iptables -I FORWARD 1 -d 10.10.10.0/24 -o virbr10 -j ACCEPT` and NAT bypass. |
| **Stage 3: Step 1.3** | PostgreSQL bound only to `localhost` | `psql: error: connection to server on socket ... failed` | Default Ubuntu PostgreSQL configuration sets `listen_addresses = 'localhost'`, dropping all non-local connections on `10.10.10.30:5432`. | Set `listen_addresses = '*'` in `/etc/postgresql/16/main/postgresql.conf`. |
| **Stage 3: Step 1.4** | `pg_hba.conf` specified `md5` instead of `scram-sha-256` | Source Endpoint Test: `FATAL: password authentication failed for user "streamflix_user"` | PostgreSQL 16 hashes passwords with SCRAM-SHA-256. When a client matches an `md5` rule, PostgreSQL cannot verify the password against a SCRAM hash. | Set `host all all 10.20.0.0/16 scram-sha-256` in `/etc/postgresql/16/main/pg_hba.conf`. |
| **Stage 3: Step 1.5** | `streamflix_user` lacked `SUPERUSER` privilege | DMS Replication Task: `Stream Component Fatal error` (`ddl_create_db_artifact failed`) | AWS DMS CDC installs an event trigger (`awsdms_intercept_ddl`) to capture DDL changes. PostgreSQL restricts event triggers exclusively to superusers. | Granted `ALTER USER streamflix_user WITH SUPERUSER;` on `DB01`. |
| **Stage 3: Step 3.2** | Target DMS Endpoint SSL mode set to `none` | Target Endpoint Test: `no pg_hba.conf entry ... no encryption` | Amazon RDS PostgreSQL enforces TLS/SSL encryption by default. Unencrypted connection attempts are rejected by RDS `pg_hba.conf`. | Modified target endpoint in AWS DMS to use `--ssl-mode require`. |
| **Stage 3: Step 4.1** | Premigration Assessment checkbox enabled in UI | Console Wizard: `Migration task cannot start automatically on create...` | AWS Console enables premigration assessment by default, which disables automatic task startup until an S3 bucket and IAM role are provided. | Unchecked **"Turn on premigration assessment"** in the AWS Console wizard. |

---

## 2. Deep Dive: AWS Network & Routing Failures

### Issue 2.1: Missing Static Route in AWS Route Tables (Stage 2 Step 1.4)
* **The Architecture**: AWS DMS replication instances live inside a private subnet (e.g. `streamflix-target-app-private-1b`, IP `10.20.11.112`).
* **The Problem**: When AWS DMS sends traffic to on-premises IP `10.10.10.30`, it inspects the VPC route table associated with its subnet (`rtb-04bf1704f096ed647`). If route propagation is disabled or static routes are not populated, the route table only knows `10.20.0.0/16 -> local`. The packets to `10.10.10.30` have no next hop and are immediately blackholed.
* **How to Fix**:
  ```bash
  aws ec2 create-route \
    --route-table-id rtb-04bf1704f096ed647 \
    --destination-cidr-block 10.10.0.0/16 \
    --gateway-id vgw-07ecf815eb50f71c3
  ```
  *(Repeat for all route tables where resources need to communicate with on-premises).*

---

### Issue 2.2: StrongSwan ESP Proposal Mismatch (Stage 2 Step 2.3)
* **The Architecture**: StrongSwan on `HV01` negotiates two separate cryptographic associations with the AWS Virtual Private Gateway:
  1. **Phase 1 (IKE_SA)**: Authenticates the endpoints and sets up the control channel.
  2. **Phase 2 (CHILD_SA)**: Encrypts the actual data traffic using Encapsulating Security Payload (ESP).
* **The Problem**: In AWS Site-to-Site VPN, AWS endpoints enforce **Perfect Forward Secrecy (PFS)** on Phase 2, typically Diffie-Hellman Group 14 (`modp2048`) or Group 2 (`modp1024`). If `/etc/ipsec.conf` specifies only cipher algorithms without DH groups (e.g. `esp=aes256gcm16-sha256,aes256-sha256!`), Phase 1 succeeds (`ESTABLISHED`), but Phase 2 fails with:
  ```text
  parsed CREATE_CHILD_SA response 55 [ N(NO_PROP) ]
  received NO_PROPOSAL_CHOSEN notify, no CHILD_SA built
  ```
  Without a `CHILD_SA`, the Linux kernel installs no IPsec Security Policies (SPD/SAD), and zero packets are encrypted.
* **How to Fix**:
  Update `/etc/ipsec.conf` on `HV01`:
  ```ini
  conn aws-tunnel-1
      ...
      ike=aes256gcm16-sha256-modp2048,aes256-sha256-modp2048,aes128-sha1-modp1024!
      esp=aes256gcm16-sha256,aes256-sha256-modp2048,aes256-sha256,aes128-sha1-modp1024,aes128-sha1!
      auto=start
  ```
  Verify with `sudo ipsec statusall` that output displays:
  ```text
  aws-tunnel-1{1}:  INSTALLED, TUNNEL, reqid 1, ESP in UDP
  aws-tunnel-1{1}:   10.10.0.0/16 === 10.20.0.0/16
  ```

---

### Issue 2.3: KVM / Libvirt Virtual Bridge Isolation (Stage 2 Step 2.5)
* **The Architecture**: `HV01` acts as both the VPN endpoint (terminating IPsec on `eth0`) and the KVM Hypervisor hosting `DB01` on internal virtual bridge `virbr10` (`10.10.10.0/24`).
* **The Problem**: By default, `libvirt` configures Linux `iptables` to isolate guest virtual machines from unsolicited external traffic:
  `-A FORWARD -o virbr10 -j REJECT --reject-with icmp-port-unreachable`
  `-A POSTROUTING -s 10.10.10.0/24 ! -d 10.10.10.0/24 -p tcp -j MASQUERADE`
  1. When AWS DMS sends a packet to `10.10.10.30`, `HV01` decapsulates the IPsec packet and attempts to forward it into `virbr10`. The packet hits the `REJECT` rule and is dropped.
  2. When `DB01` replies, libvirt masquerades the source IP to `HV01`'s host IP (`10.10.1.10`), breaking the stateful connection.
* **How to Fix**:
  Execute on `HV01`:
  ```bash
  # 1. Enable kernel packet forwarding
  sudo sysctl -w net.ipv4.ip_forward=1

  # 2. Allow incoming traffic from AWS VPC into virbr10
  sudo iptables -I FORWARD 1 -d 10.10.10.0/24 -o virbr10 -j ACCEPT

  # 3. Allow return traffic from virbr10 back to AWS VPC
  sudo iptables -I FORWARD 1 -s 10.10.10.0/24 -i virbr10 -j ACCEPT

  # 4. Bypass NAT masquerade so original IP (10.10.10.30) is preserved across the VPN
  sudo iptables -t nat -I POSTROUTING 1 -s 10.10.10.0/24 -d 10.20.0.0/16 -j ACCEPT
  ```

---

## 3. Deep Dive: PostgreSQL & Database Engine Failures

### Issue 3.1: PostgreSQL Localhost Binding (Stage 3 Step 1.3)
* **The Problem**: PostgreSQL defaults to `listen_addresses = 'localhost'`. It creates a listening socket only on `127.0.0.1:5432`, rejecting connections on `10.10.10.30:5432`.
* **How to Fix**:
  Inside **`DB01`**:
  ```bash
  sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/16/main/postgresql.conf
  sudo sed -i "s/listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/16/main/postgresql.conf
  sudo systemctl restart postgresql
  sudo ss -tulpn | grep 5432
  ```
  *Verification*: Output must show `0.0.0.0:5432` or `*:5432`.

---

### Issue 3.2: Authentication Protocol Mismatch: SCRAM-SHA-256 vs. MD5 (Stage 3 Step 1.4)
* **The Problem**: PostgreSQL 16 generates passwords using the secure `SCRAM-SHA-256` hashing mechanism. If `/etc/postgresql/16/main/pg_hba.conf` specifies `md5`:
  `host all all 10.20.0.0/16 md5`
  When AWS DMS connects, PostgreSQL offers an MD5 challenge. Because the password hash in `pg_shadow` is stored as `SCRAM-SHA-256$...`, PostgreSQL cannot perform an MD5 verification, resulting in:
  `FATAL: password authentication failed for user "streamflix_user"`
* **How to Fix**:
  Inside **`DB01`**, configure `pg_hba.conf` with matching authentication:
  ```text
  host    all             all             10.20.0.0/16            scram-sha-256
  host    replication     all             10.20.0.0/16            scram-sha-256
  ```
  Reload PostgreSQL:
  ```bash
  sudo systemctl reload postgresql
  ```

---

### Issue 3.3: Superuser Privilege Required for CDC Event Triggers (Stage 3 Step 1.5)
* **The Problem**: A standard user with `REPLICATION` role can stream Write-Ahead Logs (WAL). However, AWS DMS continuous CDC also captures Data Definition Language (DDL) changes (`CREATE TABLE`, `ALTER TABLE`, `DROP TABLE`). To capture DDL, AWS DMS executes:
  ```sql
  CREATE EVENT TRIGGER awsdms_intercept_ddl ON ddl_command_end EXECUTE PROCEDURE public.awsdms_intercept_ddl();
  ```
  PostgreSQL engine security strictly mandates that **only superusers can create event triggers**. Because `streamflix_user` was not a superuser, the replication task crashed during initialization:
  ```text
  [SOURCE_CAPTURE] E: ddl_artifact_execute_statement(...) failed in executing statement 'CREATE EVENT TRIGGER awsdms_intercept_ddl...'
  [TASK_MANAGER] E: Stream component failed ... Fatal error
  ```
* **How to Fix**:
  Inside **`DB01`**:
  ```bash
  sudo -u postgres psql -c "ALTER USER streamflix_user WITH SUPERUSER;"
  ```

---

### Issue 3.4: Outbound Routing on Multi-Homed VM (`DB01`)
* **The Problem**: In a Vagrant/KVM environment, guest VMs typically have two network interfaces:
  * `eth0`: Vagrant management NAT network (`192.168.121.x`) with default gateway `192.168.121.1`.
  * `eth1`: Lab private network (`10.10.10.30/24`) attached to `virbr10`.
  When AWS DMS connects inbound to `DB01`, the connection succeeds because the packet arrives on `eth1` and connection tracking routes replies back to `eth1`.
  However, when running an outbound query from `DB01` to Amazon RDS (e.g. `psql -h streamflix-target-db`), `DB01` consults its routing table and sends the packet out `eth0` via the default gateway `192.168.121.1` instead of `eth1`. The packet leaves with source IP `192.168.121.x` (which is not encrypted by StrongSwan), causing connection timeouts.
* **How to Fix**:
  Inside **`DB01`**, add a permanent static route directing AWS VPC traffic to `virbr10` (`10.10.10.1`):
  ```bash
  sudo ip route add 10.20.0.0/16 via 10.10.10.1 dev eth1
  ```

---

## 4. Deep Dive: AWS DMS & RDS Configuration Failures

### Issue 4.1: Amazon RDS Enforced SSL / TLS Mode (Stage 3 Step 3.2)
* **The Problem**: Amazon RDS PostgreSQL instances enforce encrypted transit (`hostssl`) by default (`rds.force_ssl = 1`). When the target endpoint was created with default settings (`SslMode: none`), connections were made without encryption, resulting in:
  `FATAL: no pg_hba.conf entry for host "10.20.11.112", user "postgres", database "streamflix_db", no encryption`
* **How to Fix**:
  Modify the target endpoint to enforce SSL encryption:
  ```bash
  aws dms modify-endpoint \
    --endpoint-arn <TARGET_ENDPOINT_ARN> \
    --ssl-mode require
  ```

---

### Issue 4.2: Premigration Assessment Blocking Automatic Startup (Stage 3 Step 4.1)
* **The Problem**: In the AWS Management Console, the **"Turn on premigration assessment"** checkbox is enabled by default. When checked, AWS DMS assumes an assessment must be executed and stored in an S3 bucket before the task is allowed to run, disabling the **"Automatically on create"** radio button and forcing **"Manually later"**.
* **How to Fix**:
  * In the AWS Console wizard: Scroll to **Premigration assessment** $\to$ **Uncheck** the box.
  * Once unchecked, the **"Automatically on create"** radio button immediately becomes active.

---

## 5. Master Remediation Runbook (Copy-Paste Ready)

If you rebuild this environment or deploy a similar migration in the future, run these two consolidated scripts to ensure 100% first-time success:

### Script A: Execute on Hypervisor (`HV01`)
```bash
#!/usr/bin/env bash
set -e

# 1. Enable Linux kernel IP forwarding
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward = 1" | sudo tee -a /etc/sysctl.d/99-ipforward.conf

# 2. Allow KVM Bridge Forwarding for AWS Target VPC
sudo iptables -I FORWARD 1 -d 10.10.10.0/24 -o virbr10 -j ACCEPT
sudo iptables -I FORWARD 1 -s 10.10.10.0/24 -i virbr10 -j ACCEPT
sudo iptables -t nat -I POSTROUTING 1 -s 10.10.10.0/24 -d 10.20.0.0/16 -j ACCEPT

# 3. Configure StrongSwan with AWS-compatible Diffie-Hellman proposals
sudo sed -i 's/esp=.*/esp=aes256gcm16-sha256,aes256-sha256-modp2048,aes256-sha256,aes128-sha1-modp1024,aes128-sha1!/' /etc/ipsec.conf
sudo systemctl restart strongswan-starter

echo "[SUCCESS] HV01 network forwarding, firewall, and StrongSwan configured."
```

---

### Script B: Execute on Database Server (`DB01`)
```bash
#!/usr/bin/env bash
set -e

# 1. Add static route for AWS Target VPC via KVM bridge gateway
sudo ip route add 10.20.0.0/16 via 10.10.10.1 dev eth1 2>/dev/null || sudo ip route replace 10.20.0.0/16 via 10.10.10.1 dev eth1

# 2. Configure PostgreSQL to listen externally on port 5432
sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/16/main/postgresql.conf
sudo sed -i "s/listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/16/main/postgresql.conf

# 3. Enable logical replication for AWS DMS CDC
sudo tee -a /etc/postgresql/16/main/postgresql.conf << 'EOF'
wal_level = logical
max_replication_slots = 5
max_wal_senders = 5
EOF

# 4. Allow AWS Target VPC in pg_hba.conf using SCRAM-SHA-256
sudo tee -a /etc/postgresql/16/main/pg_hba.conf << 'EOF'
host    all             all             10.20.0.0/16            scram-sha-256
host    replication     all             10.20.0.0/16            scram-sha-256
EOF

# 5. Restart PostgreSQL
sudo systemctl restart postgresql

# 6. Grant Superuser and Replication roles to the DMS user
sudo -u postgres psql -c "ALTER USER streamflix_user WITH SUPERUSER;"
sudo -u postgres psql -c "ALTER USER streamflix_user WITH REPLICATION;"
sudo -u postgres psql -c "ALTER USER streamflix_user WITH PASSWORD 'StreamFlixPass2026!';"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO streamflix_user;"

echo "[SUCCESS] DB01 PostgreSQL and routing configured for AWS DMS."
```

---

### Script C: Execute via AWS CLI (Endpoints & Routing)
```bash
# 1. Add static route to VPC Route Tables
aws ec2 create-route --route-table-id <APP_PRIVATE_RT_ID> --destination-cidr-block 10.10.0.0/16 --gateway-id <VGW_ID>
aws ec2 create-route --route-table-id <DB_ISOLATED_RT_ID> --destination-cidr-block 10.10.0.0/16 --gateway-id <VGW_ID>

# 2. Ensure RDS Target Endpoint has SSL enforced
aws dms modify-endpoint --endpoint-arn <TARGET_ENDPOINT_ARN> --ssl-mode require

# 3. Test both endpoints
aws dms test-connection --endpoint-arn <SOURCE_ENDPOINT_ARN> --replication-instance-arn <REP_INSTANCE_ARN>
aws dms test-connection --endpoint-arn <TARGET_ENDPOINT_ARN> --replication-instance-arn <REP_INSTANCE_ARN>
```
