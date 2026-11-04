# Stage 5: Application Migration Manual Runbook — StreamFlix to Amazon ECS Fargate & ALB
**Document ID**: RUNBOOK-STAGE5-APP-MIGRATION-ECS-FARGATE-20261104  
**Target Audience**: Cloud Migration Engineers, Solutions Architects, DevSecOps  
**Lab Context**: Enterprise Cloud Migration Lab (StreamFlix Application Tier)  
**Strategy**: Microservices Containerization, Serverless ECS Fargate & Application Load Balancer  
**UI Focus**: Dual Click-by-Click AWS Management Console & Terminal CLI Instructions  

---

## 1. Architectural Overview & Traffic Flow

In **Stage 5**, you will migrate the core StreamFlix web and application tier from the monolithic virtual machine (`APP01` on Azure) to a modern, highly available, serverless container architecture on **Amazon Elastic Container Service (Amazon ECS)** powered by **AWS Fargate** behind an **Application Load Balancer (ALB)**.

Traffic is cleanly decoupled using **Path-Based Routing**:
* Root & static asset requests (`/*`) route to the **StreamFlix React Frontend** containers (Port 80).
* API requests (`/api/*`) route to the **StreamFlix Node.js Express API** containers (Port 5000).
* The API queries the target **Amazon RDS PostgreSQL** instance (`streamflix-target-db`) deployed in Stage 3.
* Video streaming and posters are delivered through the **Amazon CloudFront CDN** deployed in Stage 4.

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
|  Security Group: streamflix-alb-sg (Allows 80/443 from 0.0.0.0/0)                                                       |
|                                                                                                                          |
|         | Path: /* (Default Rule)                               | Path: /api/* (Path Rule)                               |
|         v                                                       v                                                        |
|  [Target Group: streamflix-tg-frontend]                 [Target Group: streamflix-tg-backend]                            |
|  Port: 80 | Health Check: /health                       Port: 5000 | Health Check: /api/health                          |
|         |                                                       |                                                        |
| +-------+-------------------------------------------------------+------------------------------------------------------+ |
| | PRIVATE APPLICATION SUBNETS (No Public IPs):                                                                         | |
| | Subnets: subnet-0f94155d4f2a9ffda (10.20.10.0/24) & subnet-092b27e4a5bd71540 (10.20.11.0/24)                         | |
| | Security Group: streamflix-target-app-sg                                                                             | |
| |                                                                                                                      | |
| |  [ECS Service: streamflix-frontend-service]            [ECS Service: streamflix-backend-service]                     | |
| |   * Task: streamflix-frontend-task                      * Task: streamflix-backend-task                               | |
| |   * Engine: AWS Fargate (2 Tasks in Multi-AZ)           * Engine: AWS Fargate (2 Tasks in Multi-AZ)                    | |
| |   * Image: <ECR>/streamflix-frontend:latest             * Image: <ECR>/streamflix-backend:latest                      | |
| |   * Port: 80 (Nginx serving React SPA)                  * Port: 5000 (Express Node.js REST API)                       | |
| |                                                                |                                                     | |
| +----------------------------------------------------------------+-----------------------------------------------------+ |
|                                                                  |                                                       |
|                                           SQL Queries (Port 5432)|                  Media Streaming (HTTPS)              |
|                                                                  v                                    v                  |
|                                     [Target Amazon RDS PostgreSQL]              [Amazon CloudFront CDN / S3]             |
|                                     (streamflix-target-db)                      (streamflix-media-165772574557)          |
+--------------------------------------------------------------------------------------------------------------------------+
```

---

### Parameter Reference Table

| Component | Parameter | Value | Description |
| :--- | :--- | :--- | :--- |
| **AWS Account ID** | Account ID | `165772574557` | AWS account running target landing zone |
| **AWS Region** | Region Name | `us-east-1` | Target AWS Cloud Region |
| **Target VPC ID** | VPC ID | `vpc-020d6b01e57048985` | StreamFlix Landing Zone VPC (`10.20.0.0/16`) |
| **Public Subnets (ALB)**| Subnet 1a / 1b | `subnet-048d1aa28e96df5fe` / `subnet-0928d6d5c54f3d2a5` | For public-facing Application Load Balancer |
| **Private App Subnets** | Subnet 1a / 1b | `subnet-0f94155d4f2a9ffda` / `subnet-092b27e4a5bd71540` | For private ECS Fargate tasks |
| **ALB Security Group** | Group Name / Port | `streamflix-alb-sg` / Port 80, 443 | Accepts public incoming user requests |
| **App Security Group** | Group ID | `sg-075c2521b1372d1a5` | `streamflix-target-app-sg` |
| **ECR Backend Repo** | Repository Name | `streamflix-backend` | Container registry for Express.js API |
| **ECR Frontend Repo** | Repository Name | `streamflix-frontend` | Container registry for React SPA |
| **ECS Cluster Name** | Cluster Identifier | `streamflix-cluster` | Serverless Fargate cluster |
| **Backend Task Def** | Task Family | `streamflix-backend-task` | 0.5 vCPU, 1 GB RAM, Port 5000 |
| **Frontend Task Def** | Task Family | `streamflix-frontend-task` | 0.25 vCPU, 0.5 GB RAM, Port 80 |
| **Backend Target Group**| Group Name / Port | `streamflix-tg-backend` / Port 5000 | Target type: IP, Health Check: `/api/health` |
| **Frontend Target Group**| Group Name / Port | `streamflix-tg-frontend` / Port 80 | Target type: IP, Health Check: `/health` |
| **Application Load Balancer**| ALB Name | `streamflix-alb` | Internet-facing HTTP/HTTPS Load Balancer |

---

## 2. Phase 1: Container Build & Push to Amazon ECR

Before deploying to Amazon ECS, the application code must be packaged into container images and published to **Amazon Elastic Container Registry (Amazon ECR)**.

### Step 1.1: Verify Docker Installation
You can build the container images on **`APP01`**, **`HV01`**, or your local laptop workstation:

```bash
# Check Docker version
docker --version

# If Docker is not yet installed on your build machine, install it with one command:
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER
```

---

### Step 1.2: Create Amazon ECR Repositories

#### Option A: Via AWS Management Console (Click-by-Click UI)
1. In the AWS Management Console search bar at the top, type **ECR** and click **Elastic Container Registry**.
2. In the left navigation menu, click **Repositories** $\to$ Click the orange **Create repository** button.
3. **Repository 1: Backend API**:
   * **Visibility settings**: Select **Private**.
   * **Repository name**: Enter `streamflix-backend`.
   * **Tag immutability**: Leave Disabled.
   * **Scan on push**: Enable (recommended for security).
   * Click **Create repository**.
4. Repeat for **Repository 2: Frontend UI**:
   * Click **Create repository**.
   * **Visibility settings**: Select **Private**.
   * **Repository name**: Enter `streamflix-frontend`.
   * Click **Create repository**.

#### Option B: Via AWS CLI Command
```bash
# Create Backend ECR Repository
aws ecr create-repository \
  --repository-name streamflix-backend \
  --image-scanning-configuration scanOnPush=true \
  --region us-east-1

# Create Frontend ECR Repository
aws ecr create-repository \
  --repository-name streamflix-frontend \
  --image-scanning-configuration scanOnPush=true \
  --region us-east-1
```

---

### Step 1.3: Build the Container Images
Navigate to the `applications/streamflix` directory containing the application source:

```bash
cd /vagrant/dev_projects/Enterprise_Cloud_Migration_Lab/onprem-cloud-migration-lab/applications/streamflix
```

Build the backend and frontend container images:

```bash
# 1. Build Backend API image
docker build -t streamflix-backend:latest ./backend

# 2. Build Frontend React Nginx image
docker build -t streamflix-frontend:latest ./frontend
```

Verify that both images exist in local Docker storage:
```bash
docker images | grep streamflix
```
**Expected Output:**
```text
streamflix-frontend   latest   7261a8b9e0f1   About a minute ago   23.8MB
streamflix-backend    latest   9b42e71f5c3a   About a minute ago   142MB
```

---

### Step 1.4: Authenticate Docker and Push Images to Amazon ECR
Authenticate Docker against your private ECR registry in `us-east-1`:

```bash
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin 165772574557.dkr.ecr.us-east-1.amazonaws.com
```
*Expected: `Login Succeeded`.*

Tag and push both container images:

```bash
ECR_REGISTRY="165772574557.dkr.ecr.us-east-1.amazonaws.com"

# Tag and push Backend
docker tag streamflix-backend:latest ${ECR_REGISTRY}/streamflix-backend:latest
docker push ${ECR_REGISTRY}/streamflix-backend:latest

# Tag and push Frontend
docker tag streamflix-frontend:latest ${ECR_REGISTRY}/streamflix-frontend:latest
docker push ${ECR_REGISTRY}/streamflix-frontend:latest
```

---

## 3. Phase 2: Application Load Balancer (ALB) & Routing Setup

Now we deploy the public **Application Load Balancer (ALB)** and configure **Path-Based Routing** to decouple the frontend and backend microservices.

### Step 2.1: Create ALB Security Group

#### Option A: Via AWS Management Console (Click-by-Click UI)
1. In the AWS Console, search for **VPC** $\to$ Click **Security groups** in the left menu.
2. Click the orange **Create security group** button.
3. **Basic details**:
   * **Security group name**: Enter `streamflix-alb-sg`.
   * **Description**: Enter `Security group for public StreamFlix ALB`.
   * **VPC**: Select `streamflix-target-vpc` (`vpc-020d6b01e57048985`).
4. **Inbound rules**:
   * Click **Add rule**:
     * Type: **HTTP** | Port: `80` | Source: `Anywhere-IPv4` (`0.0.0.0/0`)
   * Click **Add rule**:
     * Type: **HTTPS** | Port: `443` | Source: `Anywhere-IPv4` (`0.0.0.0/0`)
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

# Authorize inbound HTTP port 80
aws ec2 authorize-security-group-ingress \
  --group-id $ALB_SG_ID \
  --protocol tcp \
  --port 80 \
  --cidr 0.0.0.0/0 \
  --region us-east-1
```

---

### Step 2.2: Create Target Groups (Frontend & Backend)

Because ECS Fargate tasks are assigned private VPC IP addresses (in `awsvpc` network mode), the target group type **MUST be IP**:

#### Option A: Via AWS Management Console (Click-by-Click UI)
1. In the EC2 Console left navigation, scroll down to **Load Balancing** $\to$ Click **Target Groups**.
2. Click the orange **Create target group** button.
3. **Target Group 1: Frontend**:
   * Choose target type: **IP addresses** *(Crucial for Fargate!)*.
   * Target group name: `streamflix-tg-frontend`.
   * Protocol: **HTTP** | Port: `80`.
   * IP address type: **IPv4**.
   * VPC: Select `streamflix-target-vpc` (`vpc-020d6b01e57048985`).
   * Health check path: Enter `/health`.
   * Click **Next** $\to$ Under Register targets, do not add any IPs (ECS registers them automatically!) $\to$ Click **Create target group**.
4. **Target Group 2: Backend API**:
   * Click **Create target group**.
   * Choose target type: **IP addresses**.
   * Target group name: `streamflix-tg-backend`.
   * Protocol: **HTTP** | Port: `5000`.
   * VPC: Select `streamflix-target-vpc` (`vpc-020d6b01e57048985`).
   * Health check path: Enter `/api/health`.
   * Click **Next** $\to$ Click **Create target group**.

#### Option B: Via AWS CLI Command
```bash
# 1. Create Frontend Target Group (Port 80)
TG_FRONTEND_ARN=$(aws elbv2 create-target-group \
  --name streamflix-tg-frontend \
  --protocol HTTP \
  --port 80 \
  --vpc-id vpc-020d6b01e57048985 \
  --target-type ip \
  --health-check-path "/health" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text \
  --region us-east-1)

# 2. Create Backend Target Group (Port 5000)
TG_BACKEND_ARN=$(aws elbv2 create-target-group \
  --name streamflix-tg-backend \
  --protocol HTTP \
  --port 5000 \
  --vpc-id vpc-020d6b01e57048985 \
  --target-type ip \
  --health-check-path "/api/health" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text \
  --region us-east-1)
```

---

### Step 2.3: Create Application Load Balancer & Path Rules

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
     * Availability Zone 1 (`us-east-1a`): Check box $\to$ Select `subnet-048d1aa28e96df5fe` (`streamflix-target-public-1a`).
     * Availability Zone 2 (`us-east-1b`): Check box $\to$ Select `subnet-0928d6d5c54f3d2a5` (`streamflix-target-public-1b`).
5. **Security groups**:
   * Select `streamflix-alb-sg` $\to$ Remove `default`.
6. **Listeners and routing**:
   * Protocol: **HTTP** | Port: `80`.
   * Default action: Forward to **`streamflix-tg-frontend`**.
7. Click the orange **Create load balancer** button at the bottom.
8. **Add Path-Based Routing Rule for API**:
   * In the Load Balancers list, click **`streamflix-alb`** $\to$ Click the **Listeners and rules** tab.
   * Click on the **HTTP:80** listener.
   * Click **Add rule**:
     * Name: `route-api-traffic`.
     * Add condition: Select **Path** $\to$ Enter `/api/*`.
     * Add action: Select **Forward to** $\to$ Choose `streamflix-tg-backend`.
     * Priority: Enter `10`.
     * Click **Save**.

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

# 2. Create Default HTTP:80 Listener (Routes to Frontend)
LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn $ALB_ARN \
  --protocol HTTP \
  --port 80 \
  --default-actions Type=forward,TargetGroupArn=$TG_FRONTEND_ARN \
  --query 'Listeners[0].ListenerArn' \
  --output text \
  --region us-east-1)

# 3. Add Path-Based Routing Rule (/api/* Routes to Backend)
aws elbv2 create-rule \
  --listener-arn $LISTENER_ARN \
  --priority 10 \
  --conditions Field=path-pattern,Values='/api/*' \
  --actions Type=forward,TargetGroupArn=$TG_BACKEND_ARN \
  --region us-east-1
```

---

## 4. Phase 3: Amazon ECS Fargate Cluster & Task Definitions

Now we create the serverless **Amazon ECS Fargate** cluster and register the container task definitions.

### Step 3.1: Create ECS Cluster

#### Option A: Via AWS Management Console (Click-by-Click UI)
1. In the AWS search bar, type **ECS** and click **Elastic Container Service**.
2. In the left navigation menu, click **Clusters** $\to$ Click the orange **Create cluster** button.
3. **Cluster configuration**:
   * Cluster name: Enter `streamflix-cluster`.
4. **Infrastructure**:
   * Ensure **AWS Fargate (serverless)** is selected.
5. Click **Create**.

#### Option B: Via AWS CLI Command
```bash
aws ecs create-cluster \
  --cluster-name streamflix-cluster \
  --region us-east-1
```

---

### Step 3.2: Verify ECS Task Execution IAM Role
ECS Fargate tasks need an IAM execution role (`ecsTaskExecutionRole`) to pull container images from ECR and write logs to CloudWatch.

Verify or create the role:
```bash
# Check if role exists
aws iam get-role --role-name ecsTaskExecutionRole || \
(aws iam create-role --role-name ecsTaskExecutionRole \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}' && \
 aws iam attach-role-policy --role-name ecsTaskExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy)
```

---

### Step 3.3: Register Backend Task Definition (UI & CLI)

The backend task definition configures the container port `5000` and the database connection to RDS.

#### Option A: Via AWS Management Console (Click-by-Click UI)
1. In the ECS Console left navigation, click **Task definitions** $\to$ Click **Create new task definition** $\to$ Click **Create new task definition with JSON** (or Wizard).
2. **Task definition configuration**:
   * Task definition family: `streamflix-backend-task`.
   * Launch type: **AWS Fargate**.
   * CPU: `.5 vCPU` | Memory: `1 GB`.
   * Task execution role: `ecsTaskExecutionRole`.
3. **Container - 1**:
   * Name: `backend`.
   * Image URI: `165772574557.dkr.ecr.us-east-1.amazonaws.com/streamflix-backend:latest`.
   * Port mappings: Port `5000` | Protocol: TCP | App protocol: HTTP.
   * **Environment variables**:
     * `DB_HOST`: `<YOUR_RDS_ENDPOINT>`
     * `DB_PORT`: `5432`
     * `DB_NAME`: `streamflix_db`
     * `DB_USER`: `streamflix_user`
     * `DB_PASSWORD`: `StreamFlixPass2026!`
     * `MEDIA_BASE_URL`: `https://<YOUR_CLOUDFRONT_DOMAIN>`
4. Click **Create**.

#### Option B: Via AWS CLI Command
```bash
cat << EOF > /tmp/backend-task-def.json
{
  "family": "streamflix-backend-task",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "512",
  "memory": "1024",
  "executionRoleArn": "arn:aws:iam::165772574557:role/ecsTaskExecutionRole",
  "containerDefinitions": [
    {
      "name": "backend",
      "image": "165772574557.dkr.ecr.us-east-1.amazonaws.com/streamflix-backend:latest",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 5000,
          "hostPort": 5000,
          "protocol": "tcp"
        }
      ],
      "environment": [
        {"name": "PORT", "value": "5000"},
        {"name": "DB_HOST", "value": "<YOUR_RDS_ENDPOINT>"},
        {"name": "DB_PORT", "value": "5432"},
        {"name": "DB_NAME", "value": "streamflix_db"},
        {"name": "DB_USER", "value": "streamflix_user"},
        {"name": "DB_PASSWORD", "value": "StreamFlixPass2026!"},
        {"name": "MEDIA_BASE_URL", "value": "https://<YOUR_CLOUDFRONT_DOMAIN>"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/streamflix-backend",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "backend",
          "awslogs-create-group": "true"
        }
      }
    }
  ]
}
EOF

aws ecs register-task-definition --cli-input-json file:///tmp/backend-task-def.json --region us-east-1
```

---

### Step 3.4: Register Frontend Task Definition (UI & CLI)

#### Option A: Via AWS Management Console (Click-by-Click UI)
1. In the ECS Console $\to$ Click **Task definitions** $\to$ Click **Create new task definition**.
2. **Task definition configuration**:
   * Task definition family: `streamflix-frontend-task`.
   * Launch type: **AWS Fargate**.
   * CPU: `.25 vCPU` | Memory: `.5 GB`.
   * Task execution role: `ecsTaskExecutionRole`.
3. **Container - 1**:
   * Name: `frontend`.
   * Image URI: `165772574557.dkr.ecr.us-east-1.amazonaws.com/streamflix-frontend:latest`.
   * Port mappings: Port `80` | Protocol: TCP | App protocol: HTTP.
4. Click **Create**.

#### Option B: Via AWS CLI Command
```bash
cat << EOF > /tmp/frontend-task-def.json
{
  "family": "streamflix-frontend-task",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "arn:aws:iam::165772574557:role/ecsTaskExecutionRole",
  "containerDefinitions": [
    {
      "name": "frontend",
      "image": "165772574557.dkr.ecr.us-east-1.amazonaws.com/streamflix-frontend:latest",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 80,
          "hostPort": 80,
          "protocol": "tcp"
        }
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/streamflix-frontend",
          "awslogs-region": "us-east-1",
          "awslogs-stream-prefix": "frontend",
          "awslogs-create-group": "true"
        }
      }
    }
  ]
}
EOF

aws ecs register-task-definition --cli-input-json file:///tmp/frontend-task-def.json --region us-east-1
```

---

## 5. Phase 4: Launch Highly Available ECS Services

Now we launch both services with **2 tasks each** deployed across both Availability Zones (`us-east-1a` and `us-east-1b`) inside the private application subnets.

### Step 4.1: Deploy Backend ECS Service

#### Option A: Via AWS Management Console (Click-by-Click UI)
1. Go to **ECS Console** $\to$ Click **Clusters** $\to$ Click **`streamflix-cluster`**.
2. Under the **Services** tab, click the orange **Create** button.
3. **Environment**:
   * Launch type: **Fargate**.
4. **Deployment configuration**:
   * Application type: **Service**.
   * Family: Select `streamflix-backend-task` (Revision: latest).
   * Service name: `streamflix-backend-service`.
   * Desired tasks: Enter `2` *(Multi-AZ High Availability)*.
5. **Networking**:
   * VPC: Select `streamflix-target-vpc` (`vpc-020d6b01e57048985`).
   * Subnets: Select both private app subnets:
     * `subnet-0f94155d4f2a9ffda` (`10.20.10.0/24`)
     * `subnet-092b27e4a5bd71540` (`10.20.11.0/24`)
   * Security group: Choose existing $\to$ `streamflix-target-app-sg` (`sg-075c2521b1372d1a5`).
   * Public IP: **Turn OFF (Disabled)**.
6. **Load balancing**:
   * Load balancer type: Select **Application Load Balancer**.
   * Container: `backend 5000:5000`.
   * Use an existing load balancer: Select `streamflix-alb`.
   * Use an existing listener: Select `80:HTTP`.
   * Target group: Select **Choose an existing target group** $\to$ Select `streamflix-tg-backend`.
7. Click the orange **Create** button.

#### Option B: Via AWS CLI Command
```bash
aws ecs create-service \
  --cluster streamflix-cluster \
  --service-name streamflix-backend-service \
  --task-definition streamflix-backend-task \
  --desired-count 2 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-0f94155d4f2a9ffda,subnet-092b27e4a5bd71540],securityGroups=[sg-075c2521b1372d1a5],assignPublicIp=DISABLED}" \
  --load-balancers "targetGroupArn=$TG_BACKEND_ARN,containerName=backend,containerPort=5000" \
  --region us-east-1
```

---

### Step 4.2: Deploy Frontend ECS Service

#### Option A: Via AWS Management Console (Click-by-Click UI)
1. In **`streamflix-cluster`** $\to$ Under **Services**, click **Create**.
2. **Environment**: Launch type: **Fargate**.
3. **Deployment configuration**:
   * Family: Select `streamflix-frontend-task` (Revision: latest).
   * Service name: `streamflix-frontend-service`.
   * Desired tasks: Enter `2`.
4. **Networking**:
   * Subnets: Select both private app subnets (`10.20.10.0/24` and `10.20.11.0/24`).
   * Security group: Select `streamflix-target-app-sg` (`sg-075c2521b1372d1a5`).
   * Public IP: **Turn OFF (Disabled)**.
5. **Load balancing**:
   * Load balancer type: **Application Load Balancer**.
   * Container: `frontend 80:80`.
   * Use existing load balancer: Select `streamflix-alb`.
   * Use existing listener: Select `80:HTTP`.
   * Target group: Choose existing target group $\to$ Select `streamflix-tg-frontend`.
6. Click **Create**.

#### Option B: Via AWS CLI Command
```bash
aws ecs create-service \
  --cluster streamflix-cluster \
  --service-name streamflix-frontend-service \
  --task-definition streamflix-frontend-task \
  --desired-count 2 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-0f94155d4f2a9ffda,subnet-092b27e4a5bd71540],securityGroups=[sg-075c2521b1372d1a5],assignPublicIp=DISABLED}" \
  --load-balancers "targetGroupArn=$TG_FRONTEND_ARN,containerName=frontend,containerPort=80" \
  --region us-east-1
```

---

## 6. Phase 5: Verification & End-to-End Live Application Test 🎬

Now verify that both target groups are healthy and test the live application through the Application Load Balancer!

### Step 5.1: Retrieve the ALB Public DNS Name
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

### Step 5.2: Test Health Endpoints via ALB
Test both microservice health checks through the ALB:

```bash
# 1. Test Frontend health check (Port 80)
curl -i http://$ALB_DNS/health
```
**Expected Output:**
```text
HTTP/1.1 200 OK
Content-Type: text/plain
healthy
```

```bash
# 2. Test Backend API health check (Port 5000 routed via /api/*)
curl -s http://$ALB_DNS/api/health | jq .
```
**Expected Output:**
```json
{
  "status": "UP",
  "service": "StreamFlix API",
  "host": "ip-10-20-10-xx.ec2.internal",
  "database": "CONNECTED",
  "timestamp": "2026-11-04T..."
}
```

---

### Step 5.3: Test Movie Catalog API via ALB
Query the movie catalog endpoint:

```bash
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

### Step 5.4: Test Full Web UI in Your Browser 🌐
Open your laptop browser and navigate to:
```text
http://<YOUR_ALB_DNS_NAME>
```

**Verification:**
1. The **StreamFlix React Web UI** renders with modern dark mode styling.
2. The movie catalog loads dynamically from the ECS Backend API.
3. Movie posters load with sub-millisecond edge latency from **Amazon CloudFront CDN**.
4. Click on any movie card to stream the MP4 video! The video player buffers and scrubs seamlessly via CloudFront HTTP 206 range requests.

---

## 7. Verification Checklist & Success Criteria

| # | Check Item | Verification Command / URL | Expected Result | Status |
| :-: | :--- | :--- | :--- | :-: |
| 1 | **ECR Images** | `aws ecr list-images --repository-name streamflix-backend` | Image tag `latest` present | [ ] |
| 2 | **ALB Ingress** | EC2 Console $\to$ Load Balancers | Status: `active` | [ ] |
| 3 | **Target Groups** | EC2 Console $\to$ Target Groups | Both `healthy` (2 targets each) | [ ] |
| 4 | **ECS Tasks** | ECS Console $\to$ Clusters $\to$ Tasks | 4 tasks running (2 frontend, 2 backend) | [ ] |
| 5 | **Frontend Route** | `curl -i http://<ALB_DNS>/health` | `HTTP 200 OK (healthy)` | [ ] |
| 6 | **API Route** | `curl -s http://<ALB_DNS>/api/health` | `database: "CONNECTED"` | [ ] |
| 7 | **Catalog API** | `curl -s http://<ALB_DNS>/api/movies` | Full movie list returned | [ ] |
| 8 | **Browser Test** | Load `http://<ALB_DNS>` in Chrome/Firefox | React UI & video playback working | [ ] |

---

## 8. Rollback Runbook (In Case of Issues)

If any unexpected issue occurs during testing:
1. Traffic can be immediately reverted to the on-premises `APP01` server by directing user DNS / test traffic back to `20.29.104.127:80`.
2. Both ECS services can be scaled to 0 to save costs during debugging:
   ```bash
   aws ecs update-service --cluster streamflix-cluster --service streamflix-backend-service --desired-count 0 --region us-east-1
   aws ecs update-service --cluster streamflix-cluster --service streamflix-frontend-service --desired-count 0 --region us-east-1
   ```
