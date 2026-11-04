# Stage 5: Enterprise Server Rehost Manual Runbook — Migrating APP01 to Amazon EC2 using AWS Application Migration Service (AWS MGN)
**Document ID**: RUNBOOK-STAGE5-REHOST-MGN-EC2-20261104  
**Target Audience**: Cloud Migration Engineers, Solutions Architects, Infrastructure Leads  
**Lab Context**: Enterprise Cloud Migration Lab (StreamFlix Application Server Rehost)  
**Strategy**: Automated Block-Level Server Rehost (Lift-and-Shift) via AWS Application Migration Service (AWS MGN)  
**UI Focus**: Dual Click-by-Click AWS Management Console & Terminal CLI Instructions  

---

## 1. Architectural Overview & Migration Lifecycle

You are completely right: in an enterprise cloud migration, a true **Rehost (Lift-and-Shift)** does **not** mean manually reinstalling an operating system and copying files. 

An enterprise Rehost uses **AWS Application Migration Service (AWS MGN)** (formerly CloudEndure Migration), AWS's primary automated server migration technology:
* The **AWS Replication Agent** is installed on the live on-premises server (`APP01` on Azure/KVM, `10.10.10.20`).
* The agent performs **non-disruptive, block-level data replication** over the encrypted IPsec VPN bridge (`10.10.0.0/16 <-> 10.20.0.0/16`) into a private staging area in AWS.
* After the initial copy, AWS MGN continuously captures and streams every block change in real time (**Continuous Data Replication** with zero lag).
* An automated **Conversion Server** injects AWS NVMe/ENA hypervisor drivers and converts the KVM disks into native Amazon EBS volumes.
* You launch and validate a **Test Instance** in AWS without interrupting the live on-premises application.
* During the final maintenance window, you perform **Cutover** to launch the production EC2 instance, register it with the **Application Load Balancer (ALB)**, and finalize the migration.

```
+--------------------------------------------------------------------------------------------------------------------------+
| ON-PREMISES DATACENTER (AZURE)                             | TARGET MIGRATION LANDING ZONE (AWS)                         |
| Source Server: APP01 (10.10.10.20)                         | Target VPC: vpc-020d6b01e57048985 (10.20.0.0/16)            |
| Operating System: Ubuntu 24.04 LTS                         | Region: us-east-1                                           |
| Disks: /dev/vda (Root Volume)                              |                                                             |
|                                                            |                                                             |
| +--------------------------------------------------------+ | +---------------------------------------------------------+ |
| | Source VM: APP01 (10.10.10.20)                         | | | AWS MGN Staging Area (Subnet: 10.20.10.0/24)             | |
| |  * Running Web & API Workloads                         | | |                                                         | |
| |  * [AWS Replication Agent]                             | | |  [Lightweight Replication Server: t3.micro]             | |
| |        |                                               | | |  * Attached Staging EBS Volumes (gp3)                   | |
| +--------+-----------------------------------------------+ | +---------------------------------------------------------+ |
|          |                                                 |                              |                              |
|          | Block-Level Replication (TCP 1500 Over IPsec)   |                              | Snapshot & Driver Injection  |
|          v                                                 |                              v                              |
|   [StrongSwan IPsec Daemon]                                |                   [AWS Conversion Server]                   |
|      (on HV01 Host)                                        |                              |                              |
|          |                                                 |                              v                              |
|          +=================================================+ | +---------------------------------------------------------+ |
|                      Encrypted IPsec VPN Bridge              | | TARGET EC2 LAUNCH SUBNET (10.20.10.0/24 - Private):     | |
|                      Route: 10.10.0.0/16 <-> 10.20.0.0/16    | |                                                         | |
|                                                              | |  [Migrated Production EC2 Instance: APP01]              | |
|                                                              | |   * Exact bit-for-bit replica of on-prem APP01          | |
|                                                              | |   * Converted to AWS EC2 native drivers                 | |
|                                                              | |   * Protected behind Application Load Balancer          | |
|                                                              | |   * Connected to Target Amazon RDS PostgreSQL           | |
|                                                              | |   * Connected to Target CloudFront Media CDN            | |
|                                                              | +---------------------------------------------------------+ |
+--------------------------------------------------------------------------------------------------------------------------+
```

---

### Parameter Reference Table

| Component | Parameter | Value | Description |
| :--- | :--- | :--- | :--- |
| **Source Server** | Hostname / IP | `APP01` / `10.10.10.20` | On-premises Linux KVM VM on Azure |
| **Source OS** | Operating System | Ubuntu 24.04 LTS (x86_64) | Source application host |
| **Target VPC** | VPC ID | `vpc-020d6b01e57048985` | Landing Zone Target VPC (`10.20.0.0/16`) |
| **Staging Subnet** | Subnet ID | `subnet-0f94155d4f2a9ffda` | `streamflix-target-app-private-1a` (`10.20.10.0/24`) |
| **Target Subnet** | Subnet ID | `subnet-0f94155d4f2a9ffda` | Subnet where migrated EC2 will boot |
| **Security Group** | App Security Group | `sg-075c2521b1372d1a5` | `streamflix-target-app-sg` |
| **Replication Port**| TCP Port | `1500` | Port used by AWS MGN agent to stream blocks |
| **Replication Type**| Disk Staging Type | `gp3` (Standard) | Cost-effective EBS volume staging |
| **IAM Installer User**| Username | `mgn-installer-user` | Dedicated identity for agent installation |
| **IAM Policy** | Attached Policy | `AWSApplicationMigrationAgentInstallationPolicy` | Least-privilege agent permissions |
| **Target EC2 Class**| Instance Type | `t3.micro` or `t3.small` | Sizing for migrated server |
| **Target Database** | Target RDS Endpoint | From Stage 3 | `streamflix-target-db` |
| **Target CDN** | CloudFront Domain | From Stage 4 | Media CDN endpoint |

---

## 2. Phase 1: Initialize AWS Application Migration Service (AWS MGN)

When using AWS MGN for the first time in an AWS account, you must initialize the service and configure the **Replication Settings Template** that defines where staging resources live.

### Step 1.1: Initialize AWS MGN in the Console

1. In the AWS Management Console search bar at the top, type **Application Migration Service** and click on it.
2. If this is the first time opening the service, you will see a welcome screen. Click the orange **Get started** button.
   *(AWS automatically configures the required service-linked roles).*

---

### Step 1.2: Configure Replication Settings Template

1. In the left navigation menu of AWS MGN, click **Settings** $\to$ Click the **Replication template** tab.
2. Click the **Edit** button on the right.
3. **Staging area subnets**:
   * VPC: Select `streamflix-target-vpc` (`vpc-020d6b01e57048985`).
   * Subnet: Select `subnet-0f94155d4f2a9ffda` (`streamflix-target-app-private-1a`).
4. **Replication Servers security group**:
   * Select `streamflix-target-app-sg` (`sg-075c2521b1372d1a5`).
5. **Staging disk type**:
   * Select **Standard (gp3)**.
6. **Data routing**:
   * Select **Use private IP (VPN, DirectConnect, or VPC peering)** *(This routes replication traffic securely across your IPsec VPN tunnel without touching the public internet!)*.
7. Click **Save template**.

---

### Step 1.3: Configure Default EC2 Launch Template Settings
AWS MGN uses an Amazon EC2 Launch Template to determine the instance class and networking of your migrated server.

1. In the AWS MGN left navigation, click **Settings** $\to$ Click the **Launch template** tab.
2. Click **Modify launch template**:
   * **Instance type**: Select `t3.micro` (or `t3.small`).
   * **Key pair**: Select your lab key pair (e.g. `CloudForge`).
   * **Network settings**:
     * Subnet: Select `subnet-0f94155d4f2a9ffda` (`streamflix-target-app-private-1a`).
     * Security groups: Select `streamflix-target-app-sg` (`sg-075c2521b1372d1a5`).
     * Auto-assign public IP: **Disable** *(Keeps the server securely private)*.
3. Click **Save launch template**.

---

## 3. Phase 2: Create Agent Installation Credentials

The AWS Replication Agent running on `APP01` needs credentials with permissions to communicate with AWS MGN.

### Step 2.1: Generate Access Key for `mgn-installer-user`

We already created the dedicated IAM user `mgn-installer-user` with the `AWSApplicationMigrationAgentInstallationPolicy` policy attached.

Now generate an Access Key for this user:

#### Option A: Via AWS Management Console (Click-by-Click UI)
1. In the AWS Console, search for **IAM** $\to$ Click **Users** in the left menu.
2. Click on **`mgn-installer-user`**.
3. Click on the **Security credentials** tab.
4. Scroll down to **Access keys** $\to$ Click **Create access key**.
5. Select **Application running outside AWS** $\to$ Click **Next**.
6. Description tag value: Enter `MGN-Agent-APP01` $\to$ Click **Create access key**.
7. **Copy both the Access Key ID and Secret Access Key** (save them in a safe temporary notepad).

#### Option B: Via AWS CLI Command
```bash
aws iam create-access-key \
  --user-name mgn-installer-user \
  --query 'AccessKey.{AccessKeyId:AccessKeyId,SecretAccessKey:SecretAccessKey}' \
  --output table
```

---

## 4. Phase 3: Install AWS Replication Agent on APP01

Now connect to `APP01` on Azure, download the official AWS Replication Agent installer, and register `APP01` with AWS MGN.

### Step 3.1: Connect to APP01
From your workstation or HV01 terminal:

```bash
# Connect to APP01
ssh -i /home/labadmin/Enterprise_Cloud_Migration_Lab/stage-1/vagrant/app01/.vagrant/machines/default/libvirt/private_key vagrant@10.10.10.20
```

---

### Step 3.2: Download the AWS Replication Agent Installer
Inside **`APP01`**:

```bash
# Download the installer script directly from AWS S3
wget -O ./aws-replication-installer-init.py https://aws-application-migration-service-us-east-1.s3.us-east-1.amazonaws.com/latest/linux/aws-replication-installer-init.py
```

---

### Step 3.3: Run the Agent Installer
Execute the installer with root privileges:

```bash
sudo python3 aws-replication-installer-init.py
```

The interactive installer will ask you 3 questions:
1. **AWS Region Name**: Enter `us-east-1`.
2. **AWS Access Key ID**: Paste the Access Key ID created in Step 2.1.
3. **AWS Secret Access Key**: Paste the Secret Access Key created in Step 2.1.
4. **Choose disks to replicate**: Press **Enter** to select all disks (e.g. `/dev/vda`).

**Expected Installer Output:**
```text
The Installation_ID is: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx.
Identified volumes for replication: /dev/vda of size 30 GiB
All volumes for replication were successfully mapped to AWS.
Replication Agent was successfully installed.
```

Exit `APP01`:
```bash
exit
```

---

## 5. Phase 4: Monitor Continuous Block-Level Replication

As soon as the agent is installed, `APP01` automatically appears in the AWS MGN Management Console!

### Step 4.1: View Source Server in AWS Console

1. In the AWS Management Console, open **Application Migration Service**.
2. In the left navigation menu, click **Source servers**.
3. You will see **`APP01`** (or its IP `10.10.10.20`) listed in the table!
4. Click on the server name to open its details page.

---

### Step 4.2: Watch the Replication Lifecycle Progress

In the **Data replication status** dashboard, watch the automated stages:

```
[1. Agent Installed] ---> [2. Initial Sync: 0% to 100%] ---> [3. Continuous Data Replication]
                                                               (Lag: 0 seconds)
                                                               Status: Healthy
```

* **Initial sync**: AWS MGN creates a temporary `t3.micro` replication server in your private staging subnet and copies the 30 GiB disk over the IPsec VPN.
* **Continuous data replication**: Once 100% of the disk is copied, the status changes to:
  * **Data replication status**: `Healthy`
  * **Replication lag**: `0 seconds` (or real-time)
  * **Lifecycle**: **`Ready for testing`**!

> [!NOTE]
> For a 30 GiB disk with ~3 GiB of actual data, the initial sync over the VPN typically takes **10 to 15 minutes**. While it replicates, `APP01` remains 100% active and running on Azure with zero downtime!

---

## 6. Phase 5: Launch Test Instance & Verification (MAP Standard Step)

In enterprise cloud migrations following the AWS Migration Acceleration Program (MAP) methodology, you **NEVER cut over without launching a Test Instance first**.

Launching a test instance allows you to verify that the converted EC2 instance boots properly, all services start, and database connectivity works—**without affecting the live source server or stopping replication**.

### Step 5.1: Launch Test Instance in AWS MGN Console

1. In the **Source servers** list, check the box next to **`APP01`**.
2. Click the **Test and cutover** button at the top right $\to$ Click **Launch test instances**.
3. Confirm by clicking **Launch**.

---

### Step 5.2: Monitor the Automated Conversion Process
Click the **Alerts and activities** tab on the server page to watch AWS perform the automated conversion:
1. AWS takes a point-in-time EBS snapshot of the replicated volume.
2. An automated **Conversion Server** boots, attaches the volume, injects AWS NVMe, ENA, and Xen kernel drivers into Ubuntu, and creates an Amazon Machine Image (AMI).
3. AWS launches a new `t3.micro` EC2 instance in `subnet-0f94155d4f2a9ffda` using the Launch Template.
4. The Lifecycle status changes to: **`Test in progress`**.

---

### Step 5.3: Verify the Test EC2 Instance
1. In the AWS Console, open **Amazon EC2** $\to$ Click **Instances**.
2. You will see a newly launched instance named **`APP01 - Test`**!
3. Note its **Private IP address** (e.g. `10.20.10.x`).
4. From **`HV01`**, test connectivity over the IPsec VPN:
   ```bash
   # Ping the test instance
   ping -c 3 <TEST_INSTANCE_PRIVATE_IP>

   # Test StreamFlix API health on the test instance
   curl -s http://<TEST_INSTANCE_PRIVATE_IP>/api/health | jq .

   # Test Movies catalog on the test instance
   curl -s http://<TEST_INSTANCE_PRIVATE_IP>/api/movies | jq .
   ```
5. Verify that:
   * Status is **`UP`**.
   * Database is **`CONNECTED`** (pointing to RDS).
   * All on-premises files, packages, and configurations are 100% preserved!

---

### Step 5.4: Mark as Ready for Cutover & Clean Up Test Instance
Once testing is successful:

1. Return to **Application Migration Service** $\to$ **Source servers** $\to$ Select **`APP01`**.
2. Click **Test and cutover** $\to$ Click **Mark as "Ready for cutover"**.
3. Check the box to confirm that you have tested the instance $\to$ Click **Continue**.
4. A prompt will ask whether to terminate the test instance. Click **Yes, terminate test instance** *(AWS automatically deletes the test instance to keep your account clean and avoid charges)*.
5. The Lifecycle status changes to: **`Ready for cutover`**!

---

## 7. Phase 6: Execute Cutover to Production EC2

Now you perform the final cutover during your maintenance window.

### Step 6.1: Launch Cutover Instance in AWS MGN Console

1. In the **Source servers** list, select **`APP01`**.
2. Click **Test and cutover** $\to$ Click **Launch cutover instances**.
3. Click **Launch**.

AWS will take the final differential snapshot, convert the volume with any last-second block updates, and boot your final **Production EC2 Instance**!

---

### Step 6.2: Finalize Cutover
Once the Cutover instance status is running and verified:

1. In **Source servers**, select **`APP01`**.
2. Click **Test and cutover** $\to$ Click **Finalize cutover**.
3. Confirm by clicking **Finalize**.

**What Finalize Cutover does:**
* Changes the Lifecycle state to **`Cutover complete`**.
* Automatically terminates the temporary replication server and deletes the staging disks to **stop all ongoing replication charges**.
* The newly migrated EC2 instance is now an independent, native AWS production server!

---

## 8. Phase 7: Attach Application Load Balancer & Public Access

Now expose the newly migrated production EC2 instance to the internet through the Application Load Balancer.

### Step 7.1: Register Production EC2 with Target Group

1. In the AWS Console, open **EC2** $\to$ **Instances** $\to$ Copy the **Instance ID** of your migrated production server (`APP01 - Cutover`).
2. Go to **Target Groups** $\to$ Click on **`streamflix-tg-app-ec2`**.
3. Under the **Targets** tab, click **Register targets**.
4. Select the migrated instance $\to$ Ensure Port is `80` $\to$ Click **Include as pending below** $\to$ Click **Register pending targets**.
5. Within 30 seconds, the target health check status will turn green: **`healthy`**!

---

### Step 7.2: Verify Live Application via ALB DNS
1. In the EC2 Console $\to$ **Load Balancers** $\to$ Copy the **DNS name** of `streamflix-alb`.
2. Open your laptop browser and navigate to:
   ```text
   http://<YOUR_ALB_DNS_NAME>
   ```

**Verification:**
1. The **StreamFlix React Web UI** renders in your browser.
2. The movie catalog loads dynamically from the migrated EC2 instance querying RDS PostgreSQL.
3. Movie posters load from **Amazon CloudFront CDN**.
4. Click on any movie card to stream video smoothly via CloudFront HTTP 206 range requests!

---

## 9. Verification Checklist & Success Criteria

| # | Check Item | Verification in UI Console / Terminal | Expected Result | Status |
| :-: | :--- | :--- | :--- | :-: |
| 1 | **Replication Agent** | `sudo python3 aws-replication-installer-init.py` | `Installation successful` | [ ] |
| 2 | **Source Server in MGN**| AWS MGN Console $\to$ Source servers | `APP01` visible | [ ] |
| 3 | **Continuous Replication**| AWS MGN Console $\to$ Replication status | `Healthy`, Lag: 0s | [ ] |
| 4 | **Test Instance Launch** | AWS MGN $\to$ Launch test instances | Test EC2 boots successfully | [ ] |
| 5 | **Test Validation** | `curl http://<TEST_IP>/api/health` | `database: "CONNECTED"` | [ ] |
| 6 | **Ready for Cutover** | Lifecycle status in MGN | `Ready for cutover` | [ ] |
| 7 | **Production Cutover** | AWS MGN $\to$ Launch cutover instances | Production EC2 running | [ ] |
| 8 | **ALB Integration** | EC2 Target Groups | Status: `healthy` | [ ] |
| 9 | **Browser Playback** | Open `http://<ALB_DNS>` in Chrome | React UI & video playback working | [ ] |

---

## 10. Rollback Runbook (In Case of Issues)

If any issue arises during or after cutover:
1. **Source Server Remains Unchanged**: Because AWS MGN performs non-destructive read-only block replication, the original `APP01` virtual machine on Azure was never modified or deleted!
2. To roll back, simply redirect user DNS or test traffic back to the on-premises `APP01` server (`20.29.104.127:80`).
3. Terminate the cutover EC2 instance in AWS.
