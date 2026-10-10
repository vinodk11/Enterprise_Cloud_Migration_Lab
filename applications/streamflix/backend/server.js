// ==============================================================================
// StreamFlix Lab — Express REST API Backend
// Deployed on APP01 (192.168.10.20)
// ==============================================================================

const express = require('express');
const cors = require('cors');
const { Pool } = require('pg');
require('dotenv').config();

const app = express();
const PORT = process.env.PORT || 5000;

// PostgreSQL Connection Pool (Points to DB01: 192.168.10.30)
const pool = new Pool({
  host: process.env.DB_HOST || '192.168.10.30',
  port: parseInt(process.env.DB_PORT || '5432'),
  user: process.env.DB_USER || 'streamflix_user',
  password: process.env.DB_PASSWORD || 'StreamFlixPass2026!',
  database: process.env.DB_NAME || 'streamflix_db'
});

app.use(cors());
app.use(express.json());

// Deep Health Check Endpoint
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

// Movie Catalog Endpoint
app.get('/api/movies', async (req, res) => {
  try {
    const { rows } = await pool.query('SELECT id, title, description, release_year, genre, duration_minutes, poster_path, video_path FROM movies ORDER BY id ASC');
    res.json(rows);
  } catch (err) {
    res.status(500).json({ error: 'Failed to retrieve movie catalog', details: err.message });
  }
});

// Movie Details Endpoint
app.get('/api/movies/:id', async (req, res) => {
  try {
    const { rows } = await pool.query('SELECT * FROM movies WHERE id = $1', [req.params.id]);
    if (rows.length === 0) return res.status(404).json({ error: 'Movie not found' });
    res.json(rows[0]);
  } catch (err) {
    res.status(500).json({ error: 'Failed to retrieve movie details', details: err.message });
  }
});

app.listen(PORT, () => {
  console.log(`[StreamFlix Backend] Running on http://0.0.0.0:${PORT} on APP01`);
});
