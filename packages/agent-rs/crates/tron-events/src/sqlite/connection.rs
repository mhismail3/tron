//! `SQLite` connection pool with WAL mode and foreign keys enabled.
//!
//! Uses `r2d2` connection pooling with `r2d2_sqlite` backend.
//! The [`PragmaCustomizer`] runs on each new connection to ensure
//! WAL mode, foreign keys, and performance pragmas are set.

use r2d2::Pool;
use r2d2_sqlite::SqliteConnectionManager;
use rusqlite::Connection;

use crate::errors::{EventStoreError, Result};

/// Alias for the connection pool type.
pub type ConnectionPool = Pool<SqliteConnectionManager>;

/// Alias for a pooled connection.
pub type PooledConnection = r2d2::PooledConnection<SqliteConnectionManager>;

/// Configuration for the connection pool.
#[derive(Clone, Debug)]
pub struct ConnectionConfig {
    /// Maximum pool size (default: 16).
    pub pool_size: u32,
    /// Busy timeout in milliseconds (default: 30000).
    pub busy_timeout_ms: u32,
    /// Cache size in KiB (default: 8192 = 8 MB).
    pub cache_size_kib: i64,
}

impl Default for ConnectionConfig {
    fn default() -> Self {
        Self {
            pool_size: 16,
            busy_timeout_ms: 30_000,
            cache_size_kib: 8192,
        }
    }
}

/// `SQLite` pragma customizer that runs on each new connection.
#[derive(Debug)]
struct PragmaCustomizer {
    busy_timeout_ms: u32,
    cache_size_kib: i64,
}

impl r2d2::CustomizeConnection<Connection, rusqlite::Error> for PragmaCustomizer {
    fn on_acquire(&self, conn: &mut Connection) -> std::result::Result<(), rusqlite::Error> {
        conn.execute_batch(&format!(
            "PRAGMA journal_mode = WAL;\
             PRAGMA busy_timeout = {};\
             PRAGMA foreign_keys = ON;\
             PRAGMA cache_size = -{};\
             PRAGMA synchronous = NORMAL;",
            self.busy_timeout_ms, self.cache_size_kib
        ))?;
        Ok(())
    }
}

/// Create an in-memory connection pool (for testing).
pub fn new_in_memory(config: &ConnectionConfig) -> Result<ConnectionPool> {
    let manager = SqliteConnectionManager::memory();
    let pool = Pool::builder()
        .max_size(config.pool_size)
        .connection_timeout(std::time::Duration::from_secs(5))
        .connection_customizer(Box::new(PragmaCustomizer {
            busy_timeout_ms: config.busy_timeout_ms,
            cache_size_kib: config.cache_size_kib,
        }))
        .build(manager)?;
    Ok(pool)
}

/// Create a file-backed connection pool.
pub fn new_file(path: &str, config: &ConnectionConfig) -> Result<ConnectionPool> {
    let manager = SqliteConnectionManager::file(path);
    let pool = Pool::builder()
        .max_size(config.pool_size)
        .connection_timeout(std::time::Duration::from_secs(5))
        .connection_customizer(Box::new(PragmaCustomizer {
            busy_timeout_ms: config.busy_timeout_ms,
            cache_size_kib: config.cache_size_kib,
        }))
        .build(manager)?;
    Ok(pool)
}

/// Verify pragmas are set correctly on a connection.
pub fn verify_pragmas(conn: &Connection) -> Result<PragmaState> {
    let journal_mode: String = conn
        .query_row("PRAGMA journal_mode", [], |row| row.get(0))
        .map_err(EventStoreError::Sqlite)?;
    let foreign_keys: i32 = conn
        .query_row("PRAGMA foreign_keys", [], |row| row.get(0))
        .map_err(EventStoreError::Sqlite)?;
    Ok(PragmaState {
        journal_mode,
        foreign_keys_enabled: foreign_keys == 1,
    })
}

/// Pragma state for verification.
#[derive(Debug)]
pub struct PragmaState {
    /// Journal mode (should be "wal").
    pub journal_mode: String,
    /// Whether foreign keys are enabled.
    pub foreign_keys_enabled: bool,
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn in_memory_pool_creates_successfully() {
        let config = ConnectionConfig::default();
        let pool = new_in_memory(&config).unwrap();
        let conn = pool.get().unwrap();
        let pragmas = verify_pragmas(&conn).unwrap();
        assert!(
            pragmas.journal_mode == "wal" || pragmas.journal_mode == "memory",
            "journal_mode should be wal or memory, got: {}",
            pragmas.journal_mode
        );
        assert!(pragmas.foreign_keys_enabled);
    }

    #[test]
    fn file_pool_creates_successfully() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("test.db");
        let config = ConnectionConfig::default();
        let pool = new_file(path.to_str().unwrap(), &config).unwrap();
        let conn = pool.get().unwrap();
        let pragmas = verify_pragmas(&conn).unwrap();
        assert_eq!(pragmas.journal_mode, "wal");
        assert!(pragmas.foreign_keys_enabled);
    }

    #[test]
    fn concurrent_connections() {
        let config = ConnectionConfig {
            pool_size: 16,
            ..Default::default()
        };
        let pool = new_in_memory(&config).unwrap();

        // Get multiple connections concurrently
        let conns: Vec<_> = (0..16).map(|_| pool.get().unwrap()).collect();
        assert_eq!(conns.len(), 16);
    }

    #[test]
    fn custom_config() {
        let config = ConnectionConfig {
            pool_size: 2,
            busy_timeout_ms: 10000,
            cache_size_kib: 16384,
        };
        let pool = new_in_memory(&config).unwrap();
        assert_eq!(pool.max_size(), 2);
    }

    #[test]
    fn default_config_values() {
        let config = ConnectionConfig::default();
        assert_eq!(config.pool_size, 16);
        assert_eq!(config.busy_timeout_ms, 30_000);
        assert_eq!(config.cache_size_kib, 8192);
    }
}
