//! Device token repository — CRUD for the `device_tokens` table.
//!
//! Manages APNS device token registrations for push notifications.
//!
//! # Identity
//!
//! Since v007 (plan M3), a registration is uniquely identified by the tuple
//! `(device_token, platform, workspace_id, bundle_id)`. The same APNs push
//! token MAY coexist across two workspaces or two bundle IDs on the same
//! device (e.g., Beta vs Prod installs after the Xcode scheme split).
//! `bundle_id` is NOT NULL; workspace_id remains nullable (workspace-less
//! tokens are legal) and collapses to the canonical `''` via a COALESCE-
//! widened unique index so two (token, NULL-ws, same-bundle) rows don't
//! accumulate.
//!
//! `session_id` is NOT part of the identity key: re-registering the same
//! `(token, platform, workspace, bundle)` with a new `session_id` updates
//! the row in place, preserving the per-workspace-per-bundle-per-device
//! binding while letting the "currently active session" pointer float.
//!
//! # Deactivation
//!
//! When APNs returns a terminal error (410 Gone, BadDeviceToken,
//! DeviceTokenNotForTopic), the token itself is dead device-wide — every
//! row carrying it must be deactivated. [`DeviceTokenRepo::deactivate`]
//! sweeps all active rows for the token and returns one
//! [`DeactivatedTokenInfo`] per row so callers can emit one
//! `device.token_invalidated` event per affected registration without a
//! second round-trip.

use rusqlite::{Connection, OptionalExtension, params};
use uuid::Uuid;

use crate::domains::session::event_store::errors::Result;
use crate::domains::session::event_store::sqlite::row_types::DeviceTokenRow;

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
    /// APNs `apns-topic` the token was issued against. Always present
    /// (NOT NULL since R5).
    pub bundle_id: String,
}

/// Device token repository — stateless, every method takes `&Connection`.
pub struct DeviceTokenRepo;

impl DeviceTokenRepo {
    /// Register or update a device token. Returns `{id, created}`.
    ///
    /// Identity (see module docs) is
    /// `(device_token, platform, workspace_id, bundle_id)`. When an
    /// active or inactive row matches this full tuple, that row is updated
    /// (session_id floats, environment refreshes, is_active → 1). When
    /// no match exists, a new row is inserted.
    ///
    /// NULL workspace_id collapses to canonical `''` via COALESCE so
    /// workspace-less tokens dedup correctly. `bundle_id` is NOT NULL and
    /// participates in the index directly.
    ///
    /// `bundle_id` is the APNs `apns-topic` this token was issued against
    /// (e.g., `com.tron.mobile` vs `com.tron.mobile.beta`). Required —
    /// every client sends its bundle identifier so the send path never
    /// needs a topic fallback.
    pub fn register(
        conn: &Connection,
        device_token: &str,
        session_id: Option<&str>,
        workspace_id: Option<&str>,
        environment: &str,
        bundle_id: &str,
    ) -> Result<RegisterTokenResult> {
        let now = chrono::Utc::now().to_rfc3339();
        let platform = "ios";

        // Identity lookup: match the full (token, platform, workspace, bundle)
        // tuple. Only workspace_id needs COALESCE-widening (NULL workspace is
        // still a legal identity; bundle_id is NOT NULL so it participates
        // directly).
        let existing: Option<String> = conn
            .query_row(
                "SELECT id FROM device_tokens
                 WHERE device_token = ?1
                   AND platform = ?2
                   AND COALESCE(workspace_id, '') = COALESCE(?3, '')
                   AND bundle_id = ?4",
                params![device_token, platform, workspace_id, bundle_id],
                |row| row.get(0),
            )
            .optional()?;

        if let Some(id) = existing {
            // Same identity already known — float session_id / environment
            // and reactivate. workspace_id and bundle_id are part of the
            // identity so they cannot change here; we still re-write them
            // to keep the UPDATE uniform and so a future identity widening
            // doesn't silently leave stale columns behind.
            let _ = conn.execute(
                "UPDATE device_tokens
                 SET session_id = ?1, workspace_id = ?2, environment = ?3,
                     bundle_id = ?4, last_used_at = ?5, is_active = 1
                 WHERE id = ?6",
                params![session_id, workspace_id, environment, bundle_id, now, id],
            )?;
            Ok(RegisterTokenResult { id, created: false })
        } else {
            // New identity — insert. The unique index on (device_token,
            // platform, COALESCE(workspace_id, ''), bundle_id) guarantees
            // no duplicate-identity row survives even under racing callers.
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

    /// Deactivate every active row for a token and return one
    /// [`DeactivatedTokenInfo`] per row, in a single transaction so
    /// downstream callers can emit one `device.token_invalidated` event
    /// per affected registration without a second round-trip.
    ///
    /// Under the v007 workspace+bundle-scoped identity (plan M3), a single
    /// APNs token may legitimately have multiple active registrations
    /// (e.g., same device, two workspaces). When APNs returns a terminal
    /// error for the token, every row carrying it must be deactivated and
    /// each affected session/workspace/bundle must see its own
    /// invalidation event.
    ///
    /// Returns an empty Vec when no active row matched the token (already
    /// deactivated, or never registered). Callers treat an empty Vec as a
    /// no-op: idempotent, must NOT emit audit events. The dedup invariant
    /// is preserved because the SELECT filters on `is_active = 1`, so
    /// a repeated call after the first returns empty.
    pub fn deactivate(conn: &Connection, device_token: &str) -> Result<Vec<DeactivatedTokenInfo>> {
        let tx = conn.unchecked_transaction()?;

        // Pre-read every active row for this token. Filtering on
        // is_active = 1 makes the call idempotent: the second call
        // for the same token returns an empty Vec.
        let infos: Vec<DeactivatedTokenInfo> = {
            let mut stmt = tx.prepare(
                "SELECT session_id, workspace_id, bundle_id
                 FROM device_tokens
                 WHERE device_token = ?1 AND is_active = 1",
            )?;
            let rows = stmt.query_map(params![device_token], |row| {
                Ok(DeactivatedTokenInfo {
                    session_id: row.get(0)?,
                    workspace_id: row.get(1)?,
                    bundle_id: row.get(2)?,
                })
            })?;
            rows.collect::<std::result::Result<Vec<_>, _>>()?
        };

        if infos.is_empty() {
            // Nothing to update; keep the transaction clean so a concurrent
            // writer doesn't see spurious activity.
            tx.commit()?;
            return Ok(infos);
        }

        let _ = tx.execute(
            "UPDATE device_tokens SET is_active = 0 WHERE device_token = ?1 AND is_active = 1",
            params![device_token],
        )?;
        tx.commit()?;

        Ok(infos)
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
    use crate::domains::session::event_store::sqlite::migrations::run_migrations;

    fn setup() -> Connection {
        let conn = Connection::open_in_memory().unwrap();
        conn.execute_batch("PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON;")
            .unwrap();
        run_migrations(&conn).unwrap();
        conn
    }

    const BUNDLE_PROD: &str = "com.tron.mobile";
    const BUNDLE_BETA: &str = "com.tron.mobile.beta";

    #[test]
    fn register_new_token() {
        let conn = setup();
        let result = DeviceTokenRepo::register(
            &conn,
            "a".repeat(64).as_str(),
            None,
            None,
            "production",
            BUNDLE_PROD,
        )
        .unwrap();
        assert!(!result.id.is_empty());
        assert!(result.created);
    }

    #[test]
    fn register_existing_token_returns_same_id() {
        let conn = setup();
        let token = "b".repeat(64);
        let first = DeviceTokenRepo::register(&conn, &token, None, None, "production", BUNDLE_PROD)
            .unwrap();
        let second =
            DeviceTokenRepo::register(&conn, &token, None, None, "production", BUNDLE_PROD)
                .unwrap();
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

    /// Re-registering the same full identity (same workspace + bundle) with
    /// a new session_id / environment updates the row in place rather than
    /// inserting a second one. session_id and environment are NOT part of
    /// the identity key — they float within a stable identity.
    #[test]
    fn register_updates_session_id_within_same_identity() {
        let conn = setup();
        insert_workspace_and_session(&conn);
        let token = "c".repeat(64);
        let r1 =
            DeviceTokenRepo::register(&conn, &token, None, Some("ws_1"), "sandbox", BUNDLE_PROD)
                .unwrap();
        let r2 = DeviceTokenRepo::register(
            &conn,
            &token,
            Some("sess_1"),
            Some("ws_1"),
            "production",
            BUNDLE_PROD,
        )
        .unwrap();

        assert!(r1.created);
        assert!(
            !r2.created,
            "same full identity must update the existing row"
        );
        assert_eq!(
            r1.id, r2.id,
            "row id is stable across same-identity re-register"
        );

        let row = conn
            .query_row(
                "SELECT session_id, workspace_id, environment, bundle_id
                 FROM device_tokens WHERE device_token = ?1",
                params![token],
                |row| {
                    Ok((
                        row.get::<_, Option<String>>(0)?,
                        row.get::<_, Option<String>>(1)?,
                        row.get::<_, String>(2)?,
                        row.get::<_, String>(3)?,
                    ))
                },
            )
            .unwrap();
        assert_eq!(row.0.as_deref(), Some("sess_1"));
        assert_eq!(row.1.as_deref(), Some("ws_1"));
        assert_eq!(row.2, "production");
        assert_eq!(row.3, BUNDLE_PROD);

        // And there is exactly one row (the UNIQUE index held).
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM device_tokens WHERE device_token = ?1",
                params![token],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(count, 1);
    }

    /// A different workspace with the same token+bundle is a different
    /// identity: register creates a second row rather than updating.
    /// Complement of [`same_token_two_workspaces_coexist`]: asserts the
    /// non-workspace side of the identity tuple works as expected.
    #[test]
    fn register_with_different_workspace_creates_distinct_row() {
        let conn = setup();
        insert_workspace_and_session(&conn);
        insert_second_workspace(&conn);

        let token = "w".repeat(64);
        let r1 = DeviceTokenRepo::register(
            &conn,
            &token,
            Some("sess_1"),
            Some("ws_1"),
            "sandbox",
            BUNDLE_PROD,
        )
        .unwrap();
        let r2 = DeviceTokenRepo::register(
            &conn,
            &token,
            Some("sess_2"),
            Some("ws_2"),
            "production",
            BUNDLE_PROD,
        )
        .unwrap();

        assert!(r1.created);
        assert!(r2.created, "workspace change must create a new row");
        assert_ne!(r1.id, r2.id);

        // Both rows survive; the older one is NOT mutated by the newer
        // registration (session, env stay where they were).
        let rows: Vec<(String, Option<String>, Option<String>, String)> = conn
            .prepare(
                "SELECT id, session_id, workspace_id, environment FROM device_tokens
                 WHERE device_token = ?1 ORDER BY workspace_id",
            )
            .unwrap()
            .query_map(params![token], |row| {
                Ok((row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?))
            })
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();

        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].1.as_deref(), Some("sess_1"));
        assert_eq!(rows[0].2.as_deref(), Some("ws_1"));
        assert_eq!(rows[0].3, "sandbox");
        assert_eq!(rows[1].1.as_deref(), Some("sess_2"));
        assert_eq!(rows[1].2.as_deref(), Some("ws_2"));
        assert_eq!(rows[1].3, "production");
    }

    #[test]
    fn register_reactivates_inactive_token() {
        let conn = setup();
        let token = "d".repeat(64);
        DeviceTokenRepo::register(&conn, &token, None, None, "production", BUNDLE_PROD).unwrap();
        DeviceTokenRepo::unregister(&conn, &token).unwrap();

        // Re-register should reactivate
        let result =
            DeviceTokenRepo::register(&conn, &token, None, None, "production", BUNDLE_PROD)
                .unwrap();
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
        DeviceTokenRepo::register(&conn, &token, None, None, "production", BUNDLE_PROD).unwrap();
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
        let result =
            DeviceTokenRepo::register(&conn, &token, None, None, "production", BUNDLE_PROD)
                .unwrap();
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
        DeviceTokenRepo::register(&conn, &token1, None, None, "production", BUNDLE_PROD).unwrap();
        DeviceTokenRepo::register(&conn, &token2, None, None, "production", BUNDLE_PROD).unwrap();
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
        DeviceTokenRepo::register(
            &conn,
            &token1,
            Some("sess_1"),
            None,
            "production",
            BUNDLE_PROD,
        )
        .unwrap();
        DeviceTokenRepo::register(
            &conn,
            &token2,
            Some("sess_2"),
            None,
            "production",
            BUNDLE_PROD,
        )
        .unwrap();

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
            BUNDLE_PROD,
        )
        .unwrap();

        let infos = DeviceTokenRepo::deactivate(&conn, &token).unwrap();
        assert_eq!(
            infos.len(),
            1,
            "single registration should produce one info"
        );
        let info = &infos[0];
        assert_eq!(info.session_id.as_deref(), Some("sess_1"));
        assert_eq!(info.workspace_id.as_deref(), Some("ws_1"));
        assert_eq!(info.bundle_id, BUNDLE_PROD);

        let row = DeviceTokenRepo::get_by_id(&conn, &result.id)
            .unwrap()
            .unwrap();
        assert!(!row.is_active, "row must be flipped inactive");
    }

    #[test]
    fn deactivate_returns_empty_for_nonexistent_token() {
        let conn = setup();
        let infos = DeviceTokenRepo::deactivate(&conn, "nonexistent").unwrap();
        assert!(
            infos.is_empty(),
            "no row → empty Vec → caller must not emit event"
        );
    }

    /// Dedup invariant: a second terminal error on the same token
    /// must NOT re-emit an invalidation event. The deactivate query
    /// filters on `is_active = 1` so already-deactivated tokens
    /// return an empty Vec.
    #[test]
    fn deactivate_returns_empty_on_already_inactive_rows() {
        let conn = setup();
        let token = "g".repeat(64);
        let _ = DeviceTokenRepo::register(&conn, &token, None, None, "production", BUNDLE_PROD)
            .unwrap();
        let first = DeviceTokenRepo::deactivate(&conn, &token).unwrap();
        assert_eq!(first.len(), 1);

        let second = DeviceTokenRepo::deactivate(&conn, &token).unwrap();
        assert!(
            second.is_empty(),
            "second call on same token must be empty to avoid duplicate events"
        );
    }

    #[test]
    fn deactivate_preserves_nullable_session() {
        let conn = setup();
        let token = "h".repeat(64);
        let _ = DeviceTokenRepo::register(&conn, &token, None, None, "production", BUNDLE_PROD)
            .unwrap();
        let infos = DeviceTokenRepo::deactivate(&conn, &token).unwrap();
        assert_eq!(infos.len(), 1);
        let info = &infos[0];
        assert!(info.session_id.is_none());
        assert!(info.workspace_id.is_none());
        assert_eq!(info.bundle_id, BUNDLE_PROD);
    }

    /// When a single token has multiple active registrations (e.g., the
    /// same device in two workspaces), deactivate sweeps all of them and
    /// returns one info per row so the caller can emit one
    /// `device.token_invalidated` event per affected registration. This
    /// is the fidelity requirement of the v007 identity widening.
    #[test]
    fn deactivate_sweeps_all_rows_for_token() {
        let conn = setup();
        insert_workspace_and_session(&conn);
        insert_second_workspace(&conn);
        let token = "y".repeat(64);

        DeviceTokenRepo::register(
            &conn,
            &token,
            Some("sess_1"),
            Some("ws_1"),
            "production",
            BUNDLE_PROD,
        )
        .unwrap();
        DeviceTokenRepo::register(&conn, &token, None, Some("ws_2"), "production", BUNDLE_PROD)
            .unwrap();

        let infos = DeviceTokenRepo::deactivate(&conn, &token).unwrap();
        assert_eq!(
            infos.len(),
            2,
            "every active row for the token must be deactivated"
        );
        let mut workspaces: Vec<String> = infos
            .iter()
            .filter_map(|i| i.workspace_id.clone())
            .collect();
        workspaces.sort();
        assert_eq!(workspaces, vec!["ws_1".to_string(), "ws_2".to_string()]);

        // No active rows remain.
        let active: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM device_tokens WHERE device_token = ?1 AND is_active = 1",
                params![token],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(active, 0);

        // A repeat call is a no-op.
        let again = DeviceTokenRepo::deactivate(&conn, &token).unwrap();
        assert!(again.is_empty());
    }

    #[test]
    fn register_preserves_platform_ios() {
        let conn = setup();
        let token = "h".repeat(64);
        let result =
            DeviceTokenRepo::register(&conn, &token, None, None, "sandbox", BUNDLE_PROD).unwrap();
        let row = DeviceTokenRepo::get_by_id(&conn, &result.id)
            .unwrap()
            .unwrap();
        assert_eq!(row.platform, "ios");
        assert_eq!(row.environment, "sandbox");
    }

    // ── bundle_id round-trip ──────────────────────────────────────────

    #[test]
    fn register_with_bundle_id_stores_it() {
        let conn = setup();
        let token = "1".repeat(64);
        let result =
            DeviceTokenRepo::register(&conn, &token, None, None, "sandbox", BUNDLE_BETA).unwrap();
        let row = DeviceTokenRepo::get_by_id(&conn, &result.id)
            .unwrap()
            .unwrap();
        assert_eq!(row.bundle_id, BUNDLE_BETA);
    }

    /// A different bundle is a different identity (plan M3, v007). The same
    /// device installing com.tron.mobile.beta after com.tron.mobile would
    /// produce two distinct registrations — Apple emits a fresh token per
    /// bundle in practice, but the schema must not silently collapse them
    /// when a caller happens to reuse a token across bundles.
    #[test]
    fn register_with_different_bundle_creates_distinct_row() {
        let conn = setup();
        let token = "3".repeat(64);
        let r1 = DeviceTokenRepo::register(&conn, &token, None, None, "production", BUNDLE_PROD)
            .unwrap();
        let r2 =
            DeviceTokenRepo::register(&conn, &token, None, None, "sandbox", BUNDLE_BETA).unwrap();

        assert!(r1.created);
        assert!(r2.created, "distinct bundles must create distinct rows");
        assert_ne!(r1.id, r2.id);

        let mut bundles: Vec<String> = conn
            .prepare(
                "SELECT bundle_id FROM device_tokens WHERE device_token = ?1 ORDER BY bundle_id",
            )
            .unwrap()
            .query_map(params![token], |row| row.get::<_, String>(0))
            .unwrap()
            .filter_map(std::result::Result::ok)
            .collect();
        bundles.sort();
        assert_eq!(bundles.len(), 2);
        assert_eq!(bundles[0], BUNDLE_PROD);
        assert_eq!(bundles[1], BUNDLE_BETA);
    }

    #[test]
    fn get_all_active_returns_bundle_id_for_each_token() {
        let conn = setup();
        let t_prod = "5".repeat(64);
        let t_beta = "6".repeat(64);
        DeviceTokenRepo::register(&conn, &t_prod, None, None, "production", BUNDLE_PROD).unwrap();
        DeviceTokenRepo::register(&conn, &t_beta, None, None, "sandbox", BUNDLE_BETA).unwrap();

        let mut rows = DeviceTokenRepo::get_all_active(&conn).unwrap();
        rows.sort_by(|a, b| a.device_token.cmp(&b.device_token));
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].device_token, t_prod);
        assert_eq!(rows[0].bundle_id, BUNDLE_PROD);
        assert_eq!(rows[1].device_token, t_beta);
        assert_eq!(rows[1].bundle_id, BUNDLE_BETA);
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
            BUNDLE_BETA,
        )
        .unwrap();

        let rows = DeviceTokenRepo::get_by_session(&conn, "sess_1").unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].bundle_id, BUNDLE_BETA);
    }

    // ── M3: workspace-scoped identity (v007) ───────────────────────────

    fn insert_second_workspace(conn: &Connection) {
        conn.execute(
            "INSERT INTO workspaces (id, path, created_at, last_activity_at)
             VALUES ('ws_2', '/tmp/test2', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
            [],
        )
        .unwrap();
    }

    /// Regression guard (plan M3): the same push token may coexist for two
    /// different workspaces. Under the old narrow `UNIQUE(device_token,
    /// platform)` constraint, the second register would have updated the
    /// first row instead of inserting a new one.
    #[test]
    fn same_token_two_workspaces_coexist() {
        let conn = setup();
        insert_workspace_and_session(&conn);
        insert_second_workspace(&conn);

        let token = "z".repeat(64);
        let r1 = DeviceTokenRepo::register(
            &conn,
            &token,
            None,
            Some("ws_1"),
            "production",
            "com.tron.mobile",
        )
        .unwrap();
        let r2 = DeviceTokenRepo::register(
            &conn,
            &token,
            None,
            Some("ws_2"),
            "production",
            "com.tron.mobile",
        )
        .unwrap();

        assert!(r1.created, "first registration should create a row");
        assert!(
            r2.created,
            "second registration with a different workspace must create a distinct row"
        );
        assert_ne!(
            r1.id, r2.id,
            "distinct identities must produce distinct IDs"
        );

        let active_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM device_tokens WHERE device_token = ?1 AND is_active = 1",
                params![token],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(
            active_count, 2,
            "both workspace registrations must remain active"
        );

        let mut rows = DeviceTokenRepo::get_all_active(&conn).unwrap();
        rows.sort_by(|a, b| a.workspace_id.cmp(&b.workspace_id));
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].workspace_id.as_deref(), Some("ws_1"));
        assert_eq!(rows[1].workspace_id.as_deref(), Some("ws_2"));
        assert!(rows.iter().all(|r| r.device_token == token));
        assert!(rows.iter().all(|r| r.bundle_id == "com.tron.mobile"));
    }
}
