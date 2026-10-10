import React, { useState, useEffect } from 'react';

export default function App() {
  const [movies, setMovies] = useState([]);
  const [selectedMovie, setSelectedMovie] = useState(null);
  const [health, setHealth] = useState({ status: 'CHECKING', database: 'UNKNOWN' });
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    // 1. Fetch Backend Health
    fetch('/api/health')
      .then(res => res.json())
      .then(data => setHealth(data))
      .catch(() => setHealth({ status: 'DOWN', database: 'UNREACHABLE' }));

    // 2. Fetch Movie Catalog from PostgreSQL via Express
    fetch('/api/movies')
      .then(res => res.json())
      .then(data => {
        setMovies(data);
        if (data.length > 0) setSelectedMovie(data[0]);
        setLoading(false);
      })
      .catch(err => {
        console.error('Failed to load movies:', err);
        setLoading(false);
      });
  }, []);

  const [isPlaying, setIsPlaying] = useState(false);

  return (
    <div style={{ minHeight: '100vh', backgroundColor: '#141414', color: '#fff' }}>
      {/* 1. Header Navigation Bar */}
      <nav style={{
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'space-between',
        padding: '16px 40px',
        backgroundColor: '#0a0a0a',
        borderBottom: '1px solid #222'
      }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: '20px' }}>
          <h1 style={{ color: '#E50914', fontSize: '26px', fontWeight: 'bold', letterSpacing: '1px' }}>
            STREAMFLIX <span style={{ fontSize: '13px', color: '#888', fontWeight: 'normal' }}>LAB</span>
          </h1>
          <span style={{
            fontSize: '11px',
            backgroundColor: '#222',
            padding: '4px 10px',
            borderRadius: '12px',
            color: '#aaa',
            border: '1px solid #333'
          }}>
            Source Datacenter Environment (On-Premises)
          </span>
        </div>

        {/* Health Indicators */}
        <div style={{ display: 'flex', gap: '15px', alignItems: 'center', fontSize: '12px' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: '6px' }}>
            <span style={{
              width: '8px',
              height: '8px',
              borderRadius: '50%',
              backgroundColor: health.status === 'UP' ? '#46d369' : '#e50914'
            }}></span>
            <span>API: {health.status}</span>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: '6px' }}>
            <span style={{
              width: '8px',
              height: '8px',
              borderRadius: '50%',
              backgroundColor: health.database === 'CONNECTED' ? '#46d369' : '#e50914'
            }}></span>
            <span>DB01: {health.database}</span>
          </div>
        </div>
      </nav>

      {/* 2. Hero Billboard Section */}
      {selectedMovie && (
        <div style={{
          position: 'relative',
          padding: '60px 40px',
          background: 'linear-gradient(to right, rgba(20,20,20,0.95) 40%, rgba(20,20,20,0.4)), url(/media/posters/migration.svg)',
          backgroundSize: 'cover',
          borderBottom: '1px solid #262626'
        }}>
          <div style={{ maxWidth: '650px' }}>
            <span style={{ fontSize: '12px', color: '#E50914', fontWeight: 'bold', letterSpacing: '1px' }}>
              {selectedMovie.genre.toUpperCase()} • {selectedMovie.release_year} • {selectedMovie.duration_minutes} MIN
            </span>
            <h2 style={{ fontSize: '42px', fontWeight: '800', margin: '10px 0 16px' }}>
              {selectedMovie.title}
            </h2>
            <p style={{ color: '#ccc', fontSize: '16px', lineHeight: '1.5', marginBottom: '24px' }}>
              {selectedMovie.description}
            </p>

            <div style={{ display: 'flex', gap: '14px' }}>
              <button
                onClick={() => setIsPlaying(true)}
                style={{
                  backgroundColor: '#E50914',
                  color: '#fff',
                  border: 'none',
                  padding: '12px 28px',
                  fontSize: '15px',
                  fontWeight: 'bold',
                  borderRadius: '4px',
                  cursor: 'pointer',
                  display: 'flex',
                  alignItems: 'center',
                  gap: '8px'
                }}
              >
                ▶ Stream Video (HTTP 206)
              </button>
              <button
                onClick={() => alert(`Movie Details:\nTitle: ${selectedMovie.title}\nVideo Storage: FILE01 (${selectedMovie.video_path})\nDatabase: DB01`)}
                style={{
                  backgroundColor: 'rgba(109, 109, 110, 0.7)',
                  color: '#fff',
                  border: 'none',
                  padding: '12px 24px',
                  fontSize: '15px',
                  fontWeight: 'bold',
                  borderRadius: '4px',
                  cursor: 'pointer'
                }}
              >
                ℹ Architecture Info
              </button>
            </div>
          </div>
        </div>
      )}

      {/* 3. Movie Catalog Grid */}
      <div style={{ padding: '40px' }}>
        <h3 style={{ fontSize: '20px', fontWeight: '600', marginBottom: '20px' }}>
          On-Premises Video Catalog (Served via FILE01 Samba Share)
        </h3>

        {loading ? (
          <p style={{ color: '#888' }}>Loading catalog from PostgreSQL (DB01)...</p>
        ) : (
          <div style={{ display: 'flex', gap: '20px', flexWrap: 'wrap' }}>
            {movies.map(movie => (
              <div
                key={movie.id}
                onClick={() => setSelectedMovie(movie)}
                style={{
                  width: '220px',
                  backgroundColor: '#1f1f1f',
                  borderRadius: '6px',
                  overflow: 'hidden',
                  cursor: 'pointer',
                  border: selectedMovie?.id === movie.id ? '2px solid #E50914' : '1px solid #2d2d2d',
                  transition: 'transform 0.2s',
                }}
              >
                <div style={{ width: '100%', height: '280px', backgroundColor: '#111' }}>
                  <img
                    src={movie.poster_path}
                    alt={movie.title}
                    style={{ width: '100%', height: '100%', objectFit: 'cover' }}
                    onError={(e) => { e.target.style.display = 'none'; }}
                  />
                </div>
                <div style={{ padding: '12px' }}>
                  <h4 style={{ fontSize: '14px', fontWeight: 'bold', marginBottom: '4px' }}>{movie.title}</h4>
                  <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: '12px', color: '#888' }}>
                    <span>{movie.genre}</span>
                    <span>{movie.release_year}</span>
                  </div>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>

      {/* 4. HTML5 Video Player Modal (Testing HTTP Byte Range Requests) */}
      {isPlaying && selectedMovie && (
        <div style={{
          position: 'fixed',
          top: 0,
          left: 0,
          width: '100%',
          height: '100%',
          backgroundColor: 'rgba(0,0,0,0.92)',
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          justifyContent: 'center',
          zIndex: 9999
        }}>
          <div style={{ width: '80%', maxWidth: '900px', backgroundColor: '#181818', borderRadius: '8px', overflow: 'hidden' }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', padding: '16px 20px', borderBottom: '1px solid #333' }}>
              <h3 style={{ fontSize: '18px' }}>Streaming: {selectedMovie.title}</h3>
              <button
                onClick={() => setIsPlaying(false)}
                style={{ background: 'none', border: 'none', color: '#fff', fontSize: '20px', cursor: 'pointer' }}
              >
                ✕
              </button>
            </div>
            <div style={{ padding: '20px', backgroundColor: '#000' }}>
              <video
                controls
                autoPlay
                style={{ width: '100%', maxHeight: '480px' }}
                src={selectedMovie.video_path}
              >
                Your browser does not support HTML5 video playback.
              </video>
            </div>
            <div style={{ padding: '14px 20px', fontSize: '12px', color: '#888', display: 'flex', justifyContent: 'space-between' }}>
              <span>Delivery: Nginx HTTP 206 Partial Content Range Requests</span>
              <span>Backend Source: FILE01 (192.168.10.40)</span>
            </div>
          </div>
        </div>
      )}

      {/* 5. Enterprise Migration Tier Architecture Footer */}
      <footer style={{
        marginTop: '60px',
        padding: '30px 40px',
        backgroundColor: '#0a0a0a',
        borderTop: '1px solid #222',
        fontSize: '13px',
        color: '#777'
      }}>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: '20px' }}>
          <div>
            <strong style={{ color: '#fff' }}>DC01 (192.168.10.10)</strong>
            <p>Samba Active Directory Domain Controller & Internal DNS Server</p>
          </div>
          <div>
            <strong style={{ color: '#fff' }}>APP01 (192.168.10.20)</strong>
            <p>React 18 Frontend, Node.js Express API & Nginx Reverse Proxy</p>
          </div>
          <div>
            <strong style={{ color: '#fff' }}>DB01 (192.168.10.30)</strong>
            <p>PostgreSQL 14+ Relational Database & StreamFlix Catalog</p>
          </div>
          <div>
            <strong style={{ color: '#fff' }}>FILE01 (192.168.10.40)</strong>
            <p>Samba File Share for Videos, Posters & Static Media Storage</p>
          </div>
        </div>
      </footer>
    </div>
  );
}
