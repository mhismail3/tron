//! Device token repository — CRUD for the `device_tokens` table.
//!
//! Manages APNS device token registrations for push notifications.
//! Tokens are uniquely identified by `(device_token, platform)`.

use rusqlite::{Connection, OptionalExtension, params};
use uuid::Uuid;

use crate::events::errors::Result;
use crate::events::sqlite::row_types::DeviceTokenRow;

/// Result of registering a device token (upsert).
#[derive(Debug)]
pub struct RegisterTokenResult {
    /// The registration ID.
    pub id: String,
    /// Whether a new row was created (vs. updated existing).
    pub created: bool,
}

/// Row context returned by [`DeviceTokenRepo::deactivate`] so callers
/// can attribute a `device.token_invalidated` event to the right
/// session without a separate query.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeactivatedTokenInfo {
    /// Session the token was registered to (at registration time).
    /// `None` for tokens registered without a session binding.
    pub session_id: Option<String>,
    /// Workspace the token was registered to. Useful for cross-session
    /// attribution when `session_id` is absent.
    pub workspace_id: Option<String>,
    /// APNs `apns-topic` the token was issued against.
    pub bundle_id: Option<String>,
}

/// Device token repository — stateless, every method takes `&Connection`.
pub struct DeviceTokenRepo;

impl DeviceTokenRepo {
    /// Register or update a device token. Returns `{id, created}`.
    ///
    /// If the `(device_token, platform)` pair already exists, updates the
    /// session/workspace/environment/bundle_id and reactivates it. Otherwise
    /// inserts a new row.
    ///
    /// `bundle_id` is the APNs `apns-topic` this token was issued against
    /// (e.g., `com.tron.mobile` vs `com.tron.mobile.beta`). Nullable for
    /// callers that don't yet send it; the relay falls back to its env
    /// default at delivery time.
    pub fn register(
        conn: &Connection,
        device_token: &str,
        session_id: Option<&str>,
        workspace_id: Option<&str>,
        environment: &str,
        bundle_id: Option<&str>,
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
            // Update existing token — bundle_id overwrites, including NULL,
            // so the DB reflects the current client's state (matches the
            // existing semantics for session_id/workspace_id/environment).
            let _ = conn.execute(
                "UPDATE device_tokens
                 SET session_id = ?1, workspace_id = ?2, environment = ?3,
                     bundle_id = ?4, last_used_at = ?5, is_active = 1
                 WHERE id = ?6",
                params![session_id, workspace_id, environment, bundle_id, now, id],
            )?;
            Ok(RegisterTokenResult { id, created: false })
        } else {
            // Insert new token
            let id = Uuid::now_v7().to_string();
            let _ = conn.execute(
                "INSERT INTO device_tokens (id, device_token, session_id, workspace_id,
                     platform, environment, bundle_id, created_at, last_used_at, is_active)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 1)",
                params![
                    id,
                    device_token,
                    session_id,
                    workspace_id,
                    platform,
                    environment,
                    bundle_id,
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
                        environment, bundle_id, created_at, last_used_at, is_active
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
                    environment, bundle_id, created_at, last_used_at, is_active
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
                    environment, bundle_id, created_at, last_used_at, is_active
             FROM device_tokens WHERE session_id = ?1 AND is_active = 1",
        )?;
        let rows = stmt
            .query_map(params![session_id], Self::map_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Deactivate a token and return the row context (session, bundle)
    /// in a single transaction so downstream callers can emit a
    /// `device.token_invalidated` event without a second round-trip.
    ///
    /// Returns `Some(info)` when a currently-active row existed and was
    /// deactivated. Returns `None` when no active row matched the token
    /// (already deactivated, or never registered) — callers treat this
    /// as a no-op and must NOT emit an audit event.
    pub fn deactivate(
        conn: &Connection,
        device_token: &str,
    ) -> Result<Option<DeactivatedTokenInfo>> {
        let tx = conn.unchecked_transaction()?;

        // Pre-read the relevant columns; filter to is_active=1 so
        // repeated terminal errors for the same token don't produce
        // multiple invalidation events.
        let info: Option<DeactivatedTokenInfo> = tx
            .query_row(
                "SELECT session_id, workspace_id, bundle_id
                 FROM device_tokens
                 WHERE device_token = ?1 AND is_active = 1",
                params![device_token],
                |row| {
                    Ok(DeactivatedTokenInfo {
                        session_id: row.get(0)?,
                        workspace_id: row.get(1)?,
                        bundle_id: row.get(2)?,
                    })
                },
            )
            .optional()?;

        if info.is_none() {
            // Nothing to update; avoid touching the row so a concurrent
            // writer doesn't see spurious activity.
            tx.commit()?;
            return Ok(None);
        }

        let _ = tx.execute(
            "UPDATE device_tokens SET is_active = 0 WHERE device_token = ?1",
            params![device_token],
        )?;
        tx.commit()?;

        Ok(info)
    }

    /// Map a rusqlite row to `DeviceTokenRow`.
    ///
    /// Column order MUST match every `SELECT` above:
    /// 0=id, 1=device_token, 2=session_id, 3=workspace_id, 4=platform,
    /// 5=environment, 6=bundle_id, 7=created_at, 8=last_used_at, 9=is_active.
    fn map_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<DeviceTokenRow> {
        Ok(DeviceTokenRow {
            id: row.get(0)?,
            device_token: row.get(1)?,
            session_id: row.get(2)?,
            workspace_id: row.get(3)?,
            platform: row.get(4)?,
            environment: row.get(5)?,
            bundle_id: row.get(6)?,
            created_at: row.get(7)?,
            last_used_at: row.get(8)?,
            is_active: row.get::<_, i32>(9)? == 1,
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
    use crate::events::sqlite::migrations::run_migrations;

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
            DeviceTokenRepo::register(&conn, "a".repeat(64).as_str(), None, None, "production", None)
                .unwrap();
        assert!(!result.id.is_empty());
        assert!(result.created);
    }

    #[test]
    fn register_existing_token_returns_same_id() {
        let conn = setup();
        let token = "b".repeat(64);
        let first = DeviceTokenRepo::register(&conn, &token, None, None, "production", None).unwrap();
        let second = DeviceTokenRepo::register(&conn, &token, None, None, "production", None).unwrap();
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
        DeviceTokenRepo::register(&conn, &token, None, None, "sandbox", None).unwrap();
        DeviceTokenRepo::register(&conn, &token, Some("sess_1"), Some("ws_1"), "production", None)
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
        DeviceTokenRepo::register(&conn, &token, None, None, "production", None).unwrap();
        DeviceTokenRepo::unregister(&conn, &token).unwrap();

        // Re-register should reactivate
        let result = DeviceTokenRepo::register(&conn, &token, None, None, "production", None).unwrap();
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
        DeviceTokenRepo::register(&conn, &token, None, None, "production", None).unwrap();
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
        let result = DeviceTokenRepo::register(&conn, &token, None, None, "production", None).unwrap();
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
        DeviceTokenRepo::register(&conn, &token1, None, None, "production", None).unwrap();
        DeviceTokenRepo::register(&conn, &token2, None, None, "production", None).unwrap();
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
        DeviceTokenRepo::register(&conn, &token1, Some("sess_1"), None, "production", None).unwrap();
        DeviceTokenRepo::register(&conn, &token2, Some("sess_2"), None, "production", None).unwrap();

        let session_tokens = DeviceTokenRepo::get_by_session(&conn, "sess_1").unwrap();
        assert_eq!(session_tokens.len(), 1);
        assert_eq!(session_tokens[0].device_token, token1);
    }

    #[test]
    fn deactivate_flips_is_active_and_returns_info() {
        let conn = setup();
        insert_workspace_and_session(&conn);
        let token = "g".repeat(64);
        let result = DeviceTokenRepo::register(
            &conn,
            &token,
            Some("sess_1"),
            Some("ws_1"),
            "production",
            Some("com.tron.mobile"),
        )
        .unwrap();

        let info = DeviceTokenRepo::deactivate(&conn, &token).unwrap();
        let info = info.expect("active row should produce info");
        assert_eq!(info.session_id.as_deref(), Some("sess_1"));
        assert_eq!(info.workspace_id.as_deref(), Some("ws_1"));
        assert_eq!(info.bundle_id.as_deref(), Some("com.tron.mobile"));

        let row = DeviceTokenRepo::get_by_id(&conn, &result.id)
            .unwrap()
            .unwrap();
        assert!(!row.is_active, "row must be flipped inactive");
    }

    #[test]
    fn deactivate_returns_none_for_nonexistent_token() {
        let conn = setup();
        let info = DeviceTokenRepo::deactivate(&conn, "nonexistent").unwrap();
        assert!(info.is_none(), "no row → no info → caller must not emit event");
    }

    /// Dedup invariant: a second terminal error on the same token
    /// must NOT re-emit an invalidation event. The deactivate query
    /// filters on `is_active = 1` so already-deactivated tokens
    /// return None.
    #[test]
    fn deactivate_returns_none_on_already_inactive_row() {
        let conn = setup();
        let token = "g".repeat(64);
        let _ = DeviceTokenRepo::register(&conn, &token, None, None, "production", None)
            .unwrap();
        let first = DeviceTokenRepo::deactivate(&conn, &token).unwrap();
        assert!(first.is_some());

        let second = DeviceTokenRepo::deactivate(&conn, &token).unwrap();
        assert!(
            second.is_none(),
            "second call on same token must be a no-op to avoid duplicate events"
        );
    }

    #[test]
    fn deactivate_preserves_nullable_session_and_bundle() {
        let conn = setup();
        let token = "h".repeat(64);
        let _ = DeviceTokenRepo::register(&conn, &token, None, None, "production", None)
            .unwrap();
        let info = DeviceTokenRepo::deactivate(&conn, &token).unwrap().unwrap();
        assert!(info.session_id.is_none());
        assert!(info.workspace_id.is_none());
        assert!(info.bundle_id.is_none());
    }

    #[test]
    fn register_preserves_platform_ios() {
        let conn = setup();
        let token = "h".repeat(64);
        let result = DeviceTokenRepo::register(&conn, &token, None, None, "sandbox", None).unwrap();
        let row = DeviceTokenRepo::get_by_id(&conn, &result.id)
            .unwrap()
            .unwrap();
        assert_eq!(row.platform, "ios");
        assert_eq!(row.environment, "sandbox");
    }

    // ── bundle_id round-trip (v006) ─────────────────────────────────

    #[test]
    fn register_with_bundle_id_stores_it() {
        let conn = setup();
        let token = "1".repeat(64);
        let result = DeviceTokenRepo::register(
            &conn,
            &token,
            None,
            None,
            "sandbox",
            Some("com.tron.mobile.beta"),
        )
        .unwrap();
        let row = DeviceTokenRepo::get_by_id(&conn, &result.id)
            .unwrap()
            .unwrap();
        assert_eq!(row.bundle_id.as_deref(), Some("com.tron.mobile.beta"));
    }

    #[test]
    fn register_without_bundle_id_stores_null() {
        let conn = setup();
        let token = "2".repeat(64);
        let result =
            DeviceTokenRepo::register(&conn, &token, None, None, "production", None).unwrap();
        let row = DeviceTokenRepo::get_by_id(&conn, &result.id)
            .unwrap()
            .unwrap();
        assert!(
            row.bundle_id.is_none(),
            "register(..., None) should store NULL bundle_id"
        );
    }

    #[test]
    fn register_updates_bundle_id_on_reregistration() {
        // Token moves between bundles (e.g., same device reinstalls Beta after Prod).
        let conn = setup();
        let token = "3".repeat(64);
        DeviceTokenRepo::register(
            &conn,
            &token,
            None,
            None,
            "production",
            Some("com.tron.mobile"),
        )
        .unwrap();
        DeviceTokenRepo::register(
            &conn,
            &token,
            None,
            None,
            "sandbox",
            Some("com.tron.mobile.beta"),
        )
        .unwrap();

        let stored: Option<String> = conn
            .query_row(
                "SELECT bundle_id FROM device_tokens WHERE device_token = ?1",
                params![token],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(stored.as_deref(), Some("com.tron.mobile.beta"));
    }

    #[test]
    fn register_clears_bundle_id_when_new_is_none() {
        // A downgraded or legacy client re-registers without bundle_id —
        // DB reflects current state (matches session_id/workspace_id semantics).
        let conn = setup();
        let token = "4".repeat(64);
        DeviceTokenRepo::register(
            &conn,
            &token,
            None,
            None,
            "production",
            Some("com.tron.mobile"),
        )
        .unwrap();
        DeviceTokenRepo::register(&conn, &token, None, None, "production", None).unwrap();

        let stored: Option<String> = conn
            .query_row(
                "SELECT bundle_id FROM device_tokens WHERE device_token = ?1",
                params![token],
                |row| row.get(0),
            )
            .unwrap();
        assert!(stored.is_none(), "re-register with None should clear to NULL");
    }

    #[test]
    fn get_all_active_returns_bundle_id_for_each_token() {
        let conn = setup();
        let t_prod = "5".repeat(64);
        let t_beta = "6".repeat(64);
        let t_legacy = "7".repeat(64);
        DeviceTokenRepo::register(
            &conn,
            &t_prod,
            None,
            None,
            "production",
            Some("com.tron.mobile"),
        )
        .unwrap();
        DeviceTokenRepo::register(
            &conn,
            &t_beta,
            None,
            None,
            "sandbox",
            Some("com.tron.mobile.beta"),
        )
        .unwrap();
        DeviceTokenRepo::register(&conn, &t_legacy, None, None, "production", None).unwrap();

        let mut rows = DeviceTokenRepo::get_all_active(&conn).unwrap();
        rows.sort_by(|a, b| a.device_token.cmp(&b.device_token));
        assert_eq!(rows.len(), 3);
        assert_eq!(rows[0].device_token, t_prod);
        assert_eq!(rows[0].bundle_id.as_deref(), Some("com.tron.mobile"));
        assert_eq!(rows[1].device_token, t_beta);
        assert_eq!(rows[1].bundle_id.as_deref(), Some("com.tron.mobile.beta"));
        assert_eq!(rows[2].device_token, t_legacy);
        assert!(rows[2].bundle_id.is_none());
    }

    #[test]
    fn get_by_session_returns_bundle_id() {
        let conn = setup();
        insert_workspace_and_session(&conn);
        let token = "8".repeat(64);
        DeviceTokenRepo::register(
            &conn,
            &token,
            Some("sess_1"),
            Some("ws_1"),
            "sandbox",
            Some("com.tron.mobile.beta"),
        )
        .unwrap();

        let rows = DeviceTokenRepo::get_by_session(&conn, "sess_1").unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].bundle_id.as_deref(), Some("com.tron.mobile.beta"));
    }


    #[test]
    fn map_row_handles_null_bundle_id() {
        // Direct insert with explicit NULL (simulates legacy pre-v006 row).
        let conn = setup();
        conn.execute(
            "INSERT INTO device_tokens (id, device_token, platform, environment,
                                        created_at, last_used_at, is_active)
             VALUES ('legacy_1', '9999', 'ios', 'production',
                     '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 1)",
            [],
        )
        .unwrap();

        let row = DeviceTokenRepo::get_by_id(&conn, "legacy_1").unwrap().unwrap();
        assert_eq!(row.device_token, "9999");
        assert!(row.bundle_id.is_none());
    }
}
