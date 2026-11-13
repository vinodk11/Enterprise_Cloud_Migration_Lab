# Stage 3: Enterprise Database Migration Manual Runbook — Method B (AWS DMS with Zero-Downtime CDC)
**Document ID**: RUNBOOK-STAGE3-METHOD-B-DMS-CDC-20261113-V2  
**Target Audience**: Cloud Migration Engineers, Database Architects, DevSecOps  
**Lab Context**: Enterprise Cloud Migration Lab (StreamFlix Application Stack)  
**Strategy**: Method B — Full Load + Ongoing Change Data Capture (CDC) via AWS DMS  
**UI Focus**: Dual AWS Management Console (Click-by-Click UI) & AWS CLI / Terminal Automation  
**Hardened Version**: Fully incorporates all lessons learned, missed steps, and RCA resolutions from `REF-STAGE2-STAGE3-TROUBLESHOOTING-20261105`.

---

## 1. Architectural Overview & Migration Flow

In this enterprise migration pattern, you will migrate PostgreSQL 16 from the on-premises database server (`DB01` on Azure) to managed **Amazon RDS PostgreSQL** using **AWS Database Migration Service (AWS DMS)** with **Change Data Capture (CDC)**.

The source database and application **remain 100% online** while AWS DMS migrates existing data and continuously streams live transactions (`INSERT`, `UPDATE`, `DELETE`) across the encrypted IPsec VPN bridge. When ready, application cutover takes less than **60 seconds**.

```
+--------------------------------------------------------------------------------------------------------------------------+
| ON-PREMISES DATACENTER (AZURE)                             | TARGET MIGRATION LANDING ZONE (AWS)                         |
| HV01 Edge Host: 20.118.39.120 (formerly 135.119.80.55)    | Region: us-east-1                                           |
| Host Internal: 10.10.1.10                                  | Target VPC: 10.20.0.0/16                                    |
| Guest Network: 10.10.10.0/24 (virbr10)                     |                                                             |
|                                                            |                                                             |
| +--------------------------------------------------------+ | +---------------------------------------------------------+ |
| | Source Application & Database VMs:                     | | | Target AWS Landing Zone Subnets:                        | |
| |                                                        | | |                                                         | |
| |  [APP01 - Web/App Tier] (10.10.10.20)                  | | |  [App Tier Private Subnets]                             | |
| |   * Nginx Reverse Proxy (Port 80)                      | | |   * 10.20.10.0/24 (us-east-1a)                          | |
| |   * Node.js / Express API (Port 5000)                  | | |   * 10.20.11.0/24 (us-east-1b)                          | |
| |           |                                            | | |                                                         | |
| |           | Live Queries (TCP 5432)                    | | |   [AWS DMS Replication Instance]                        | |
| |           v                                            | | |    * Identifier: streamflix-dms-instance                | |
| |  [DB01 - Database Tier] (10.10.10.30)                  | | |    * Class: dms.t3.micro (Private VPC only)             | |
| |   * PostgreSQL 16 (streamflix_db)                      | | |    * Security Group: streamflix-target-app-sg           | |
| |   * WAL Level: LOGICAL (CDC Enabled)                   | | |                   |                                     | |
| |   * Replication Slots & Superuser Role                 | | |                   | Reads source & writes target        | |
| |   * Static Route: 10.20.0.0/16 via 10.10.10.1 (eth1)   | | |                   v                                     | |
| +--------------------------------------------------------+ | |  [Database Isolated Subnets] (No Internet)              | |
|          |                                                 | |   * 10.20.20.0/24 (us-east-1a)                          | |
|          | Live CDC Stream (TCP 5432)                      | |   * 10.20.21.0/24 (us-east-1b)                          | |
|          v                                                 | |                   |                                     | |
|   [KVM virbr10 Forwarding & NAT Bypass]                    | |                   v                                     | |
|   [StrongSwan IPsec Daemon (ESP DH-14)]                    | |   [Target Amazon RDS PostgreSQL 16]                     | |
|      (on HV01 Host)                                        | |    * Engine: PostgreSQL 16.x                            | |
|          |                                                 | |    * Subnet Group: streamflix-target-db-subnet-group    | |
|          |                                                 | |    * Security Group: streamflix-target-db-sg            | |
|          |                                                 | |    * SSL Mode: Enforced (hostssl)                       | |
|          +=================================================+ | +---------------------------------------------------------+ |
|                      Encrypted IPsec Tunnel Over WAN         |                   ^                                         |
|                      Route: 10.10.0.0/16 <-> 10.20.0.0/16    +-------------------+                                         |
|                                                                 Virtual Private Gateway (VGW)                              |
+--------------------------------------------------------------------------------------------------------------------------+
```

---

### Master Credentials & Parameter Matrix

To avoid authentication and authorization errors, strictly reference this credential matrix:

| Context | Host / Destination | Username | Password | Privileges / Role | Purpose |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Target RDS Master** | RDS Endpoint | `postgres` | `MasterAdminPass2026!` | `rds_superuser` | RDS administrative setup & master verification |
| **Target RDS App User** | RDS Endpoint | `streamflix_user` | `StreamFlixPass2026!` | `LOGIN`, database owner | StreamFlix app target after cutover |
| **Source DB CDC User** | `10.10.10.30` | `streamflix_user` | `StreamFlixPass2026!` | `SUPERUSER`, `REPLICATION` | DMS CDC replication & DDL event triggers |
| **Source DB Local Root** | `10.10.10.30` | `postgres` | *(OS peer / `sudo`)* | `SUPERUSER` | Source local administration via `sudo -u postgres` |
| **Hypervisor Host** | `HV01` Public IP | `azureuser` / `labadmin` | `AzureUser2026!#` / `LabAdmin2026!#` | `sudo`, `libvirt`, `kvm` | Direct SSH hypervisor administration |

---

## 2. Phase 0: Pre-Flight Cross-Cloud Network & Firewall Checklist

> [!IMPORTANT]
> **Why this phase is mandatory**: During previous migrations, source endpoint tests and CDC tasks failed due to missing KVM bridge forward rules, missing Diffie-Hellman Phase 2 proposals in StrongSwan, and missing AWS VPC static routes. Completing this checklist guarantees zero connectivity failures.

### Step 0.1: Hypervisor (`HV01`) Firewall & Bridge Forwarding
By default, KVM `libvirt` installs a `-o virbr10 -j REJECT` firewall rule that drops all incoming connections from the AWS VPN to `DB01`. Additionally, default NAT masquerade changes the source IP, breaking return routing.

SSH into **`HV01`** and run the pre-flight network script:

```bash
# SSH into HV01
ssh azureuser@<HV01_PUBLIC_IP>
```

Execute on `HV01`:
```bash
# 1. Enable Linux kernel IP forwarding
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward = 1" | sudo tee -a /etc/sysctl.d/99-ipforward.conf

# 2. Allow incoming traffic from AWS VPC (10.20.0.0/16) into KVM bridge virbr10
sudo iptables -I FORWARD 1 -d 10.10.10.0/24 -o virbr10 -j ACCEPT

# 3. Allow return traffic from virbr10 back to AWS VPC
sudo iptables -I FORWARD 1 -s 10.10.10.0/24 -i virbr10 -j ACCEPT

# 4. Bypass NAT masquerade so original DB01 IP (10.10.10.30) is preserved across the VPN
sudo iptables -t nat -I POSTROUTING 1 -s 10.10.10.0/24 -d 10.20.0.0/16 -j ACCEPT
```

---

### Step 0.2: StrongSwan ESP Phase 2 Proposal on `HV01`
AWS Site-to-Site VPN enforces Diffie-Hellman Perfect Forward Secrecy on Phase 2 (ESP). If DH Group 14 (`modp2048`) is missing, Phase 1 establishes but Phase 2 fails with `NO_PROPOSAL_CHOSEN notify, no CHILD_SA built`.

Verify `/etc/ipsec.conf` on `HV01`:
```bash
sudo grep "esp=" /etc/ipsec.conf
```
Ensure the `esp` line includes `aes256-sha256-modp2048`:
```ini
esp=aes256gcm16-sha256,aes256-sha256-modp2048,aes256-sha256,aes128-sha1-modp1024,aes128-sha1!
```
If updating, restart StrongSwan:
```bash
sudo systemctl restart strongswan-starter
sudo ipsec statusall | grep "INSTALLED"
```
*Expected: Output shows `aws-tunnel-1{1}: INSTALLED, TUNNEL, reqid 1, ESP in UDP`.*

---

### Step 0.3: AWS VPC Route Table Static Routes
AWS DMS replication instances live in the private application subnets (`10.20.10.0/24`, `10.20.11.0/24`). The associated route tables must route `10.10.0.0/16` traffic to the Virtual Private Gateway (`vgw`).

Verify or add via AWS CLI:
```bash
# Add route to App Private Route Table
aws ec2 create-route \
  --route-table-id <APP_PRIVATE_ROUTE_TABLE_ID> \
  --destination-cidr-block 10.10.0.0/16 \
  --gateway-id <VGW_ID> 2>/dev/null || true

# Add route to DB Isolated Route Table
aws ec2 create-route \
  --route-table-id <DB_ISOLATED_ROUTE_TABLE_ID> \
  --destination-cidr-block 10.10.0.0/16 \
  --gateway-id <VGW_ID> 2>/dev/null || true
```

---

## 3. Phase 1: Source Database Hardening on DB01

To enable AWS DMS to stream live transactions via Change Data Capture (CDC), PostgreSQL must be properly bound to the network, configured for logical replication, authenticated with SCRAM-SHA-256, granted superuser rights for DDL triggers, and equipped with a return static route.

### Step 1.1: Connect to DB01
From `HV01`:

```bash
# Connect to DB01 using Vagrant SSH key or password
ssh -i /home/labadmin/Enterprise_Cloud_Migration_Lab/stage-1/vagrant/db01/.vagrant/machines/default/libvirt/private_key vagrant@10.10.10.30
# Or: ssh vagrant@10.10.10.30 (password: vagrant)
```

---

### Step 1.2: Record Baseline Data & Row Counts
```bash
sudo -u postgres psql -d streamflix_db -c "SELECT count(*) FROM movies;"
sudo -u postgres psql -d streamflix_db -c "SELECT id, title, release_year FROM movies ORDER BY id;"
```
*(Record: exactly 3 rows: Inception, The Dark Knight, Interstellar).*

---

### Step 1.3: Enable External Network Binding & Logical Replication in `postgresql.conf`

> [!CAUTION]
> **Root Cause Fix**: By default, Ubuntu binds PostgreSQL only to `localhost` (`127.0.0.1:5432`), rejecting all incoming connections from AWS DMS on `10.10.10.30`. Both `listen_addresses = '*'` and `wal_level = logical` are required.

Run on `DB01`:
```bash
# 1. Bind PostgreSQL to listen on all interfaces
sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/16/main/postgresql.conf
sudo sed -i "s/listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/16/main/postgresql.conf

# 2. Append logical replication and CDC worker parameters
sudo tee -a /etc/postgresql/16/main/postgresql.conf << 'EOF'
# AWS DMS CDC Logical Replication Configuration
wal_level = logical
max_replication_slots = 5
max_wal_senders = 5
EOF
```

---

### Step 1.4: Configure Client Authentication in `pg_hba.conf` using `scram-sha-256`

> [!CAUTION]
> **Root Cause Fix**: PostgreSQL 16 stores user password hashes using `SCRAM-SHA-256`. If `pg_hba.conf` specifies `md5`, PostgreSQL cannot verify the password against the SCRAM hash, resulting in:
> `FATAL: password authentication failed for user "streamflix_user"`.
> You **must** specify `scram-sha-256`.

Run on `DB01`:
```bash
sudo tee -a /etc/postgresql/16/main/pg_hba.conf << 'EOF'

# Allow AWS Target VPC (including DMS) to access streamflix_db and replication streams
host    all             all             10.20.0.0/16            scram-sha-256
host    replication     all             10.20.0.0/16            scram-sha-256
EOF
```

---

### Step 1.5: Grant SUPERUSER and Replication Privileges to `streamflix_user`

> [!CAUTION]
> **Root Cause Fix**: AWS DMS CDC captures Data Definition Language (DDL) changes (`CREATE TABLE`, `ALTER TABLE`) by creating a PostgreSQL event trigger: `CREATE EVENT TRIGGER awsdms_intercept_ddl`. PostgreSQL strictly enforces that **only superusers can create event triggers**. Without `SUPERUSER`, the task crashes on startup with:
> `Stream Component Fatal error (ddl_create_db_artifact failed)`.

Run on `DB01`:
```bash
sudo -u postgres psql -c "ALTER USER streamflix_user WITH SUPERUSER;"
sudo -u postgres psql -c "ALTER USER streamflix_user WITH REPLICATION;"
sudo -u postgres psql -c "ALTER USER streamflix_user WITH PASSWORD 'StreamFlixPass2026!';"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO streamflix_user;"
```

---

### Step 1.6: Add Permanent Static Outbound Route on `DB01`

> [!CAUTION]
> **Root Cause Fix**: `DB01` is a multi-homed VM (`eth0`: Vagrant management NAT `192.168.121.x`; `eth1`: Lab network `10.10.10.30`). When querying Amazon RDS directly (`10.20.21.8`), `DB01` routes outbound packets via default route on `eth0` (`192.168.121.1`) instead of `eth1`, causing connections to time out. Adding this static route directs AWS traffic across `virbr10`.

Run on `DB01`:
```bash
sudo ip route add 10.20.0.0/16 via 10.10.10.1 dev eth1 2>/dev/null || sudo ip route replace 10.20.0.0/16 via 10.10.10.1 dev eth1
```

---

### Step 1.7: Restart PostgreSQL & Perform 4-Point Health Check
Restart the database service:
```bash
sudo systemctl restart postgresql
```

Execute the verification commands:
```bash
# Check 1: Port 5432 bound to * (not 127.0.0.1)
sudo ss -tulpn | grep 5432

# Check 2: WAL level is logical
sudo -u postgres psql -c "SHOW wal_level;"

# Check 3: User roles show Superuser and Replication
sudo -u postgres psql -c "\du streamflix_user"

# Check 4: Outbound route to AWS VPC is eth1
ip route get 10.20.21.8
```

**Expected Check Output:**
```text
tcp   LISTEN 0      244          0.0.0.0:5432       0.0.0.0:*
wal_level: logical
Role name: streamflix_user | Attributes: Superuser, Replication
10.20.21.8 via 10.10.10.1 dev eth1 src 10.10.10.30
```

Exit `DB01`:
```bash
exit
```

---

## 4. Phase 2: Provision Target Amazon RDS PostgreSQL

### Step 2.1: Create RDS PostgreSQL Instance

#### Option A: Via AWS Management Console (Click-by-Click UI)
1. In the AWS Console search bar, type **RDS** and click **Amazon RDS**.
2. Click **Databases** $\to$ click the orange **Create database** button.
3. **Database creation method**: Select **Standard create**.
4. **Engine options**: Select **PostgreSQL** $\to$ Version **PostgreSQL 16.3-R1** (or latest 16.x).
5. **Templates**: Select **Free tier** (or **Dev/Test**).
6. **Settings**:
   - **DB instance identifier**: `streamflix-target-db`
   - **Master username**: `postgres`
   - **Master password**: `MasterAdminPass2026!`
   - **Confirm master password**: `MasterAdminPass2026!`
7. **Instance configuration**: Select `db.t4g.micro` or `db.t3.micro`.
8. **Storage**: Select **gp3**, `20` GiB, **Uncheck** *"Enable storage autoscaling"*.
9. **Connectivity**:
   - **Virtual private cloud (VPC)**: Select `streamflix-target-vpc` (`10.20.0.0/16`).
   - **DB Subnet Group**: Select `streamflix-target-db-subnet-group`.
   - **Public access**: **No** *(Private only)*.
   - **VPC security group**: Select **Choose existing** $\to$ select `streamflix-target-db-sg`. Remove `default` SG if present.
10. **Database authentication**: Select **Password authentication**.
11. **Additional configuration** *(expand)*:
    - **Initial database name**: `streamflix_db`
    - **Backup retention period**: `0 days`
    - **Deletion protection**: Uncheck.
12. Click **Create database**.

#### Option B: Via AWS CLI Command
```bash
aws rds create-db-instance \
  --db-instance-identifier streamflix-target-db \
  --db-instance-class db.t4g.micro \
  --engine postgres \
  --engine-version 16.3 \
  --master-username postgres \
  --master-user-password "MasterAdminPass2026!" \
  --allocated-storage 20 \
  --storage-type gp3 \
  --no-auto-minor-version-upgrade \
  --no-publicly-accessible \
  --db-subnet-group-name streamflix-target-db-subnet-group \
  --vpc-security-group-ids sg-08f6e173df43c49d9 \
  --db-name streamflix_db \
  --backup-retention-period 0 \
  --region us-east-1
```

---

### Step 2.2: Retrieve RDS Endpoint
Wait for status to become **`Available`** (~5-8 mins), then retrieve endpoint:
```bash
RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier streamflix-target-db \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text --region us-east-1)
echo "Target RDS Endpoint: $RDS_ENDPOINT"
```

---

### Step 2.3: Create Target Application Role on RDS
From `HV01` (or `DB01` using the static route), connect to RDS using the **master password** and create the application role:

```bash
PGPASSWORD='MasterAdminPass2026!' psql \
  -h "$RDS_ENDPOINT" \
  -U postgres \
  -d streamflix_db \
  -c "CREATE ROLE streamflix_user WITH LOGIN PASSWORD 'StreamFlixPass2026!';"

PGPASSWORD='MasterAdminPass2026!' psql \
  -h "$RDS_ENDPOINT" \
  -U postgres \
  -d streamflix_db \
  -c "GRANT ALL PRIVILEGES ON DATABASE streamflix_db TO streamflix_user;"
```

---

## 5. Phase 3: Deploy & Configure AWS DMS (Zero-Failure Execution)

### Step 3.1: Create DMS Replication Subnet Group

#### Option A: Via AWS Console (UI)
1. In the AWS Console search bar, type **DMS** $\to$ click **Database Migration Service**.
2. Click **Subnet groups** $\to$ click **Create subnet group**.
3. **Name**: `streamflix-dms-subnet-group`.
4. **VPC**: Select `streamflix-target-vpc`.
5. **Add subnets**: Select the two App Private Subnets (`10.20.10.0/24` in `1a` and `10.20.11.0/24` in `1b`).
6. Click **Create subnet group**.

#### Option B: Via AWS CLI
```bash
aws dms create-replication-subnet-group \
  --replication-subnet-group-identifier streamflix-dms-subnet-group \
  --replication-subnet-group-description "DMS Subnet Group in Private App Subnets" \
  --subnet-ids subnet-0f94155d4f2a9ffda subnet-092b27e4a5bd71540 \
  --region us-east-1
```

---

### Step 3.2: Create DMS Replication Instance

#### Option A: Via AWS Console (UI)
1. Click **Replication instances** $\to$ click **Create replication instance**.
2. **Name**: `streamflix-dms-instance`.
3. **Instance class**: `dms.t3.micro`.
4. **Allocated storage**: `20` GiB.
5. **VPC**: Select `streamflix-target-vpc`.
6. **Replication subnet group**: `streamflix-dms-subnet-group`.
7. **Publicly accessible**: **Uncheck this box** *(Strictly private)*.
8. **Advanced network configuration**:
   - **VPC security group**: Select `streamflix-target-app-sg`. Remove `default`.
9. Click **Create replication instance**.

#### Option B: Via AWS CLI
```bash
aws dms create-replication-instance \
  --replication-instance-identifier streamflix-dms-instance \
  --replication-instance-class dms.t3.micro \
  --allocated-storage 20 \
  --replication-subnet-group-identifier streamflix-dms-subnet-group \
  --vpc-security-group-ids sg-075c2521b1372d1a5 \
  --no-publicly-accessible \
  --no-multi-az \
  --region us-east-1
```

---

### Step 3.3: Create Source Endpoint (`dms-source-db01`)

#### Option A: Via AWS Console (UI)
1. Click **Endpoints** $\to$ click **Create endpoint**.
2. **Endpoint type**: Select **Source endpoint**.
3. **Endpoint identifier**: `dms-source-db01`.
4. **Source engine**: **PostgreSQL**.
5. **Access info**: Select **Provide access information manually**.
   - **Server name**: `10.10.10.30`
   - **Port**: `5432`
   - **User name**: `streamflix_user`
   - **Password**: `StreamFlixPass2026!`
   - **Database name**: `streamflix_db`
   - **Secure Sockets Layer (SSL) mode**: **none** *(Traffic is hardware-encrypted inside the IPsec tunnel)*.
6. Click **Create endpoint**.

#### Option B: Via AWS CLI
```bash
aws dms create-endpoint \
  --endpoint-identifier dms-source-db01 \
  --endpoint-type source \
  --engine-name postgres \
  --server-name 10.10.10.30 \
  --port 5432 \
  --database-name streamflix_db \
  --username streamflix_user \
  --password 'StreamFlixPass2026!' \
  --ssl-mode none \
  --region us-east-1
```

---

### Step 3.4: Create Target Endpoint (`dms-target-rds`)

> [!IMPORTANT]
> **CRITICAL CONFIGURATION**: Amazon RDS PostgreSQL strictly requires SSL encryption (`hostssl`). Under **Secure Sockets Layer (SSL) mode**, you **MUST select `require`** (CLI: `--ssl-mode require`). Setting `none` results in:
> `FATAL: no pg_hba.conf entry for host "...", user "postgres", database "streamflix_db", no encryption`.

#### Option A: Via AWS Console (UI)
1. Click **Endpoints** $\to$ click **Create endpoint**.
2. **Endpoint type**: Select **Target endpoint**.
3. **Endpoint identifier**: `dms-target-rds`.
4. **Target engine**: **PostgreSQL**.
5. **Access info**: Select **Provide access information manually**.
   - **Server name**: Paste your RDS Endpoint address (`streamflix-target-db.xxxx.us-east-1.rds.amazonaws.com`).
   - **Port**: `5432`
   - **User name**: `postgres`
   - **Password**: `MasterAdminPass2026!`
   - **Database name**: `streamflix_db`
   - **Secure Sockets Layer (SSL) mode**: **require** *(Mandatory for RDS)*.
6. Click **Create endpoint**.

#### Option B: Via AWS CLI
```bash
aws dms create-endpoint \
  --endpoint-identifier dms-target-rds \
  --endpoint-type target \
  --engine-name postgres \
  --server-name "$RDS_ENDPOINT" \
  --port 5432 \
  --database-name streamflix_db \
  --username postgres \
  --password 'MasterAdminPass2026!' \
  --ssl-mode require \
  --region us-east-1
```

---

### Step 3.5: Test Cross-Cloud Connectivity on Both Endpoints

Once `streamflix-dms-instance` status is **`Available`**:

#### Option A: Via AWS Console (UI)
1. Go to **Endpoints** $\to$ Select `dms-source-db01` $\to$ **Actions** $\to$ **Test connection**.
   - Replication instance: `streamflix-dms-instance` $\to$ click **Run test**.
   - *Status changes to `successful` (green).*
2. Select `dms-target-rds` $\to$ **Actions** $\to$ **Test connection**.
   - Replication instance: `streamflix-dms-instance` $\to$ click **Run test**.
   - *Status changes to `successful` (green).*

#### Option B: Via AWS CLI
```bash
REP_ARN=$(aws dms describe-replication-instances --filters "Name=replication-instance-id,Values=streamflix-dms-instance" --query 'ReplicationInstances[0].ReplicationInstanceArn' --output text --region us-east-1)
SRC_ARN=$(aws dms describe-endpoints --filters "Name=endpoint-id,Values=dms-source-db01" --query 'Endpoints[0].EndpointArn' --output text --region us-east-1)
TGT_ARN=$(aws dms describe-endpoints --filters "Name=endpoint-id,Values=dms-target-rds" --query 'Endpoints[0].EndpointArn' --output text --region us-east-1)

aws dms test-connection --replication-instance-arn "$REP_ARN" --endpoint-arn "$SRC_ARN" --region us-east-1
aws dms test-connection --replication-instance-arn "$REP_ARN" --endpoint-arn "$TGT_ARN" --region us-east-1

# Verify both are successful
aws dms describe-connections --query 'Connections[*].{Endpoint:EndpointIdentifier,Status:Status}' --output table --region us-east-1
```

#### Diagnostic Table for Endpoint Test Failures:
| Symptom / Error | Root Cause | Immediate Fix |
| :--- | :--- | :--- |
| `timeout expired / Read timed out` (Source) | `virbr10` packet reject or missing AWS route | Run Step 0.1 iptables rules on `HV01` and verify AWS route `10.10.0.0/16` -> `vgw`. |
| `FATAL: password authentication failed` (Source) | `pg_hba.conf` had `md5` instead of SCRAM | Verify Step 1.4: change `md5` to `scram-sha-256` in `pg_hba.conf` and reload postgresql. |
| `no pg_hba.conf entry ... no encryption` (Target) | Target endpoint SSL mode was `none` | Run: `aws dms modify-endpoint --endpoint-arn <TGT_ARN> --ssl-mode require`. |

---

## 6. Phase 4: Create & Run Full Load + CDC Replication Task

### Step 4.1: Create the Replication Task

> [!IMPORTANT]
> **Premigration Assessment (Console Trap)**: In the AWS Management Console wizard, scroll down to the **Premigration assessment** section and **UNCHECK** the box **"Turn on premigration assessment"**. If left checked, AWS DMS disables the **"Automatically on create"** radio button.

#### Option A: Via AWS Console (UI)
1. Click **Database migration tasks** $\to$ click **Create task**.
2. **Task configuration**:
   - **Task identifier**: `dms-task-streamflix-cdc`
   - **Replication instance**: `streamflix-dms-instance`
   - **Source endpoint**: `dms-source-db01`
   - **Target endpoint**: `dms-target-rds`
   - **Migration type**: Select **Migrate existing data and replicate ongoing changes** *(Full Load + CDC)*.
3. **Task settings**:
   - **Target table preparation mode**: Select **Do nothing** (or Drop tables on target).
   - **Stop task after full load completes**: Select **Don't stop** *(Keeps CDC listening!)*.
   - **Include LOB columns**: Select **Limited LOB mode** $\to$ Max LOB size: `32` KB.
   - **Turn on CloudWatch logs**: Checked.
4. **Table mappings (Wizard)**:
   - Click **Add new selection rule**:
     - **Schema**: `public`
     - **Source table name**: `%` *(All tables)*
     - **Action**: `Include`
5. **Premigration assessment**: **UNCHECK** *"Turn on premigration assessment"*.
6. **Migration task startup configuration**: Select **Automatically on create**.
7. Click **Create task**.

#### Option B: Via AWS CLI
```bash
cat << 'EOF' > /tmp/table-mappings.json
{
  "rules": [
    {
      "rule-type": "selection",
      "rule-id": "1",
      "rule-name": "1",
      "object-locator": {
        "schema-name": "public",
        "table-name": "%"
      },
      "rule-action": "include"
    }
  ]
}
EOF

aws dms create-replication-task \
  --replication-task-identifier dms-task-streamflix-cdc \
  --source-endpoint-arn "$SRC_ARN" \
  --target-endpoint-arn "$TGT_ARN" \
  --replication-instance-arn "$REP_ARN" \
  --migration-type full-load-and-cdc \
  --table-mappings file:///tmp/table-mappings.json \
  --replication-task-settings '{"TargetMetadata":{"TargetSchema":"","SupportLobs":true,"FullLobMode":false,"LobChunkSize":0,"LimitedSizeLobMode":true,"LobMaxSize":32}}' \
  --region us-east-1

TASK_ARN=$(aws dms describe-replication-tasks --filters "Name=replication-task-id,Values=dms-task-streamflix-cdc" --query 'ReplicationTasks[0].ReplicationTaskArn' --output text --region us-east-1)
aws dms start-replication-task --replication-task-arn "$TASK_ARN" --start-replication-task-type start-replication --region us-east-1
```

---

### Step 4.2: Monitor Task Progress in UI Console
1. In **Database migration tasks**, click `dms-task-streamflix-cdc`.
2. Status transitions: `Creating` $\to$ `Starting` $\to$ `Running`.
3. In **Table statistics**:
   - `movies`: Full load rows shows **`3`**, State shows **`Table completed`**.
4. In **Overview details**:
   - Status displays: **`Load complete, replication ongoing`**.

---

### Step 4.3: Verify Initial Data in RDS
From `HV01` (or `DB01`):

```bash
PGPASSWORD='MasterAdminPass2026!' psql \
  -h "$RDS_ENDPOINT" \
  -U postgres \
  -d streamflix_db \
  -c "SELECT count(*) FROM movies;"
```
*(Expected: exactly 3 rows).*

---

## 7. Phase 5: Live Real-Time CDC Test

Verify that live on-premises database transactions replicate across clouds to Amazon RDS in real time over the IPsec tunnel.

### Step 5.1: Insert a 4th Movie on DB01 (Azure)
From `DB01`:
```bash
sudo -u postgres psql -d streamflix_db -c "
INSERT INTO movies (title, description, release_year, genre, duration_minutes, poster_path, video_path) 
VALUES ('The Matrix Resurrections', 'Return to a world of two realities.', 2021, 'Sci-Fi', 148, '/media/posters/matrix.svg', '/media/videos/matrix.mp4');
"

# Check local count
sudo -u postgres psql -d streamflix_db -c "SELECT count(*) FROM movies;"
```
*(Local count: 4 rows).*

---

### Step 5.2: Observe Real-Time CDC in DMS Console
1. In the DMS Console $\to$ **Database migration tasks** $\to$ `dms-task-streamflix-cdc`.
2. Click **Table statistics**:
   - **Inserts** column for `movies` increments to **`1`**.
   - **CDC latency**: shows **`0 seconds`**.

---

### Step 5.3: Verify Replicated Row in Target RDS (AWS)
Query RDS using the master admin password:
```bash
PGPASSWORD='MasterAdminPass2026!' psql \
  -h "$RDS_ENDPOINT" \
  -U postgres \
  -d streamflix_db \
  -c "SELECT id, title, release_year, genre FROM movies ORDER BY id;"
```

**Expected Output:**
```text
 id |            title            | release_year |    genre    
----+-----------------------------+--------------+-------------
  1 | Cloud Migration Chronicles  |         2026 | Documentary
  2 | KVM Virtualization Horizons |         2025 | Sci-Fi
  3 | Samba in the Datacenter     |         2024 | Tech Drama
  4 | The Matrix Resurrections    |         2021 | Sci-Fi
(4 rows)
```
🎉 **Live transaction replicated across clouds via CDC with zero downtime!**

---

## 8. Phase 6: 60-Second Application Cutover

Because changes replicate continuously with 0 seconds latency, cutover only requires redirecting `APP01` to the RDS endpoint.

### Step 6.1: Update Application Configuration on APP01
SSH into **`APP01`**:
```bash
ssh -i /home/labadmin/Enterprise_Cloud_Migration_Lab/stage-1/vagrant/app01/.vagrant/machines/default/libvirt/private_key vagrant@10.10.10.20
```

Update `/var/www/streamflix/backend/.env`:
```bash
cat << EOF | sudo tee /var/www/streamflix/backend/.env
PORT=5000
DB_HOST=<YOUR_RDS_ENDPOINT>
DB_PORT=5432
DB_NAME=streamflix_db
DB_USER=streamflix_user
DB_PASSWORD=StreamFlixPass2026!
EOF
```

Restart the service:
```bash
sudo systemctl restart streamflix
```

---

### Step 6.2: Verify StreamFlix Application Health
```bash
# 1. Health endpoint
curl -s http://localhost/api/health | jq .

# 2. Movie catalog (returns all 4 rows from RDS!)
curl -s http://localhost/api/movies | jq .
```

Expected Health JSON:
```json
{
  "status": "UP",
  "service": "StreamFlix API",
  "host": "APP01",
  "database": "CONNECTED"
}
```

---

### Step 6.3: Stop the DMS Task (Cost Control)
In the DMS Console $\to$ **Database migration tasks** $\to$ Select `dms-task-streamflix-cdc` $\to$ **Actions** $\to$ click **Stop**.

---

## 9. Master Quick-Remediation Scripts (Turnkey Automation)

If rebuilding or automating this setup in a fresh environment, run these three master scripts:

### Script A: Run on Hypervisor (`HV01`)
```bash
#!/usr/bin/env bash
set -e
sudo sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward = 1" | sudo tee -a /etc/sysctl.d/99-ipforward.conf
sudo iptables -I FORWARD 1 -d 10.10.10.0/24 -o virbr10 -j ACCEPT
sudo iptables -I FORWARD 1 -s 10.10.10.0/24 -i virbr10 -j ACCEPT
sudo iptables -t nat -I POSTROUTING 1 -s 10.10.10.0/24 -d 10.20.0.0/16 -j ACCEPT
sudo sed -i 's/esp=.*/esp=aes256gcm16-sha256,aes256-sha256-modp2048,aes256-sha256,aes128-sha1-modp1024,aes128-sha1!/' /etc/ipsec.conf
sudo systemctl restart strongswan-starter
echo "[SUCCESS] HV01 network forwarding, firewall, and StrongSwan configured."
```

### Script B: Run on Database Server (`DB01`)
```bash
#!/usr/bin/env bash
set -e
sudo ip route add 10.20.0.0/16 via 10.10.10.1 dev eth1 2>/dev/null || sudo ip route replace 10.20.0.0/16 via 10.10.10.1 dev eth1
sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/16/main/postgresql.conf
sudo sed -i "s/listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/16/main/postgresql.conf
sudo tee -a /etc/postgresql/16/main/postgresql.conf << 'EOF'
wal_level = logical
max_replication_slots = 5
max_wal_senders = 5
EOF
sudo tee -a /etc/postgresql/16/main/pg_hba.conf << 'EOF'
host    all             all             10.20.0.0/16            scram-sha-256
host    replication     all             10.20.0.0/16            scram-sha-256
EOF
sudo systemctl restart postgresql
sudo -u postgres psql -c "ALTER USER streamflix_user WITH SUPERUSER;"
sudo -u postgres psql -c "ALTER USER streamflix_user WITH REPLICATION;"
sudo -u postgres psql -c "ALTER USER streamflix_user WITH PASSWORD 'StreamFlixPass2026!';"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO streamflix_user;"
echo "[SUCCESS] DB01 PostgreSQL and routing configured for AWS DMS."
```

### Script C: Run via AWS CLI (Routing & Enforce SSL)
```bash
aws ec2 create-route --route-table-id <APP_PRIVATE_RT_ID> --destination-cidr-block 10.10.0.0/16 --gateway-id <VGW_ID>
aws ec2 create-route --route-table-id <DB_ISOLATED_RT_ID> --destination-cidr-block 10.10.0.0/16 --gateway-id <VGW_ID>
aws dms modify-endpoint --endpoint-arn <TARGET_ENDPOINT_ARN> --ssl-mode require
```
