//! Branch repository — CRUD for the `branches` table.
//!
//! Branches are named positions in the event tree. Each session can have
//! multiple branches, with one marked as default.

use rusqlite::{Connection, OptionalExtension, params};
use uuid::Uuid;

use crate::errors::Result;
use crate::sqlite::row_types::BranchRow;

/// Options for creating a new branch.
pub struct CreateBranchOptions<'a> {
    /// Session this branch belongs to.
    pub session_id: &'a str,
    /// Branch name.
    pub name: &'a str,
    /// Optional description.
    pub description: Option<&'a str>,
    /// Root event ID for the branch.
    pub root_event_id: &'a str,
    /// Head event ID for the branch.
    pub head_event_id: &'a str,
    /// Whether this is the default branch.
    pub is_default: bool,
}

/// Branch repository — stateless, every method takes `&Connection`.
pub struct BranchRepo;

impl BranchRepo {
    /// Create a new branch.
    pub fn create(conn: &Connection, opts: &CreateBranchOptions<'_>) -> Result<BranchRow> {
        let id = format!("br_{}", Uuid::now_v7());
        let now = chrono::Utc::now().to_rfc3339();
        let _ = conn.execute(
            "INSERT INTO branches (id, session_id, name, description, root_event_id, head_event_id, is_default, created_at, last_activity_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![id, opts.session_id, opts.name, opts.description, opts.root_event_id, opts.head_event_id, opts.is_default, now, now],
        )?;
        Ok(BranchRow {
            id,
            session_id: opts.session_id.to_string(),
            name: opts.name.to_string(),
            description: opts.description.map(String::from),
            root_event_id: opts.root_event_id.to_string(),
            head_event_id: opts.head_event_id.to_string(),
            is_default: opts.is_default,
            created_at: now.clone(),
            last_activity_at: now,
        })
    }

    /// Get branch by ID.
    pub fn get_by_id(conn: &Connection, branch_id: &str) -> Result<Option<BranchRow>> {
        let row = conn
            .query_row(
                "SELECT id, session_id, name, description, root_event_id, head_event_id, is_default, created_at, last_activity_at
                 FROM branches WHERE id = ?1",
                params![branch_id],
                Self::map_row,
            )
            .optional()?;
        Ok(row)
    }

    /// Get all branches for a session, ordered by creation time.
    pub fn get_by_session(conn: &Connection, session_id: &str) -> Result<Vec<BranchRow>> {
        let mut stmt = conn.prepare(
            "SELECT id, session_id, name, description, root_event_id, head_event_id, is_default, created_at, last_activity_at
             FROM branches WHERE session_id = ?1 ORDER BY created_at ASC",
        )?;
        let rows = stmt
            .query_map(params![session_id], Self::map_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Get the default branch for a session.
    pub fn get_default(conn: &Connection, session_id: &str) -> Result<Option<BranchRow>> {
        let row = conn
            .query_row(
                "SELECT id, session_id, name, description, root_event_id, head_event_id, is_default, created_at, last_activity_at
                 FROM branches WHERE session_id = ?1 AND is_default = 1",
                params![session_id],
                Self::map_row,
            )
            .optional()?;
        Ok(row)
    }

    /// Update the head event ID and last activity.
    pub fn update_head(conn: &Connection, branch_id: &str, head_event_id: &str) -> Result<bool> {
        let now = chrono::Utc::now().to_rfc3339();
        let changed = conn.execute(
            "UPDATE branches SET head_event_id = ?1, last_activity_at = ?2 WHERE id = ?3",
            params![head_event_id, now, branch_id],
        )?;
        Ok(changed > 0)
    }

    /// Set a branch as default (unsets all others in the same session).
    pub fn set_default(conn: &Connection, branch_id: &str) -> Result<bool> {
        // Get the session_id for this branch
        let session_id: Option<String> = conn
            .query_row(
                "SELECT session_id FROM branches WHERE id = ?1",
                params![branch_id],
                |row| row.get(0),
            )
            .optional()?;

        let Some(session_id) = session_id else {
            return Ok(false);
        };

        // Unset all defaults in this session
        let _ = conn.execute(
            "UPDATE branches SET is_default = 0 WHERE session_id = ?1",
            params![session_id],
        )?;

        // Set the new default
        let changed = conn.execute(
            "UPDATE branches SET is_default = 1 WHERE id = ?1",
            params![branch_id],
        )?;
        Ok(changed > 0)
    }

    /// Delete a branch. Returns `true` if deleted.
    pub fn delete(conn: &Connection, branch_id: &str) -> Result<bool> {
        let changed = conn.execute("DELETE FROM branches WHERE id = ?1", params![branch_id])?;
        Ok(changed > 0)
    }

    /// Delete all branches for a session. Returns count deleted.
    pub fn delete_by_session(conn: &Connection, session_id: &str) -> Result<usize> {
        let changed = conn.execute(
            "DELETE FROM branches WHERE session_id = ?1",
            params![session_id],
        )?;
        Ok(changed)
    }

    /// Count branches for a session.
    pub fn count_by_session(conn: &Connection, session_id: &str) -> Result<i64> {
        let count: i64 = conn.query_row(
            "SELECT COUNT(*) FROM branches WHERE session_id = ?1",
            params![session_id],
            |row| row.get(0),
        )?;
        Ok(count)
    }

    /// Check if branch exists.
    pub fn exists(conn: &Connection, branch_id: &str) -> Result<bool> {
        let exists: bool = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM branches WHERE id = ?1)",
            params![branch_id],
            |row| row.get(0),
        )?;
        Ok(exists)
    }

    fn map_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<BranchRow> {
        Ok(BranchRow {
            id: row.get(0)?,
            session_id: row.get(1)?,
            name: row.get(2)?,
            description: row.get(3)?,
            root_event_id: row.get(4)?,
            head_event_id: row.get(5)?,
            is_default: row.get(6)?,
            created_at: row.get(7)?,
            last_activity_at: row.get(8)?,
        })
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
    use crate::sqlite::repositories::workspace::{CreateWorkspaceOptions, WorkspaceRepo};

    /// Sets up an in-memory DB with migrations and returns (conn, workspace_id, session_id, event_id).
    fn setup() -> (Connection, String, String, String) {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")
            .unwrap();
        run_migrations(&conn).unwrap();

        let ws = WorkspaceRepo::create(
            &conn,
            &CreateWorkspaceOptions {
                path: "/tmp/test",
                name: None,
            },
        )
        .unwrap();

        // Create a session
        conn.execute(
            "INSERT INTO sessions (id, workspace_id, latest_model, working_directory, created_at, last_activity_at)
             VALUES ('sess_1', ?1, 'claude-3', '/tmp/test', datetime('now'), datetime('now'))",
            params![ws.id],
        )
        .unwrap();

        // Create an event (for branch references)
        conn.execute(
            "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id)
             VALUES ('evt_1', 'sess_1', 1, 'session.start', datetime('now'), '{}', ?1)",
            params![ws.id],
        )
        .unwrap();

        (conn, ws.id, "sess_1".to_string(), "evt_1".to_string())
    }

    #[test]
    fn create_branch() {
        let (conn, _, _, evt_id) = setup();
        let br = BranchRepo::create(
            &conn,
            &CreateBranchOptions {
                session_id: "sess_1",
                name: "main",
                description: Some("Default branch"),
                root_event_id: &evt_id,
                head_event_id: &evt_id,
                is_default: true,
            },
        )
        .unwrap();

        assert!(br.id.starts_with("br_"));
        assert_eq!(br.name, "main");
        assert_eq!(br.description.as_deref(), Some("Default branch"));
        assert!(br.is_default);
    }

    #[test]
    fn get_by_id() {
        let (conn, _, _, evt_id) = setup();
        let br = BranchRepo::create(
            &conn,
            &CreateBranchOptions {
                session_id: "sess_1",
                name: "main",
                description: None,
                root_event_id: &evt_id,
                head_event_id: &evt_id,
                is_default: false,
            },
        )
        .unwrap();

        let found = BranchRepo::get_by_id(&conn, &br.id).unwrap().unwrap();
        assert_eq!(found.id, br.id);
        assert_eq!(found.name, "main");
    }

    #[test]
    fn get_by_session() {
        let (conn, _, _, evt_id) = setup();
        BranchRepo::create(
            &conn,
            &CreateBranchOptions {
                session_id: "sess_1",
                name: "main",
                description: None,
                root_event_id: &evt_id,
                head_event_id: &evt_id,
                is_default: true,
            },
        )
        .unwrap();
        BranchRepo::create(
            &conn,
            &CreateBranchOptions {
                session_id: "sess_1",
                name: "feature",
                description: None,
                root_event_id: &evt_id,
                head_event_id: &evt_id,
                is_default: false,
            },
        )
        .unwrap();

        let branches = BranchRepo::get_by_session(&conn, "sess_1").unwrap();
        assert_eq!(branches.len(), 2);
    }

    #[test]
    fn get_default() {
        let (conn, _, _, evt_id) = setup();
        BranchRepo::create(
            &conn,
            &CreateBranchOptions {
                session_id: "sess_1",
                name: "main",
                description: None,
                root_event_id: &evt_id,
                head_event_id: &evt_id,
                is_default: true,
            },
        )
        .unwrap();

        let def = BranchRepo::get_default(&conn, "sess_1").unwrap().unwrap();
        assert_eq!(def.name, "main");
        assert!(def.is_default);
    }

    #[test]
    fn get_default_none() {
        let (conn, _, _, _) = setup();
        let def = BranchRepo::get_default(&conn, "sess_1").unwrap();
        assert!(def.is_none());
    }

    #[test]
    fn update_head() {
        let (conn, ws_id, _, evt_id) = setup();
        let br = BranchRepo::create(
            &conn,
            &CreateBranchOptions {
                session_id: "sess_1",
                name: "main",
                description: None,
                root_event_id: &evt_id,
                head_event_id: &evt_id,
                is_default: false,
            },
        )
        .unwrap();

        // Create a second event
        conn.execute(
            "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id)
             VALUES ('evt_2', 'sess_1', 2, 'message.user', datetime('now'), '{}', ?1)",
            params![ws_id],
        )
        .unwrap();

        BranchRepo::update_head(&conn, &br.id, "evt_2").unwrap();
        let updated = BranchRepo::get_by_id(&conn, &br.id).unwrap().unwrap();
        assert_eq!(updated.head_event_id, "evt_2");
    }

    #[test]
    fn set_default_switches() {
        let (conn, _, _, evt_id) = setup();
        let br1 = BranchRepo::create(
            &conn,
            &CreateBranchOptions {
                session_id: "sess_1",
                name: "main",
                description: None,
                root_event_id: &evt_id,
                head_event_id: &evt_id,
                is_default: true,
            },
        )
        .unwrap();
        let br2 = BranchRepo::create(
            &conn,
            &CreateBranchOptions {
                session_id: "sess_1",
                name: "feature",
                description: None,
                root_event_id: &evt_id,
                head_event_id: &evt_id,
                is_default: false,
            },
        )
        .unwrap();

        BranchRepo::set_default(&conn, &br2.id).unwrap();

        let updated1 = BranchRepo::get_by_id(&conn, &br1.id).unwrap().unwrap();
        let updated2 = BranchRepo::get_by_id(&conn, &br2.id).unwrap().unwrap();
        assert!(!updated1.is_default);
        assert!(updated2.is_default);
    }

    #[test]
    fn delete_branch() {
        let (conn, _, _, evt_id) = setup();
        let br = BranchRepo::create(
            &conn,
            &CreateBranchOptions {
                session_id: "sess_1",
                name: "main",
                description: None,
                root_event_id: &evt_id,
                head_event_id: &evt_id,
                is_default: false,
            },
        )
        .unwrap();

        assert!(BranchRepo::delete(&conn, &br.id).unwrap());
        assert!(BranchRepo::get_by_id(&conn, &br.id).unwrap().is_none());
    }

    #[test]
    fn delete_by_session() {
        let (conn, _, _, evt_id) = setup();
        BranchRepo::create(
            &conn,
            &CreateBranchOptions {
                session_id: "sess_1",
                name: "a",
                description: None,
                root_event_id: &evt_id,
                head_event_id: &evt_id,
                is_default: false,
            },
        )
        .unwrap();
        BranchRepo::create(
            &conn,
            &CreateBranchOptions {
                session_id: "sess_1",
                name: "b",
                description: None,
                root_event_id: &evt_id,
                head_event_id: &evt_id,
                is_default: false,
            },
        )
        .unwrap();

        let deleted = BranchRepo::delete_by_session(&conn, "sess_1").unwrap();
        assert_eq!(deleted, 2);
    }

    #[test]
    fn count_by_session() {
        let (conn, _, _, evt_id) = setup();
        assert_eq!(BranchRepo::count_by_session(&conn, "sess_1").unwrap(), 0);

        BranchRepo::create(
            &conn,
            &CreateBranchOptions {
                session_id: "sess_1",
                name: "main",
                description: None,
                root_event_id: &evt_id,
                head_event_id: &evt_id,
                is_default: false,
            },
        )
        .unwrap();
        assert_eq!(BranchRepo::count_by_session(&conn, "sess_1").unwrap(), 1);
    }

    #[test]
    fn exists_branch() {
        let (conn, _, _, evt_id) = setup();
        let br = BranchRepo::create(
            &conn,
            &CreateBranchOptions {
                session_id: "sess_1",
                name: "main",
                description: None,
                root_event_id: &evt_id,
                head_event_id: &evt_id,
                is_default: false,
            },
        )
        .unwrap();

        assert!(BranchRepo::exists(&conn, &br.id).unwrap());
        assert!(!BranchRepo::exists(&conn, "br_nonexistent").unwrap());
    }
}
