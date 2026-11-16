# Stage 5: Enterprise Application Server Migration Manual Runbook — Migrating APP01 to Amazon EC2 via AWS Application Migration Service (AWS MGN) & ALB
**Document ID**: RUNBOOK-STAGE5-APP-MIGRATION-MGN-EC2-ALB-20261116  
**Target Audience**: Cloud Migration Engineers, Solutions Architects, Infrastructure Leads, DevSecOps  
**Lab Context**: Enterprise Cloud Migration Lab (StreamFlix Application Server Rehost)  
**Strategy**: Enterprise Automated Block-Level Server Rehost (Lift-and-Shift) via AWS Application Migration Service (AWS MGN) behind Application Load Balancer (ALB)  
**UI Focus**: Dual Click-by-Click AWS Management Console & Terminal CLI / Shell Instructions  

---

## 1. Architectural Overview & Migration Lifecycle

In an enterprise cloud migration following the **AWS Migration Acceleration Program (MAP)** framework, migrating a mission-critical application server (`APP01`) does **not** involve manually spinning up an empty operating system and attempting to manually reinstall libraries or copy code snippets. 

Instead, enterprise migrations leverage **AWS Application Migration Service (AWS MGN)** (formerly CloudEndure Migration), the native AWS technology for non-disruptive, automated block-level server rehosting:

1. **Continuous Block-Level Replication**: The lightweight **AWS Replication Agent** is installed on the source server (`APP01` at `10.10.10.20` running on Azure KVM). It captures every disk write at the block level on `/dev/vda` (30 GiB root disk) and streams it over the encrypted **IPsec Site-to-Site VPN** (`10.10.0.0/16 <-> 10.20.0.0/16`) to a dedicated Replication Server inside the private staging subnet.
2. **Zero Downtime During Replication**: The source server remains 100% online and actively serves users during the entire synchronization process.
3. **Automated Kernel Driver Conversion**: AWS MGN automatically launches a temporary **Conversion Server** that attaches snapshot volumes, injects native AWS hypervisor drivers (ENA networking, NVMe storage, and Xen), configures bootloaders (`grub`), and creates an Amazon Machine Image (AMI).
4. **Non-Disruptive Pre-Cutover Testing (MAP Best Practice)**: AWS MGN launches a **Test Instance** inside your private application subnet (`10.20.10.0/24`). You can thoroughly validate application health, database queries to RDS, and CloudFront CDN media delivery without stopping replication or affecting on-premises operations.
5. **Final Production Cutover**: Once testing passes, you launch the **Cutover Instance**, finalize the migration, and register the instance with an **Application Load Balancer (ALB)** deployed in public subnets (`10.20.1.0/24` and `10.20.2.0/24`).

```
+------------------------------------------------------------------------------------------------------------------------------------+
| ON-PREMISES DATACENTER (AZURE KVM)                                  | TARGET MIGRATION LANDING ZONE (AWS us-east-1)                 |
| Hypervisor: HV01 (172.173.122.68)                                   | VPC: vpc-0eacb09847d857983 (10.20.0.0/16)                     |
|                                                                     |                                                              |
| +-----------------------------------------------------------------+ | +----------------------------------------------------------+ |
| | Source VM: APP01 (10.10.10.20 on virbr10)                       | | | PUBLIC WEB / ALB SUBNETS:                                | |
| |  * OS: Ubuntu 24.04 LTS (x86_64)                                | | |  subnet-0f17c60078c74fc05 (10.20.1.0/24 - 1a)        | |
| |  * Disk: /dev/vda (30 GiB Root Volume)                          | | |  subnet-018c04fd8f2edcd6e (10.20.2.0/24 - 1b)        | |
| |  * Stack: React Dist + Nginx (Port 80), Express API (Port 5000)  | | |                                                          | |
| |  * [AWS Replication Agent]                                      | | |  [Application Load Balancer: streamflix-alb]             | |
| +--------+--------------------------------------------------------+ | |  Security Group: streamflix-alb-sg (Port 80 from 0.0.0.0/0) |
|          |                                                          | +-------+--------------------------------------------------+ |
|          | Block-Level Stream (TCP 1500)                            |         |                                                    |
|          v                                                          |         | Forward HTTP (Port 80)                             |
|   [StrongSwan IPsec Daemon]                                         |         v                                                    |
|     (HV01 Hypervisor)                                               |  [Target Group: streamflix-tg-app-ec2] (/api/health)        |
|          |                                                          |         |                                                    |
|          +==========================================================+=========+====================================================+
|                               Encrypted IPsec VPN Bridge                                                                           |
|                               Route: 10.10.0.0/16 <-> 10.20.0.0/16                                                                 |
|                                                                                                                                    |
|                                                                     | +----------------------------------------------------------+ |
|                                                                     | | PRIVATE STAGING SUBNET (subnet-094426acfea458e5c - 1a):   | |
|                                                                     | |  * Security Group: sg-0c7841ad581251d1d (Port 1500 In)   | |
|                                                                     | |  * Data Plane Routing: PRIVATE_IP                        | |
|                                                                     | |  * [Replication Server: t3.micro + gp3 Staging EBS]       | |
|                                                                     | +-------+--------------------------------------------------+ |
|                                                                     |         |                                                    |
|                                                                     |         | Automated Conversion & Driver Injection            |
|                                                                     |         v                                                    |
|                                                                     |  [AWS MGN Conversion Server]                                 |
|                                                                     |         |                                                    |
|                                                                     |         v                                                    |
|                                                                     | +----------------------------------------------------------+ |
|                                                                     | | TARGET PRIVATE APP SUBNET (subnet-094426acfea458e5c):     | |
|                                                                     | |                                                          | |
|                                                                     | |  [Migrated Production EC2 Instance: streamflix-app-ec2]  | |
|                                                                     | |   * Converted from KVM /dev/vda to AWS NVMe EBS Root     | |
|                                                                     | |   * Private IP: 10.20.10.x (No Public IP)                | |
|                                                                     | |   * Security Group: streamflix-target-app-sg             | |
|                                                                     | |   * Native Nginx + Express systemd service running       | |
|                                                                     | +-------+----------------------------+---------------------+ |
|                                                                     |         |                            |                       |
+---------------------------------------------------------------------+---------|----------------------------|-----------------------+
                                                                                | SQL (Port 5432)            | Media Assets (HTTPS)
                                                                                v                            v
                                                      +-----------------------------------+        +-----------------------------------+
                                                      | Target Amazon RDS PostgreSQL 16   |        | Amazon CloudFront CDN / S3 Bucket |
                                                      | streamflix-target-db.cy9mak0su1oj |        | d1u8bkpbx2mtpm.cloudfront.net     |
                                                      | (streamflix-target-db-isolated-1a)|        | (streamflix-media-165772574557)   |
                                                      +-----------------------------------+        +-----------------------------------+
```

---

### Migration Lifecycle Stages

```
 +---------------------------------------------------------------------------------------------------+
 | 1. Initialize AWS MGN        2. Agent Installation      3. Continuous Replication                 |
 | Configure Replication        Download installer on      Initial Sync 0% -> 100%                   |
 | Template (PRIVATE_IP)        APP01; register with AWS   Continuous block updates (Lag: 0s)        |
 +--------------------+-------------------+-----------------------------------+----------------------+
                      |                   |                                   |
                      v                   v                                   v
 +---------------------------------------------------------------------------------------------------+
 | 4. Launch Test Instance      5. Validate Test VM        6. Cutover to Production EC2              |
 | Conversion server injects    Confirm /api/health &      Launch production EC2; finalize cutover;  |
 | NVMe/ENA drivers & boots EC2 /api/movies via VPN        register with ALB for public traffic      |
 +---------------------------------------------------------------------------------------------------+
```

---

### Parameter Reference Table

| Component | Parameter | Value | Description |
| :--- | :--- | :--- | :--- |
| **AWS Region** | Region Name | `us-east-1` | Target AWS Cloud Region |
| **Target VPC ID** | VPC ID | `vpc-0eacb09847d857983` | StreamFlix Landing Zone VPC (`10.20.0.0/16`) |
| **Staging Subnet (MGN)**| Subnet ID | `subnet-094426acfea458e5c` | `streamflix-target-app-private-1a` (`10.20.10.0/24`) |
| **Private App Subnets** | Subnet 1a / 1b | `subnet-094426acfea458e5c` / `subnet-0d7fc76b1b17050f0` | Target subnets for migrated EC2 workloads |
| **Public Subnets (ALB)**| Subnet 1a / 1b | `subnet-0f17c60078c74fc05` / `subnet-018c04fd8f2edcd6e` | Public subnets for Application Load Balancer |
| **App Security Group** | Group ID | `sg-0c7841ad581251d1d` | Name: `streamflix-target-app-sg` |
| **DB Security Group** | Group ID | `sg-075c1320653bd7215` | Name: `streamflix-target-db-sg` |
| **ALB Security Group** | Group Name | `streamflix-alb-sg` | Public ingress on Port 80 and 443 |
| **Replication Template**| Template ID | `rct-308d988f0aeebc90d` | Configured with `dataPlaneRouting: PRIVATE_IP` |
| **Launch Config Template**| Template ID | `lct-3442db0a84143a61f` | AWS MGN Account Launch Configuration Template |
| **EC2 Launch Template**| Template ID | `lt-0922d1ce857d3b781` | Version 2 (Default): `t3.micro`, `CloudForge` |
| **Replication Port** | TCP Port | `1500` | Inbound port for block data replication |
| **IAM Installer User**| Username | `mgn-installer-user` | IAM user with `AWSApplicationMigrationAgentInstallationPolicy` |
| **Target Instance Type**| Instance Class | `t3.micro` (or `t3.small`) | Compute size for target EC2 instance |
| **Target Key Pair** | Key Name | `CloudForge` | SSH key pair for target EC2 access |
| **Target Database** | RDS Endpoint | `streamflix-target-db.cy9mak0su1oj.us-east-1.rds.amazonaws.com` | Target PostgreSQL 16 database from Stage 3 |
| **Target CDN** | CloudFront Domain | `d1u8bkpbx2mtpm.cloudfront.net` | Target Media CDN endpoint from Stage 4 |
| **Target S3 Bucket** | Bucket Name | `streamflix-media-165772574557` | Target media origin bucket |
| **Source Server** | Hostname / IP | `APP01` / `10.10.10.20` | On-premises Linux KVM VM on Azure |
| **Source Hypervisor** | Hostname / IP | `HV01` / `172.173.122.68` | Azure-hosted KVM hypervisor host |

---

## 2. Phase 0: Pre-Flight Verification & Connectivity Checks

Before starting the migration, execute these essential pre-flight checks to verify network connectivity, routing, and access permissions.

### Step 0.1: Verify IPsec VPN Connectivity from HV01 to AWS
From your workstation or hypervisor `HV01` (`172.173.122.68`), verify StrongSwan IPsec status:

```bash
# Verify StrongSwan IPsec Child SA is INSTALLED
sudo ipsec status
```
*Expected Output:*
```text
Security Associations (1 up, 1 connecting):
    AWS-VPC-1[1]: ESTABLISHED 45 minutes ago, 10.0.0.4[172.173.122.68]...3.212.183.18[3.212.183.18]
    AWS-VPC-1{1}:  INSTALLED, TUNNEL, reqid 1, ESP SPIs: c71f8e21_0b41c9a3
    AWS-VPC-1{1}:   10.10.0.0/16 === 10.20.0.0/16
```

Test routing to the AWS private app subnet gateway:
```bash
# Ping AWS private subnet router or test RDS connectivity
nc -zv streamflix-target-db.cy9mak0su1oj.us-east-1.rds.amazonaws.com 5432
```
*Expected Output: `Connection to streamflix-target-db.cy9mak0su1oj.us-east-1.rds.amazonaws.com 5432 port [tcp/postgresql] succeeded!`*

---

### Step 0.2: Verify APP01 Guest VM Status & Outbound Access
From `HV01`, SSH into `APP01` and verify network reachability:

```bash
# SSH into APP01
ssh vagrant@10.10.10.20

# 1. Verify Internet access for AWS API endpoints & package downloads
curl -I https://aws-application-migration-service-us-east-1.s3.us-east-1.amazonaws.com

# 2. Verify DNS resolution
nslookup mgn.us-east-1.amazonaws.com

# 3. Check disk layout and root filesystem
df -hT /
lsblk
```
*Expected Output: HTTP `200` or `403` (endpoint reachable), DNS resolves to AWS IP addresses, `/dev/vda` is mounted as `/`.*

Exit `APP01` back to `HV01`:
```bash
exit
```

---

## 3. Phase 1: Initialize AWS Application Migration Service (AWS MGN)

AWS MGN requires initialization in `us-east-1`, creation of service-linked roles, and configuration of the **Replication Configuration Template** configured with **`dataPlaneRouting: PRIVATE_IP`**.

### Step 1.1: Verify Service-Linked Role and Instance Profiles

AWS MGN requires the service-linked role `AWSServiceRoleForApplicationMigrationService` and the EC2 instance profiles `AWSApplicationMigrationConversionServerRole` and `AWSApplicationMigrationReplicationServerRole`.

#### Option A: Via AWS Management Console (Click-by-Click UI)
1. In the AWS Management Console search bar at the top, type **Application Migration Service** and press **Enter**.
2. If this is your first time in the region, a welcome banner appears: **"Welcome to AWS Application Migration Service"**.
3. Click the orange **Get started** button. AWS will automatically create the required service-linked roles.
4. If already initialized, you are navigated directly to the **Source servers** dashboard.

#### Option B: Via AWS CLI Command
```bash
# Verify the service-linked role exists
aws iam get-role \
  --role-name AWSServiceRoleForApplicationMigrationService \
  --query 'Role.Arn' \
  --output text 2>/dev/null || \
aws iam create-service-linked-role \
  --aws-service-name mgn.amazonaws.com
```

---

### Step 1.2: Configure Replication Settings Template (`PRIVATE_IP` Routing)

> [!IMPORTANT]
> By default, AWS MGN routes replication data over the public internet. Because our architecture features an enterprise **Site-to-Site IPsec VPN** (`10.10.0.0/16 <-> 10.20.0.0/16`), we must set **Data routing** to **Use private IP**. This ensures all disk blocks travel through the encrypted VPN tunnel directly into your private staging subnet without requiring public IPs or internet gateways for replication!

#### Option A: Via AWS Management Console (Click-by-Click UI)
1. In the AWS MGN left navigation pane, under **Settings**, click **Replication template**.
2. Click the **Edit** button in the top right corner.
3. Configure the following parameters:
   * **Staging area subnets**:
     * VPC: Select `streamflix-target-vpc` (`vpc-0eacb09847d857983`).
     * Subnet: Select `streamflix-target-app-private-1a` (`subnet-094426acfea458e5c`).
   * **Replication Servers security group**:
     * Select `streamflix-target-app-sg` (`sg-0c7841ad581251d1d`).
   * **Replication Server instance type**:
     * Select **`t3.micro`** (cost-effective).
   * **Staging disk type**:
     * Select **Standard (gp3)**.
   * **EBS encryption**:
     * Select **Default (AWS managed key)**.
   * **Data routing**:
     * Select the radio button: **Use private IP (VPN, DirectConnect, or VPC peering)**.
   * **Bandwidth throttling**:
     * Leave at `0` (unlimited).
4. Scroll to the bottom and click **Save template**.

#### Option B: Via AWS CLI Command
```bash
# Update existing replication template rct-308d988f0aeebc90d
aws mgn update-replication-configuration-template \
  --replication-configuration-template-id rct-308d988f0aeebc90d \
  --staging-area-subnet-id subnet-094426acfea458e5c \
  --replication-servers-security-groups-ids sg-0c7841ad581251d1d \
  --replication-server-instance-type t3.micro \
  --default-large-staging-disk-type GP3 \
  --data-plane-routing PRIVATE_IP \
  --region us-east-1
```

---

### Step 1.3: Verify Security Group Inbound TCP Port 1500

The Replication Server in `subnet-094426acfea458e5c` listens on **TCP Port 1500** for block data transmitted by the agent on `APP01` (`10.10.10.20`). Ensure this port is open to the on-premises subnet:

```bash
# Authorize inbound TCP 1500 on streamflix-target-app-sg from on-prem CIDR
aws ec2 authorize-security-group-ingress \
  --group-id sg-0c7841ad581251d1d \
  --protocol tcp \
  --port 1500 \
  --cidr 10.10.0.0/16 \
  --region us-east-1 2>/dev/null || true
```

---

### Step 1.4: Configure Launch Template Settings for Target EC2

AWS MGN uses an **Account-Level Launch Configuration Template** (`lct-3442db0a84143a61f`) backed by an **Amazon EC2 Launch Template** (`lt-0922d1ce857d3b781`) to control how test and cutover instances are provisioned.

> [!NOTE]
> **Why Launch Template Settings cannot be edited directly in-place:**
> 1. AWS EC2 Launch Templates are strictly **immutable and version-controlled**. You cannot "edit" an existing version; you must create a new version (e.g. Version 2) and mark it as the **Default Version**.
> 2. Until an account has an initialized Launch Configuration Template (`lct-...`), the AWS MGN Console will not display the "Modify launch template" options.
> 3. We have initialized the MGN template **`lct-3442db0a84143a61f`** and configured EC2 Launch Template **`lt-0922d1ce857d3b781`** Version 2 as Default with `t3.micro`, private subnet `subnet-094426acfea458e5c`, and security group `sg-0c7841ad581251d1d`.

#### Option A: Via AWS Management Console (Viewing & Modifying)
1. In the AWS MGN left navigation pane, under **Settings**, click **Launch template**.
2. You will now see the active Launch Configuration Template linked to EC2 Launch Template **`lt-0922d1ce857d3b781`**.
3. To view or make changes to the EC2 Launch Template:
   * Click **Modify launch template** (or open the **Amazon EC2 Console** $\to$ **Launch Templates** $\to$ select `created-and-used-by-application-migration-service...` `lt-0922d1ce857d3b781`).
   * Click **Actions** $\to$ **Modify template (Create new version)**.
   * Under **Template version description**: Enter `StreamFlix Target EC2 Configuration`.
   * Under **Instance type**: Ensure `t3.micro` is selected.
   * Under **Key pair (login)**: Select `CloudForge`.
   * Under **Network settings**:
     * Subnet: Select `streamflix-target-app-private-1a` (`subnet-094426acfea458e5c`).
     * Security groups: Select `streamflix-target-app-sg` (`sg-0c7841ad581251d1d`).
     * Auto-assign public IP: **Disable**.
   * Click **Create template version**.
   * Click **Actions** $\to$ **Set default version** $\to$ Select the newly created version $\to$ Click **Set as default version**.

#### Option B: Via AWS CLI Command (Already Configured)
```bash
# 1. Create a configured version (Version 2) of the EC2 Launch Template
aws ec2 create-launch-template-version \
  --launch-template-id lt-0922d1ce857d3b781 \
  --source-version 1 \
  --version-description "StreamFlix Target EC2 Configuration" \
  --launch-template-data '{
    "InstanceType": "t3.micro",
    "KeyName": "CloudForge",
    "NetworkInterfaces": [
      {
        "DeviceIndex": 0,
        "SubnetId": "subnet-094426acfea458e5c",
        "Groups": ["sg-0c7841ad581251d1d"],
        "AssociatePublicIpAddress": false
      }
    ],
    "TagSpecifications": [
      {
        "ResourceType": "instance",
        "Tags": [
          {"Key": "Name", "Value": "streamflix-app-ec2"},
          {"Key": "Environment", "Value": "Production"},
          {"Key": "Project", "Value": "StreamFlix"},
          {"Key": "AWSApplicationMigrationServiceManaged", "Value": "mgn.amazonaws.com"}
        ]
      }
    ]
  }' \
  --region us-east-1

# 2. Set Version 2 as the Default version
aws ec2 modify-launch-template \
  --launch-template-id lt-0922d1ce857d3b781 \
  --default-version 2 \
  --region us-east-1

# 3. Update the MGN Launch Configuration Template
aws mgn update-launch-configuration-template \
  --launch-configuration-template-id lct-3442db0a84143a61f \
  --launch-disposition STARTED \
  --no-associate-public-ip-address \
  --target-instance-type-right-sizing-method NONE \
  --region us-east-1
```

---

## 4. Phase 2: Create Agent Installation IAM Credentials

The AWS Replication Agent running on `APP01` must authenticate to AWS MGN endpoints to register the server and coordinate block transfers.

### Step 2.1: Verify Dedicated IAM User `mgn-installer-user`

The IAM user must have the AWS-managed policy `AWSApplicationMigrationAgentInstallationPolicy` attached.

```bash
# Verify policy attachment
aws iam list-attached-user-policies --user-name mgn-installer-user
```
*Expected: `PolicyArn: arn:aws:iam::aws:policy/AWSApplicationMigrationAgentInstallationPolicy`*

---

### Step 2.2: Generate Access Key for Agent Installation

#### Option A: Via AWS Management Console (Click-by-Click UI)
1. In the AWS Console search bar, type **IAM** $\to$ Click **Users** in the left menu.
2. Click on **`mgn-installer-user`**.
3. Click the **Security credentials** tab.
4. Scroll down to the **Access keys** section $\to$ Click **Create access key**.
5. Select **Application running outside AWS** $\to$ Click **Next**.
6. Set Description: `MGN-Agent-Installation-APP01` $\to$ Click **Create access key**.
7. Copy both the **Access Key ID** and **Secret Access Key** (save them in a secure temporary buffer).
8. Click **Done**.

#### Option B: Via AWS CLI Command
```bash
# Generate access key pair
aws iam create-access-key \
  --user-name mgn-installer-user \
  --query 'AccessKey.{AccessKeyId:AccessKeyId,SecretAccessKey:SecretAccessKey}' \
  --output table
```

---

## 5. Phase 3: Install AWS Replication Agent on APP01

Now connect to `APP01` on Azure, download the official AWS Replication Agent installer, and register `APP01` with AWS MGN.

### Step 3.1: Connect to APP01 from HV01

From your workstation or Azure hypervisor `HV01` (`172.173.122.68`):

```bash
# SSH into APP01 from HV01
ssh vagrant@10.10.10.20
# (Password: vagrant)
```

---

### Step 3.2: Verify Pre-Requisites on APP01

Inside `APP01`, verify Python 3 and disk layout:

```bash
# 1. Verify Python 3 is installed
python3 --version

# 2. Inspect root disk to be replicated
lsblk -f
```
*Notice `/dev/vda` is the root disk (`30G`), formatted as `ext4` with `/` mounted.*

---

### Step 3.3: Download the AWS Replication Agent Installer

Download the official AWS Replication Agent installer script directly to `APP01`:

```bash
wget -O ./aws-replication-installer-init.py https://aws-application-migration-service-us-east-1.s3.us-east-1.amazonaws.com/latest/linux/aws-replication-installer-init.py
```

---

### Step 3.4: Run the Agent Installer

You can run the installer interactively or non-interactively using CLI flags.

#### Method 1: Non-Interactive (Recommended for Lab Automation)
```bash
sudo python3 aws-replication-installer-init.py \
  --region us-east-1 \
  --aws-access-key-id <YOUR_AWS_ACCESS_KEY_ID> \
  --aws-secret-access-key <YOUR_AWS_SECRET_ACCESS_KEY> \
  --no-prompt
```

#### Method 2: Interactive Prompt
```bash
sudo python3 aws-replication-installer-init.py
```
When prompted:
1. **AWS Region Name**: Enter `us-east-1`.
2. **AWS Access Key ID**: Paste your Access Key ID.
3. **AWS Secret Access Key**: Paste your Secret Access Key.
4. **Choose disks to replicate**: Press **Enter** to replicate all disks (`/dev/vda`).

**Expected Installer Output:**
```text
The Installation_ID is: c1a8e992-4f12-4d22-9d33-9114f828a211.
Identified volumes for replication: /dev/vda of size 30 GiB
All volumes for replication were successfully mapped to AWS.
Replication Agent was successfully installed.
```

Exit `APP01`:
```bash
exit
```

---

## 6. Phase 4: Monitor Continuous Block-Level Replication

As soon as the agent installer finishes, `APP01` automatically registers with AWS MGN and triggers staging infrastructure creation in AWS!

### Step 4.1: View Source Server in AWS Console

1. In the AWS Management Console, open **Application Migration Service**.
2. In the left navigation menu, click **Source servers**.
3. You will see **`APP01`** (or its IP `10.10.10.20`) in the list!
4. Click on the server name to open its real-time replication dashboard.

---

### Step 4.2: Track Replication Stages

In the **Data replication status** panel, AWS MGN automatically progresses through the following states:

```
[1. Discovered]
      |
      v
[2. Creating replication server] ----> Launches t3.micro in subnet-094426acfea458e5c
      |
      v
[3. Initial Sync (0% -> 100%)]   ----> Copies 30 GiB block volume over IPsec VPN (TCP 1500)
      |
      v
[4. Continuous Data Replication] ----> Lag: 0 seconds | Status: Healthy
      |
      v
[5. Ready for testing]           ----> Lifecycle status turns green!
```

* **Initial Sync**: Takes approximately 10 to 15 minutes over the Site-to-Site VPN for a 30 GiB volume with ~3 GiB used data.
* **Continuous Data Replication**: Once 100% synchronized, any change written on `APP01` is replicated in near real-time (Lag: 0s).
* **Lifecycle State**: Automatically transitions to **`Ready for testing`**.

#### Verify via AWS CLI:
```bash
aws mgn describe-source-servers \
  --region us-east-1 \
  --query 'items[*].{ID:sourceServerID,Hostname:sourceProperties.os.rawOSDescription,DataSync:dataReplicationInfo.dataReplicationState,Lag:dataReplicationInfo.lagDuration,LifeCycle:lifeCycle.state}' \
  --output table
```

---

## 7. Phase 5: Launch & Validate Test Instance (MAP Best Practice)

In enterprise migrations adhering to the **AWS Migration Acceleration Program (MAP)** framework, launching a **Test Instance** is a mandatory gate before production cutover. 

This test verifies that:
* The automated conversion server properly injected AWS NVMe/ENA kernel drivers.
* Ubuntu 24.04 boots natively on AWS hardware.
* Nginx and the Node.js Express service start automatically on boot.
* PostgreSQL queries connect successfully to Amazon RDS over the private subnet.
* Source replication continues in the background with zero impact!

---

### Step 5.1: Launch Test Instance

> [!CRITICAL]
> **Pre-Launch Gate: Ensure Your Launch Template Version is Set as "Default"!**
> When you modify the EC2 Launch Template to specify your private subnet and security group, Amazon EC2 creates a new version (e.g. Version 5). 
> **You MUST promote that version to the Default Version** (`EC2 Console -> Launch Templates -> Actions -> Set default version`). If this step is missed, AWS MGN will boot from Version 2 (which has no subnet specified), causing the instance to launch into the **AWS Default VPC (`172.31.x.x`)** instead of your landing zone VPC (`10.20.0.0/16`)!

> [!NOTE]
> **Wait for Snapshot Finalization**: 
> Immediately after initial sync hits 100%, AWS MGN creates a point-in-time baseline snapshot (`CREATING_SNAPSHOT`). Wait 1-2 minutes until the server Lifecycle changes from `NOT_READY` to **`Ready for testing`** before clicking Launch.

#### Option A: Via AWS Management Console (Click-by-Click UI)
1. In the AWS MGN Console $\to$ **Source servers** $\to$ Check the box next to **`APP01`**.
2. Click the **Test and cutover** button at the top right $\to$ Click **Launch test instances**.
3. In the confirmation dialog, click **Launch**.
4. The Lifecycle status changes to **`Test in progress`**.

#### Option B: Via AWS CLI Command
```bash
# Retrieve APP01 Source Server ID
SOURCE_SERVER_ID=$(aws mgn describe-source-servers \
  --region us-east-1 \
  --query 'items[0].sourceServerID' \
  --output text)

# Launch test instance (AWS MGN API)
aws mgn start-test \
  --source-server-ids $SOURCE_SERVER_ID \
  --region us-east-1
```

---

### Step 5.2: Monitor Automated Conversion & EC2 Launch

Click the **Alerts and activities** tab on the server details page to observe AWS MGN performing:
1. Snapshot generation of staging EBS volumes.
2. Spin-up of the **AWS Conversion Server**.
3. Driver injection (NVMe, ENA) into the Ubuntu kernel.
4. Creation of the converted target AMI.
5. Launch of the EC2 instance named **`APP01 - Test`** in `subnet-094426acfea458e5c`.

---

### Step 5.3: Verify Test EC2 Instance Reachability & Application Health

1. In the AWS Console, open **Amazon EC2** $\to$ Click **Instances**.
2. Find the instance named **`APP01 - Test`** and copy its **Private IP address** (e.g. `10.20.10.x`).
3. From **`HV01`**, test connectivity over the IPsec VPN:

```bash
# Set test IP variable
TEST_IP="<TEST_INSTANCE_PRIVATE_IP>"

# 1. Ping the test instance over IPsec VPN
ping -c 3 $TEST_IP

# 2. Test StreamFlix API Health
curl -s http://$TEST_IP/api/health | jq .
```

**Expected Health Output:**
```json
{
  "status": "UP",
  "service": "StreamFlix API",
  "host": "APP01",
  "database": "CONNECTED",
  "timestamp": "2026-11-16T..."
}
```

```bash
# 3. Test Movies Catalog
curl -s http://$TEST_IP/api/movies | jq .
```
*Expected: Returns all movies (Inception, The Dark Knight, Interstellar, The Matrix Resurrections) queried from RDS PostgreSQL!*

---

### Step 5.4: Mark as "Ready for Cutover" & Terminate Test Instance

Once testing is validated:

#### Option A: Via AWS Management Console (Click-by-Click UI)
1. In AWS MGN $\to$ **Source servers** $\to$ Select **`APP01`**.
2. Click **Test and cutover** $\to$ Click **Mark as "Ready for cutover"**.
3. Check the confirmation checkbox $\to$ Click **Continue**.
4. In the cleanup dialog, select **Yes, terminate test instance** *(AWS automatically deletes the test instance to avoid unnecessary compute charges)*.
5. The Lifecycle state changes to **`Ready for cutover`**!

#### Option B: Via AWS CLI Command
```bash
# Mark as ready for cutover
aws mgn mark-as-ready-for-cutover \
  --source-server-id $SOURCE_SERVER_ID \
  --region us-east-1

# Terminate the test instance
TEST_INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*Test*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text \
  --region us-east-1)

if [ "$TEST_INSTANCE_ID" != "None" ]; then
  aws ec2 terminate-instances --instance-ids $TEST_INSTANCE_ID --region us-east-1
fi
```

---

## 8. Phase 6: Execute Cutover to Production EC2

Now perform the final cutover during your scheduled maintenance window.

### Step 6.1: Launch Cutover Instance

#### Option A: Via AWS Management Console (Click-by-Click UI)
1. In the AWS MGN Console $\to$ **Source servers** $\to$ Select **`APP01`**.
2. Click **Test and cutover** $\to$ Click **Launch cutover instances**.
3. In the confirmation dialog, click **Launch**.
4. AWS will take the final differential snapshot, apply last-second block updates, convert the volume, and boot your final **Production EC2 Instance**!

#### Option B: Via AWS CLI Command
```bash
aws mgn start-cutover \
  --source-server-ids $SOURCE_SERVER_ID \
  --region us-east-1
```

---

### Step 6.2: Retrieve Production EC2 Instance ID and Private IP

Wait until the cutover instance is running:

```bash
# Retrieve Cutover Instance ID and Private IP
CUTOVER_INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=*Cutover*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text \
  --region us-east-1)

CUTOVER_PRIVATE_IP=$(aws ec2 describe-instances \
  --instance-ids $CUTOVER_INSTANCE_ID \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text \
  --region us-east-1)

echo "Cutover EC2 Instance ID: $CUTOVER_INSTANCE_ID"
echo "Cutover EC2 Private IP:  $CUTOVER_PRIVATE_IP"

# Tag the instance cleanly as streamflix-app-ec2
aws ec2 create-tags \
  --resources $CUTOVER_INSTANCE_ID \
  --tags Key=Name,Value=streamflix-app-ec2 Key=Environment,Value=Production Key=Project,Value=StreamFlix \
  --region us-east-1
```

---

### Step 6.3: Finalize Cutover

Once the cutover instance is validated:

#### Option A: Via AWS Management Console (Click-by-Click UI)
1. In AWS MGN $\to$ **Source servers** $\to$ Select **`APP01`**.
2. Click **Test and cutover** $\to$ Click **Finalize cutover**.
3. Confirm by clicking **Finalize**.

#### Option B: Via AWS CLI Command
```bash
aws mgn finalize-cutover \
  --source-server-id $SOURCE_SERVER_ID \
  --region us-east-1
```

**What Finalize Cutover does:**
* Transitions the server Lifecycle state to **`Cutover complete`**.
* Automatically terminates the replication server and deletes staging EBS volumes, **stopping ongoing replication costs**.
* Permanently decouples the target EC2 instance as an independent production server.

---

## 9. Phase 7: Application Load Balancer (ALB) Setup & Production Target Registration

To make the private EC2 instance accessible to end users, deploy an internet-facing **Application Load Balancer** in your public subnets (`subnet-0f17c60078c74fc05` and `subnet-018c04fd8f2edcd6e`) and register the migrated EC2 instance.

### Step 7.1: Create ALB Security Group

#### Option A: Via AWS Management Console (Click-by-Click UI)
1. In the AWS Console, search for **VPC** $\to$ Click **Security groups** in the left menu.
2. Click **Create security group**:
   * **Security group name**: `streamflix-alb-sg`.
   * **Description**: `Security group for public StreamFlix Application Load Balancer`.
   * **VPC**: Select `streamflix-target-vpc` (`vpc-0eacb09847d857983`).
   * **Inbound rules**:
     * Rule 1: Type: **HTTP** | Port: `80` | Source: `Anywhere-IPv4` (`0.0.0.0/0`).
     * Rule 2: Type: **HTTPS** | Port: `443` | Source: `Anywhere-IPv4` (`0.0.0.0/0`).
3. Click **Create security group**.

#### Option B: Via AWS CLI Command
```bash
ALB_SG_ID=$(aws ec2 create-security-group \
  --group-name streamflix-alb-sg \
  --description "Security group for public StreamFlix ALB" \
  --vpc-id vpc-0eacb09847d857983 \
  --query 'GroupId' \
  --output text \
  --region us-east-1)

# Allow HTTP Port 80 from everywhere
aws ec2 authorize-security-group-ingress \
  --group-id $ALB_SG_ID \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0 \
  --region us-east-1

# Allow HTTPS Port 443 from everywhere
aws ec2 authorize-security-group-ingress \
  --group-id $ALB_SG_ID \
  --protocol tcp \
  --port 443 \
  --cidr 0.0.0.0/0 \
  --region us-east-1
```

---

### Step 7.2: Authorize Inbound HTTP Traffic from ALB to App Security Group

Ensure `streamflix-target-app-sg` (`sg-0c7841ad581251d1d`) permits HTTP Port 80 traffic originating from `streamflix-alb-sg`:

```bash
aws ec2 authorize-security-group-ingress \
  --group-id sg-0c7841ad581251d1d \
  --protocol tcp \
  --port 80 \
  --source-group $ALB_SG_ID \
  --region us-east-1 2>/dev/null || true
```

---

### Step 7.3: Create Target Group & Register Production EC2

#### Option A: Via AWS Management Console (Click-by-Click UI)
1. In the EC2 Console left navigation, scroll to **Load Balancing** $\to$ Click **Target Groups**.
2. Click **Create target group**:
   * **Target type**: Select **Instances**.
   * **Target group name**: Enter `streamflix-tg-app-ec2`.
   * **Protocol**: **HTTP** | **Port**: `80`.
   * **VPC**: Select `streamflix-target-vpc` (`vpc-0eacb09847d857983`).
   * **Health checks**:
     * Health check protocol: **HTTP**.
     * Health check path: Enter `/api/health`.
3. Click **Next**.
4. **Register targets**:
   * Check the box next to your migrated production EC2 instance (`streamflix-app-ec2`).
   * Port: `80`.
   * Click **Include as pending below**.
5. Click **Create target group**.

#### Option B: Via AWS CLI Command
```bash
# 1. Create Target Group
TG_APP_ARN=$(aws elbv2 create-target-group \
  --name streamflix-tg-app-ec2 \
  --protocol HTTP \
  --port 80 \
  --vpc-id vpc-0eacb09847d857983 \
  --target-type instance \
  --health-check-path "/api/health" \
  --health-check-interval-seconds 15 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 2 \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text \
  --region us-east-1)

# 2. Register Migrated EC2 Instance
aws elbv2 register-targets \
  --target-group-arn $TG_APP_ARN \
  --targets Id=$CUTOVER_INSTANCE_ID,Port=80 \
  --region us-east-1
```

---

### Step 7.4: Deploy Application Load Balancer

#### Option A: Via AWS Management Console (Click-by-Click UI)
1. In the EC2 Console left navigation, click **Load Balancers** $\to$ Click **Create load balancer**.
2. Under **Application Load Balancer**, click **Create**.
3. **Basic configuration**:
   * Load balancer name: `streamflix-alb`.
   * Scheme: **Internet-facing**.
   * IP address type: **IPv4**.
4. **Network mapping**:
   * VPC: Select `streamflix-target-vpc` (`vpc-0eacb09847d857983`).
   * Subnets (Select both public subnets):
     * Zone `us-east-1a`: Select `subnet-0f17c60078c74fc05` (`streamflix-target-public-1a`).
     * Zone `us-east-1b`: Select `subnet-018c04fd8f2edcd6e` (`streamflix-target-public-1b`).
5. **Security groups**:
   * Select `streamflix-alb-sg`.
6. **Listeners and routing**:
   * Protocol: **HTTP** | Port: `80`.
   * Default action: Forward to **`streamflix-tg-app-ec2`**.
7. Click **Create load balancer**.

#### Option B: Via AWS CLI Command
```bash
# 1. Create Application Load Balancer
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name streamflix-alb \
  --subnets subnet-0f17c60078c74fc05 subnet-018c04fd8f2edcd6e \
  --security-groups $ALB_SG_ID \
  --scheme internet-facing \
  --type application \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text \
  --region us-east-1)

# 2. Create HTTP Port 80 Listener
aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTP \
  --port 80 \
  --default-actions Type=forward,TargetGroupArn=$TG_APP_ARN \
  --region us-east-1
```

---

## 10. Phase 8: Live End-to-End Application Verification 🎬

Now verify that the Application Load Balancer routes traffic to the migrated EC2 instance and validates the full application stack!

### Step 8.1: Check Target Health in Target Group

Wait 30-45 seconds for initial health checks to complete:

```bash
aws elbv2 describe-target-health \
  --target-group-arn $TG_APP_ARN \
  --query 'TargetHealthDescriptions[*].{Id:Target.Id,Port:Target.Port,State:TargetHealth.State,Reason:TargetHealth.Reason}' \
  --output table \
  --region us-east-1
```
*Expected: State displays **`healthy`**!*

---

### Step 8.2: Retrieve Public ALB DNS Name & Test API Endpoints

```bash
# Get ALB DNS name
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names streamflix-alb \
  --query 'LoadBalancers[0].DNSName' \
  --output text \
  --region us-east-1)

echo "Application Load Balancer URL: http://$ALB_DNS"

# 1. Test Health endpoint through public ALB
curl -s http://$ALB_DNS/api/health | jq .
```

**Expected Output:**
```json
{
  "status": "UP",
  "service": "StreamFlix API",
  "host": "APP01",
  "database": "CONNECTED",
  "timestamp": "2026-11-16T..."
}
```

```bash
# 2. Test Movies Catalog endpoint through public ALB
curl -s http://$ALB_DNS/api/movies | jq .
```

**Expected Output:**
```json
[
  {
    "id": 1,
    "title": "Inception",
    "release_year": 2010,
    "genre": "Sci-Fi",
    "rating": "8.8",
    "poster_url": "https://d1u8bkpbx2mtpm.cloudfront.net/posters/inception.jpg",
    "video_url": "https://d1u8bkpbx2mtpm.cloudfront.net/trailers/inception.mp4"
  },
  {
    "id": 2,
    "title": "The Dark Knight",
    "release_year": 2008,
    "genre": "Action",
    "rating": "9.0",
    "poster_url": "https://d1u8bkpbx2mtpm.cloudfront.net/posters/dark-knight.jpg",
    "video_url": "https://d1u8bkpbx2mtpm.cloudfront.net/trailers/dark-knight.mp4"
  },
  {
    "id": 3,
    "title": "Interstellar",
    "release_year": 2014,
    "genre": "Sci-Fi",
    "rating": "8.6",
    "poster_url": "https://d1u8bkpbx2mtpm.cloudfront.net/posters/interstellar.jpg",
    "video_url": "https://d1u8bkpbx2mtpm.cloudfront.net/trailers/interstellar.mp4"
  },
  {
    "id": 4,
    "title": "The Matrix Resurrections",
    "release_year": 2021,
    "genre": "Sci-Fi",
    "rating": "5.7",
    "poster_url": "https://d1u8bkpbx2mtpm.cloudfront.net/posters/matrix.jpg",
    "video_url": "https://d1u8bkpbx2mtpm.cloudfront.net/trailers/matrix.mp4"
  }
]
```

---

### Step 8.3: Open the Web UI in Your Browser 🌐

Open your laptop browser and navigate to:
```text
http://<YOUR_ALB_DNS_NAME>
```

**Verification Checklist:**
1. **React UI**: The StreamFlix application interface loads smoothly.
2. **Dynamic Database Loading**: The 4 movies load dynamically from the migrated EC2 instance querying **Amazon RDS PostgreSQL**.
3. **CloudFront CDN Assets**: Movie posters and UI thumbnails load with edge caching from `d1u8bkpbx2mtpm.cloudfront.net`.
4. **Video Streaming**: Click any movie card to stream high-definition MP4 video via CloudFront HTTP 206 partial range requests!

---

## 11. Phase 9: Verification Checklist, Rollback Runbook & RCA Guide

### 11.1: Migration Verification Checklist

| # | Check Item | Verification Command / UI Location | Expected Result | Status |
| :-: | :--- | :--- | :--- | :-: |
| 1 | **Replication Agent** | `sudo python3 aws-replication-installer-init.py` | `Installation successful` | [ ] |
| 2 | **Source Server in MGN** | AWS MGN Console $\to$ Source servers | `APP01` visible and active | [ ] |
| 3 | **Data Replication** | AWS MGN Console $\to$ Replication status | `Healthy`, Lag: `0 seconds` | [ ] |
| 4 | **Test Instance Launch** | AWS MGN $\to$ Launch test instances | `APP01 - Test` boots in private subnet | [ ] |
| 5 | **Test Validation** | `curl http://<TEST_IP>/api/health` | `database: "CONNECTED"` | [ ] |
| 6 | **Ready for Cutover** | AWS MGN Lifecycle status | `Ready for cutover` | [ ] |
| 7 | **Production Cutover** | AWS MGN $\to$ Launch cutover instances | Production EC2 instance running | [ ] |
| 8 | **ALB Ingress** | EC2 Console $\to$ Load Balancers | Status: `active` | [ ] |
| 9 | **Target Group Health** | `aws elbv2 describe-target-health` | State: `healthy` | [ ] |
| 10| **Full Application Test**| Open `http://<ALB_DNS>` in Chrome | React UI & CloudFront streaming active | [ ] |

---

### 11.2: Rollback Runbook (Zero Data Loss)

Because AWS MGN operates through **read-only, non-destructive block-level replication**:
1. The on-premises source virtual machine `APP01` on Azure was **never modified, halted, or corrupted**.
2. **Instant Rollback**: If any unexpected issue occurs during cutover, immediately route user DNS or traffic back to the on-premises IP (`172.173.122.68` / `APP01`).
3. Clean up AWS resources if rolling back:
   ```bash
   # Deregister target from ALB
   aws elbv2 deregister-targets --target-group-arn $TG_APP_ARN --targets Id=$CUTOVER_INSTANCE_ID --region us-east-1

   # Stop or terminate cutover EC2 instance
   aws ec2 terminate-instances --instance-ids $CUTOVER_INSTANCE_ID --region us-east-1
   ```

---

### 11.3: Real-World Post-Mortem & Root Cause Analysis (Where Things Went Wrong & How to Fix Them)

During live migration execution, several subtle enterprise failure modes were encountered. Below is the comprehensive post-mortem detailing the exact error symptoms, underlying root causes, and definitive resolutions.

---

#### Pitfall 1: Replication Stalled with `FAILED_TO_LAUNCH_REPLICATION_SERVER` (`iam:PassRole` UnauthorizedOperation)

* **Symptom**:
  After installing the agent on `APP01`, the server appeared in AWS MGN with state **`STALLED`**. In the Data replication initiation steps, `CREATE_SECURITY_GROUP` succeeded, but **`LAUNCH_REPLICATION_SERVER` failed** with error: `FAILED_TO_LAUNCH_REPLICATION_SERVER`.
* **CloudTrail Error**:
  ```json
  {
    "eventSource": "ec2.amazonaws.com",
    "eventName": "RunInstances",
    "errorCode": "Client.UnauthorizedOperation",
    "errorMessage": "You are not authorized to perform this operation. User: arn:aws:sts::165772574557:assumed-role/AWSServiceRoleForApplicationMigrationService/... is not authorized to perform: iam:PassRole on resource: arn:aws:iam::165772574557:role/AWSApplicationMigrationReplicationServerRole because no identity-based policy allows the iam:PassRole action."
  }
  ```
* **Root Cause Analysis (RCA)**:
  AWS MGN's AWS-managed service policy (`AWSApplicationMigrationServiceRolePolicy`) strictly restricts `iam:PassRole` to roles with the path prefix `/service-role/`:
  ```json
  "Resource": [
    "arn:aws:iam::*:role/service-role/AWSApplicationMigrationReplicationServerRole",
    "arn:aws:iam::*:role/service-role/AWSApplicationMigrationConversionServerRole"
  ]
  ```
  The IAM role in the account had been manually created under the root path `/` (`arn:aws:iam::...:role/AWSApplicationMigrationReplicationServerRole`). Because the ARN lacked `/service-role/`, the IAM policy engine denied the `iam:PassRole` call during `ec2:RunInstances`.
* **Resolution**:
  Recreate the roles with `--path /service-role/` and associate them with their instance profiles:
  ```bash
  # Delete and recreate with /service-role/ path
  aws iam remove-role-from-instance-profile --instance-profile-name AWSApplicationMigrationReplicationServerRole --role-name AWSApplicationMigrationReplicationServerRole
  aws iam delete-role --role-name AWSApplicationMigrationReplicationServerRole

  aws iam create-role --path /service-role/ --role-name AWSApplicationMigrationReplicationServerRole \
    --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
  aws iam attach-role-policy --role-name AWSApplicationMigrationReplicationServerRole --policy-arn arn:aws:iam::aws:policy/service-role/AWSApplicationMigrationReplicationServerPolicy
  aws iam add-role-to-instance-profile --instance-profile-name AWSApplicationMigrationReplicationServerRole --role-name AWSApplicationMigrationReplicationServerRole
  ```

---

#### Pitfall 2: Replication Server Stuck at `AUTHENTICATE_WITH_SERVICE` (No Internet Route in Private Staging Subnet)

* **Symptom**:
  The Replication Server launched and booted in private app subnet `subnet-094426acfea458e5c`, but initiation remained permanently in progress at **`AUTHENTICATE_WITH_SERVICE: IN_PROGRESS`** and never advanced to `DOWNLOAD_REPLICATION_SOFTWARE`.
* **Root Cause Analysis (RCA)**:
  When the Replication Server boots, it requires outbound HTTPS (Port 443) access to:
  1. The AWS MGN regional API endpoint (`mgn.us-east-1.amazonaws.com`) to authenticate.
  2. Amazon S3 (`s3.us-east-1.amazonaws.com`) to download replication software.
  Because the landing zone private application subnet has **no NAT Gateway** (deployed without NAT to minimize lab costs), all outbound internet traffic was black-holed.
* **Resolution**:
  Configure the **Staging Subnet** to use the public subnet (`subnet-0f17c60078c74fc05`) with `createPublicIP: true` (giving the temporary replication server egress through the Internet Gateway), while maintaining **`dataPlaneRouting: PRIVATE_IP`**:
  * **Control Plane Egress**: The Replication Server reaches `mgn.us-east-1.amazonaws.com` via the Internet Gateway.
  * **Data Plane Security**: The replication block stream (TCP port 1500) routes securely across the private StrongSwan IPsec VPN tunnel (`10.10.0.0/16 <-> 10.20.0.0/16`).
  * Enable VGW route propagation on the public route table (`rtb-09f58b24d7bcf61c0`) so the replication server can route return packets back to on-prem `10.10.0.0/16`.

---

#### Pitfall 3: "Cannot Launch Test Instances" Error (`ApiNotAllowedForThisState: SourceServer.lifeCycle.state is NOT_READY`)

* **Symptom**:
  Immediately after the initial 64 GB data copy reached 100%, clicking **Launch test instances** failed with a popup:
  > *"This action cannot be performed on the selected server because you can only launch test instances for servers whose lifecycle state is 'Ready for test launch'."*
* **API Error**:
  ```json
  {
    "code": "ApiNotAllowedForThisState",
    "message": "You cannot call StartTest when SourceServer.lifeCycle.state is NOT_READY"
  }
  ```
* **Root Cause Analysis (RCA)**:
  Although data block transfer was 100% complete, AWS MGN was actively creating the **point-in-time baseline EBS snapshot** (`snap-09e93a9e62796c736` / `snap-07dadfacebb6bce2b`). During the `CREATING_SNAPSHOT` stage, the lifecycle state remains `NOT_READY`. AWS strictly prevents launching test instances until the snapshot has reached `100% completed` to avoid corrupt or incomplete volume conversions.
* **Resolution**:
  Wait 1 to 2 minutes for the EBS snapshot state to transition to `completed`. Once verified, the lifecycle state automatically turns green (**`Ready for testing`**), unlocking the **Launch test instances** button.

---

#### Pitfall 4: Test Instance Booted into the Wrong VPC (AWS Default VPC `172.31.x.x` Instead of Landing Zone VPC `10.20.x.x`)

* **Symptom**:
  The test instance launched successfully, but was assigned private IP `172.31.6.25` in `subnet-0e3daac08f57e1830` in the **AWS Default VPC** (`vpc-0d7dfc3c42d0f39c0`), with no SSH key pair (`KeyName: null`) and default security group. The server was completely unreachable from `HV01` over the VPN and could not access the Amazon RDS database.
* **Root Cause Analysis (RCA)**:
  The engineer correctly created updated versions (Version 4 and Version 5) in EC2 Launch Template `lt-0484d4fc7d27143eb` with the target private app subnet, security group `sg-0c7841ad581251d1d`, and key pair `CloudForge`.
  **However, Version 2 was still set as the "Default Version" in EC2!**
  In AWS EC2, services launch from the **Default Version** unless explicitly specified. Because Version 2 was the default and had no `SubnetId` defined, AWS EC2 fell back to launching the instance in the account's Default VPC!
* **Resolution & Re-Test Procedure**:
  1. **Promote the New Version to Default**:
     In EC2 Console $\to$ **Launch Templates** $\to$ select `lt-0484d4fc7d27143eb` $\to$ click **Actions** $\to$ **Set default version** $\to$ choose **Version 5** $\to$ **Set as default version**.
     ```bash
     aws ec2 modify-launch-template \
       --launch-template-id lt-0484d4fc7d27143eb \
       --default-version 5 \
       --region us-east-1
     ```
  2. **Revert the Bad Test Launch**:
     In AWS MGN Console $\to$ **Source servers** $\to$ select `APP01` $\to$ click **Test and cutover** $\to$ click **Revert to "Ready for testing"**.
     *(AWS MGN automatically terminates instance `i-02ca6e61261f78bc1` in the default VPC and resets the lifecycle state to `Ready for testing`)*.
  3. **Re-launch Test Instance**:
     Click **Test and cutover** $\to$ **Launch test instances**. The instance will now boot directly in `subnet-0d7fc76b1b17050f0` (`10.20.11.x`), attached to `sg-0c7841ad581251d1d`, with full VPN and RDS reachability!

---

#### Pitfall 5: Launch Template Settings Were Uneditable Before Adding Server

* **Symptom**:
  Navigating to AWS MGN $\to$ **Settings** $\to$ **Launch template** showed a disabled or missing configuration where settings could not be edited directly.
* **Root Cause Analysis (RCA)**:
  AWS MGN creates replication configuration templates automatically upon region initialization, but does **not** create a global account-level Launch Configuration Template (`lct-...`) by default. Furthermore, server-specific launch templates are only generated once a source server agent registers.
* **Resolution**:
  In standard AWS migration practice, always **install the replication agent on the source server first**. Once `APP01` appears under **Source servers**, AWS MGN auto-generates a dedicated Launch Template for that server, accessible under **Source servers** $\to$ **`APP01`** $\to$ **Launch settings**.
