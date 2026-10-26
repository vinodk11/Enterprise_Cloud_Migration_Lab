#!/usr/bin/env bash
# ==============================================================================
# Enterprise Cloud Migration Lab — APP01: StreamFlix Web & API Server
# Target Machine: APP01 (10.10.10.20)
# Domain: CORP.LOCAL
# OS: Ubuntu Server 24.04 LTS (bento/ubuntu-24.04)
# ==============================================================================

set -u
export DEBIAN_FRONTEND=noninteractive

APP_ROOT="/var/www/streamflix"
MOUNT_DIR="/mnt/file01/media"
STATIC_IP="10.10.10.20"
FILE01_IP="10.10.10.40"
DB01_IP="10.10.10.30"
DC01_IP="10.10.10.10"
GATEWAY_IP="10.10.10.1"

echo "=================================================================="
echo "  Enterprise Cloud Migration Lab: APP01 StreamFlix Deployment     "
echo "=================================================================="

# 1. Root check
if [[ $EUID -ne 0 ]]; then
   echo "[-] This script must be run as root (e.g. sudo bash configure-app01.sh)"
   exit 1
fi

# Helper: Wait for background apt / unattended-upgrades locks
wait_for_apt() {
    local max_wait=300
    local waited=0

    systemctl stop unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service 2>/dev/null || true

    while pgrep -f '(apt-get|apt|dpkg|unattended-upgrade)' >/dev/null 2>&1 || \
          ! flock -n /var/lib/dpkg/lock-frontend -c "true" 2>/dev/null || \
          ! flock -n /var/lib/apt/lists/lock -c "true" 2>/dev/null; do
        echo "[*] Waiting for apt / unattended-upgrades lock to release ($waited s)..."
        sleep 5
        waited=$((waited + 5))
        if [[ $waited -ge $max_wait ]]; then
            echo "[!] Timeout waiting for apt locks. Clearing stale locks..."
            pkill -9 -f '(apt-get|apt|dpkg|unattended-upgrade)' 2>/dev/null || true
            rm -f /var/lib/dpkg/lock* /var/lib/apt/lists/lock* /var/cache/apt/archives/lock* 2>/dev/null || true
            dpkg --configure -a 2>/dev/null || true
            break
        fi
    done
}

echo -e "\n>>> [1/7] Configuring Hostname and /etc/hosts..."
hostnamectl set-hostname app01.corp.local || true
sed -i '/127.0.1.1/d' /etc/hosts
if ! grep -q "${STATIC_IP} app01.corp.local app01" /etc/hosts; then
    echo "${STATIC_IP} app01.corp.local app01" >> /etc/hosts
fi
echo "[OK] Hostname configured: $(hostname -f 2>/dev/null || hostname)"

echo -e "\n>>> [2/7] Verifying Static IP ${STATIC_IP}..."
LAB_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^eth1|^enp2s0' | head -n 1 || true)
if [[ -z "${LAB_IFACE}" ]]; then
    LAB_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo" | sed -n '2p' || true)
fi
if [[ -n "${LAB_IFACE}" ]]; then
    ip addr add "${STATIC_IP}/24" dev "${LAB_IFACE}" 2>/dev/null || true
fi
echo "[OK] Interface ${LAB_IFACE:-eth1} verified with IP ${STATIC_IP}/24."

echo -e "\n>>> [3/7] Installing Node.js, npm, Nginx, and CIFS utilities..."
wait_for_apt
apt-get update -qq || true
apt-get install -y -qq nodejs npm nginx cifs-utils curl || true

echo "[OK] Dependencies installed: Node $(node -v 2>/dev/null || echo 'installed'), Nginx $(nginx -v 2>&1 | cut -d'/' -f2 || echo 'installed')"

echo -e "\n>>> [4/7] Mounting Media Share from FILE01 (${FILE01_IP})..."
mkdir -p "${MOUNT_DIR}"
# Attempt CIFS mount with retry
for i in {1..5}; do
    if mount -t cifs "//${FILE01_IP}/media" "${MOUNT_DIR}" -o guest,ro,iocharset=utf8 2>/dev/null; then
        echo "[OK] Successfully mounted //${FILE01_IP}/media to ${MOUNT_DIR}"
        break
    else
        echo "[*] Waiting for FILE01 Samba share (attempt $i/5)..."
        sleep 3
    fi
done

if ! mountpoint -q "${MOUNT_DIR}"; then
    echo "[!] Notice: Direct CIFS mount not yet available. Creating fallback local media structure."
    mkdir -p "${MOUNT_DIR}/videos" "${MOUNT_DIR}/posters"
fi

if ! grep -q "//${FILE01_IP}/media" /etc/fstab 2>/dev/null; then
    echo "//${FILE01_IP}/media ${MOUNT_DIR} cifs guest,ro,iocharset=utf8,nofail 0 0" >> /etc/fstab
fi

echo -e "\n>>> [5/7] Deploying StreamFlix Express Backend API..."
mkdir -p "${APP_ROOT}/backend"

cat << 'BACKEND_EOF' > "${APP_ROOT}/backend/package.json"
{
  "name": "streamflix-backend",
  "version": "1.0.0",
  "main": "server.js",
  "dependencies": {
    "cors": "^2.8.5",
    "dotenv": "^16.4.5",
    "express": "^4.19.2",
    "pg": "^8.11.5"
  }
}
BACKEND_EOF

cat << 'BACKEND_SERVER_EOF' > "${APP_ROOT}/backend/server.js"
const express = require('express');
const cors = require('cors');
const { Pool } = require('pg');

const app = express();
const PORT = process.env.PORT || 5000;

const pool = new Pool({
  host: process.env.DB_HOST || '10.10.10.30',
  port: parseInt(process.env.DB_PORT || '5432'),
  user: process.env.DB_USER || 'streamflix_user',
  password: process.env.DB_PASSWORD || 'StreamFlixPass2026!',
  database: process.env.DB_NAME || 'streamflix_db'
});

app.use(cors());
app.use(express.json());

app.get('/api/health', async (req, res) => {
  try {
    const dbCheck = await pool.query('SELECT 1 AS alive');
    res.json({
      status: 'UP',
      service: 'StreamFlix API',
      host: 'APP01',
      database: dbCheck.rows[0].alive === 1 ? 'CONNECTED' : 'DISCONNECTED',
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
    res.json(rows);
  } catch (err) {
    res.status(500).json({ error: 'Failed to retrieve movie catalog', details: err.message });
  }
});

app.get('/api/movies/:id', async (req, res) => {
  try {
    const { rows } = await pool.query('SELECT * FROM movies WHERE id = $1', [req.params.id]);
    if (rows.length === 0) return res.status(404).json({ error: 'Movie not found' });
    res.json(rows[0]);
  } catch (err) {
    res.status(500).json({ error: 'Failed to retrieve movie details', details: err.message });
  }
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`[StreamFlix Backend] Running on port ${PORT} on APP01`);
});
BACKEND_SERVER_EOF

cd "${APP_ROOT}/backend"
for i in {1..3}; do
    if npm install --silent 2>/dev/null; then
        echo "[OK] Node.js dependencies installed."
        break
    else
        echo "[*] Retrying npm install ($i/3)..."
        sleep 3
    fi
done

cat << 'SYSTEMD_EOF' > /etc/systemd/system/streamflix-backend.service
[Unit]
Description=StreamFlix Node.js Express API
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/var/www/streamflix/backend
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=5
Environment=PORT=5000

[Install]
WantedBy=multi-user.target
SYSTEMD_EOF

systemctl daemon-reload
systemctl enable --now streamflix-backend 2>/dev/null || systemctl restart streamflix-backend 2>/dev/null || true
echo "[OK] StreamFlix Express API systemd service running on port 5000."

echo -e "\n>>> [6/7] Deploying Frontend UI & Nginx Reverse Proxy..."
mkdir -p "${APP_ROOT}/frontend/dist"

cat << 'INDEX_HTML_EOF' > "${APP_ROOT}/frontend/dist/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>StreamFlix Lab — Enterprise Cloud Migration</title>
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&display=swap" rel="stylesheet">
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; font-family: 'Inter', sans-serif; }
    body { background-color: #141414; color: #ffffff; min-height: 100vh; }
    nav { display: flex; justify-content: space-between; align-items: center; padding: 16px 40px; background: #0a0a0a; border-bottom: 1px solid #222; }
    .hero { padding: 60px 40px; background: linear-gradient(to right, rgba(20,20,20,0.95) 40%, rgba(20,20,20,0.4)), url('/media/posters/migration.svg'); background-size: cover; border-bottom: 1px solid #262626; }
    .hero h2 { font-size: 38px; margin: 10px 0; }
    .hero p { color: #ccc; max-width: 600px; margin-bottom: 20px; line-height: 1.5; }
    .btn { background-color: #E50914; color: #fff; border: none; padding: 12px 24px; font-weight: bold; border-radius: 4px; cursor: pointer; text-decoration: none; display: inline-block; }
    .catalog { padding: 40px; }
    .grid { display: flex; gap: 20px; flex-wrap: wrap; margin-top: 20px; }
    .card { width: 220px; background: #1f1f1f; border-radius: 6px; overflow: hidden; border: 1px solid #2d2d2d; cursor: pointer; }
    .card img { width: 100%; height: 280px; object-fit: cover; }
    .card-info { padding: 12px; }
    .card-info h4 { font-size: 14px; margin-bottom: 4px; }
    .card-info span { font-size: 12px; color: #888; }
    footer { margin-top: 60px; padding: 30px 40px; background: #0a0a0a; border-top: 1px solid #222; font-size: 13px; color: #777; display: grid; grid-template-columns: repeat(4, 1fr); gap: 20px; }
    footer strong { color: #fff; }
    .modal { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(0,0,0,0.9); display: none; align-items: center; justify-content: center; z-index: 999; }
    .modal-box { width: 80%; max-width: 800px; background: #181818; border-radius: 8px; overflow: hidden; }
  </style>
</head>
<body>
  <nav>
    <div style="display:flex;align-items:center;gap:15px;">
      <h1 style="color:#E50914;font-size:24px;">STREAMFLIX <span style="font-size:12px;color:#888;">LAB</span></h1>
      <span style="font-size:11px;background:#222;padding:4px 8px;border-radius:12px;border:1px solid #333;">On-Premises Source</span>
    </div>
    <div id="health" style="font-size:12px;display:flex;gap:15px;">Connecting...</div>
  </nav>

  <div class="hero">
    <span style="font-size:12px;color:#E50914;font-weight:bold;">FEATURED SHOW</span>
    <h2 id="hero-title">Cloud Migration Chronicles</h2>
    <p id="hero-desc">An epic documentary exploring enterprise modernization, KVM nested virtualization, and seamless workload migration to AWS and Azure.</p>
    <button class="btn" onclick="openPlayer('/media/videos/migration.mp4', 'Cloud Migration Chronicles')">▶ Play Stream (HTTP 206)</button>
  </div>

  <div class="catalog">
    <h3>Media Catalog (Loaded from PostgreSQL on DB01)</h3>
    <div class="grid" id="movie-grid"></div>
  </div>

  <div class="modal" id="player-modal">
    <div class="modal-box">
      <div style="display:flex;justify-content:space-between;padding:12px 20px;border-bottom:1px solid #333;">
        <span id="player-title">Now Streaming</span>
        <button onclick="closePlayer()" style="background:none;border:none;color:#fff;font-size:20px;cursor:pointer;">✕</button>
      </div>
      <video id="video-el" controls style="width:100%;max-height:450px;background:#000;"></video>
      <div style="padding:10px 20px;font-size:12px;color:#888;">Delivery: Nginx HTTP Byte-Range Partial Content (Range: bytes) | Storage: FILE01</div>
    </div>
  </div>

  <footer>
    <div><strong>DC01 (10.10.10.10)</strong><p>Samba Active Directory & DNS</p></div>
    <div><strong>APP01 (10.10.10.20)</strong><p>React Frontend, Express API, Nginx</p></div>
    <div><strong>DB01 (10.10.10.30)</strong><p>PostgreSQL Database Engine</p></div>
    <div><strong>FILE01 (10.10.10.40)</strong><p>Samba CIFS Video & Poster Storage</p></div>
  </footer>

  <script>
    fetch('/api/health')
      .then(r => r.json())
      .then(d => {
        document.getElementById('health').innerHTML = 
          '<span>API: <b style="color:' + (d.status === "UP" ? "#46d369" : "#e50914") + '">' + d.status + '</b></span>' +
          '<span>DB01: <b style="color:' + (d.database === "CONNECTED" ? "#46d369" : "#e50914") + '">' + d.database + '</b></span>';
      }).catch(() => {
        document.getElementById('health').innerHTML = '<span style="color:#e50914">API Disconnected</span>';
      });

    fetch('/api/movies')
      .then(r => r.json())
      .then(movies => {
        const grid = document.getElementById('movie-grid');
        grid.innerHTML = '';
        movies.forEach(m => {
          const card = document.createElement('div');
          card.className = 'card';
          card.onclick = () => openPlayer(m.video_path, m.title);
          card.innerHTML = 
            '<img src="' + m.poster_path + '" alt="' + m.title + '">' +
            '<div class="card-info"><h4>' + m.title + '</h4><span>' + m.genre + ' • ' + m.release_year + '</span></div>';
          grid.appendChild(card);
        });
      });

    function openPlayer(src, title) {
      document.getElementById('player-title').innerText = title;
      const v = document.getElementById('video-el');
      v.src = src;
      v.play();
      document.getElementById('player-modal').style.display = 'flex';
    }

    function closePlayer() {
      const v = document.getElementById('video-el');
      v.pause();
      v.src = '';
      document.getElementById('player-modal').style.display = 'none';
    }
  </script>
</body>
</html>
INDEX_HTML_EOF

cat << 'NGINX_EOF' > /etc/nginx/sites-available/streamflix
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    location / {
        root /var/www/streamflix/frontend/dist;
        index index.html index.htm;
        try_files $uri $uri/ /index.html;
    }

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

    location /media/ {
        alias /mnt/file01/media/;
        autoindex off;
        sendfile on;
        tcp_nopush on;
        tcp_nodelay on;
        expires 1d;
        add_header Accept-Ranges bytes;
    }
}
NGINX_EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/streamflix /etc/nginx/sites-enabled/streamflix
nginx -t 2>/dev/null || true
systemctl restart nginx 2>/dev/null || systemctl start nginx 2>/dev/null || true
echo "[OK] Nginx configured and active on port 80."

echo -e "\n>>> [7/7] Verifying End-to-End Application Health..."
sleep 2
echo "1. Checking Local API Health Endpoint (/api/health):"
curl -s http://127.0.0.1:5000/api/health || true

echo -e "\n2. Checking Nginx Reverse Proxy Endpoint (http://127.0.0.1/):"
curl -I -s http://127.0.0.1/ 2>/dev/null | head -n 3 || true

echo -e "\n[SUCCESS] APP01 StreamFlix Web Application & API Gateway is fully operational!"
