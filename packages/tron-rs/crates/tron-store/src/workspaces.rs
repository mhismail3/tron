use chrono::Utc;
use serde::{Deserialize, Serialize};
use tracing::instrument;

use tron_core::ids::WorkspaceId;

use crate::database::Database;
use crate::error::StoreError;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct WorkspaceRow {
    pub id: WorkspaceId,
    pub path: String,
    pub name: String,
    pub created_at: String,
}

pub struct WorkspaceRepo {
    db: Database,
}

impl WorkspaceRepo {
    pub fn new(db: Database) -> Self {
        Self { db }
    }

    /// Get or create a workspace for the given path.
    /// If a workspace already exists for this path, returns it.
    /// Otherwise, creates a new one.
    #[instrument(skip(self), fields(path, name))]
    pub fn get_or_create(&self, path: &str, name: &str) -> Result<WorkspaceRow, StoreError> {
        self.db.with_conn(|conn| {
            // Try to find existing
            let existing = conn
                .query_row(
                    "SELECT id, path, name, created_at FROM workspaces WHERE path = ?1",
                    [path],
                    |row| {
                        Ok(WorkspaceRow {
                            id: WorkspaceId::from_raw(row.get::<_, String>(0)?),
                            path: row.get(1)?,
                            name: row.get(2)?,
                            created_at: row.get(3)?,
                        })
                    },
                )
                .ok();

            if let Some(ws) = existing {
                return Ok(ws);
            }

            // Create new
            let id = WorkspaceId::new();
            let now = Utc::now().to_rfc3339();
            conn.execute(
                "INSERT INTO workspaces (id, path, name, created_at) VALUES (?1, ?2, ?3, ?4)",
                rusqlite::params![id.as_str(), path, name, now],
            )?;

            Ok(WorkspaceRow {
                id,
                path: path.to_string(),
                name: name.to_string(),
                created_at: now,
            })
        })
    }

    /// Get a workspace by ID.
    #[instrument(skip(self), fields(workspace_id = %id))]
    pub fn get(&self, id: &WorkspaceId) -> Result<WorkspaceRow, StoreError> {
        self.db.with_conn(|conn| {
            conn.query_row(
                "SELECT id, path, name, created_at FROM workspaces WHERE id = ?1",
                [id.as_str()],
                |row| {
                    Ok(WorkspaceRow {
                        id: WorkspaceId::from_raw(row.get::<_, String>(0)?),
                        path: row.get(1)?,
                        name: row.get(2)?,
                        created_at: row.get(3)?,
                    })
                },
            )
            .map_err(|_| StoreError::NotFound(format!("workspace {id}")))
        })
    }

    /// List all workspaces.
    #[instrument(skip(self))]
    pub fn list(&self) -> Result<Vec<WorkspaceRow>, StoreError> {
        self.db.with_conn(|conn| {
            let mut stmt = conn
                .prepare("SELECT id, path, name, created_at FROM workspaces ORDER BY created_at DESC")?;
            let rows = stmt
                .query_map([], |row| {
                    Ok(WorkspaceRow {
                        id: WorkspaceId::from_raw(row.get::<_, String>(0)?),
                        path: row.get(1)?,
                        name: row.get(2)?,
                        created_at: row.get(3)?,
                    })
                })?
                .collect::<Result<Vec<_>, _>>()?;
            Ok(rows)
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_db() -> Database {
        Database::in_memory().unwrap()
    }

    #[test]
    fn create_workspace() {
        let repo = WorkspaceRepo::new(test_db());
        let ws = repo.get_or_create("/home/user/project", "project").unwrap();
        assert!(ws.id.as_str().starts_with("ws_"));
        assert_eq!(ws.path, "/home/user/project");
        assert_eq!(ws.name, "project");
    }

    #[test]
    fn get_or_create_returns_existing() {
        let repo = WorkspaceRepo::new(test_db());
        let ws1 = repo.get_or_create("/home/user/project", "project").unwrap();
        let ws2 = repo.get_or_create("/home/user/project", "project").unwrap();
        assert_eq!(ws1.id, ws2.id);
    }

    #[test]
    fn get_by_id() {
        let repo = WorkspaceRepo::new(test_db());
        let ws = repo.get_or_create("/tmp/test", "test").unwrap();
        let fetched = repo.get(&ws.id).unwrap();
        assert_eq!(fetched.path, "/tmp/test");
    }

    #[test]
    fn get_nonexistent_fails() {
        let repo = WorkspaceRepo::new(test_db());
        let result = repo.get(&WorkspaceId::from_raw("ws_nonexistent"));
        assert!(result.is_err());
    }

    #[test]
    fn list_workspaces() {
        let repo = WorkspaceRepo::new(test_db());
        repo.get_or_create("/a", "a").unwrap();
        repo.get_or_create("/b", "b").unwrap();
        let all = repo.list().unwrap();
        assert_eq!(all.len(), 2);
    }

    #[test]
    fn different_paths_create_different_workspaces() {
        let repo = WorkspaceRepo::new(test_db());
        let ws1 = repo.get_or_create("/path/a", "a").unwrap();
        let ws2 = repo.get_or_create("/path/b", "b").unwrap();
        assert_ne!(ws1.id, ws2.id);
    }
}
