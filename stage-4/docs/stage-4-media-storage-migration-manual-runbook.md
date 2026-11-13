# Stage 4: Enterprise Media Storage Migration Manual Runbook — FILE01 to Amazon S3 & CloudFront CDN
**Document ID**: RUNBOOK-STAGE4-MEDIA-MIGRATION-S3-CLOUDFRONT-20261104  
**Target Audience**: Cloud Migration Engineers, Storage Architects, DevSecOps  
**Lab Context**: Enterprise Cloud Migration Lab (StreamFlix Application Media Tier)  
**Strategy**: SMB/CIFS File Migration to Amazon S3 with Edge Delivery via Amazon CloudFront (OAC)  
**UI Focus**: Dual Click-by-Click AWS Management Console & Terminal CLI Instructions  

---

## 1. Architectural Overview & Migration Flow

In **Stage 4**, you will migrate the enterprise media storage tier of the StreamFlix application from an on-premises Samba (SMB/CIFS) file server (`FILE01` on Azure) to **Amazon Simple Storage Service (Amazon S3)** and deliver it globally with low latency using **Amazon CloudFront CDN**.

To follow strict AWS security best practices, the S3 bucket will have **Block Public Access 100% enabled**. Public access will **not** be allowed directly to S3. Instead, media assets will be served securely through CloudFront using **Origin Access Control (OAC)**, enabling HTTP 206 Partial Content range requests for smooth video streaming.

```
+--------------------------------------------------------------------------------------------------------------------------+
| ON-PREMISES DATACENTER (AZURE)                             | TARGET MIGRATION CLOUD (AWS)                                |
| Source Storage Server: FILE01 (10.10.10.40)                | Region: us-east-1                                           |
| Share: //10.10.10.40/media                                 | Target Storage: Amazon S3 & Amazon CloudFront CDN           |
| Mount Point on APP01: /mnt/file01/media                    |                                                             |
|                                                            |                                                             |
| +--------------------------------------------------------+ | +---------------------------------------------------------+ |
| | Source Media Storage Assets:                           | | | Target AWS Cloud Storage & CDN Tier:                    | |
| |                                                        | | |                                                         | |
| |  /srv/media/posters/                                   | | |  [Amazon CloudFront CDN] (Global Edge Network)          | |
| |   * hyperv.svg, migration.svg, samba.svg               | | |   * Domain: d123456abcdef8.cloudfront.net               | |
| |  /srv/media/videos/                                    | | |   * Origin Access Control (OAC)                         | |
| |   * hyperv.mp4, migration.mp4, samba.mp4               | | |   * HTTP 206 Partial Content Video Streaming            | |
| +--------------------------------------------------------+ | |   * HTTPS / SSL Enforced                                | |
|          |                                                 | |                        |                                |
|          | Transfer over TLS (Rclone / DataSync)           | |                        v (Signed OAC Requests)          |
|          v                                                 | |  [Amazon S3 Media Bucket]                               | |
|   [Migration Client: APP01 or HV01]                        | |   * Bucket: streamflix-media-165772574557               | |
|   (rclone sync /mnt/file01/media s3:...)                   | |   * Block Public Access: ENABLED (Strict Private)       | |
|          |                                                 | |   * Server-Side Encryption: SSE-S3 (AES-256)            | |
|          +=================================================+ |   * Bucket Policy: Restricted to CloudFront OAC only    | |
|                      Encrypted Cloud Upload                  +---------------------------------------------------------+ |
+--------------------------------------------------------------------------------------------------------------------------+
```

---

### Parameter Reference Table

| Component | Parameter | Value | Description |
| :--- | :--- | :--- | :--- |
| **Source File Server** | Hostname / IP | `FILE01` / `10.10.10.40` | Ubuntu Linux running Samba CIFS |
| **Source Share Path** | Local Path on FILE01 | `/srv/media` | Root of media storage |
| **Source Mount Path** | Mounted Path on APP01 | `/mnt/file01/media` | SMB/CIFS mount on web/app server |
| **Media Assets** | Poster SVGs & Video MP4s | 6 files total | `hyperv.*`, `migration.*`, `samba.*` |
| **Target Storage** | S3 Bucket Name | `streamflix-media-165772574557` | Globally unique Amazon S3 bucket |
| **Target AWS Region** | Region Name | `us-east-1` | Primary migration region |
| **S3 Security** | Block Public Access | **Enabled** (All 4 settings) | Zero public bucket exposure |
| **S3 Encryption** | Default Encryption | `AES256` (SSE-S3) | Automated server-side encryption |
| **CDN Distribution** | Origin Domain | S3 Bucket Regional Endpoint | CloudFront distribution origin |
| **CDN Access Type** | Origin Access | **Origin Access Control (OAC)** | Cryptographic IAM-free origin lock |
| **Transfer Tool** | Utility | `Rclone` (or AWS DataSync) | High-performance multi-threaded sync |

---

## 2. Phase 1: Source Storage Assessment & Inventory

Before moving media files, cloud storage architects must record an exact baseline inventory including file counts, file sizes, directory hierarchy, and cryptographic checksums (MD5/SHA256).

### Step 1.1: Connect to APP01 and Verify Mount Status
Log into `APP01` from `HV01`:

```bash
# Connect to APP01
ssh -i /home/labadmin/Enterprise_Cloud_Migration_Lab/stage-1/vagrant/app01/.vagrant/machines/default/libvirt/private_key vagrant@10.10.10.20
```

Verify that the SMB share from `FILE01` is actively mounted:
```bash
df -h | grep media
```
**Expected Output:**
```text
//10.10.10.40/media   31G  7.2G   24G  24% /mnt/file01/media
```

---

### Step 1.2: Record Baseline Inventory & File Sizes
Inspect the files inside `/mnt/file01/media`:

```bash
# 1. Check total directory size
du -sh /mnt/file01/media

# 2. Count total files
find /mnt/file01/media -type f | wc -l

# 3. List all poster and video assets
find /mnt/file01/media -type f -exec ls -lh {} +
```
**Baseline Inventory:**
```text
- /mnt/file01/media/posters/hyperv.svg    (~825 bytes)
- /mnt/file01/media/posters/migration.svg (~826 bytes)
- /mnt/file01/media/posters/samba.svg     (~824 bytes)
- /mnt/file01/media/videos/hyperv.mp4     (~226 KB)
- /mnt/file01/media/videos/migration.mp4  (~226 KB)
- /mnt/file01/media/videos/samba.mp4      (~226 KB)
Total: 6 files
```

---

### Step 1.3: Generate Baseline MD5 Checksums
Generate cryptographic checksums to verify against the target cloud objects after migration:

```bash
cd /mnt/file01/media
find . -type f -exec md5sum {} + | sort -k 2 | tee /tmp/source_media_checksums.txt
```

Exit `APP01`:
```bash
exit
```

---

## 3. Phase 2: Create Secure Amazon S3 Media Bucket

Now you will create the target Amazon S3 bucket.

### Step 2.1: Create S3 Bucket

#### Option A: Via AWS Management Console (Click-by-Click UI)
1. In the AWS Management Console search bar at the top, type **S3** and click **S3**.
2. Click the orange **Create bucket** button.
3. **General configuration**:
   * **AWS Region**: Select **US East (N. Virginia) us-east-1**.
   * **Bucket type**: Select **General purpose**.
   * **Bucket name**: Enter `streamflix-media-165772574557` *(Bucket names must be globally unique across all AWS accounts)*.
4. **Object Ownership**:
   * Select **ACLs disabled (recommended)**.
5. **Block Public Access settings for this bucket**:
   * Ensure **Block *all* public access** is **CHECKED** *(Do not allow direct public access!)*.
6. **Bucket Versioning**:
   * Select **Enable** *(Protects against accidental deletions or overwrites)*.
7. **Default encryption**:
   * Encryption type: **Server-side encryption with Amazon S3 managed keys (SSE-S3)**.
   * Bucket Key: **Enable**.
8. Click the orange **Create bucket** button at the bottom.

#### Option B: Via AWS CLI Command
```bash
aws s3api create-bucket \
  --bucket streamflix-media-165772574557 \
  --region us-east-1

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket streamflix-media-165772574557 \
  --versioning-configuration Status=Enabled

# Ensure Block Public Access is active
aws s3api put-public-access-block \
  --bucket streamflix-media-165772574557 \
  --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

---

## 4. Phase 3: Media Migration Execution via Rclone

We will use **Rclone**, the industry-standard high-performance cloud synchronization utility. It supports multi-threading, MD5 checksum validation, automatic retries, and direct S3 streaming.

### Step 3.1: Install Rclone on APP01
SSH into **`APP01`**:

```bash
ssh -i /home/labadmin/Enterprise_Cloud_Migration_Lab/stage-1/vagrant/app01/.vagrant/machines/default/libvirt/private_key vagrant@10.10.10.20
```

Install Rclone and AWS CLI:
```bash
sudo apt update
sudo apt install -y rclone awscli
```

---

### Step 3.2: Configure AWS Credentials on APP01
Run `aws configure` to allow Rclone and AWS CLI to authenticate:

```bash
aws configure
```
* **AWS Access Key ID**: *(Enter your lab AWS Access Key)*
* **AWS Secret Access Key**: *(Enter your lab AWS Secret Key)*
* **Default region name**: `us-east-1`
* **Default output format**: `json`

Verify S3 access:
```bash
aws s3 ls s3://streamflix-media-165772574557/
```

---

### Step 3.3: Configure Rclone for Amazon S3
Create the Rclone configuration file on `APP01`:

```bash
mkdir -p ~/.config/rclone
cat << 'EOF' > ~/.config/rclone/rclone.conf
[streamflix-s3]
type = s3
provider = AWS
env_auth = true
region = us-east-1
location_constraint = us-east-1
server_side_encryption = AES256
EOF
```

Verify that Rclone can communicate with S3:
```bash
rclone lsd streamflix-s3:
```
*(You will see your `streamflix-media-165772574557` bucket listed!)*

---

### Step 3.4: Execute Synchronization from SMB Share to S3
Run the synchronization with progress tracking and checksum validation:

```bash
rclone sync /mnt/file01/media streamflix-s3:streamflix-media-165772574557 \
  --progress \
  --checksum \
  --transfers 4 \
  --verbose
```

**Expected Output:**
```text
Transferred:        680.144 KiB / 680.144 KiB, 100%, 1.258 MiB/s, ETA 0s
Transferred:            6 / 6, 100%
Elapsed time:         0.7s
```

---

### Step 3.5: Validate Target S3 Objects and Parity
Compare file counts and list objects in S3:

```bash
# 1. List objects in S3
aws s3 ls s3://streamflix-media-165772574557/ --recursive --human-readable

# 2. Count objects in S3
aws s3 ls s3://streamflix-media-165772574557/ --recursive | wc -l
```
*(Expected: exactly 6 objects).*

Run an Rclone check to verify 100% hash parity:
```bash
rclone check /mnt/file01/media streamflix-s3:streamflix-media-165772574557
```
**Expected Output:**
```text
0 differences found
6 matching files
```

Exit `APP01`:
```bash
exit
```

---

## 5. Phase 4: Deploy Amazon CloudFront with Origin Access Control (OAC)

To deliver video and poster assets with low latency and support video scrub-seeking, we deploy an **Amazon CloudFront** Content Delivery Network (CDN) distribution.

Using **Origin Access Control (OAC)** ensures that users cannot bypass the CDN or access S3 directly.

### Step 4.1: Create CloudFront Distribution (UI Console & CLI)

#### Option A: Via AWS Management Console (Click-by-Click UI)
1. In the AWS Management Console, search for **CloudFront** and click **CloudFront**.
2. Click the orange **Create distribution** button.
3. **Origin**:
   * **Origin domain**: Click the text box and select `streamflix-media-165772574557.s3.us-east-1.amazonaws.com`.
   * **Name**: Auto-populates `streamflix-media-165772574557.s3.us-east-1.amazonaws.com`.
   * **Origin access**: Select **`Origin access control settings (recommended)`**.
   * Under **Origin access control**, click **Create control setting**:
     * Name: `streamflix-media-oac`
     * Origin type: Select **S3**.
     * Signing behavior: **Sign requests (recommended)**.
     * Click **Create**.
4. **Default cache behavior**:
   * **Viewer protocol policy**: Select **Redirect HTTP to HTTPS**.
   * **Allowed HTTP methods**: Select **`GET, HEAD, OPTIONS`**.
   * **Cache key and origin requests**: Select **Cache policy and origin request policy (recommended)**.
     * Cache policy: Select **`CachingOptimized`**.
     * Origin request policy: Select **`CORS-S3Origin`**.
5. **Web Application Firewall (WAF)**:
   * Select **Do not enable security protections** *(To prevent unexpected AWS WAF hourly charges in the lab)*.
6. **Settings**:
   * **Price class**: Select **Use only North America and Europe** (or Best performance).
   * **Description**: Enter `StreamFlix Media CDN`.
7. Click the orange **Create distribution** button at the bottom.

---

### Step 4.2: Update S3 Bucket Policy with CloudFront OAC Authorization
Immediately after creating the distribution, AWS CloudFront displays a yellow banner at the top:
> *"The S3 bucket policy needs to be updated..."*

1. Click the white **Copy policy** button in the CloudFront banner.
   *(Alternatively, use the JSON policy template below, replacing your Distribution ID and Account ID)*:

```json
{
    "Version": "2012-10-17",
    "Statement": {
        "Sid": "AllowCloudFrontServicePrincipalReadOnly",
        "Effect": "Allow",
        "Principal": {
            "Service": "cloudfront.amazonaws.com"
        },
        "Action": "s3:GetObject",
        "Resource": "arn:aws:s3:::streamflix-media-165772574557/*",
        "Condition": {
            "StringEquals": {
                "AWS:SourceArn": "arn:aws:cloudfront::165772574557:distribution/<YOUR_DISTRIBUTION_ID>"
            }
        }
    }
}
```

2. Go to **S3 Console** $\to$ Click **`streamflix-media-165772574557`** $\to$ Click the **Permissions** tab.
3. Scroll down to **Bucket policy** $\to$ Click **Edit**.
4. Paste the copied policy into the editor and click **Save changes**.

---

### Step 4.3: Retrieve CloudFront Domain Name
1. Return to the **CloudFront Console** $\to$ Click **Distributions**.
2. Locate your distribution and copy the **Distribution domain name**.
   *(It will look like `d123456abcdef8.cloudfront.net`)*.

---

## 6. Phase 5: Verification & Video Streaming Tests

Now verify that video files and posters stream smoothly through CloudFront.

### Step 5.1: Test Asset Delivery via CloudFront
From your workstation terminal:

```bash
# IMPORTANT: Provide only the raw domain name (DO NOT include https://)
CF_DOMAIN="<YOUR_CLOUDFRONT_DOMAIN>"

# 1. Test Poster SVG download
curl -I https://$CF_DOMAIN/posters/migration.svg
```

> [!IMPORTANT]
> When assigning `CF_DOMAIN`, omit the `https://` protocol prefix (e.g., use `d2mq4y5w2vj2m3.cloudfront.net`, NOT `https://d2mq4y5w2vj2m3.cloudfront.net`). If `https://` is included in the variable, running `https://$CF_DOMAIN/...` results in `https://https://...` and fails with `curl: (6) Could not resolve host: https`.

**Expected Output:**
```text
HTTP/2 200 
content-type: image/svg+xml
etag: "5f85ff579ed59ab14905ae574cd3efe9"
x-cache: Hit from cloudfront (or Miss from cloudfront)
```

---

### Step 5.2: Test Video Range Requests (HTTP 206 Partial Content)
Video players require HTTP `Range` requests so users can jump forward and backward in videos without downloading the whole file:

```bash
# Request the first 1024 bytes of the video
curl -i \
  -H "Range: bytes=0-1023" \
  https://$CF_DOMAIN/videos/migration.mp4 | head -n 15
```

**Expected Output:**
```text
HTTP/2 206 Partial Content
content-type: video/mp4
content-range: bytes 0-1023/230692
content-length: 1024
etag: "11c6266a8ec93605f975972112158514"
server: AmazonS3
x-cache: Miss from cloudfront
via: 1.1 ... CloudFront
```
*HTTP/2 206 Partial Content confirms video streaming scrub-seeking is fully functional!*

---

### Step 5.3: Verify Direct S3 Access is Blocked (Security Check)
Confirm that unauthorized users cannot bypass CloudFront to download directly from S3:

```bash
curl -I https://streamflix-media-165772574557.s3.amazonaws.com/videos/migration.mp4
```
**Expected Output:**
```text
HTTP/1.1 403 Forbidden
```
*(403 Forbidden confirms that Origin Access Control (OAC) is strictly enforcing CDN-only access!)*

---

## 7. Phase 6: Application Media Re-Targeting on APP01

Now reconfigure StreamFlix to serve all movie posters and video streaming streams from CloudFront instead of the local SMB mount.

### Step 6.1a: Grant Table-Level Permissions on Target Amazon RDS
When AWS DMS performs the Initial Full Load, it creates the database tables under the master user `postgres`. In PostgreSQL, privileges granted on a database do not cascade to newly created tables. The application user `streamflix_user` requires explicit grants on schema `public` tables and sequences.

From `DB01` (or any host with RDS network access):
```bash
PGPASSWORD='MasterAdminPass2026!' psql \
  -h "<YOUR_RDS_ENDPOINT>" \
  -U postgres \
  -d streamflix_db \
  -c "GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO streamflix_user; GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO streamflix_user; ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO streamflix_user;"
```

---

### Step 6.1b: Update Application Environment on APP01
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
MEDIA_BASE_URL=https://<YOUR_CLOUDFRONT_DOMAIN>
EOF
```
*(Ensure there are no leading spaces after `=` in the variable assignments)*.

---

### Step 6.1c: Update Backend Code (`server.js`) with Dynamic URL Enrichment & RDS SSL
Amazon RDS PostgreSQL enforces SSL connections over VPN. Furthermore, `server.js` dynamically prefixes `MEDIA_BASE_URL` to create `poster_url` and `video_url` for CloudFront delivery:

```bash
cat << 'SERVER_EOF' | sudo tee /var/www/streamflix/backend/server.js
require('dotenv').config();
const express = require('express');
const cors = require('cors');
const { Pool } = require('pg');

const app = express();
const PORT = process.env.PORT || 5000;

// Enable SSL encryption automatically when connecting to Amazon RDS
const isRds = process.env.DB_HOST && !process.env.DB_HOST.includes('10.10.10.30') && !process.env.DB_HOST.includes('localhost');

const pool = new Pool({
  host: process.env.DB_HOST || '10.10.10.30',
  port: parseInt(process.env.DB_PORT || '5432'),
  user: process.env.DB_USER || 'streamflix_user',
  password: process.env.DB_PASSWORD || 'StreamFlixPass2026!',
  database: process.env.DB_NAME || 'streamflix_db',
  ssl: isRds ? { rejectUnauthorized: false } : false
});

app.use(cors());
app.use(express.json());

const getMediaBaseUrl = () => (process.env.MEDIA_BASE_URL || '').trim().replace(/\/$/, '');

function formatMovie(movie) {
  const mediaBase = getMediaBaseUrl();
  const posterRel = movie.poster_path ? movie.poster_path.replace(/^\/media/, '') : '';
  const videoRel = movie.video_path ? movie.video_path.replace(/^\/media/, '') : '';

  const posterUrl = mediaBase ? `${mediaBase}${posterRel}` : movie.poster_path;
  const videoUrl = mediaBase ? `${mediaBase}${videoRel}` : movie.video_path;

  return {
    ...movie,
    poster_path: posterUrl,
    video_path: videoUrl,
    poster_url: posterUrl,
    video_url: videoUrl
  };
}

app.get('/api/health', async (req, res) => {
  try {
    const dbCheck = await pool.query('SELECT 1 AS alive');
    res.json({
      status: 'UP',
      service: 'StreamFlix API',
      host: 'APP01',
      database: dbCheck.rows[0].alive === 1 ? 'CONNECTED' : 'DISCONNECTED',
      db_target: process.env.DB_HOST ? 'AWS RDS (' + process.env.DB_HOST + ')' : 'On-Premises (10.10.10.30)',
      media_base_url: getMediaBaseUrl() || 'local (/media)',
      timestamp: new Date().toISOString()
    });
  } catch (err) {
    res.status(503).json({
      status: 'DEGRADED',
      service: 'StreamFlix API',
      error: err.message,
      timestamp: new Date().toISOString()
    });
  }
});

app.get('/api/movies', async (req, res) => {
  try {
    const { rows } = await pool.query('SELECT * FROM movies ORDER BY id ASC');
    res.json(rows.map(formatMovie));
  } catch (err) {
    res.status(500).json({ error: 'Failed to retrieve movie catalog', details: err.message });
  }
});

app.get('/api/movies/:id', async (req, res) => {
  try {
    const { rows } = await pool.query('SELECT * FROM movies WHERE id = $1', [req.params.id]);
    if (rows.length === 0) return res.status(404).json({ error: 'Movie not found' });
    res.json(formatMovie(rows[0]));
  } catch (err) {
    res.status(500).json({ error: 'Failed to retrieve movie details', details: err.message });
  }
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`[StreamFlix Backend] Running on port ${PORT} on APP01`);
});
SERVER_EOF
```

---

### Step 6.1d: Configure Systemd Environment Loading & Restart Service
Ensure systemd imports `/var/www/streamflix/backend/.env` upon startup:

```bash
# Add EnvironmentFile directive if not present
if ! grep -q "EnvironmentFile" /etc/systemd/system/streamflix-backend.service; then
  sudo sed -i "/\[Service\]/a EnvironmentFile=-/var/www/streamflix/backend/.env" /etc/systemd/system/streamflix-backend.service
fi

# Reload systemd and restart service
sudo systemctl daemon-reload
sudo systemctl restart streamflix-backend
sudo systemctl status streamflix-backend --no-pager
```

---

### Step 6.2: Validate End-to-End Media Delivery

1. **Verify Health Endpoint**:
   ```bash
   curl -s http://localhost/api/health | jq .
   ```
   **Expected Output:**
   ```json
   {
     "status": "UP",
     "service": "StreamFlix API",
     "host": "APP01",
     "database": "CONNECTED",
     "db_target": "AWS RDS (streamflix-target-db.cy9mak0su1oj.us-east-1.rds.amazonaws.com)",
     "media_base_url": "https://<YOUR_CLOUDFRONT_DOMAIN>",
     "timestamp": "2026-11-13T17:03:09.521Z"
   }
   ```

2. **Verify Movie Catalog API**:
   ```bash
   curl -s http://localhost/api/movies | jq .
   ```
   **Expected Output:**
   ```json
   [
     {
       "id": 1,
       "title": "Cloud Migration Chronicles",
       "description": "An epic documentary following legacy monolith migration to cloud infrastructure.",
       "release_year": 2026,
       "genre": "Documentary",
       "duration_minutes": 85,
       "poster_path": "https://<YOUR_CLOUDFRONT_DOMAIN>/posters/migration.svg",
       "video_path": "https://<YOUR_CLOUDFRONT_DOMAIN>/videos/migration.mp4",
       "created_at": "2026-11-13T10:18:34.345Z",
       "poster_url": "https://<YOUR_CLOUDFRONT_DOMAIN>/posters/migration.svg",
       "video_url": "https://<YOUR_CLOUDFRONT_DOMAIN>/videos/migration.mp4"
     },
     {
       "id": 2,
       "title": "KVM Virtualization Horizons",
       "description": "A deep dive into Linux Kernel-based Virtual Machine architecture and libvirt.",
       "release_year": 2025,
       "genre": "Sci-Fi",
       "duration_minutes": 110,
       "poster_path": "https://<YOUR_CLOUDFRONT_DOMAIN>/posters/hyperv.svg",
       "video_path": "https://<YOUR_CLOUDFRONT_DOMAIN>/videos/hyperv.mp4",
       "created_at": "2026-11-13T10:18:34.345Z",
       "poster_url": "https://<YOUR_CLOUDFRONT_DOMAIN>/posters/hyperv.svg",
       "video_url": "https://<YOUR_CLOUDFRONT_DOMAIN>/videos/hyperv.mp4"
     },
     {
       "id": 3,
       "title": "Samba in the Datacenter",
       "description": "Building resilient Active Directory domains on Linux platforms.",
       "release_year": 2024,
       "genre": "Tech Drama",
       "duration_minutes": 95,
       "poster_path": "https://<YOUR_CLOUDFRONT_DOMAIN>/posters/samba.svg",
       "video_path": "https://<YOUR_CLOUDFRONT_DOMAIN>/videos/samba.mp4",
       "created_at": "2026-11-13T10:18:34.345Z",
       "poster_url": "https://<YOUR_CLOUDFRONT_DOMAIN>/posters/samba.svg",
       "video_url": "https://<YOUR_CLOUDFRONT_DOMAIN>/videos/samba.mp4"
     },
     {
       "id": 4,
       "title": "The Matrix Resurrections",
       "description": "Return to a world of two realities: one, everyday life; the other, what lies behind it.",
       "release_year": 2021,
       "genre": "Sci-Fi",
       "duration_minutes": 148,
       "poster_path": "https://<YOUR_CLOUDFRONT_DOMAIN>/posters/matrix.svg",
       "video_path": "https://<YOUR_CLOUDFRONT_DOMAIN>/videos/matrix.mp4",
       "created_at": "2026-11-13T14:57:52.599Z",
       "poster_url": "https://<YOUR_CLOUDFRONT_DOMAIN>/posters/matrix.svg",
       "video_url": "https://<YOUR_CLOUDFRONT_DOMAIN>/videos/matrix.mp4"
     }
   ]
   ```

Exit `APP01`:
```bash
exit
```

---

## 8. Verification Checklist & Success Criteria

| # | Check Item | Verification Command / URL | Expected Result | Status |
| :-: | :--- | :--- | :--- | :-: |
| 1 | **Source Baseline** | `find /mnt/file01/media -type f \| wc -l` | Exactly 6 files | [ ] |
| 2 | **S3 Provisioned** | `aws s3 ls s3://streamflix-media-165772574557` | Bucket accessible | [ ] |
| 3 | **Block Public Access** | S3 Permissions tab in Console | All 4 blocks ON | [ ] |
| 4 | **Rclone Sync** | `rclone check /mnt/file01/media ...` | 0 differences found | [ ] |
| 5 | **CloudFront OAC** | CloudFront Console Distribution | Status: `Enabled` | [ ] |
| 6 | **HTTP 206 Streaming** | `curl -i -H "Range: bytes=0-1023" ...` | `HTTP/2 206 Partial Content` | [ ] |
| 7 | **Direct S3 Blocked** | `curl -I https://<bucket>.s3.amazonaws.com/...` | `HTTP 403 Forbidden` | [ ] |
| 8 | **App Integration** | `curl -s http://10.10.10.20/api/movies` | Media URLs point to CloudFront | [ ] |

---

## 9. Rollback Runbook (In Case of Issues)

If CloudFront or S3 testing requires temporary rollback:
1. Revert `APP01` media path to local SMB share:
   ```bash
   cat << EOF | sudo tee /var/www/streamflix/backend/.env
   PORT=5000
   DB_HOST=<YOUR_RDS_ENDPOINT>
   DB_PORT=5432
   DB_NAME=streamflix_db
   DB_USER=streamflix_user
   DB_PASSWORD=StreamFlixPass2026!
   MEDIA_BASE_URL=/media
   EOF
   sudo systemctl restart streamflix-backend
   sudo systemctl status streamflix-backend --no-pager
   ```
2. Verify local playback:
   ```bash
   curl -s http://localhost/api/movies
   ```
   *The application will immediately resume serving assets from `/mnt/file01/media`.*

---

## 10. Troubleshooting & Root Cause Analysis (RCA) Guide

This section documents real-world production incidents, exact root causes, and resolutions encountered during Stage 4 execution.

```
+----------------------------------------------------------------------------------------------------+
| STAGE 4 ROOT CAUSE ANALYSIS & ERROR RESOLUTION MATRIX                                               |
+----------------------------------------------------------------------------------------------------+
| Phase / Step | Error Message / Symptom             | Root Cause              | Resolution          |
+--------------+-------------------------------------+-------------------------+---------------------+
| Phase 5      | curl: (6) Could not resolve host:   | Accidental duplicate    | Omit https:// from  |
| Step 5.2     | https                               | https:// in variable    | CF_DOMAIN variable  |
+--------------+-------------------------------------+-------------------------+---------------------+
| Phase 6      | no pg_hba.conf entry ...            | AWS RDS PostgreSQL      | Enable SSL in       |
| Step 6.1c    | no encryption                       | enforces SSL over VPN   | node pg Pool config |
+--------------+-------------------------------------+-------------------------+---------------------+
| Phase 6      | permission denied for table         | AWS DMS created tables  | Grant ALL on ALL    |
| Step 6.1a    | movies (code 42501)                 | as postgres master user | TABLES to app user  |
+--------------+-------------------------------------+-------------------------+---------------------+
| Phase 6      | curl /api/movies still outputs      | Missing systemd env     | Add EnvironmentFile |
| Step 6.1d    | /media/posters/... (no CloudFront)  | loading & URL mapping   | & formatMovie map   |
+--------------+-------------------------------------+-------------------------+---------------------+
| Phase 6      | Unit streamflix.service             | Service named           | Symlink streamflix  |
| Step 6.1d    | could not be found                  | streamflix-backend      | to backend unit     |
+----------------------------------------------------------------------------------------------------+
```

---

### Incident 1: `curl: (6) Could not resolve host: https`

* **Location**: Phase 5, Step 5.2 (CloudFront Range Requests).
* **Symptom**:
  ```text
  curl: (6) Could not resolve host: https
  ```
* **Root Cause**: The variable was defined with `CF_DOMAIN="https://d2mq4y5w2vj2m3.cloudfront.net"`. When executed as `curl https://$CF_DOMAIN/...`, the resulting URL expanded to `https://https://d2mq4y5w2vj2m3.cloudfront.net/...`. Curl interpreted the first `https` as the destination hostname.
* **Resolution**: Define `CF_DOMAIN="d2mq4y5w2vj2m3.cloudfront.net"` containing strictly the Fully Qualified Domain Name (FQDN) without protocol scheme.

---

### Incident 2: `no pg_hba.conf entry for host "...", user "streamflix_user", no encryption`

* **Location**: Phase 6, Step 6.1c (Application Cutover to Amazon RDS).
* **Symptom**:
  ```json
  {"status":"DEGRADED","service":"StreamFlix API","error":"no pg_hba.conf entry for host \"10.10.1.10\", user \"streamflix_user\", database \"streamflix_db\", no encryption"}
  ```
* **Root Cause**: Amazon RDS PostgreSQL parameter groups enforce SSL encryption for remote connections traversing the VPN tunnel (`10.10.0.0/16`). Node.js `pg.Pool` defaults to unencrypted plaintext connections.
* **Resolution**: In `server.js`, configure `ssl: { rejectUnauthorized: false }` whenever connecting to Amazon RDS:
  ```javascript
  const isRds = process.env.DB_HOST && !process.env.DB_HOST.includes('10.10.10.30') && !process.env.DB_HOST.includes('localhost');
  const pool = new Pool({
    // ...
    ssl: isRds ? { rejectUnauthorized: false } : false
  });
  ```

---

### Incident 3: `ERROR 42501: permission denied for table movies`

* **Location**: Phase 6, Step 6.1a (PostgreSQL Table Privileges).
* **Symptom**:
  ```text
  error: permission denied for table movies (code 42501, routine: aclcheck_error)
  ```
* **Root Cause**: When AWS DMS executes the Full Load migration task, it authenticates as master user `postgres` and creates the target schema tables. In PostgreSQL, database-level grants (`GRANT ALL PRIVILEGES ON DATABASE ...`) do not cascade to existing or newly created tables in schema `public`.
* **Resolution**: Connect to RDS as master user `postgres` and explicitly grant schema and table permissions:
  ```sql
  GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO streamflix_user;
  GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO streamflix_user;
  ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO streamflix_user;
  ```

---

### Incident 4: `curl -s http://localhost/api/movies` Still Returning Local `/media/posters/...` Paths

* **Location**: Phase 6, Step 6.1b/c/d (Media Retargeting).
* **Symptom**:
  Running `curl -s http://localhost/api/movies | jq .` continued to output `/media/posters/migration.svg` even after setting `MEDIA_BASE_URL` in `/var/www/streamflix/backend/.env`.
* **Root Cause**:
  1. The systemd service unit `/etc/systemd/system/streamflix-backend.service` was missing `EnvironmentFile=-/var/www/streamflix/backend/.env`. Therefore, systemd never passed `.env` variables into `process.env`.
  2. `server.js` was outputting raw SQL rows (`res.json(rows)`) without prefixing `MEDIA_BASE_URL`.
* **Resolution**:
  1. Add `EnvironmentFile=-/var/www/streamflix/backend/.env` under `[Service]` in the systemd unit.
  2. In `server.js`, dynamically map each movie to prepend `MEDIA_BASE_URL`, populating both `poster_url` and `video_url`.

---

### Incident 5: `Unit streamflix.service could not be found`

* **Location**: Phase 6, Step 6.1d (Service Management).
* **Symptom**:
  ```text
  Failed to restart streamflix.service: Unit streamflix.service could not be found.
  ```
* **Root Cause**: The provisioning script named the service `streamflix-backend.service`.
* **Resolution**: Create an alias symlink on `APP01`:
  ```bash
  sudo ln -sf /etc/systemd/system/streamflix-backend.service /etc/systemd/system/streamflix.service
  sudo systemctl daemon-reload
  ```

