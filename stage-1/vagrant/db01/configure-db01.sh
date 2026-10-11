#!/usr/bin/env bash
# ==============================================================================
# Enterprise Cloud Migration Lab — Phase 7: PostgreSQL Database Server
# Target Machine: DB01 (192.168.10.30)
#
# What this script executes end-to-end on DB01:
#   1. Sets hostname to DB01.corp.streamflix.lab
#   2. Installs PostgreSQL and dependencies non-interactively
#   3. Configures postgresql.conf to listen on all interfaces
#   4. Restricts pg_hba.conf to allow only APP01 (192.168.10.20) and localhost
#   5. Creates database 'streamflix_db' and user 'streamflix_user'
#   6. Applies schema.sql (tables: users, movies, watch_history) and seed data
#   7. Validates local and TCP database access
# ==============================================================================

set -euo pipefail

DB_NAME="streamflix_db"
DB_USER="streamflix_user"
DB_PASS="StreamFlixPass2026!"
APP_IP="192.168.10.20"

echo "=================================================================="
echo "  Enterprise Cloud Migration Lab: DB01 PostgreSQL Setup           "
echo "=================================================================="

# 1. Root check
if [[ $EUID -ne 0 ]]; then
   echo "[-] This script must be run as root (e.g. sudo bash configure-db01.sh)"
   exit 1
fi

echo -e "\n>>> [1/6] Configuring Hostname and /etc/hosts..."
hostnamectl set-hostname DB01.corp.streamflix.lab
sed -i '/127.0.1.1/d' /etc/hosts
if ! grep -q "192.168.10.30 DB01.corp.streamflix.lab DB01" /etc/hosts; then
    echo "192.168.10.30 DB01.corp.streamflix.lab DB01" >> /etc/hosts
fi
echo "[OK] Hostname configured: $(hostname -f)"

echo -e "\n>>> [2/6] Installing PostgreSQL Engine..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq postgresql postgresql-contrib

systemctl enable --now postgresql
PG_VERSION=$(ls /etc/postgresql/ | head -n 1)
echo "[OK] PostgreSQL ${PG_VERSION} installed and running."

echo -e "\n>>> [3/6] Configuring Network Listening & Access Control (pg_hba.conf)..."
PG_CONF="/etc/postgresql/${PG_VERSION}/main/postgresql.conf"
PG_HBA="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"

# Listen on all IP addresses (network-facing)
sed -i "s/^#listen_addresses = 'localhost'/listen_addresses = '*'/" "$PG_CONF"
sed -i "s/^listen_addresses = 'localhost'/listen_addresses = '*'/" "$PG_CONF"

# Restrict access: Allow APP01 (192.168.10.20) and localhost only
if ! grep -q "host    ${DB_NAME}     ${DB_USER}     ${APP_IP}/32" "$PG_HBA"; then
    cat <<EOF >> "$PG_HBA"

# StreamFlix Application Access Control
host    ${DB_NAME}     ${DB_USER}     ${APP_IP}/32            scram-sha-256
host    ${DB_NAME}     ${DB_USER}     127.0.0.1/32            scram-sha-256
host    all             postgres        127.0.0.1/32            scram-sha-256
EOF
fi

systemctl restart postgresql
echo "[OK] PostgreSQL configured to listen on port 5432, restricted to ${APP_IP}."

echo -e "\n>>> [4/6] Creating Database and Application User..."
sudo -u postgres psql <<EOF
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

echo "[OK] Database '${DB_NAME}' and role '${DB_USER}' ready."

echo -e "\n>>> [5/6] Applying Schema and Seed Data..."
cat << 'SCHEMA_EOF' | sudo -u postgres psql -d "${DB_NAME}"
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

-- Seed Sample Movie Catalog
INSERT INTO movies (title, description, release_year, genre, duration_minutes, poster_path, video_path)
VALUES 
('Cloud Migration Chronicles', 'An epic documentary following legacy monolith migration to cloud infrastructure.', 2026, 'Documentary', 85, '/media/posters/migration.svg', '/media/videos/migration.mp4'),
('Hyper-V Horizons', 'A deep dive into Type-1 hypervisors and nested virtualization architecture.', 2025, 'Sci-Fi', 110, '/media/posters/hyperv.svg', '/media/videos/hyperv.mp4'),
('Samba in the Datacenter', 'Building resilient Active Directory domains on Linux platforms.', 2024, 'Tech Drama', 95, '/media/posters/samba.svg', '/media/videos/samba.mp4')
ON CONFLICT DO NOTHING;

GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO streamflix_user;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO streamflix_user;
SCHEMA_EOF

echo "[OK] Schema and initial seed movies created."

echo -e "\n>>> [6/6] Validation & Connection Check..."
echo "Verifying local connection as ${DB_USER}..."
PGPASSWORD="${DB_PASS}" psql -h 127.0.0.1 -U "${DB_USER}" -d "${DB_NAME}" -c "SELECT id, title, genre, release_year FROM movies;"

echo -e "\n[SUCCESS] DB01 PostgreSQL Database Server is online, secured, and ready for APP01!"
