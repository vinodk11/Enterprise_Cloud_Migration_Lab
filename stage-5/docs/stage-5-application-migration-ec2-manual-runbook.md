# Stage 5: Application Migration Manual Runbook — StreamFlix Lift-and-Shift to Amazon EC2 & ALB
**Document ID**: RUNBOOK-STAGE5-APP-MIGRATION-EC2-ALB-20261104  
**Target Audience**: Cloud Migration Engineers, Solutions Architects, DevSecOps  
**Lab Context**: Enterprise Cloud Migration Lab (StreamFlix Application Tier)  
**Strategy**: VM-Based Rehost / Lift-and-Shift to Amazon EC2 behind Application Load Balancer  
**UI Focus**: Dual Click-by-Click AWS Management Console & Terminal CLI Instructions  

---

## 1. Architectural Overview & Traffic Flow

In **Stage 5**, you will migrate the core StreamFlix web and application tier from the on-premises virtual machine (`APP01` on Azure) to an **Amazon Elastic Compute Cloud (Amazon EC2)** instance deployed inside your private application subnets, protected by an **Application Load Balancer (ALB)**.

This follows the classic enterprise **Lift-and-Shift / Replatform (IaaS)** migration pattern:
* The EC2 instance mirrors `APP01` (Ubuntu 24.04 LTS, Node.js 18, Express API on Port 5000, Nginx on Port 80).
* The EC2 instance sits securely inside the **private application subnet** (`10.20.10.0/24`) with **no direct public IP**, protecting it from internet threats.
* An internet-facing **Application Load Balancer (ALB)** receives public user traffic on Port 80 and forwards it to the private EC2 instance.
* The application connects directly to the target **Amazon RDS PostgreSQL** database deployed in Stage 3.
* Video streaming and movie poster assets are delivered through the **Amazon CloudFront CDN** deployed in Stage 4.

```
+--------------------------------------------------------------------------------------------------------------------------+
| INTERNET CLIENTS & BROWSERS                                                                                              |
+--------------------------------------------------------------------------------------------------------------------------+
                                          |
                                          | HTTP (Port 80)
                                          v
+--------------------------------------------------------------------------------------------------------------------------+
| TARGET AWS LANDING ZONE: VPC vpc-020d6b01e57048985 (10.20.0.0/16)                                                        |
|                                                                                                                          |
|  [Application Load Balancer: streamflix-alb]                                                                             |
|  Public Subnets: subnet-048d1aa28e96df5fe (10.20.1.0/24) & subnet-0928d6d5c54f3d2a5 (10.20.2.0/24)                      |
|  Security Group: streamflix-alb-sg (Allows Inbound Port 80 from 0.0.0.0/0)                                              |
|                                                                                                                          |
|         | Forward Port 80                                                                                                |
|         v                                                                                                                |
|  [Target Group: streamflix-tg-app-ec2] (Port 80, Health Check: /api/health)                                              |
|         |                                                                                                                |
|         v                                                                                                                |
| +-------+--------------------------------------------------------------------------------------------------------------+ |
| | PRIVATE APPLICATION SUBNET (subnet-0f94155d4f2a9ffda: 10.20.10.0/24 - us-east-1a):                                  | |
| | Security Group: streamflix-target-app-sg (Allows Port 80 from ALB, Port 22 from On-Prem VPN)                          | |
| |                                                                                                                      | |
| |  [Amazon EC2 Instance: streamflix-app-ec2]                                                                            | |
| |   * OS: Ubuntu 24.04 LTS (t3.micro)                                                                                  | |
| |   * Private IP: 10.20.10.x                                                                                           | |
| |   * Nginx Reverse Proxy (Port 80): Serves React Frontend (/var/www/streamflix/frontend/dist)                          | |
| |   * Express.js API (Port 5000): Managed via systemd (streamflix.service)                                              | |
| |   * Environment (.env): Points to Target RDS Endpoint & CloudFront Domain                                            | |
| |                                                                                                                      | |
| +-------+--------------------------------------------------------------------+-----------------------------------------+ |
|         |                                                                    |                                           |
|         | SQL Queries (Port 5432)                                            | Media Streaming (HTTPS)                   |
|         v                                                                    v                                           |
|  [Target Amazon RDS PostgreSQL 16]                                    [Amazon CloudFront CDN / S3]                       |
|  (streamflix-target-db in Isolated DB Subnet)                         (streamflix-media-165772574557)                    |
+--------------------------------------------------------------------------------------------------------------------------+
```

---

### Parameter Reference Table

| Component | Parameter | Value | Description |
| :--- | :--- | :--- | :--- |
| **AWS Region** | Region Name | `us-east-1` | Target AWS Cloud Region |
| **Target VPC ID** | VPC ID | `vpc-020d6b01e57048985` | StreamFlix Landing Zone VPC (`10.20.0.0/16`) |
| **Public Subnets (ALB)**| Subnet 1a / 1b | `subnet-048d1aa28e96df5fe` / `subnet-0928d6d5c54f3d2a5` | Internet-facing ALB subnets |
| **Private App Subnet** | Subnet 1a | `subnet-0f94155d4f2a9ffda` (`10.20.10.0/24`) | Isolated private subnet for EC2 |
| **EC2 Instance Name** | Tag Name | `streamflix-app-ec2` | Target application server |
| **EC2 Instance Type** | Instance Class | `t3.micro` | Cost-effective / Free tier eligible |
| **EC2 Operating System**| AMI | Ubuntu 24.04 LTS (64-bit x86) | Matches on-premises `APP01` |
| **App Security Group** | Group ID | `sg-075c2521b1372d1a5` | Name: `streamflix-target-app-sg` |
| **ALB Security Group** | Group Name | `streamflix-alb-sg` | Inbound Port 80 from `0.0.0.0/0` |
| **Target Group Name** | Target Group | `streamflix-tg-app-ec2` | Target type: `instance`, Port 80, `/api/health` |
| **Load Balancer Name** | ALB Name | `streamflix-alb` | Internet-facing Application Load Balancer |

---

## 2. Phase 1: Provision the Application EC2 Instance

You will launch the Ubuntu 24.04 instance inside your **private application subnet** (`subnet-0f94155d4f2a9ffda`).

### Step 1.1: Launch EC2 Instance via Console or CLI

#### Option A: Via AWS Management Console (Click-by-Click UI)
1. In the AWS Management Console search bar at the top, type **EC2** and click **EC2**.
2. In the EC2 Dashboard, click the orange **Launch instance** button.
3. **Name and tags**:
   * Name: Enter `streamflix-app-ec2`.
4. **Application and OS Images (Amazon Machine Image)**:
   * Select **Ubuntu**.
   * Amazon Machine Image (AMI): Choose **Ubuntu Server 24.04 LTS (HVM), SSD Volume Type** (64-bit x86).
5. **Instance type**:
   * Select **`t3.micro`** (or `t3.small`).
6. **Key pair (login)**:
   * Select an existing key pair, or click **Create new key pair** (e.g. `streamflix-key.pem`).
7. **Network settings** *(Click "Edit" on the right)*:
   * **VPC**: Select `streamflix-target-vpc` (`vpc-020d6b01e57048985`).
   * **Subnet**: Select `subnet-0f94155d4f2a9ffda` (`streamflix-target-app-private-1a`).
   * **Auto-assign public IP**: Select **Disable** *(Keeps the server securely isolated in private subnet)*.
   * **Firewall (security groups)**: Choose **Select existing security group** $\to$ Select `streamflix-target-app-sg` (`sg-075c2521b1372d1a5`).
8. **Configure storage**:
   * Root volume: `20` GiB **General Purpose SSD (gp3)**.
9. Click the orange **Launch instance** button.

---

#### Option B: Via AWS CLI Command
```bash
# Retrieve latest Ubuntu 24.04 AMI ID
AMI_ID=$(aws ec2 describe-images \
  --owners 099720109477 \
  --filters "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
  --query 'sort_by(Images, &CreationDate)[-1].ImageId' \
  --output text \
  --region us-east-1)

# Launch EC2 instance in private app subnet
aws ec2 run-instances \
  --image-id $AMI_ID \
  --instance-type t3.micro \
  --key-name CloudForge \
  --subnet-id subnet-0f94155d4f2a9ffda \
  --security-group-ids sg-075c2521b1372d1a5 \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=streamflix-app-ec2}]' \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":20,"VolumeType":"gp3"}}]' \
  --region us-east-1
```

---

### Step 1.2: Retrieve the Private IP of the EC2 Instance
Wait until the instance is in the `running` state and note its private IP:

```bash
EC2_PRIVATE_IP=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=streamflix-app-ec2" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].PrivateIpAddress' \
  --output text \
  --region us-east-1)

echo "EC2 Private IP: $EC2_PRIVATE_IP"
```
*(The private IP will be in the `10.20.10.x` range).*

---

### Step 1.3: Verify Cross-Cloud Reachability from On-Premises
Because your IPsec Site-to-Site VPN is active (`10.10.0.0/16 <-> 10.20.0.0/16`), you can **ping and SSH directly into the private EC2 instance from HV01**:

From `HV01`:
```bash
# Ping the new private EC2 instance over the IPsec VPN tunnel
ping -c 3 $EC2_PRIVATE_IP
```
*Expected: 0% packet loss!*

---

## 3. Phase 2: Deploy & Configure StreamFlix on EC2

Now connect to the EC2 instance and install the application dependencies, Nginx reverse proxy, and systemd service.

### Step 2.1: SSH into the Private EC2 Instance from HV01
From your **`HV01`** terminal (or using your key):

```bash
ssh -i /home/labadmin/CloudForge.pem ubuntu@$EC2_PRIVATE_IP
```

---

### Step 2.2: Install Node.js 18, NPM, and Nginx
Inside the **`streamflix-app-ec2`** instance:

```bash
# Update package repositories
sudo apt update && sudo apt upgrade -y

# Install Node.js 18 LTS and Nginx
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt install -y nodejs nginx jq git

# Verify installations
node -v
npm -v
nginx -v
```

---

### Step 2.3: Deploy StreamFlix Application Source Code
Create the application directory structure:

```bash
sudo mkdir -p /var/www/streamflix
sudo chown -R ubuntu:ubuntu /var/www/streamflix
```

Copy the application source from `APP01` (or clone the repository):

```bash
# From inside the EC2 instance, copy directly from on-prem APP01 over the VPN:
scp -r vagrant@10.10.10.20:/var/www/streamflix/frontend /var/www/streamflix/
scp -r vagrant@10.10.10.20:/var/www/streamflix/backend /var/www/streamflix/
```
*(Password for vagrant: `vagrant`)*.

---

### Step 2.4: Build React Frontend & Install Backend Dependencies
1. **Build the React Frontend bundle**:
   ```bash
   cd /var/www/streamflix/frontend
   npm install
   npm run build
   ```
   *Verify that `/var/www/streamflix/frontend/dist` is populated with `index.html` and assets.*

2. **Install Backend API production dependencies**:
   ```bash
   cd /var/www/streamflix/backend
   npm install --omit=dev
   ```

---

### Step 2.5: Configure Backend Environment Variables
Create `/var/www/streamflix/backend/.env` pointing to your **Amazon RDS Endpoint** (from Stage 3) and **Amazon CloudFront Domain** (from Stage 4):

```bash
cat << 'EOF' | sudo tee /var/www/streamflix/backend/.env
PORT=5000
DB_HOST=<YOUR_RDS_ENDPOINT>
DB_PORT=5432
DB_NAME=streamflix_db
DB_USER=streamflix_user
DB_PASSWORD=StreamFlixPass2026!
MEDIA_BASE_URL=https://<YOUR_CLOUDFRONT_DOMAIN>
EOF
```

---

### Step 2.6: Configure Systemd Service for Express API
Create a persistent systemd service so the Node.js API runs continuously and restarts automatically on reboot:

```bash
cat << 'EOF' | sudo tee /etc/systemd/system/streamflix.service
[Unit]
Description=StreamFlix Node.js REST API
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/var/www/streamflix/backend
ExecStart=/usr/bin/node /var/www/streamflix/backend/server.js
Restart=always
RestartSec=5
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd, enable and start service
sudo systemctl daemon-reload
sudo systemctl enable streamflix
sudo systemctl start streamflix
sudo systemctl status streamflix --no-pager
```

---

### Step 2.7: Configure Nginx Reverse Proxy
Configure Nginx to serve the React frontend static build and reverse proxy `/api/*` to the Node.js process:

```bash
cat << 'EOF' | sudo tee /etc/nginx/sites-available/streamflix
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    # 1. React Frontend Static Build
    location / {
        root /var/www/streamflix/frontend/dist;
        index index.html index.htm;
        try_files $uri $uri/ /index.html;
    }

    # 2. Node.js Express API Reverse Proxy
    location /api/ {
        proxy_pass http://127.0.0.1:5000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_cache_bypass $http_upgrade;
    }
}
EOF

# Enable configuration and test syntax
sudo rm -f /etc/nginx/sites-enabled/default
sudo ln -sf /etc/nginx/sites-available/streamflix /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx
```

---

### Step 2.8: Test Local Health & Catalog on EC2
From inside the EC2 instance, test both endpoints:

```bash
# 1. Test Health endpoint
curl -s http://localhost/api/health | jq .

# 2. Test Movies catalog endpoint
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

Exit the EC2 instance:
```bash
exit
```

---

## 4. Phase 3: Application Load Balancer (ALB) Setup (UI Console & CLI)

Now we deploy an **Application Load Balancer** in the public subnets to route incoming internet traffic to port 80 of your private EC2 instance.

### Step 3.1: Create ALB Security Group

#### Option A: Via AWS Management Console (Click-by-Click UI)
1. In the AWS Console, search for **VPC** $\to$ Click **Security groups** in the left menu.
2. Click the orange **Create security group** button.
3. **Basic details**:
   * Security group name: `streamflix-alb-sg`.
   * Description: `Security group for public StreamFlix ALB`.
   * VPC: Select `streamflix-target-vpc` (`vpc-020d6b01e57048985`).
4. **Inbound rules**:
   * Click **Add rule**:
     * Type: **HTTP** | Port: `80` | Source: `Anywhere-IPv4` (`0.0.0.0/0`).
   * Click **Add rule**:
     * Type: **HTTPS** | Port: `443` | Source: `Anywhere-IPv4` (`0.0.0.0/0`).
5. Click **Create security group**.

#### Option B: Via AWS CLI Command
```bash
ALB_SG_ID=$(aws ec2 create-security-group \
  --group-name streamflix-alb-sg \
  --description "Security group for public StreamFlix ALB" \
  --vpc-id vpc-020d6b01e57048985 \
  --query 'GroupId' \
  --output text \
  --region us-east-1)

aws ec2 authorize-security-group-ingress \
  --group-id $ALB_SG_ID \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0 \
  --region us-east-1
```

---

### Step 3.2: Allow Inbound Traffic from ALB to EC2 Security Group
Ensure that `streamflix-target-app-sg` allows incoming HTTP (Port 80) traffic from the ALB security group:

```bash
aws ec2 authorize-security-group-ingress \
  --group-id sg-075c2521b1372d1a5 \
  --protocol tcp \
  --port 80 \
  --source-group $ALB_SG_ID \
  --region us-east-1 2>/dev/null || true
```

---

### Step 3.3: Create Target Group for EC2 Instance

#### Option A: Via AWS Management Console (Click-by-Click UI)
1. In the EC2 Console left navigation, scroll to **Load Balancing** $\to$ Click **Target Groups**.
2. Click the orange **Create target group** button.
3. **Basic configuration**:
   * Choose a target type: Select **Instances** *(Targeting our EC2 VM)*.
   * Target group name: Enter `streamflix-tg-app-ec2`.
   * Protocol: **HTTP** | Port: `80`.
   * IP address type: **IPv4**.
   * VPC: Select `streamflix-target-vpc` (`vpc-020d6b01e57048985`).
4. **Health checks**:
   * Health check protocol: **HTTP**.
   * Health check path: Enter `/api/health`.
5. Click **Next**.
6. **Register targets**:
   * Select the checkbox next to **`streamflix-app-ec2`**.
   * Port for selected instances: `80`.
   * Click the white button: **Include as pending below**.
7. Click the orange **Create target group** button.

#### Option B: Via AWS CLI Command
```bash
# 1. Create Target Group
TG_APP_ARN=$(aws elbv2 create-target-group \
  --name streamflix-tg-app-ec2 \
  --protocol HTTP \
  --port 80 \
  --vpc-id vpc-020d6b01e57048985 \
  --target-type instance \
  --health-check-path "/api/health" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text \
  --region us-east-1)

# 2. Get EC2 Instance ID
EC2_INSTANCE_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=streamflix-app-ec2" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' \
  --output text \
  --region us-east-1)

# 3. Register EC2 Instance with Target Group
aws elbv2 register-targets \
  --target-group-arn $TG_APP_ARN \
  --targets Id=$EC2_INSTANCE_ID,Port=80 \
  --region us-east-1
```

---

### Step 3.4: Create the Application Load Balancer

#### Option A: Via AWS Management Console (Click-by-Click UI)
1. In the EC2 Console left navigation, click **Load Balancers** $\to$ Click **Create load balancer**.
2. Under **Application Load Balancer**, click **Create**.
3. **Basic configuration**:
   * Load balancer name: `streamflix-alb`.
   * Scheme: **Internet-facing**.
   * IP address type: **IPv4**.
4. **Network mapping**:
   * VPC: Select `streamflix-target-vpc` (`vpc-020d6b01e57048985`).
   * Mappings (Select both public subnets):
     * Zone `us-east-1a`: Check box $\to$ Select `subnet-048d1aa28e96df5fe` (`streamflix-target-public-1a`).
     * Zone `us-east-1b`: Check box $\to$ Select `subnet-0928d6d5c54f3d2a5` (`streamflix-target-public-1b`).
5. **Security groups**:
   * Select `streamflix-alb-sg` $\to$ Remove `default`.
6. **Listeners and routing**:
   * Protocol: **HTTP** | Port: `80`.
   * Default action: Forward to **`streamflix-tg-app-ec2`**.
7. Click the orange **Create load balancer** button at the bottom.

#### Option B: Via AWS CLI Command
```bash
# 1. Create ALB
ALB_ARN=$(aws elbv2 create-load-balancer \
  --name streamflix-alb \
  --subnets subnet-048d1aa28e96df5fe subnet-0928d6d5c54f3d2a5 \
  --security-groups $ALB_SG_ID \
  --scheme internet-facing \
  --type application \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text \
  --region us-east-1)

# 2. Create Listener forwarding Port 80 to streamflix-tg-app-ec2
aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTP \
  --port 80 \
  --default-actions Type=forward,TargetGroupArn=$TG_APP_ARN \
  --region us-east-1
```

---

## 5. Phase 4: Live End-to-End Application Verification 🎬

Now verify that the target group shows the EC2 instance as **healthy** and test the live application through the Application Load Balancer!

### Step 4.1: Retrieve the ALB Public DNS Name
1. In the EC2 Console $\to$ **Load Balancers** $\to$ Click **`streamflix-alb`**.
2. Copy the **DNS name** *(e.g. `streamflix-alb-123456789.us-east-1.elb.amazonaws.com`)*.

Or via CLI:
```bash
ALB_DNS=$(aws elbv2 describe-load-balancers \
  --names streamflix-alb \
  --query 'LoadBalancers[0].DNSName' \
  --output text \
  --region us-east-1)

echo "Application Load Balancer URL: http://$ALB_DNS"
```

---

### Step 4.2: Verify Target Health in the Console
1. In the EC2 Console $\to$ **Target Groups** $\to$ Click **`streamflix-tg-app-ec2`**.
2. Under the **Targets** tab:
   * Verify that `streamflix-app-ec2` displays status: **`healthy`**!

---

### Step 4.3: Test Health & Catalog Endpoints via ALB
From your workstation terminal:

```bash
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
  "timestamp": "2026-11-04T..."
}
```

```bash
# 2. Test Movies Catalog through public ALB
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
  },
  {
    "id": 4,
    "title": "The Matrix Resurrections",
    "release_year": 2021,
    "genre": "Sci-Fi",
    "rating": "5.7"
  }
]
```

---

### Step 4.4: Open the Full Web UI in Your Browser 🌐
Open your laptop browser and navigate to:
```text
http://<YOUR_ALB_DNS_NAME>
```

**Verification:**
1. The **StreamFlix React Web UI** renders in your browser.
2. The movie catalog loads dynamically from the EC2 backend API querying RDS PostgreSQL.
3. Movie posters load with sub-millisecond edge latency from **Amazon CloudFront CDN**.
4. Click on any movie card to stream the MP4 video! The video player buffers and scrubs seamlessly via CloudFront HTTP 206 range requests.

---

## 6. Verification Checklist & Success Criteria

| # | Check Item | Verification Command / URL | Expected Result | Status |
| :-: | :--- | :--- | :--- | :-: |
| 1 | **EC2 Provisioned** | EC2 Console $\to$ Instances | `streamflix-app-ec2` running | [ ] |
| 2 | **Private Isolation** | `Public IP` in EC2 Console | Empty (Private subnet only) | [ ] |
| 3 | **Local Service** | `systemctl status streamflix` on EC2 | `active (running)` | [ ] |
| 4 | **Nginx Status** | `systemctl status nginx` on EC2 | `active (running)` | [ ] |
| 5 | **ALB Ingress** | EC2 Console $\to$ Load Balancers | Status: `active` | [ ] |
| 6 | **Target Group Health**| EC2 Console $\to$ Target Groups | `1 healthy` target | [ ] |
| 7 | **API Health Route** | `curl -s http://<ALB_DNS>/api/health` | `database: "CONNECTED"` | [ ] |
| 8 | **Catalog Route** | `curl -s http://<ALB_DNS>/api/movies` | Full movie list returned | [ ] |
| 9 | **Browser Playback** | Open `http://<ALB_DNS>` in Chrome | React UI & CloudFront video play | [ ] |

---

## 7. Rollback Runbook (In Case of Issues)

If any unexpected issue occurs:
1. Traffic can be immediately reverted to the on-premises `APP01` server by directing user DNS / test traffic back to `20.29.104.127:80`.
2. The EC2 instance can be stopped or terminated to prevent unnecessary AWS charges:
   ```bash
   aws ec2 stop-instances --instance-ids $EC2_INSTANCE_ID --region us-east-1
   ```
