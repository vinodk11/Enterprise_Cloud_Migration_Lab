#!/usr/bin/env bash
# ==============================================================================
# Enterprise Cloud Migration Lab — DB01: PostgreSQL Database Server
# Target Machine: DB01 (10.10.10.30)
# Domain: CORP.LOCAL
# OS: Ubuntu Server 24.04 LTS (bento/ubuntu-24.04)
# ==============================================================================

set -u
export DEBIAN_FRONTEND=noninteractive

DB_NAME="streamflix_db"
DB_USER="streamflix_user"
DB_PASS="StreamFlixPass2026!"
STATIC_IP="10.10.10.30"
APP_IP="10.10.10.20"
GATEWAY_IP="10.10.10.1"
DC_IP="10.10.10.10"

echo "=================================================================="
echo "  Enterprise Cloud Migration Lab: DB01 PostgreSQL Setup           "
echo "=================================================================="

# 1. Root check
if [[ $EUID -ne 0 ]]; then
   echo "[-] This script must be run as root (e.g. sudo bash configure-db01.sh)"
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

echo -e "\n>>> [1/6] Configuring Hostname and /etc/hosts..."
hostnamectl set-hostname db01.corp.local || true
sed -i '/127.0.1.1/d' /etc/hosts
if ! grep -q "${STATIC_IP} db01.corp.local db01" /etc/hosts; then
    echo "${STATIC_IP} db01.corp.local db01" >> /etc/hosts
fi
echo "[OK] Hostname configured: $(hostname -f 2>/dev/null || hostname)"

echo -e "\n>>> [2/6] Verifying Static IP ${STATIC_IP}..."
LAB_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^eth1|^enp2s0' | head -n 1 || true)
if [[ -z "${LAB_IFACE}" ]]; then
    LAB_IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v "lo" | sed -n '2p' || true)
fi
if [[ -n "${LAB_IFACE}" ]]; then
    ip addr add "${STATIC_IP}/24" dev "${LAB_IFACE}" 2>/dev/null || true
fi
echo "[OK] Interface ${LAB_IFACE:-eth1} verified with IP ${STATIC_IP}/24."

echo -e "\n>>> [3/6] Installing PostgreSQL Engine..."
wait_for_apt
apt-get update -qq || true
apt-get install -y -qq postgresql postgresql-contrib || true

systemctl enable --now postgresql 2>/dev/null || true
systemctl start postgresql 2>/dev/null || true
PG_VERSION=$(ls /etc/postgresql/ 2>/dev/null | sort -V | tail -n 1 || echo "16")
echo "[OK] PostgreSQL ${PG_VERSION} installed and running."

echo -e "\n>>> [4/6] Configuring Network Listening & Access Control (pg_hba.conf)..."
PG_CONF="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"
PG_HBA="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"

if [[ -f "${PG_CONF}" ]]; then
    sed -i "s/^#listen_addresses = 'localhost'/listen_addresses = '*'/" "$PG_CONF"
    sed -i "s/^listen_addresses = 'localhost'/listen_addresses = '*'/" "$PG_CONF"
fi

# Allow APP01 (10.10.10.20) and lab subnet (10.10.10.0/24)
if [[ -f "${PG_HBA}" ]] && ! grep -q "StreamFlix Application Access Control" "$PG_HBA"; then
    cat <<EOF >> "$PG_HBA"

# StreamFlix Application Access Control
host    ${DB_NAME}     ${DB_USER}     ${APP_IP}/32            scram-sha-256
host    ${DB_NAME}     ${DB_USER}     10.10.10.0/24           scram-sha-256
host    ${DB_NAME}     ${DB_USER}     127.0.0.1/32            scram-sha-256
host    all             postgres        127.0.0.1/32            scram-sha-256
EOF
fi

systemctl restart postgresql 2>/dev/null || true
echo "[OK] PostgreSQL listening on port 5432, allowed for ${APP_IP} and 10.10.10.0/24."

echo -e "\n>>> [5/6] Creating Database and Application User..."
sudo -u postgres psql <<EOF || true
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
        CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASS}';
    ELSE
        ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASS}';
    END IF;
END
\$\$;

SELECT 'CREATE DATABASE ${DB_NAME} OWNER ${DB_USER}'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${DB_NAME}')\gexec

GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
EOF

# Schema and seed data
cat << 'SCHEMA_EOF' | sudo -u postgres psql -d "${DB_NAME}" || true
CREATE TABLE IF NOT EXISTS users (
    id SERIAL PRIMARY KEY,
    username VARCHAR(50) UNIQUE NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    role VARCHAR(20) DEFAULT 'viewer',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS movies (
    id SERIAL PRIMARY KEY,
    title VARCHAR(150) NOT NULL,
    description TEXT,
    release_year INTEGER,
    genre VARCHAR(50),
    duration_minutes INTEGER,
    poster_path VARCHAR(255),
    video_path VARCHAR(255) NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS watch_history (
    id SERIAL PRIMARY KEY,
    user_id INTEGER REFERENCES users(id) ON DELETE CASCADE,
    movie_id INTEGER REFERENCES movies(id) ON DELETE CASCADE,
    playback_position_seconds INTEGER DEFAULT 0,
    completed BOOLEAN DEFAULT FALSE,
    last_watched TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(user_id, movie_id)
);

INSERT INTO movies (title, description, release_year, genre, duration_minutes, poster_path, video_path)
VALUES 
('Cloud Migration Chronicles', 'An epic documentary following legacy monolith migration to cloud infrastructure.', 2026, 'Documentary', 85, '/media/posters/migration.svg', '/media/videos/migration.mp4'),
('KVM Virtualization Horizons', 'A deep dive into Linux Kernel-based Virtual Machine architecture and libvirt.', 2025, 'Sci-Fi', 110, '/media/posters/hyperv.svg', '/media/videos/hyperv.mp4'),
('Samba in the Datacenter', 'Building resilient Active Directory domains on Linux platforms.', 2024, 'Tech Drama', 95, '/media/posters/samba.svg', '/media/videos/samba.mp4')
ON CONFLICT DO NOTHING;

GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO streamflix_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO streamflix_user;
SCHEMA_EOF

echo "[OK] Database '${DB_NAME}' schema and seed catalog ready."

echo -e "\n>>> [6/6] Validation & Connection Check..."
PGPASSWORD="${DB_PASS}" psql -h 127.0.0.1 -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT id, title, genre, release_year FROM movies;" || true

echo -e "\n[SUCCESS] DB01 PostgreSQL Database Server is online and ready for APP01!"
