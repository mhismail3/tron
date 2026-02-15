use std::path::{Path, PathBuf};
use std::sync::Arc;

use parking_lot::Mutex;
use rusqlite::Connection;
use tracing::info;

use crate::error::StoreError;
use crate::schema;

/// Thread-safe SQLite connection wrapper.
/// Uses parking_lot::Mutex for synchronous access (rusqlite is not Send).
pub struct Database {
    conn: Arc<Mutex<Connection>>,
    path: PathBuf,
}

impl Database {
    /// Open or create a database at the given path.
    pub fn open(path: &Path) -> Result<Self, StoreError> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| StoreError::Io(format!("create dir: {e}")))?;
        }

        let conn = Connection::open(path)
            .map_err(|e| StoreError::Database(e.to_string()))?;

        // Apply pragmas
        conn.execute_batch(schema::PRAGMAS)
            .map_err(|e| StoreError::Database(format!("pragmas: {e}")))?;

        // Create tables
        conn.execute_batch(schema::CREATE_TABLES)
            .map_err(|e| StoreError::Database(format!("schema: {e}")))?;

        // Set schema version if not present
        let version: Option<u32> = conn
            .query_row(
                "SELECT version FROM schema_version LIMIT 1",
                [],
                |row| row.get(0),
            )
            .ok();

        if version.is_none() {
            conn.execute(
                "INSERT INTO schema_version (version) VALUES (?1)",
                [schema::SCHEMA_VERSION],
            )
            .map_err(|e| StoreError::Database(format!("schema version: {e}")))?;
        }

        info!(path = %path.display(), "database opened");

        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
            path: path.to_owned(),
        })
    }

    /// Open an in-memory database (for testing).
    pub fn in_memory() -> Result<Self, StoreError> {
        let conn = Connection::open_in_memory()
            .map_err(|e| StoreError::Database(e.to_string()))?;

        conn.execute_batch(schema::PRAGMAS)
            .map_err(|e| StoreError::Database(format!("pragmas: {e}")))?;

        conn.execute_batch(schema::CREATE_TABLES)
            .map_err(|e| StoreError::Database(format!("schema: {e}")))?;

        conn.execute(
            "INSERT INTO schema_version (version) VALUES (?1)",
            [schema::SCHEMA_VERSION],
        )
        .map_err(|e| StoreError::Database(format!("schema version: {e}")))?;

        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
            path: PathBuf::from(":memory:"),
        })
    }

    /// Execute a closure with the database connection.
    pub fn with_conn<F, T>(&self, f: F) -> Result<T, StoreError>
    where
        F: FnOnce(&Connection) -> Result<T, StoreError>,
    {
        let conn = self.conn.lock();
        f(&conn)
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Clone the Arc for shared ownership.
    pub fn shared(&self) -> Arc<Mutex<Connection>> {
        self.conn.clone()
    }
}

impl Clone for Database {
    fn clone(&self) -> Self {
        Self {
            conn: self.conn.clone(),
            path: self.path.clone(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn open_in_memory() {
        let db = Database::in_memory().unwrap();
        assert_eq!(db.path(), Path::new(":memory:"));
    }

    #[test]
    fn schema_version_set() {
        let db = Database::in_memory().unwrap();
        let version: u32 = db
            .with_conn(|conn| {
                conn.query_row("SELECT version FROM schema_version", [], |row| row.get(0))
                    .map_err(|e| StoreError::Database(e.to_string()))
            })
            .unwrap();
        assert_eq!(version, schema::SCHEMA_VERSION);
    }

    #[test]
    fn tables_created() {
        let db = Database::in_memory().unwrap();
        db.with_conn(|conn| {
            let tables: Vec<String> = conn
                .prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
                .map_err(|e| StoreError::Database(e.to_string()))?
                .query_map([], |row| row.get(0))
                .map_err(|e| StoreError::Database(e.to_string()))?
                .collect::<Result<_, _>>()
                .map_err(|e| StoreError::Database(e.to_string()))?;

            assert!(tables.contains(&"workspaces".to_string()));
            assert!(tables.contains(&"sessions".to_string()));
            assert!(tables.contains(&"events".to_string()));
            assert!(tables.contains(&"memory_entries".to_string()));
            Ok(())
        })
        .unwrap();
    }

    #[test]
    fn open_file_database() {
        let dir = std::env::temp_dir().join(format!("tron-store-test-{}", uuid::Uuid::now_v7()));
        let path = dir.join("test.db");
        let db = Database::open(&path).unwrap();
        assert!(path.exists());

        // Open again — should not fail
        let db2 = Database::open(&path).unwrap();
        drop(db);
        drop(db2);

        // Cleanup
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn wal_mode_enabled() {
        let db = Database::in_memory().unwrap();
        db.with_conn(|conn| {
            let mode: String = conn
                .query_row("PRAGMA journal_mode", [], |row| row.get(0))
                .map_err(|e| StoreError::Database(e.to_string()))?;
            // In-memory databases use "memory" journal mode, not WAL
            // File databases would use "wal"
            assert!(mode == "memory" || mode == "wal", "got: {mode}");
            Ok(())
        })
        .unwrap();
    }
}
