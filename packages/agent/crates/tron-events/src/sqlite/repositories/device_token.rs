//! Device token repository — CRUD for the `device_tokens` table.
//!
//! Manages APNS device token registrations for push notifications.
//! Tokens are uniquely identified by `(device_token, platform)`.

use rusqlite::{Connection, OptionalExtension, params};
use uuid::Uuid;

use crate::errors::Result;
use crate::sqlite::row_types::DeviceTokenRow;

/// Result of registering a device token (upsert).
#[derive(Debug)]
pub struct RegisterTokenResult {
    /// The registration ID.
    pub id: String,
    /// Whether a new row was created (vs. updated existing).
    pub created: bool,
}

/// Device token repository — stateless, every method takes `&Connection`.
pub struct DeviceTokenRepo;

impl DeviceTokenRepo {
    /// Register or update a device token. Returns `{id, created}`.
    ///
    /// If the `(device_token, platform)` pair already exists, updates the
    /// session/workspace/environment and reactivates it. Otherwise inserts a new row.
    pub fn register(
        conn: &Connection,
        device_token: &str,
        session_id: Option<&str>,
        workspace_id: Option<&str>,
        environment: &str,
    ) -> Result<RegisterTokenResult> {
        let now = chrono::Utc::now().to_rfc3339();
        let platform = "ios";

        // Check if token already exists
        let existing: Option<String> = conn
            .query_row(
                "SELECT id FROM device_tokens WHERE device_token = ?1 AND platform = ?2",
                params![device_token, platform],
                |row| row.get(0),
            )
            .optional()?;

        if let Some(id) = existing {
            // Update existing token
            let _ = conn.execute(
                "UPDATE device_tokens
                 SET session_id = ?1, workspace_id = ?2, environment = ?3,
                     last_used_at = ?4, is_active = 1
                 WHERE id = ?5",
                params![session_id, workspace_id, environment, now, id],
            )?;
            Ok(RegisterTokenResult { id, created: false })
        } else {
            // Insert new token
            let id = Uuid::now_v7().to_string();
            let _ = conn.execute(
                "INSERT INTO device_tokens (id, device_token, session_id, workspace_id,
                     platform, environment, created_at, last_used_at, is_active)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 1)",
                params![
                    id,
                    device_token,
                    session_id,
                    workspace_id,
                    platform,
                    environment,
                    now,
                    now
                ],
            )?;
            Ok(RegisterTokenResult { id, created: true })
        }
    }

    /// Unregister (deactivate) a device token. Returns whether any row was updated.
    pub fn unregister(conn: &Connection, device_token: &str) -> Result<bool> {
        let changed = conn.execute(
            "UPDATE device_tokens SET is_active = 0 WHERE device_token = ?1",
            params![device_token],
        )?;
        Ok(changed > 0)
    }

    /// Get a device token by ID.
    pub fn get_by_id(conn: &Connection, id: &str) -> Result<Option<DeviceTokenRow>> {
        let row = conn
            .query_row(
                "SELECT id, device_token, session_id, workspace_id, platform,
                        environment, created_at, last_used_at, is_active
                 FROM device_tokens WHERE id = ?1",
                params![id],
                Self::map_row,
            )
            .optional()?;
        Ok(row)
    }

    /// Get all active tokens.
    pub fn get_all_active(conn: &Connection) -> Result<Vec<DeviceTokenRow>> {
        let mut stmt = conn.prepare(
            "SELECT id, device_token, session_id, workspace_id, platform,
                    environment, created_at, last_used_at, is_active
             FROM device_tokens WHERE is_active = 1",
        )?;
        let rows = stmt
            .query_map([], Self::map_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Get active tokens for a specific session.
    pub fn get_by_session(conn: &Connection, session_id: &str) -> Result<Vec<DeviceTokenRow>> {
        let mut stmt = conn.prepare(
            "SELECT id, device_token, session_id, workspace_id, platform,
                    environment, created_at, last_used_at, is_active
             FROM device_tokens WHERE session_id = ?1 AND is_active = 1",
        )?;
        let rows = stmt
            .query_map(params![session_id], Self::map_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Mark a token as invalid (deactivate by `device_token` value).
    pub fn mark_invalid(conn: &Connection, device_token: &str) -> Result<bool> {
        let changed = conn.execute(
            "UPDATE device_tokens SET is_active = 0 WHERE device_token = ?1",
            params![device_token],
        )?;
        Ok(changed > 0)
    }

    /// Map a rusqlite row to `DeviceTokenRow`.
    fn map_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<DeviceTokenRow> {
        Ok(DeviceTokenRow {
            id: row.get(0)?,
            device_token: row.get(1)?,
            session_id: row.get(2)?,
            workspace_id: row.get(3)?,
            platform: row.get(4)?,
            environment: row.get(5)?,
            created_at: row.get(6)?,
            last_used_at: row.get(7)?,
            is_active: row.get::<_, i32>(8)? == 1,
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

    fn setup() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")
            .unwrap();
        run_migrations(&conn).unwrap();
        conn
    }

    #[test]
    fn register_new_token() {
        let conn = setup();
        let result =
            DeviceTokenRepo::register(&conn, "a".repeat(64).as_str(), None, None, "production")
                .unwrap();
        assert!(!result.id.is_empty());
        assert!(result.created);
    }

    #[test]
    fn register_existing_token_returns_same_id() {
        let conn = setup();
        let token = "b".repeat(64);
        let first = DeviceTokenRepo::register(&conn, &token, None, None, "production").unwrap();
        let second = DeviceTokenRepo::register(&conn, &token, None, None, "production").unwrap();
        assert_eq!(first.id, second.id);
        assert!(first.created);
        assert!(!second.created);
    }

    fn insert_workspace_and_session(conn: &Connection) {
        conn.execute(
            "INSERT INTO workspaces (id, path, created_at, last_activity_at)
             VALUES ('ws_1', '/tmp/test', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO sessions (id, workspace_id, latest_model, working_directory, created_at, last_activity_at)
             VALUES ('sess_1', 'ws_1', 'test', '/tmp/test', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
            [],
        )
        .unwrap();
        conn.execute(
            "INSERT INTO sessions (id, workspace_id, latest_model, working_directory, created_at, last_activity_at)
             VALUES ('sess_2', 'ws_1', 'test', '/tmp/test', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
            [],
        )
        .unwrap();
    }

    #[test]
    fn register_updates_session_and_workspace() {
        let conn = setup();
        insert_workspace_and_session(&conn);
        let token = "c".repeat(64);
        DeviceTokenRepo::register(&conn, &token, None, None, "sandbox").unwrap();
        DeviceTokenRepo::register(&conn, &token, Some("sess_1"), Some("ws_1"), "production")
            .unwrap();

        let row = conn
            .query_row(
                "SELECT session_id, workspace_id, environment FROM device_tokens WHERE device_token = ?1",
                params![token],
                |row| {
                    Ok((
                        row.get::<_, Option<String>>(0)?,
                        row.get::<_, Option<String>>(1)?,
                        row.get::<_, String>(2)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(row.0.as_deref(), Some("sess_1"));
        assert_eq!(row.1.as_deref(), Some("ws_1"));
        assert_eq!(row.2, "production");
    }

    #[test]
    fn register_reactivates_inactive_token() {
        let conn = setup();
        let token = "d".repeat(64);
        DeviceTokenRepo::register(&conn, &token, None, None, "production").unwrap();
        DeviceTokenRepo::unregister(&conn, &token).unwrap();

        // Re-register should reactivate
        let result = DeviceTokenRepo::register(&conn, &token, None, None, "production").unwrap();
        assert!(!result.created); // existing row
        let row = DeviceTokenRepo::get_by_id(&conn, &result.id)
            .unwrap()
            .unwrap();
        assert!(row.is_active);
    }

    #[test]
    fn unregister_existing_token() {
        let conn = setup();
        let token = "e".repeat(64);
        DeviceTokenRepo::register(&conn, &token, None, None, "production").unwrap();
        let success = DeviceTokenRepo::unregister(&conn, &token).unwrap();
        assert!(success);
    }

    #[test]
    fn unregister_nonexistent_token() {
        let conn = setup();
        let success = DeviceTokenRepo::unregister(&conn, "nonexistent").unwrap();
        assert!(!success);
    }

    #[test]
    fn get_by_id_found() {
        let conn = setup();
        let token = "f".repeat(64);
        let result = DeviceTokenRepo::register(&conn, &token, None, None, "production").unwrap();
        let row = DeviceTokenRepo::get_by_id(&conn, &result.id).unwrap();
        assert!(row.is_some());
        let row = row.unwrap();
        assert_eq!(row.device_token, token);
        assert_eq!(row.platform, "ios");
        assert_eq!(row.environment, "production");
        assert!(row.is_active);
    }

    #[test]
    fn get_by_id_not_found() {
        let conn = setup();
        let row = DeviceTokenRepo::get_by_id(&conn, "nonexistent").unwrap();
        assert!(row.is_none());
    }

    #[test]
    fn get_all_active_empty() {
        let conn = setup();
        let tokens = DeviceTokenRepo::get_all_active(&conn).unwrap();
        assert!(tokens.is_empty());
    }

    #[test]
    fn get_all_active_filters_inactive() {
        let conn = setup();
        let token1 = "a".repeat(64);
        let token2 = "b".repeat(64);
        DeviceTokenRepo::register(&conn, &token1, None, None, "production").unwrap();
        DeviceTokenRepo::register(&conn, &token2, None, None, "production").unwrap();
        DeviceTokenRepo::unregister(&conn, &token1).unwrap();

        let active = DeviceTokenRepo::get_all_active(&conn).unwrap();
        assert_eq!(active.len(), 1);
        assert_eq!(active[0].device_token, token2);
    }

    #[test]
    fn get_by_session() {
        let conn = setup();
        insert_workspace_and_session(&conn);
        let token1 = "a".repeat(64);
        let token2 = "b".repeat(64);
        DeviceTokenRepo::register(&conn, &token1, Some("sess_1"), None, "production").unwrap();
        DeviceTokenRepo::register(&conn, &token2, Some("sess_2"), None, "production").unwrap();

        let tokens = DeviceTokenRepo::get_by_session(&conn, "sess_1").unwrap();
        assert_eq!(tokens.len(), 1);
        assert_eq!(tokens[0].device_token, token1);
    }

    #[test]
    fn mark_invalid_deactivates() {
        let conn = setup();
        let token = "g".repeat(64);
        let result = DeviceTokenRepo::register(&conn, &token, None, None, "production").unwrap();
        DeviceTokenRepo::mark_invalid(&conn, &token).unwrap();

        let row = DeviceTokenRepo::get_by_id(&conn, &result.id)
            .unwrap()
            .unwrap();
        assert!(!row.is_active);
    }

    #[test]
    fn mark_invalid_nonexistent() {
        let conn = setup();
        let changed = DeviceTokenRepo::mark_invalid(&conn, "nonexistent").unwrap();
        assert!(!changed);
    }

    #[test]
    fn register_preserves_platform_ios() {
        let conn = setup();
        let token = "h".repeat(64);
        let result = DeviceTokenRepo::register(&conn, &token, None, None, "sandbox").unwrap();
        let row = DeviceTokenRepo::get_by_id(&conn, &result.id)
            .unwrap()
            .unwrap();
        assert_eq!(row.platform, "ios");
        assert_eq!(row.environment, "sandbox");
    }
}
