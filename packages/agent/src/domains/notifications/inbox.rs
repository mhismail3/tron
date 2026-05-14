//! Shared notification inbox logic used by notification capabilities.

use crate::domains::session::event_store::PooledConnection;
use rusqlite::{Connection, params};
use serde::Serialize;
use serde_json::Value;
use tracing::{debug, warn};

use crate::shared::server::errors::CapabilityError;

/// A single notification returned to the client inbox.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct NotificationInboxEntry {
    pub(crate) event_id: String,
    pub(crate) session_id: String,
    pub(crate) invocation_id: Option<String>,
    pub(crate) timestamp: String,
    pub(crate) title: String,
    pub(crate) body: String,
    pub(crate) sheet_content: Option<Value>,
    pub(crate) is_read: bool,
    pub(crate) read_at: Option<String>,
    pub(crate) session_title: Option<String>,
    pub(crate) is_user_session: bool,
}

/// capability response for listing notifications.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct NotificationListResult {
    pub(crate) notifications: Vec<NotificationInboxEntry>,
    pub(crate) unread_count: u64,
}

/// capability response for marking a single notification as read.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MarkReadResult {
    pub(crate) success: bool,
}

/// capability response for marking all notifications as read.
#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) struct MarkAllReadResult {
    pub(crate) marked: usize,
}

#[derive(Debug)]
struct NotificationRow {
    event_id: String,
    session_id: String,
    invocation_id: Option<String>,
    timestamp: String,
    payload: String,
    session_title: Option<String>,
    source: Option<String>,
    spawning_session_id: Option<String>,
    read_at: Option<String>,
}

#[derive(Debug)]
struct NotificationContent {
    title: String,
    body: String,
    sheet_content: Option<Value>,
}

/// Shared synchronous service for notification inbox queries and mutations.
pub(crate) struct NotificationInboxService;

impl NotificationInboxService {
    pub(crate) fn list(
        conn: &PooledConnection,
        limit: u64,
    ) -> Result<NotificationListResult, CapabilityError> {
        let mut stmt = conn
            .prepare(
                "SELECT
                    e.id,
                    e.session_id,
                    e.invocation_id,
                    e.timestamp,
                    e.payload,
                    s.title AS session_title,
                    s.source,
                    s.spawning_session_id,
                    nrs.read_at
                 FROM events e
                 JOIN sessions s ON s.id = e.session_id
                 LEFT JOIN notification_read_state nrs ON nrs.event_id = e.id
                 WHERE e.type = 'capability.invocation.completed'
                   AND json_valid(e.payload)
                   AND json_extract(e.payload, '$.contractId') = 'notifications::send'
                 ORDER BY e.timestamp DESC
                 LIMIT ?1",
            )
            .map_err(|e| CapabilityError::Internal {
                message: format!("Failed to prepare notification query: {e}"),
            })?;

        let rows = stmt
            .query_map([limit], |row| {
                Ok(NotificationRow {
                    event_id: row.get(0)?,
                    session_id: row.get(1)?,
                    invocation_id: row.get(2)?,
                    timestamp: row.get(3)?,
                    payload: row.get(4)?,
                    session_title: row.get(5)?,
                    source: row.get(6)?,
                    spawning_session_id: row.get(7)?,
                    read_at: row.get(8)?,
                })
            })
            .map_err(|e| CapabilityError::Internal {
                message: format!("Failed to query notifications: {e}"),
            })?;

        let mut notifications = Vec::new();
        let mut unread_count = 0u64;

        for row in rows {
            let row = row.map_err(|e| CapabilityError::Internal {
                message: format!("Failed to read notification row: {e}"),
            })?;

            let Some(content) = parse_notification_content(&row.event_id, &row.payload) else {
                continue;
            };

            let is_read = row.read_at.is_some();
            if !is_read {
                unread_count += 1;
            }

            notifications.push(NotificationInboxEntry {
                event_id: row.event_id,
                session_id: row.session_id,
                invocation_id: row.invocation_id,
                timestamp: row.timestamp,
                title: content.title,
                body: content.body,
                sheet_content: content.sheet_content,
                is_read,
                read_at: row.read_at,
                session_title: row.session_title,
                is_user_session: row.source.is_none() && row.spawning_session_id.is_none(),
            });
        }

        Ok(NotificationListResult {
            notifications,
            unread_count,
        })
    }

    pub(crate) fn mark_read(
        conn: &Connection,
        event_id: &str,
    ) -> Result<MarkReadResult, CapabilityError> {
        let _ = conn
            .execute(
                "INSERT OR IGNORE INTO notification_read_state (event_id, read_at) VALUES (?1, datetime('now'))",
                [event_id],
            )
            .map_err(|e| CapabilityError::Internal {
                message: format!("Failed to mark notification as read: {e}"),
            })?;

        Ok(MarkReadResult { success: true })
    }

    /// Mark unread notifications as read. When `session_id` is provided,
    /// scope the operation to that session so opening one session from
    /// the sidebar doesn't silently clear unread badges for others.
    /// A `None` sessionId marks all sessions' notifications read.
    pub(crate) fn mark_all_read(
        conn: &Connection,
        session_id: Option<&str>,
    ) -> Result<MarkAllReadResult, CapabilityError> {
        let marked = if let Some(sid) = session_id {
            conn.execute(
                "INSERT OR IGNORE INTO notification_read_state (event_id, read_at)
                 SELECT e.id, datetime('now')
                 FROM events e
                 WHERE e.type = 'capability.invocation.completed'
                   AND json_valid(e.payload)
                   AND json_extract(e.payload, '$.contractId') = 'notifications::send'
                   AND e.session_id = ?1
                   AND e.id NOT IN (SELECT event_id FROM notification_read_state)",
                params![sid],
            )
        } else {
            conn.execute(
                "INSERT OR IGNORE INTO notification_read_state (event_id, read_at)
                 SELECT e.id, datetime('now')
                 FROM events e
                 WHERE e.type = 'capability.invocation.completed'
                   AND json_valid(e.payload)
                   AND json_extract(e.payload, '$.contractId') = 'notifications::send'
                   AND e.id NOT IN (SELECT event_id FROM notification_read_state)",
                params![],
            )
        }
        .map_err(|e| CapabilityError::Internal {
            message: format!("Failed to mark all notifications as read: {e}"),
        })?;

        Ok(MarkAllReadResult { marked })
    }
}

fn parse_notification_content(event_id: &str, payload_str: &str) -> Option<NotificationContent> {
    let payload: Value = match serde_json::from_str(payload_str) {
        Ok(value) => value,
        Err(error) => {
            warn!(
                event_id,
                "skipping notification with malformed payload: {error}"
            );
            return None;
        }
    };

    let candidates = [
        payload.get("arguments"),
        payload.pointer("/details/output"),
        payload.get("output"),
        Some(&payload),
    ];
    let Some(arguments) = candidates.into_iter().flatten().find(|candidate| {
        candidate
            .get("title")
            .and_then(Value::as_str)
            .is_some_and(|title| !title.is_empty())
            || candidate
                .get("body")
                .and_then(Value::as_str)
                .is_some_and(|body| !body.is_empty())
    }) else {
        debug!(
            event_id,
            contract_id = payload
                .get("contractId")
                .and_then(|value| value.as_str())
                .unwrap_or(""),
            invocation_id = payload
                .get("invocationId")
                .and_then(|value| value.as_str())
                .unwrap_or(""),
            "skipping notification inbox row without displayable title/body"
        );
        return None;
    };
    let title = arguments
        .get("title")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let body = arguments
        .get("body")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    Some(NotificationContent {
        title,
        body,
        sheet_content: arguments.get("sheetContent").cloned(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shared::server::test_support::make_test_context;
    use serde_json::json;

    fn setup_test_data(conn: &Connection) {
        assert_eq!(
            conn.execute(
                "INSERT INTO workspaces (id, path, created_at, last_activity_at)
                 VALUES ('ws_1', '/tmp', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
                [],
            )
            .unwrap(),
            1
        );

        assert_eq!(
            conn.execute(
                "INSERT INTO sessions (id, workspace_id, title, latest_model, working_directory, created_at, last_activity_at)
                 VALUES ('sess_user', 'ws_1', 'My Session', 'claude-3', '/tmp', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z')",
                [],
            )
            .unwrap(),
            1
        );

        assert_eq!(
            conn.execute(
                "INSERT INTO sessions (id, workspace_id, title, latest_model, working_directory, created_at, last_activity_at, source)
                 VALUES ('sess_cron', 'ws_1', 'Cron: daily report', 'claude-3', '/tmp', '2025-01-01T00:00:00Z', '2025-01-01T00:00:00Z', 'cron')",
                [],
            )
            .unwrap(),
            1
        );
    }

    fn insert_notify_event(
        conn: &Connection,
        event_id: &str,
        session_id: &str,
        invocation_id: &str,
        timestamp: &str,
        payload: &Value,
    ) {
        // Per-session sequence derived from the caller-provided event_id —
        // just use the current count of events for the session so the
        // UNIQUE(session_id, sequence) constraint isn't hit when tests
        // insert multiple events for the same session.
        let seq: i64 = conn
            .query_row(
                "SELECT COALESCE(MAX(sequence), 0) + 1 FROM events WHERE session_id = ?1",
                [session_id],
                |row| row.get(0),
            )
            .unwrap_or(1);

        let payload = serde_json::to_string(payload).unwrap();
        assert_eq!(
            conn.execute(
                "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id, model_primitive_name, invocation_id)
                 VALUES (?1, ?2, ?3, 'capability.invocation.completed', ?4, ?5, 'ws_1', 'execute', ?6)",
                rusqlite::params![event_id, session_id, seq, timestamp, payload.as_str(), invocation_id],
            )
            .unwrap(),
            1
        );
    }

    fn notification_payload(title: &str, body: &str) -> Value {
        json!({
            "invocationId": "call_1",
            "modelPrimitiveName": "execute",
            "contractId": "notifications::send",
            "implementationId": "first_party.notifications.v1.send",
            "functionId": "notifications::send",
            "pluginId": "first_party.notifications",
            "workerId": "notifications",
            "isError": false,
            "duration": 3,
            "content": "{}",
            "details": {
                "output": {
                    "title": title,
                    "body": body,
                    "priority": "normal",
                    "success": true,
                    "successCount": 1,
                    "totalCount": 1
                }
            }
        })
    }

    #[test]
    fn list_skips_malformed_payloads_without_inflating_unread_count() {
        let ctx = make_test_context();
        let conn = ctx.event_store.pool().get().unwrap();
        setup_test_data(&conn);

        assert_eq!(
            conn.execute(
                "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id, model_primitive_name, invocation_id)
                 VALUES ('evt_bad', 'sess_user', 1, 'capability.invocation.completed', '2025-01-01T01:00:00Z', 'not-json', 'ws_1', 'execute', 'tc_bad')",
                [],
            )
            .unwrap(),
            1
        );

        insert_notify_event(
            &conn,
            "evt_good",
            "sess_cron",
            "tc_good",
            "2025-01-02T01:00:00Z",
            &notification_payload("Good", "ok"),
        );

        let result = NotificationInboxService::list(&conn, 50).unwrap();
        assert_eq!(result.notifications.len(), 1);
        assert_eq!(result.notifications[0].title, "Good");
        assert_eq!(result.unread_count, 1);
    }

    #[test]
    fn mark_read_is_idempotent() {
        let ctx = make_test_context();
        let conn = ctx.event_store.pool().get().unwrap();
        setup_test_data(&conn);
        insert_notify_event(
            &conn,
            "evt_1",
            "sess_user",
            "tc_1",
            "2025-01-01T01:00:00Z",
            &notification_payload("t", "b"),
        );

        let first = NotificationInboxService::mark_read(&conn, "evt_1").unwrap();
        let second = NotificationInboxService::mark_read(&conn, "evt_1").unwrap();

        assert!(first.success);
        assert!(second.success);
        let count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM notification_read_state WHERE event_id = 'evt_1'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(count, 1);
    }

    #[test]
    fn list_uses_request_arguments_when_result_summary_omits_title_body() {
        let ctx = make_test_context();
        let conn = ctx.event_store.pool().get().unwrap();
        setup_test_data(&conn);
        let payload = json!({
            "invocationId": "call_1",
            "modelPrimitiveName": "execute",
            "contractId": "notifications::send",
            "implementationId": "first_party.notifications.v1.send",
            "functionId": "notifications::send",
            "pluginId": "first_party.notifications",
            "workerId": "notifications",
            "isError": false,
            "duration": 3,
            "content": "Sent",
            "arguments": {
                "title": "From arguments",
                "body": "Rendered from the original request"
            },
            "details": {
                "output": {
                    "success": true,
                    "successCount": 1,
                    "totalCount": 1
                }
            }
        });
        insert_notify_event(
            &conn,
            "evt_args",
            "sess_user",
            "tc_args",
            "2025-01-01T01:00:00Z",
            &payload,
        );

        let result = NotificationInboxService::list(&conn, 50).unwrap();

        assert_eq!(result.notifications.len(), 1);
        assert_eq!(result.notifications[0].title, "From arguments");
        assert_eq!(
            result.notifications[0].body,
            "Rendered from the original request"
        );
    }

    #[test]
    fn mark_all_read_only_counts_new_rows() {
        let ctx = make_test_context();
        let conn = ctx.event_store.pool().get().unwrap();
        setup_test_data(&conn);
        insert_notify_event(
            &conn,
            "evt_1",
            "sess_user",
            "tc_1",
            "2025-01-01T01:00:00Z",
            &notification_payload("First", "b"),
        );
        insert_notify_event(
            &conn,
            "evt_2",
            "sess_cron",
            "tc_2",
            "2025-01-02T01:00:00Z",
            &notification_payload("Second", "b"),
        );
        let _ = NotificationInboxService::mark_read(&conn, "evt_1").unwrap();

        let result = NotificationInboxService::mark_all_read(&conn, None).unwrap();
        assert_eq!(result.marked, 1);
    }

    #[test]
    fn mark_all_read_scoped_to_session_only_marks_that_session() {
        let ctx = make_test_context();
        let conn = ctx.event_store.pool().get().unwrap();
        setup_test_data(&conn);
        insert_notify_event(
            &conn,
            "evt_user_1",
            "sess_user",
            "tc_1",
            "2025-01-01T01:00:00Z",
            &notification_payload("User 1", "b"),
        );
        insert_notify_event(
            &conn,
            "evt_user_2",
            "sess_user",
            "tc_2",
            "2025-01-01T01:01:00Z",
            &notification_payload("User 2", "b"),
        );
        insert_notify_event(
            &conn,
            "evt_cron",
            "sess_cron",
            "tc_3",
            "2025-01-01T01:02:00Z",
            &notification_payload("Cron 1", "b"),
        );

        let result = NotificationInboxService::mark_all_read(&conn, Some("sess_user")).unwrap();
        assert_eq!(result.marked, 2, "only sess_user's two events marked");

        // Verify sess_cron's event is still unread.
        let cron_read: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM notification_read_state WHERE event_id = 'evt_cron'",
                [],
                |row| row.get(0),
            )
            .unwrap();
        assert_eq!(
            cron_read, 0,
            "cross-session notifications must not be marked"
        );
    }

    #[test]
    fn mark_all_read_unscoped_marks_every_session() {
        let ctx = make_test_context();
        let conn = ctx.event_store.pool().get().unwrap();
        setup_test_data(&conn);
        insert_notify_event(
            &conn,
            "evt_a",
            "sess_user",
            "tc_a",
            "2025-01-01T01:00:00Z",
            &notification_payload("A", "b"),
        );
        insert_notify_event(
            &conn,
            "evt_b",
            "sess_cron",
            "tc_b",
            "2025-01-01T01:01:00Z",
            &notification_payload("B", "b"),
        );

        let result = NotificationInboxService::mark_all_read(&conn, None).unwrap();
        assert_eq!(result.marked, 2);
    }
}
