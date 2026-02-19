//! Workspace repository — CRUD for the `workspaces` table.
//!
//! Workspaces represent project directories. Each session belongs to a workspace,
//! and workspace paths are unique (two sessions in the same directory share one workspace).

use rusqlite::{Connection, OptionalExtension, params};
use uuid::Uuid;

use crate::errors::Result;
use crate::sqlite::row_types::WorkspaceRow;

/// Options for creating a new workspace.
pub struct CreateWorkspaceOptions<'a> {
    /// Absolute filesystem path (must be unique).
    pub path: &'a str,
    /// Optional display name.
    pub name: Option<&'a str>,
}

/// Workspace repository — stateless, every method takes `&Connection`.
pub struct WorkspaceRepo;

impl WorkspaceRepo {
    /// Create a new workspace.
    pub fn create(conn: &Connection, opts: &CreateWorkspaceOptions<'_>) -> Result<WorkspaceRow> {
        let id = format!("ws_{}", Uuid::now_v7());
        let now = chrono::Utc::now().to_rfc3339();
        let _ = conn.execute(
            "INSERT INTO workspaces (id, path, name, created_at, last_activity_at)
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![id, opts.path, opts.name, now, now],
        )?;
        Ok(WorkspaceRow {
            id,
            path: opts.path.to_string(),
            name: opts.name.map(String::from),
            created_at: now.clone(),
            last_activity_at: now,
            session_count: Some(0),
        })
    }

    /// Get workspace by ID, with session count.
    pub fn get_by_id(conn: &Connection, workspace_id: &str) -> Result<Option<WorkspaceRow>> {
        let row = conn
            .query_row(
                "SELECT w.id, w.path, w.name, w.created_at, w.last_activity_at,
                        (SELECT COUNT(*) FROM sessions WHERE workspace_id = w.id) as session_count
                 FROM workspaces w WHERE w.id = ?1",
                params![workspace_id],
                |row| {
                    Ok(WorkspaceRow {
                        id: row.get(0)?,
                        path: row.get(1)?,
                        name: row.get(2)?,
                        created_at: row.get(3)?,
                        last_activity_at: row.get(4)?,
                        session_count: row.get(5)?,
                    })
                },
            )
            .optional()?;
        Ok(row)
    }

    /// Get workspace by filesystem path, with session count.
    pub fn get_by_path(conn: &Connection, path: &str) -> Result<Option<WorkspaceRow>> {
        let row = conn
            .query_row(
                "SELECT w.id, w.path, w.name, w.created_at, w.last_activity_at,
                        (SELECT COUNT(*) FROM sessions WHERE workspace_id = w.id) as session_count
                 FROM workspaces w WHERE w.path = ?1",
                params![path],
                |row| {
                    Ok(WorkspaceRow {
                        id: row.get(0)?,
                        path: row.get(1)?,
                        name: row.get(2)?,
                        created_at: row.get(3)?,
                        last_activity_at: row.get(4)?,
                        session_count: row.get(5)?,
                    })
                },
            )
            .optional()?;
        Ok(row)
    }

    /// Get existing workspace by path, or create a new one.
    pub fn get_or_create(
        conn: &Connection,
        path: &str,
        name: Option<&str>,
    ) -> Result<WorkspaceRow> {
        if let Some(ws) = Self::get_by_path(conn, path)? {
            return Ok(ws);
        }
        Self::create(conn, &CreateWorkspaceOptions { path, name })
    }

    /// List all workspaces ordered by last activity (most recent first).
    pub fn list(conn: &Connection) -> Result<Vec<WorkspaceRow>> {
        let mut stmt = conn.prepare(
            "SELECT w.id, w.path, w.name, w.created_at, w.last_activity_at,
                    (SELECT COUNT(*) FROM sessions WHERE workspace_id = w.id) as session_count
             FROM workspaces w ORDER BY w.last_activity_at DESC",
        )?;
        let rows = stmt
            .query_map([], |row| {
                Ok(WorkspaceRow {
                    id: row.get(0)?,
                    path: row.get(1)?,
                    name: row.get(2)?,
                    created_at: row.get(3)?,
                    last_activity_at: row.get(4)?,
                    session_count: row.get(5)?,
                })
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Update last activity timestamp to now.
    pub fn update_last_activity(conn: &Connection, workspace_id: &str) -> Result<bool> {
        let now = chrono::Utc::now().to_rfc3339();
        let changed = conn.execute(
            "UPDATE workspaces SET last_activity_at = ?1 WHERE id = ?2",
            params![now, workspace_id],
        )?;
        Ok(changed > 0)
    }

    /// Update workspace name.
    pub fn update_name(conn: &Connection, workspace_id: &str, name: Option<&str>) -> Result<bool> {
        let changed = conn.execute(
            "UPDATE workspaces SET name = ?1 WHERE id = ?2",
            params![name, workspace_id],
        )?;
        Ok(changed > 0)
    }

    /// Delete workspace. Returns `true` if a row was deleted.
    pub fn delete(conn: &Connection, workspace_id: &str) -> Result<bool> {
        let changed = conn.execute(
            "DELETE FROM workspaces WHERE id = ?1",
            params![workspace_id],
        )?;
        Ok(changed > 0)
    }

    /// Count total workspaces.
    pub fn count(conn: &Connection) -> Result<i64> {
        let count: i64 = conn.query_row("SELECT COUNT(*) FROM workspaces", [], |row| row.get(0))?;
        Ok(count)
    }

    /// Check if workspace exists.
    pub fn exists(conn: &Connection, workspace_id: &str) -> Result<bool> {
        let exists: bool = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM workspaces WHERE id = ?1)",
            params![workspace_id],
            |row| row.get(0),
        )?;
        Ok(exists)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
#[allow(unused_results)]
mod tests {
    use super::*;
    use crate::sqlite::migrations::run_migrations;

    fn setup() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")
            .unwrap();
        run_migrations(&conn).unwrap();
        conn
    }

    #[test]
    fn create_workspace() {
        let conn = setup();
        let ws = WorkspaceRepo::create(
            &conn,
            &CreateWorkspaceOptions {
                path: "/tmp/project",
                name: Some("My Project"),
            },
        )
        .unwrap();

        assert!(ws.id.starts_with("ws_"));
        assert_eq!(ws.path, "/tmp/project");
        assert_eq!(ws.name.as_deref(), Some("My Project"));
        assert_eq!(ws.session_count, Some(0));
    }

    #[test]
    fn create_workspace_without_name() {
        let conn = setup();
        let ws = WorkspaceRepo::create(
            &conn,
            &CreateWorkspaceOptions {
                path: "/tmp/project",
                name: None,
            },
        )
        .unwrap();

        assert!(ws.name.is_none());
    }

    #[test]
    fn create_duplicate_path_fails() {
        let conn = setup();
        WorkspaceRepo::create(
            &conn,
            &CreateWorkspaceOptions {
                path: "/tmp/project",
                name: None,
            },
        )
        .unwrap();

        let result = WorkspaceRepo::create(
            &conn,
            &CreateWorkspaceOptions {
                path: "/tmp/project",
                name: None,
            },
        );
        assert!(result.is_err());
    }

    #[test]
    fn get_by_id() {
        let conn = setup();
        let ws = WorkspaceRepo::create(
            &conn,
            &CreateWorkspaceOptions {
                path: "/tmp/project",
                name: Some("Test"),
            },
        )
        .unwrap();

        let found = WorkspaceRepo::get_by_id(&conn, &ws.id).unwrap().unwrap();
        assert_eq!(found.id, ws.id);
        assert_eq!(found.path, "/tmp/project");
        assert_eq!(found.name.as_deref(), Some("Test"));
    }

    #[test]
    fn get_by_id_not_found() {
        let conn = setup();
        let found = WorkspaceRepo::get_by_id(&conn, "ws_nonexistent").unwrap();
        assert!(found.is_none());
    }

    #[test]
    fn get_by_path() {
        let conn = setup();
        let ws = WorkspaceRepo::create(
            &conn,
            &CreateWorkspaceOptions {
                path: "/tmp/project",
                name: None,
            },
        )
        .unwrap();

        let found = WorkspaceRepo::get_by_path(&conn, "/tmp/project")
            .unwrap()
            .unwrap();
        assert_eq!(found.id, ws.id);
    }

    #[test]
    fn get_by_path_not_found() {
        let conn = setup();
        let found = WorkspaceRepo::get_by_path(&conn, "/nonexistent").unwrap();
        assert!(found.is_none());
    }

    #[test]
    fn get_or_create_creates_new() {
        let conn = setup();
        let ws = WorkspaceRepo::get_or_create(&conn, "/tmp/new", Some("New")).unwrap();
        assert!(ws.id.starts_with("ws_"));
        assert_eq!(ws.path, "/tmp/new");
    }

    #[test]
    fn get_or_create_returns_existing() {
        let conn = setup();
        let ws1 = WorkspaceRepo::get_or_create(&conn, "/tmp/existing", Some("First")).unwrap();
        let ws2 = WorkspaceRepo::get_or_create(&conn, "/tmp/existing", Some("Second")).unwrap();
        assert_eq!(ws1.id, ws2.id);
    }

    #[test]
    fn list_empty() {
        let conn = setup();
        let workspaces = WorkspaceRepo::list(&conn).unwrap();
        assert!(workspaces.is_empty());
    }

    #[test]
    fn list_ordered_by_activity() {
        let conn = setup();
        let ws1 = WorkspaceRepo::create(
            &conn,
            &CreateWorkspaceOptions {
                path: "/tmp/a",
                name: None,
            },
        )
        .unwrap();
        let ws2 = WorkspaceRepo::create(
            &conn,
            &CreateWorkspaceOptions {
                path: "/tmp/b",
                name: None,
            },
        )
        .unwrap();

        // Update ws1 activity so it comes first
        WorkspaceRepo::update_last_activity(&conn, &ws1.id).unwrap();

        let list = WorkspaceRepo::list(&conn).unwrap();
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].id, ws1.id);
        assert_eq!(list[1].id, ws2.id);
    }

    #[test]
    fn update_last_activity() {
        let conn = setup();
        let ws = WorkspaceRepo::create(
            &conn,
            &CreateWorkspaceOptions {
                path: "/tmp/project",
                name: None,
            },
        )
        .unwrap();
        let original_activity = ws.last_activity_at.clone();

        std::thread::sleep(std::time::Duration::from_millis(10));
        WorkspaceRepo::update_last_activity(&conn, &ws.id).unwrap();

        let updated = WorkspaceRepo::get_by_id(&conn, &ws.id).unwrap().unwrap();
        assert_ne!(updated.last_activity_at, original_activity);
    }

    #[test]
    fn update_last_activity_nonexistent() {
        let conn = setup();
        let changed = WorkspaceRepo::update_last_activity(&conn, "ws_nonexistent").unwrap();
        assert!(!changed);
    }

    #[test]
    fn update_name() {
        let conn = setup();
        let ws = WorkspaceRepo::create(
            &conn,
            &CreateWorkspaceOptions {
                path: "/tmp/project",
                name: None,
            },
        )
        .unwrap();

        WorkspaceRepo::update_name(&conn, &ws.id, Some("New Name")).unwrap();
        let updated = WorkspaceRepo::get_by_id(&conn, &ws.id).unwrap().unwrap();
        assert_eq!(updated.name.as_deref(), Some("New Name"));
    }

    #[test]
    fn update_name_to_null() {
        let conn = setup();
        let ws = WorkspaceRepo::create(
            &conn,
            &CreateWorkspaceOptions {
                path: "/tmp/project",
                name: Some("Original"),
            },
        )
        .unwrap();

        WorkspaceRepo::update_name(&conn, &ws.id, None).unwrap();
        let updated = WorkspaceRepo::get_by_id(&conn, &ws.id).unwrap().unwrap();
        assert!(updated.name.is_none());
    }

    #[test]
    fn delete_workspace() {
        let conn = setup();
        let ws = WorkspaceRepo::create(
            &conn,
            &CreateWorkspaceOptions {
                path: "/tmp/project",
                name: None,
            },
        )
        .unwrap();

        let deleted = WorkspaceRepo::delete(&conn, &ws.id).unwrap();
        assert!(deleted);
        assert!(WorkspaceRepo::get_by_id(&conn, &ws.id).unwrap().is_none());
    }

    #[test]
    fn delete_nonexistent() {
        let conn = setup();
        let deleted = WorkspaceRepo::delete(&conn, "ws_nonexistent").unwrap();
        assert!(!deleted);
    }

    #[test]
    fn count_workspaces() {
        let conn = setup();
        assert_eq!(WorkspaceRepo::count(&conn).unwrap(), 0);

        WorkspaceRepo::create(
            &conn,
            &CreateWorkspaceOptions {
                path: "/tmp/a",
                name: None,
            },
        )
        .unwrap();
        WorkspaceRepo::create(
            &conn,
            &CreateWorkspaceOptions {
                path: "/tmp/b",
                name: None,
            },
        )
        .unwrap();

        assert_eq!(WorkspaceRepo::count(&conn).unwrap(), 2);
    }

    #[test]
    fn exists_workspace() {
        let conn = setup();
        let ws = WorkspaceRepo::create(
            &conn,
            &CreateWorkspaceOptions {
                path: "/tmp/project",
                name: None,
            },
        )
        .unwrap();

        assert!(WorkspaceRepo::exists(&conn, &ws.id).unwrap());
        assert!(!WorkspaceRepo::exists(&conn, "ws_nonexistent").unwrap());
    }
}
