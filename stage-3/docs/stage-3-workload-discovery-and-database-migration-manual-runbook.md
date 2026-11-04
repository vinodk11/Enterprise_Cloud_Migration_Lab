# Stage 3: Enterprise Database Migration Manual Runbook — Method B (AWS DMS with Zero-Downtime CDC)
**Document ID**: RUNBOOK-STAGE3-METHOD-B-DMS-CDC-20261104  
**Target Audience**: Cloud Migration Engineers, Database Architects, DevSecOps  
**Lab Context**: Enterprise Cloud Migration Lab (StreamFlix Application Stack)  
**Strategy**: Method B — Full Load + Ongoing Change Data Capture (CDC) via AWS DMS  
**Status**: Step-by-Step Hands-On Manual Learning Guide  

---

## 1. Architectural Overview & Migration Flow

In this enterprise migration pattern, we migrate PostgreSQL 16 from the on-premises database server (`DB01` on Azure) to managed **Amazon RDS PostgreSQL** using **AWS Database Migration Service (AWS DMS)** with **Change Data Capture (CDC)**.

The source database and application **remain 100% online** while AWS DMS migrates existing data and continuously streams live transactions (`INSERT`, `UPDATE`, `DELETE`) across the encrypted IPsec VPN bridge. When ready, cutover takes less than **60 seconds**.

```
+--------------------------------------------------------------------------------------------------------------------------+
| ON-PREMISES DATACENTER (AZURE)                             | TARGET MIGRATION LANDING ZONE (AWS)                         |
| HV01 Edge Host: 20.29.104.127                              | Region: us-east-1                                           |
| Host Internal: 10.10.1.10                                  | Target VPC: vpc-020d6b01e57048985 (10.20.0.0/16)            |
| Guest Network: 10.10.10.0/24 (virbr10)                     |                                                             |
|                                                            |                                                             |
| +--------------------------------------------------------+ | +---------------------------------------------------------+ |
| | Source Application & Database VMs:                     | | | Target AWS Landing Zone Subnets:                        | |
| |                                                        | | |                                                         | |
| |  [APP01 - Web/App Tier] (10.10.10.20)                 | | |  [App Tier Private Subnets]                             | |
| |   * Nginx Reverse Proxy (Port 80)                      | | |   * subnet-0f94155d4f2a9ffda (10.20.10.0/24 - 1a)       | |
| |   * Node.js / Express API (Port 5000)                  | | |   * subnet-092b27e4a5bd71540 (10.20.11.0/24 - 1b)       | |
| |           |                                            | | |                                                         | |
| |           | Live Queries (TCP 5432)                    | | |   [AWS DMS Replication Instance]                        | |
| |           v                                            | | |    * Identifier: streamflix-dms-instance                | |
| |  [DB01 - Database Tier] (10.10.10.30)                  | | |    * Class: dms.t3.micro (Private VPC only)             | |
| |   * PostgreSQL 16 (streamflix_db)                      | | |    * Security Group: streamflix-target-app-sg           | |
| |   * WAL Level: LOGICAL (CDC Enabled)                   | | |                   |                                     | |
| |   * Replication Slots / Senders                        | | |                   | Reads source & writes target        | |
| +--------------------------------------------------------+ | |                   v                                     | |
|          |                                                 | |  [Database Isolated Subnets] (No Internet)              | |
|          | Live CDC Stream (TCP 5432)                      | |   * subnet-0c560d86fb2bcc381 (10.20.20.0/24 - 1a)       | |
|          v                                                 | |   * subnet-0bf0d776e63b027e4 (10.20.21.0/24 - 1b)       | |
|   [StrongSwan IPsec Daemon]                                | |                   |                                     | |
|      (on HV01 Host)                                        | |                   v                                     | |
|          |                                                 | |   [Target Amazon RDS PostgreSQL 16]                     | |
|          |                                                 | |    * Engine: PostgreSQL 16.x                            | |
|          |                                                 | |    * Class : db.t4g.micro / db.t3.micro                 | |
|          |                                                 | |    * Subnet Group: streamflix-target-db-subnet-group    | |
|          |                                                 | |    * Security Group: streamflix-target-db-sg            | |
|          +=================================================+ | +---------------------------------------------------------+ |
|                      Encrypted IPsec Tunnel Over WAN         |                   ^                                         |
|                      Route: 10.10.0.0/16 <-> 10.20.0.0/16    +-------------------+                                         |
|                                                                 Virtual Private Gateway (VGW)                              |
+--------------------------------------------------------------------------------------------------------------------------+
```

---

### Parameter Reference Table

| Component | Parameter | Value | Description |
| :--- | :--- | :--- | :--- |
| **On-Prem Edge** | HV01 Public IP | `20.29.104.127` | Edge IP / SSH Gateway |
| **Source DB VM** | `DB01` IP | `10.10.10.30` | Source PostgreSQL 16 Server |
| **Source DB** | Database Name | `streamflix_db` | Application production database |
| **Source DB** | Replication User | `streamflix_user` | User configured with `REPLICATION` privilege |
| **Source DB** | Password | `StreamFlixPass2026!` | Application / Replication password |
| **AWS Target VPC** | Target VPC ID | `vpc-020d6b01e57048985` | Landing Zone Target VPC (`10.20.0.0/16`) |
| **Target DB Subnets** | Subnet IDs | `subnet-0c560d86fb2bcc381` / `subnet-0bf0d776e63b027e4` | Isolated DB Subnets in 1a & 1b |
| **Target DB Subnet Group** | Name | `streamflix-target-db-subnet-group` | RDS Subnet Group |
| **Target DB Security Group** | ID | `sg-08f6e173df43c49d9` | Name: `streamflix-target-db-sg` |
| **Target RDS DB** | DB Identifier | `streamflix-target-db` | Name of RDS instance |
| **Target RDS DB** | Engine & Version | PostgreSQL 16.x | Compatible with source version |
| **Target RDS DB** | Master User / Pass | `postgres` / `MasterAdminPass2026!` | RDS superuser credentials |
| **DMS Subnet Group** | Name | `streamflix-dms-subnet-group` | Uses App Private Subnets (`10.20.10.0/24`, `10.20.11.0/24`) |
| **DMS Security Group** | ID | `sg-075c2521b1372d1a5` | Name: `streamflix-target-app-sg` |
| **DMS Instance** | Identifier / Class | `streamflix-dms-instance` / `dms.t3.micro` | 20 GiB gp3 storage |
| **DMS Source Endpoint** | Identifier | `dms-source-db01` | Points to `10.10.10.30:5432` |
| **DMS Target Endpoint** | Identifier | `dms-target-rds` | Points to RDS Endpoint `:5432` |
| **DMS Task** | Task Identifier | `dms-task-streamflix-cdc` | Full Load + Ongoing Replication (CDC) |

---

## 2. Phase 1: Source Workload & WAL Preparation on DB01

To enable AWS DMS to capture ongoing changes in real time (**Change Data Capture / CDC**), PostgreSQL must be configured for **logical replication**.

### Step 1.1: Connect to DB01
From your workstation or HV01 terminal:

```bash
# Connect to DB01
ssh -i /home/labadmin/Enterprise_Cloud_Migration_Lab/stage-1/vagrant/db01/.vagrant/machines/default/libvirt/private_key vagrant@10.10.10.30
```

---

### Step 1.2: Record Baseline Data & Row Counts
Check the current database contents:

```bash
sudo -u postgres psql -d streamflix_db -c "SELECT count(*) FROM movies;"
sudo -u postgres psql -d streamflix_db -c "SELECT id, title, release_year FROM movies ORDER BY id;"
```
*(Record: exactly 3 rows: Inception, The Dark Knight, Interstellar).*

---

### Step 1.3: Enable Logical Replication in `postgresql.conf`
For DMS to capture changes, PostgreSQL's Write-Ahead Log level must be set to `logical`:

```bash
# 1. Edit postgresql.conf
sudo nano /etc/postgresql/16/main/postgresql.conf
```

Find or append these settings (you can paste them at the bottom of the file):
```ini
wal_level = logical
max_replication_slots = 5
max_wal_senders = 5
```
*Save and exit (`Ctrl+O`, `Enter`, `Ctrl+X`).*

---

### Step 1.4: Allow AWS Subnets in `pg_hba.conf`
Configure PostgreSQL client authentication to allow the AWS DMS replication instance (`10.20.0.0/16`) to connect for standard queries and replication:

```bash
# 1. Open pg_hba.conf
sudo nano /etc/postgresql/16/main/pg_hba.conf
```

Add these lines at the end of the file:
```text
# Allow AWS Target VPC (including DMS) to access streamflix_db and replication streams
host    streamflix_db    streamflix_user    10.20.0.0/16    md5
host    replication      streamflix_user    10.20.0.0/16    md5
host    streamflix_db    postgres           10.20.0.0/16    md5
host    replication      postgres           10.20.0.0/16    md5
```
*Save and exit (`Ctrl+O`, `Enter`, `Ctrl+X`).*

---

### Step 1.5: Grant Replication Permissions to `streamflix_user`
In PostgreSQL, only users with the `REPLICATION` role can stream the Write-Ahead Log:

```bash
sudo -u postgres psql -c "ALTER USER streamflix_user WITH REPLICATION;"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO streamflix_user;"
```

---

### Step 1.6: Restart PostgreSQL & Verify Settings
Restart the service to activate `wal_level = logical`:

```bash
sudo systemctl restart postgresql
```

Verify that the logical WAL settings are active:
```bash
sudo -u postgres psql -c "SHOW wal_level;"
sudo -u postgres psql -c "SHOW max_replication_slots;"
```
**Expected Output:**
```text
 wal_level 
-----------
 logical
(1 row)
```

Exit `DB01`:
```bash
exit
```

---

## 3. Phase 2: Provision Target AWS RDS PostgreSQL

Now you will create the target managed database in AWS. The **DB Subnet Group** (`streamflix-target-db-subnet-group`) and **DB Security Group** (`streamflix-target-db-sg` / `sg-08f6e173df43c49d9`) were already deployed in Stage 2.

### Step 2.1: Create the RDS PostgreSQL Instance

You can provision the database either via the **AWS Management Console** or the **AWS CLI**:

#### Option A: Via AWS Management Console
1. Open the **Amazon RDS** console in `us-east-1`.
2. Click **Databases** $\to$ **Create database**.
3. Choose **Standard create**.
4. **Engine options**: **PostgreSQL** $\to$ Version **PostgreSQL 16.x** (e.g. `16.3` or latest 16).
5. **Templates**: **Free tier** (or **Dev/Test**).
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
   - Storage autoscaling: *Uncheck Enable storage autoscaling*
9. **Connectivity**:
   - Virtual private cloud (VPC): `streamflix-target-vpc` (`vpc-020d6b01e57048985`)
   - DB Subnet Group: `streamflix-target-db-subnet-group`
   - Public access: **No** (Strict private isolation!)
   - VPC security group: Select existing $\to$ `streamflix-target-db-sg` (`sg-08f6e173df43c49d9`), remove `default`.
10. **Additional configuration**:
    - Initial database name: `streamflix_db`
    - Backup retention period: `0` days (disabled for lab speed)
11. Click **Create database**.

---

#### Option B: Via AWS CLI
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

*(Takes ~5–8 minutes to provision).*

---

### Step 2.2: Retrieve the RDS Endpoint Address
Wait until the database status is `available`:

```bash
aws rds wait db-instance-available \
  --db-instance-identifier streamflix-target-db \
  --region us-east-1

RDS_ENDPOINT=$(aws rds describe-db-instances \
  --db-instance-identifier streamflix-target-db \
  --query 'DBInstances[0].Endpoint.Address' \
  --output text \
  --region us-east-1)

echo "Target RDS Endpoint: $RDS_ENDPOINT"
```

---

### Step 2.3: Create Target Application Role on RDS
From `HV01` (or your workstation over VPN), connect to the new RDS instance and create the `streamflix_user` role:

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

## 4. Phase 3: Deploy & Configure AWS Database Migration Service (DMS)

Now we deploy the AWS DMS infrastructure that will perform the initial full load and stream ongoing transactions over the VPN bridge.

### Step 3.1: Create DMS Replication Subnet Group
DMS requires a subnet group spanning at least two Availability Zones. We will use the private application subnets:
* Subnet 1a: `subnet-0f94155d4f2a9ffda` (`10.20.10.0/24`)
* Subnet 1b: `subnet-092b27e4a5bd71540` (`10.20.11.0/24`)

Run:
```bash
aws dms create-replication-subnet-group \
  --replication-subnet-group-identifier streamflix-dms-subnet-group \
  --replication-subnet-group-description "DMS Subnet Group in Private App Subnets" \
  --subnet-ids subnet-0f94155d4f2a9ffda subnet-092b27e4a5bd71540 \
  --region us-east-1
```

---

### Step 3.2: Create the DMS Replication Instance
Deploy a cost-effective `dms.t3.micro` instance inside your private VPC:

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

> [!NOTE]
> DMS replication instance creation takes approximately **5 to 8 minutes**. Monitor its progress:
> ```bash
> aws dms describe-replication-instances \
>   --filters "Name=replication-instance-id,Values=streamflix-dms-instance" \
>   --query 'ReplicationInstances[0].ReplicationInstanceStatus' \
>   --output text
> ```
> Wait until it outputs **`available`**.

---

### Step 3.3: Create Source Endpoint (Pointing to On-Prem DB01)
Configure DMS to connect across the IPsec VPN to `DB01` (`10.10.10.30`):

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

### Step 3.4: Create Target Endpoint (Pointing to AWS RDS)
Configure DMS to connect to your new RDS PostgreSQL instance:

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
Retrieve the Replication Instance ARN:
```bash
REP_ARN=$(aws dms describe-replication-instances \
  --filters "Name=replication-instance-id,Values=streamflix-dms-instance" \
  --query 'ReplicationInstances[0].ReplicationInstanceArn' \
  --output text \
  --region us-east-1)

SRC_ARN=$(aws dms describe-endpoints \
  --filters "Name=endpoint-id,Values=dms-source-db01" \
  --query 'Endpoints[0].EndpointArn' \
  --output text \
  --region us-east-1)

TGT_ARN=$(aws dms describe-endpoints \
  --filters "Name=endpoint-id,Values=dms-target-rds" \
  --query 'Endpoints[0].EndpointArn' \
  --output text \
  --region us-east-1)
```

Trigger network connectivity tests:
```bash
# Test connection to on-premises DB01 across IPsec VPN
aws dms test-connection \
  --replication-instance-arn "$REP_ARN" \
  --endpoint-arn "$SRC_ARN" \
  --region us-east-1

# Test connection to RDS inside AWS VPC
aws dms test-connection \
  --replication-instance-arn "$REP_ARN" \
  --endpoint-arn "$TGT_ARN" \
  --region us-east-1
```

Verify that both show **`successful`**:
```bash
aws dms describe-connections \
  --query 'Connections[*].{Endpoint:EndpointIdentifier,Status:Status}' \
  --output table \
  --region us-east-1
```

---

## 5. Phase 4: Create & Run the Full Load + CDC Replication Task

Now we create the task that performs the initial migration and starts continuous Change Data Capture.

### Step 4.1: Define Table Mapping JSON
Create a table mapping file that tells DMS to replicate the `public` schema:

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
```

---

### Step 4.2: Create the Replication Task
Run the command to create the Full Load + CDC task:

```bash
aws dms create-replication-task \
  --replication-task-identifier dms-task-streamflix-cdc \
  --source-endpoint-arn "$SRC_ARN" \
  --target-endpoint-arn "$TGT_ARN" \
  --replication-instance-arn "$REP_ARN" \
  --migration-type full-load-and-cdc \
  --table-mappings file:///tmp/table-mappings.json \
  --replication-task-settings '{"TargetMetadata":{"TargetSchema":"","SupportLobs":true,"FullLobMode":false,"LobChunkSize":0,"LimitedSizeLobMode":true,"LobMaxSize":32}}' \
  --region us-east-1
```

---

### Step 4.3: Start the Replication Task
Start the task:

```bash
TASK_ARN=$(aws dms describe-replication-tasks \
  --filters "Name=replication-task-id,Values=dms-task-streamflix-cdc" \
  --query 'ReplicationTasks[0].ReplicationTaskArn' \
  --output text \
  --region us-east-1)

aws dms start-replication-task \
  --replication-task-arn "$TASK_ARN" \
  --start-replication-task-type start-replication \
  --region us-east-1
```

Monitor until the status transitions through `starting` $\to$ `running`:
```bash
aws dms describe-replication-tasks \
  --filters "Name=replication-task-id,Values=dms-task-streamflix-cdc" \
  --query 'ReplicationTasks[0].{Status:Status,Progress:ReplicationTaskStats.FullLoadProgressPercent}' \
  --output table \
  --region us-east-1
```

Once the initial copy completes:
* `FullLoadProgressPercent` will be **`100`**.
* `Status` will change to **`replication ongoing`**!

---

### Step 4.4: Verify Initial Data on RDS
Check that the 3 initial movies were copied into RDS:

```bash
PGPASSWORD='MasterAdminPass2026!' psql \
  -h "$RDS_ENDPOINT" \
  -U postgres \
  -d streamflix_db \
  -c "SELECT count(*) FROM movies;"
```
*(Expected: exactly 3 rows).*

---

## 6. Phase 5: The Proof — Real-Time Cross-Cloud CDC Test! 🚀

This is the most exciting demonstration of Method B. You will insert a new movie on your on-premises database in Azure, and watch it **replicate automatically to AWS RDS within milliseconds** over the IPsec VPN!

### Step 5.1: Insert a New Movie on DB01 (Azure)
SSH into **`DB01`**:

```bash
ssh -i /home/labadmin/Enterprise_Cloud_Migration_Lab/stage-1/vagrant/db01/.vagrant/machines/default/libvirt/private_key vagrant@10.10.10.30
```

Insert a 4th movie into the live database:
```sql
sudo -u postgres psql -d streamflix_db -c "
INSERT INTO movies (title, release_year, genre, rating) 
VALUES ('The Matrix Resurrections', 2021, 'Sci-Fi', '5.7');
"
```

Verify it exists locally on `DB01`:
```bash
sudo -u postgres psql -d streamflix_db -c "SELECT count(*) FROM movies;"
```
*(Now 4 rows on DB01).*

Exit `DB01`:
```bash
exit
```

---

### Step 5.2: Immediately Check Target RDS (AWS)
Query your Amazon RDS PostgreSQL instance:

```bash
PGPASSWORD='MasterAdminPass2026!' psql \
  -h "$RDS_ENDPOINT" \
  -U postgres \
  -d streamflix_db \
  -c "SELECT id, title, release_year, rating FROM movies ORDER BY id;"
```

**Expected Output:**
```text
 id |           title            | release_year | rating 
----+----------------------------+--------------+--------
  1 | Inception                  |         2010 | 8.8
  2 | The Dark Knight            |         2008 | 9.0
  3 | Interstellar               |         2014 | 8.6
  4 | The Matrix Resurrections   |         2021 | 5.7
(4 rows)
```

🎉 **The new movie replicated instantly across clouds via Change Data Capture over your encrypted IPsec VPN!**

---

## 7. Phase 6: The 60-Second Near-Zero Downtime Cutover

Because AWS DMS is continuously streaming changes, your cutover requires only switching the application's database host.

### Step 6.1: Check CDC Latency
Verify that DMS CDC latency is **0 seconds**:
```bash
aws dms describe-replication-tasks \
  --filters "Name=replication-task-id,Values=dms-task-streamflix-cdc" \
  --query 'ReplicationTasks[0].ReplicationTaskStats.CDCLatencySeconds' \
  --output text \
  --region us-east-1
```

---

### Step 6.2: Re-target StreamFlix Application on APP01
SSH into **`APP01`**:

```bash
ssh -i /home/labadmin/Enterprise_Cloud_Migration_Lab/stage-1/vagrant/app01/.vagrant/machines/default/libvirt/private_key vagrant@10.10.10.20
```

Update `/var/www/streamflix/backend/.env` with your new RDS endpoint:
```bash
cat << EOF | sudo tee /var/www/streamflix/backend/.env
PORT=5000
DB_HOST=$RDS_ENDPOINT
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

### Step 6.3: Verify StreamFlix Application Health
Test the live application endpoints:

```bash
# 1. Health endpoint
curl -s http://localhost/api/health | jq .

# 2. Movie catalog (should return all 4 movies from RDS!)
curl -s http://localhost/api/movies | jq .
```

**Expected Health Output:**
```json
{
  "status": "UP",
  "service": "StreamFlix API",
  "host": "APP01",
  "database": "CONNECTED",
  "timestamp": "2026-11-04T..."
}
```

Exit `APP01`:
```bash
exit
```

---

### Step 6.4: Stop the DMS Task (Cost Optimization)
Once cutover is verified and traffic is running against RDS, stop the DMS task so it doesn't incur ongoing charges:

```bash
aws dms stop-replication-task \
  --replication-task-arn "$TASK_ARN" \
  --region us-east-1
```

---

## 8. Verification Checklist & Success Criteria

| # | Check Item | Verification Command | Expected Result | Status |
| :-: | :--- | :--- | :--- | :-: |
| 1 | **WAL Configuration** | `SHOW wal_level;` on DB01 | `logical` | [ ] |
| 2 | **RDS Provisioning** | `aws rds describe-db-instances` | Status: `available` | [ ] |
| 3 | **DMS Replication Instance** | `aws dms describe-replication-instances` | Status: `available` | [ ] |
| 4 | **Endpoint Connectivity** | `aws dms describe-connections` | Both endpoints `successful` | [ ] |
| 5 | **Full Load Execution** | `FullLoadProgressPercent` | `100%` | [ ] |
| 6 | **CDC Real-Time Sync** | Insert row on `DB01` $\to$ query RDS | Row appears instantly | [ ] |
| 7 | **Application Cutover** | `curl -s http://10.10.10.20/api/health` | `database: "CONNECTED"` | [ ] |
| 8 | **Catalog Verification** | `curl -s http://10.10.10.20/api/movies` | 4 movies returned from RDS | [ ] |

---

## 9. Rollback Runbook (In Case of Issues)

If any issue arises after cutover:
1. Revert `APP01` back to `DB01`:
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
   *The application will immediately resume pointing to local `DB01`.*
