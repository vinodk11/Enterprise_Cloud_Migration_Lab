-- ==============================================================================
-- StreamFlix Lab — Enterprise PostgreSQL Schema
-- Deployed on DB01 (192.168.10.30)
-- ==============================================================================

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

-- Seed Initial Demonstration Movie Catalog
INSERT INTO movies (title, description, release_year, genre, duration_minutes, poster_path, video_path)
VALUES 
('Cloud Migration Chronicles', 'An epic documentary following legacy monolith migration to cloud infrastructure.', 2026, 'Documentary', 85, '/media/posters/migration.jpg', '/media/videos/migration.mp4'),
('Hyper-V Horizons', 'A deep dive into Type-1 hypervisors and nested virtualization architecture.', 2025, 'Sci-Fi', 110, '/media/posters/hyperv.jpg', '/media/videos/hyperv.mp4'),
('Samba in the Datacenter', 'Building resilient Active Directory domains on Linux platforms.', 2024, 'Tech Drama', 95, '/media/posters/samba.jpg', '/media/videos/samba.mp4')
ON CONFLICT DO NOTHING;
