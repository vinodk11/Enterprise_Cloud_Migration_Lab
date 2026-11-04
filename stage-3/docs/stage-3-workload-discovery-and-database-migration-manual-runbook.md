# Stage 3: Workload Discovery & PostgreSQL Database Migration Manual Runbook
**Document ID**: RUNBOOK-STAGE3-DISCOVERY-DB-MIGRATION-20261104  
**Target Audience**: Cloud Migration Engineers, Database Administrators, DevSecOps  
**Lab Context**: Enterprise Cloud Migration Lab (StreamFlix Application Stack)  
**Status**: Step-by-Step Hands-On Manual Learning Guide  

---

## 1. Architectural Overview & Migration Flow

In Stage 2, you successfully deployed the target AWS Landing Zone foundation and connected it to your on-premises datacenter (`HV01` on Azure) using an encrypted IPsec Site-to-Site VPN bridge.

Now, in **Stage 3**, you will discover the source on-premises workloads, map their dependencies, provision an enterprise-ready **Amazon RDS PostgreSQL** instance in your private isolated subnets, migrate the data, and validate private end-to-end operation across the hybrid VPN bridge.

```
+------------------------------------------------------------------------------------------------------------------+
| ON-PREMISES DATACENTER (AZURE)                     | TARGET MIGRATION LANDING ZONE (AWS)                         |
| HV01 Edge Host: 20.29.104.127                      | Region: us-east-1                                           |
| Host Internal: 10.10.1.10                          | Target VPC: vpc-020d6b01e57048985 (10.20.0.0/16)            |
| Guest Network: 10.10.10.0/24 (virbr10)             |                                                             |
|                                                    |                                                             |
| +------------------------------------------------+ | +---------------------------------------------------------+ |
| | Source Application & Database VMs:             | | | Target AWS Landing Zone Subnets:                        | |
| |                                                | | |                                                         | |
| |  [APP01 - Web/App Tier] (10.10.10.20)         | | |  [App Tier Private Subnets]                             | |
| |   * Nginx Reverse Proxy (Port 80)              | | |   * subnet-0f94155d4f2a9ffda (10.20.10.0/24 - 1a)       | |
| |   * Node.js / Express API (Port 5000)          | | |   * subnet-092b27e4a5bd71540 (10.20.11.0/24 - 1b)       | |
| |           |                                    | | |                                                         | |
| |           | SQL Queries (TCP 5432)             | | |  [Database Isolated Subnets] (No Internet)              | |
| |           v                                    | | |   * subnet-0c560d86fb2bcc381 (10.20.20.0/24 - 1a)       | |
| |  [DB01 - Database Tier] (10.10.10.30)          | | |   * subnet-0bf0d776e63b027e4 (10.20.21.0/24 - 1b)       | |
| |   * PostgreSQL 16 (streamflix_db)              | | |               ^                                         | |
| |   * Port 5432                                  | | |               |                                         | |
| +------------------------------------------------+ | |               v                                         | |
|          |                                         | |   [Target Amazon RDS PostgreSQL 16]                     | |
|          | pg_dump / Network Transfer              | |    * Engine: PostgreSQL 16.x                            | |
|          v                                         | |    * Class : db.t4g.micro / db.t3.micro                 | |
|   [StrongSwan IPsec Daemon]                        | |    * Multi-AZ Subnet Group:                             | |
|      (on HV01 Host)                                | |        streamflix-target-db-subnet-group                | |
|          |                                         | |    * Security Group: streamflix-target-db-sg            | |
|          |                                         | |        (sg-08f6e173df43c49d9)                           | |
|          +=========================================+ | +---------------------------------------------------------+ |
|                    Encrypted IPsec Tunnel Over WAN |                     ^                                       |
|                    Route: 10.10.0.0/16 <-> 10.20.0.0/16                  |                                       |
|                                                    +---------------------+                                       |
|                                                 Virtual Private Gateway (VGW)                            |
+------------------------------------------------------------------------------------------------------------------+
```

---

### Parameter Reference Table

| Component | Parameter | Value | Description |
| :--- | :--- | :--- | :--- |
| **On-Prem Hypervisor** | Host Public IP | `20.29.104.127` | Edge IP / Cockpit Console |
| **On-Prem Hypervisor** | Host Internal IP | `10.10.1.10` | Azure internal interface (`eth0`) |
| **On-Prem Subnet** | Guest VM Subnet | `10.10.10.0/24` | KVM bridge network (`virbr10`) |
| **Source App VM** | `APP01` IP | `10.10.10.20` | Express.js API & Nginx |
| **Source DB VM** | `DB01` IP | `10.10.10.30` | PostgreSQL 16 Server |
| **Source DB** | Database Name | `streamflix_db` | Application production database |
| **Source DB** | Database User | `streamflix_user` | Application DB user |
| **Source DB** | Database Password | `StreamFlixPass2026!` | Application DB password |
| **Source DB** | Database Port | `5432` | Standard PostgreSQL port |
| **AWS Target VPC** | Target VPC ID | `vpc-020d6b01e57048985` | Landing Zone Target VPC |
| **AWS Target CIDR** | Target VPC CIDR | `10.20.0.0/16` | AWS landing zone address space |
| **Target DB Subnet 1** | Subnet ID | `subnet-0c560d86fb2bcc381` | `streamflix-target-db-isolated-1a` (`10.20.20.0/24`) |
| **Target DB Subnet 2** | Subnet ID | `subnet-0bf0d776e63b027e4` | `streamflix-target-db-isolated-1b` (`10.20.21.0/24`) |
| **DB Subnet Group** | Subnet Group Name | `streamflix-target-db-subnet-group` | Multi-AZ RDS Subnet Group |
| **DB Security Group**| Security Group ID | `sg-08f6e173df43c49d9` | Name: `streamflix-target-db-sg` |
| **Target RDS DB** | DB Identifier | `streamflix-target-db` | Name of RDS instance |
| **Target RDS DB** | Engine & Version | PostgreSQL 16.x | Compatible with source version |
| **Target RDS DB** | Instance Class | `db.t4g.micro` or `db.t3.micro` | Cost-effective lab class |
| **Target RDS Master**| Master Username | `postgres` | RDS administrative superuser |
| **Target RDS Master**| Master Password | `MasterAdminPass2026!` | Administrative password |

---

## 2. Phase 1: Source Workload & Dependency Discovery

Before migrating any database or application, enterprise migration standards (such as AWS Migration Acceleration Program - MAP) require rigorous **Workload Assessment & Dependency Mapping**.

### Step 1.1: Connect to HV01 and Verify Virtual Machine Inventory
1. Open your terminal or Cockpit console on `HV01` (`https://20.29.104.127:9090`).
2. Verify all 4 virtual machines are actively running:
   ```bash
   sudo virsh list --all
   ```
   **Expected Output:**
   ```text
    Id   Name             State
   --------------------------------
    1    dc01_default     running
    2    db01_default     running
    3    file01_default   running
    4    app01_default    running
   ```

3. Confirm network connectivity to both `APP01` and `DB01`:
   ```bash
   ping -c 2 10.10.10.20
   ping -c 2 10.10.10.30
   ```
   Both should report `0% packet loss`.

---

### Step 1.2: Inspect Source PostgreSQL on DB01
You can log into `DB01` from `HV01` using its SSH private key or by navigating to its vagrant directory:

```bash
# Option A: Direct SSH using private key
ssh -i /home/labadmin/Enterprise_Cloud_Migration_Lab/stage-1/vagrant/db01/.vagrant/machines/default/libvirt/private_key vagrant@10.10.10.30

# Option B: Using Vagrant directory
cd /home/labadmin/Enterprise_Cloud_Migration_Lab/stage-1/vagrant/db01
vagrant ssh
```

Once connected inside **`DB01`**:

1. **Check PostgreSQL Service Status & Version**:
   ```bash
   sudo systemctl status postgresql --no-pager
   psql --version
   ```
   *Expected: PostgreSQL 16.x active and running.*

2. **Inspect Existing Databases**:
   ```bash
   sudo -u postgres psql -c "\l"
   ```
   Notice `streamflix_db` owned by `streamflix_user` with `UTF8` encoding.

3. **Inspect Application Tables and Schemas**:
   ```bash
   sudo -u postgres psql -d streamflix_db -c "\dt"
   ```
   You will see the table:
   ```text
    Schema |  Name  | Type  |      Owner      
   --------+--------+-------+-----------------
    public | movies | table | streamflix_user
   ```

4. **Record Baseline Data & Table Schema**:
   ```bash
   # Check table structure
   sudo -u postgres psql -d streamflix_db -c "\d movies"

   # Check current record count
   sudo -u postgres psql -d streamflix_db -c "SELECT COUNT(*) FROM movies;"

   # Inspect existing records
   sudo -u postgres psql -d streamflix_db -c "SELECT id, title, release_year, rating FROM movies;"
   ```
   *Record this row count! You will use it to verify the target RDS database after migration.*

5. Exit `DB01`:
   ```bash
   exit
   ```

---

### Step 1.3: Inspect StreamFlix Application Configuration on APP01
Connect to **`APP01`** from `HV01`:

```bash
# Option A: Direct SSH using private key
ssh -i /home/labadmin/Enterprise_Cloud_Migration_Lab/stage-1/vagrant/app01/.vagrant/machines/default/libvirt/private_key vagrant@10.10.10.20

# Option B: Using Vagrant directory
cd /home/labadmin/Enterprise_Cloud_Migration_Lab/stage-1/vagrant/app01
vagrant ssh
```

Once inside **`APP01`**:

1. **Inspect Nginx Reverse Proxy Configuration**:
   ```bash
   sudo nginx -T | grep -E "server_name|proxy_pass|listen"
   ```
   Notice that Nginx listens on port `80` and proxies `/api` calls to Node.js backend port `5000`.

2. **Inspect Application Database Connection String**:
   ```bash
   head -n 25 /var/www/streamflix/backend/server.js
   ```
   Observe the database environment variables:
   * `DB_HOST`: Defaults to `10.10.10.30`
   * `DB_PORT`: `5432`
   * `DB_USER`: `streamflix_user`
   * `DB_PASSWORD`: `StreamFlixPass2026!`
   * `DB_NAME`: `streamflix_db`

3. **Test the Live API Endpoint**:
   ```bash
   curl -s http://localhost/api/health | jq .
   curl -s http://localhost/api/movies | jq .
   ```
   *Expected: `status: "UP"`, `database: "CONNECTED"`.*

4. Exit `APP01`:
   ```bash
   exit
   ```

---

## 3. Phase 2: Provision Target AWS RDS PostgreSQL

Now you will create the target managed database in AWS. Because the target VPC was created with Terraform in Stage 2, the **DB Subnet Group** and **DB Security Group** are already prepared for you!

### Step 2.1: Verify Target AWS Network Foundation
Run these commands from your local workspace terminal (or CloudShell):

```bash
# 1. Verify DB Subnet Group exists
aws rds describe-db-subnet-groups \
  --db-subnet-group-name streamflix-target-db-subnet-group \
  --query 'DBSubnetGroups[0].{Name:DBSubnetGroupName,VPC:VpcId,Subnets:Subnets[*].SubnetIdentifier}'

# 2. Verify DB Security Group allows inbound PostgreSQL (5432) from DB01 (10.10.10.30)
aws ec2 describe-security-groups \
  --group-ids sg-08f6e173df43c49d9 \
  --query 'SecurityGroups[0].IpPermissions'
```

---

### Step 2.2: Create the RDS PostgreSQL Instance

You can provision the database either using the **AWS Management Console** or the **AWS CLI**. Choose whichever method you prefer to practice:

#### Method A: Via AWS Management Console
1. Navigate to the **Amazon RDS** console in `us-east-1`.
2. Click **Databases** $\to$ **Create database**.
3. Select **Standard create**.
4. **Engine options**:
   - Engine type: **PostgreSQL**
   - Engine Version: **PostgreSQL 16.x** (e.g., `16.3-R1` or latest 16)
5. **Templates**: Choose **Free tier** (or **Dev/Test**).
6. **Settings**:
   - DB instance identifier: `streamflix-target-db`
   - Master username: `postgres`
   - Master password: `MasterAdminPass2026!`
   - Confirm password: `MasterAdminPass2026!`
7. **Instance configuration**:
   - DB instance class: **Burstable classes** $\to$ `db.t4g.micro` (or `db.t3.micro`)
8. **Storage**:
   - Storage type: **General Purpose SSD (gp3)**
   - Allocated storage: `20` GiB
   - Storage autoscaling: *Disable* (to prevent unexpected costs in lab)
9. **Connectivity**:
   - Virtual private cloud (VPC): Select `streamflix-target-vpc` (`vpc-020d6b01e57048985`)
   - DB Subnet Group: Select `streamflix-target-db-subnet-group`
   - Public access: **No** (Strict private isolation!)
   - VPC security group (firewall): Choose **Select existing** $\to$ choose `streamflix-target-db-sg` (`sg-08f6e173df43c49d9`), and remove the `default` security group.
10. **Database authentication**: Password authentication.
11. **Additional configuration**:
    - Initial database name: `streamflix_db`
    - Backup retention: `1` day (or disable automated backups for lab if desired)
12. Click **Create database**.

---

#### Method B: Via AWS CLI
Alternatively, run this single AWS CLI command from your workstation:

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

> [!NOTE]
> RDS provisioning takes approximately **5 to 8 minutes** while AWS initializes the underlying storage volume, configures SSL certificates, and prepares database endpoints.

---

### Step 2.3: Retrieve the RDS Endpoint Address
Monitor the creation status until it becomes `available`:

```bash
aws rds wait db-instance-available \
  --db-instance-identifier streamflix-target-db \
  --region us-east-1
```

Once available, retrieve the private DNS endpoint:

```bash
RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier streamflix-target-db \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text \
  --region us-east-1)

echo "Target RDS Endpoint: $RDS_ENDPOINT"
```
*(Save this endpoint; it will look like `streamflix-target-db.cxxxxxxx.us-east-1.rds.amazonaws.com`)*.

---

### Step 2.4: Test Cross-Cloud Network Reachability from On-Premises
Test that your on-premises `DB01` can reach the private RDS instance over the IPsec VPN:

From `HV01` (or inside `DB01`):
```bash
# Test TCP handshake on port 5432 across the VPN bridge
nc -zv $RDS_ENDPOINT 5432
```
**Expected Output:**
```text
Connection to streamflix-target-db.xxxx.us-east-1.rds.amazonaws.com 5432 port [tcp/postgresql] succeeded!
```

---

## 4. Phase 3: Database Migration Execution

We will perform a zero-loss migration using PostgreSQL native logical utilities (`pg_dump` and `pg_restore`). This method guarantees clean schema conversion, table structure validation, and accurate sequence synchronization.

```
[DB01 (10.10.10.30)] ---> pg_dump ---> /tmp/streamflix_db.dump
                                                 |
                                         (Over IPsec VPN)
                                                 v
                                  pg_restore ---> [AWS RDS PostgreSQL]
```

---

### Step 3.1: Create Logical Dump on DB01
SSH into **`DB01`**:

```bash
ssh -i /home/labadmin/Enterprise_Cloud_Migration_Lab/stage-1/vagrant/db01/.vagrant/machines/default/libvirt/private_key vagrant@10.10.10.30
```

Inside **`DB01`**, create a compressed custom-format archive dump:

```bash
# 1. Export the database schema and data
sudo -u postgres pg_dump \
  -Fc \
  -v \
  -d streamflix_db \
  -f /tmp/streamflix_db.dump

# 2. Verify backup file creation and file size
ls -lh /tmp/streamflix_db.dump
```

---

### Step 3.2: Prepare Target Database Roles on RDS
Before restoring, ensure the target RDS database has the matching role `streamflix_user` so that table ownership and application permissions are preserved:

From `DB01` (or `HV01`):

```bash
# Connect to RDS as the master postgres user and create the application role
PGPASSWORD='MasterAdminPass2026!' psql \
  -h "<YOUR_RDS_ENDPOINT>" \
  -U postgres \
  -d streamflix_db \
  -c "CREATE ROLE streamflix_user WITH LOGIN PASSWORD 'StreamFlixPass2026!';"

# Grant permissions on the database
PGPASSWORD='MasterAdminPass2026!' psql \
  -h "<YOUR_RDS_ENDPOINT>" \
  -U postgres \
  -d streamflix_db \
  -c "GRANT ALL PRIVILEGES ON DATABASE streamflix_db TO streamflix_user;"
```

---

### Step 3.3: Restore the Database into Amazon RDS
Execute the restore directly from `DB01` targeting the RDS endpoint over the IPsec tunnel:

```bash
# Restore schema and data into RDS
PGPASSWORD='MasterAdminPass2026!' pg_restore \
  -h "<YOUR_RDS_ENDPOINT>" \
  -U postgres \
  -d streamflix_db \
  --no-owner \
  --role=streamflix_user \
  -v \
  /tmp/streamflix_db.dump
```

---

### Step 3.4: Validate Data Integrity & Row Counts
Now compare the target RDS database with the on-prem source database:

```bash
# 1. Check tables in RDS
PGPASSWORD='MasterAdminPass2026!' psql \
  -h "<YOUR_RDS_ENDPOINT>" \
  -U postgres \
  -d streamflix_db \
  -c "\dt"

# 2. Check row count in RDS
PGPASSWORD='MasterAdminPass2026!' psql \
  -h "<YOUR_RDS_ENDPOINT>" \
  -U postgres \
  -d streamflix_db \
  -c "SELECT count(*) FROM movies;"

# 3. Inspect records in RDS
PGPASSWORD='MasterAdminPass2026!' psql \
  -h "<YOUR_RDS_ENDPOINT>" \
  -U postgres \
  -d streamflix_db \
  -c "SELECT id, title, release_year, rating FROM movies ORDER BY id;"
```

**Verification Check:**
Confirm that:
- Total table count in RDS matches `DB01` (1 table: `movies`).
- Total row count in RDS matches `DB01` exactly (3 rows).
- Schema columns and primary keys are intact.

---

## 5. Phase 4: Application Re-Targeting & Verification

Now you will reconfigure the StreamFlix application on `APP01` to use the target Amazon RDS database across the hybrid VPN bridge!

```
[Client / Browser]
        |
        v
  [APP01 (Nginx)]
        |
  [Node.js API (Port 5000)]
        |
        +======== (Encrypted IPsec VPN Bridge) ========> [Amazon RDS PostgreSQL]
```

### Step 4.1: Update Application Database Configuration on APP01
SSH into **`APP01`**:

```bash
ssh -i /home/labadmin/Enterprise_Cloud_Migration_Lab/stage-1/vagrant/app01/.vagrant/machines/default/libvirt/private_key vagrant@10.10.10.20
```

Inside **`APP01`**:

1. **Create/Update the Environment Configuration File**:
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

2. **Restart the StreamFlix Application Service**:
   ```bash
   sudo systemctl restart streamflix
   sudo systemctl status streamflix --no-pager
   ```

---

### Step 4.2: Verify Application Health and Data Delivery
Test the application endpoints from `APP01` (or from `HV01`):

```bash
# 1. Verify Health Check
curl -s http://localhost/api/health | jq .
```
**Expected Output:**
```json
{
  "status": "UP",
  "service": "StreamFlix API",
  "host": "APP01",
  "database": "CONNECTED",
  "timestamp": "2026-11-04T..."
}
```

```bash
# 2. Query Movie Catalog
curl -s http://localhost/api/movies | jq .
```
**Expected Output:**
```json
[
  {
    "id": 1,
    "title": "Inception",
    "release_year": 2010,
    "genre": "Sci-Fi",
    "rating": "8.8"
  },
  {
    "id": 2,
    "title": "The Dark Knight",
    "release_year": 2008,
    "genre": "Action",
    "rating": "9.0"
  },
  {
    "id": 3,
    "title": "Interstellar",
    "release_year": 2014,
    "genre": "Sci-Fi",
    "rating": "8.6"
  }
]
```

---

### Step 4.3: Verify IPsec VPN Encryption Telemetry
Run this on **`HV01`** to confirm that the application SQL queries are traversing and being encrypted by StrongSwan:

```bash
sudo ipsec statusall | grep -A 2 "INSTALLED, TUNNEL"
```
Notice the `bytes_i` and `bytes_o` counters increasing as queries are issued!

---

## 6. Phase 5: Low-Downtime Continuous Replication (AWS DMS Overview)

In high-volume enterprise environments where downtime must be near-zero, **AWS Database Migration Service (AWS DMS)** with **Change Data Capture (CDC)** is used instead of a one-time `pg_dump`:

```
+----------------+          +-----------------------+          +------------------+
| On-Prem DB01   | -------> | AWS DMS Replication   | -------> | Target AWS RDS   |
| (PostgreSQL 16)| (WAL CDC)| Instance (Private)    | (SSL)    | PostgreSQL       |
+----------------+          +-----------------------+          +------------------+
```

### High-Level DMS Steps for Reference:
1. **Source DB Preparation**:
   Set `wal_level = logical` and `max_replication_slots = 5` in `postgresql.conf` on `DB01`.
2. **DMS Replication Instance**:
   Create a `dms.t3.micro` replication instance inside the private subnets.
3. **Endpoints**:
   - Source Endpoint: `DB01` IP `10.10.10.30`, port `5432`.
   - Target Endpoint: RDS endpoint, port `5432`.
4. **Migration Task**:
   Create a task with migration type: **Full load + ongoing replication (CDC)**.
5. **Cutover Window**:
   When CDC latency reaches 0 seconds, redirect application traffic to RDS and stop source writes.

*(For this lab, the `pg_dump`/`pg_restore` method in Phase 3 gives you full hands-on mastery of database schema, users, and cross-cloud private connectivity!)*

---

## 7. Verification Checklist & Success Criteria

Before declaring Stage 3 complete, verify every item below:

| # | Check Item | Command / Test | Expected Result | Status |
| :-: | :--- | :--- | :--- | :-: |
| 1 | **Source Discovery** | `sudo virsh list --all` on HV01 | All 4 VMs running (`10.10.10.0/24`) | [ ] |
| 2 | **Source DB Baseline** | `SELECT count(*) FROM movies;` on DB01 | Exactly 3 rows documented | [ ] |
| 3 | **RDS Provisioned** | `aws rds describe-db-instances` | Status: `available`, Multi-AZ subnet group | [ ] |
| 4 | **VPN Reachability** | `nc -zv <RDS_ENDPOINT> 5432` from DB01 | Port `5432` open across IPsec tunnel | [ ] |
| 5 | **Data Migration** | `pg_restore` / `psql` to RDS | Schema, tables, and rows imported | [ ] |
| 6 | **Data Parity** | `SELECT count(*) FROM movies;` on RDS | Exactly 3 rows (matches DB01) | [ ] |
| 7 | **App Re-targeting** | `curl -s http://10.10.10.20/api/health` | `database: "CONNECTED"` | [ ] |
| 8 | **Catalog API** | `curl -s http://10.10.10.20/api/movies` | Full JSON movie catalog returned | [ ] |

---

## 8. Rollback Runbook (In Case of Issues)

If any unexpected failure occurs during testing:
1. **Revert APP01 to Source DB**:
   ```bash
   cat << EOF | sudo tee /var/www/streamflix/backend/.env
   PORT=5000
   DB_HOST=10.10.10.30
   DB_PORT=5432
   DB_NAME=streamflix_db
   DB_USER=streamflix_user
   DB_PASSWORD=StreamFlixPass2026!
   EOF
   sudo systemctl restart streamflix
   ```
2. Verify local connectivity:
   ```bash
   curl -s http://localhost/api/health
   ```
   *The application will immediately resume pointing to local `DB01` with zero data loss.*
