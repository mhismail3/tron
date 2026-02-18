//! Session repository — session lifecycle and aggregate counters.
//!
//! Sessions are pointers into the event tree with denormalized counters
//! (event count, token usage, cost) for efficient queries.

use rusqlite::{Connection, OptionalExtension, params};
use uuid::Uuid;

use crate::errors::Result;
use crate::sqlite::row_types::SessionRow;

/// Options for creating a new session.
pub struct CreateSessionOptions<'a> {
    /// Workspace this session belongs to.
    pub workspace_id: &'a str,
    /// LLM model ID.
    pub model: &'a str,
    /// Working directory path.
    pub working_directory: &'a str,
    /// Optional title.
    pub title: Option<&'a str>,
    /// Optional tags.
    pub tags: Option<&'a [String]>,
    /// Parent session (for forks).
    pub parent_session_id: Option<&'a str>,
    /// Fork point event.
    pub fork_from_event_id: Option<&'a str>,
    /// Spawning session (for subagents).
    pub spawning_session_id: Option<&'a str>,
    /// Spawn type.
    pub spawn_type: Option<&'a str>,
    /// Spawn task description.
    pub spawn_task: Option<&'a str>,
}

/// Options for listing sessions.
#[derive(Default)]
pub struct ListSessionsOptions<'a> {
    /// Filter by workspace.
    pub workspace_id: Option<&'a str>,
    /// Filter by ended state.
    pub ended: Option<bool>,
    /// Exclude subagent sessions.
    pub exclude_subagents: Option<bool>,
    /// Maximum results.
    pub limit: Option<i64>,
    /// Skip results.
    pub offset: Option<i64>,
}

/// Counters to increment atomically.
#[derive(Default)]
pub struct IncrementCounters {
    /// Number of events to add.
    pub event_count: Option<i64>,
    /// Number of messages to add.
    pub message_count: Option<i64>,
    /// Number of turns to add.
    pub turn_count: Option<i64>,
    /// Input tokens to add.
    pub input_tokens: Option<i64>,
    /// Output tokens to add.
    pub output_tokens: Option<i64>,
    /// Set (not increment) last turn input tokens.
    pub last_turn_input_tokens: Option<i64>,
    /// Cost to add.
    pub cost: Option<f64>,
    /// Cache read tokens to add.
    pub cache_read_tokens: Option<i64>,
    /// Cache creation tokens to add.
    pub cache_creation_tokens: Option<i64>,
}

/// Message preview for session list display.
#[derive(Clone, Debug, Default)]
pub struct MessagePreview {
    /// Last user prompt text.
    pub last_user_prompt: Option<String>,
    /// Last assistant response text.
    pub last_assistant_response: Option<String>,
}

/// Extract text from a message event payload JSON string.
///
/// Handles both string content (`"content": "hello"`) and array content
/// (`"content": [{"type": "text", "text": "hello"}]`).
fn extract_text_from_payload(payload_str: &str) -> String {
    let Ok(payload) = serde_json::from_str::<serde_json::Value>(payload_str) else {
        return String::new();
    };
    match payload.get("content") {
        Some(serde_json::Value::String(s)) => s.clone(),
        Some(serde_json::Value::Array(arr)) => {
            let mut texts = Vec::new();
            for block in arr {
                if block.get("type").and_then(|t| t.as_str()) == Some("text") {
                    if let Some(text) = block.get("text").and_then(|t| t.as_str()) {
                        texts.push(text);
                    }
                }
            }
            texts.join("")
        }
        _ => String::new(),
    }
}

/// Session repository — stateless, every method takes `&Connection`.
pub struct SessionRepo;

impl SessionRepo {
    /// Create a new session.
    pub fn create(conn: &Connection, opts: &CreateSessionOptions<'_>) -> Result<SessionRow> {
        let id = format!("sess_{}", Uuid::now_v7());
        let now = chrono::Utc::now().to_rfc3339();
        let tags_json = opts.tags.map_or_else(
            || "[]".to_string(),
            |t| serde_json::to_string(t).unwrap_or_else(|_| "[]".to_string()),
        );

        let _ = conn.execute(
            "INSERT INTO sessions (id, workspace_id, title, latest_model, working_directory,
             parent_session_id, fork_from_event_id, created_at, last_activity_at, tags,
             spawning_session_id, spawn_type, spawn_task)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
            params![
                id,
                opts.workspace_id,
                opts.title,
                opts.model,
                opts.working_directory,
                opts.parent_session_id,
                opts.fork_from_event_id,
                now,
                now,
                tags_json,
                opts.spawning_session_id,
                opts.spawn_type,
                opts.spawn_task,
            ],
        )?;

        Ok(SessionRow {
            id,
            workspace_id: opts.workspace_id.to_string(),
            head_event_id: None,
            root_event_id: None,
            title: opts.title.map(String::from),
            latest_model: opts.model.to_string(),
            working_directory: opts.working_directory.to_string(),
            parent_session_id: opts.parent_session_id.map(String::from),
            fork_from_event_id: opts.fork_from_event_id.map(String::from),
            created_at: now.clone(),
            last_activity_at: now,
            ended_at: None,
            event_count: 0,
            message_count: 0,
            turn_count: 0,
            total_input_tokens: 0,
            total_output_tokens: 0,
            last_turn_input_tokens: 0,
            total_cost: 0.0,
            total_cache_read_tokens: 0,
            total_cache_creation_tokens: 0,
            tags: tags_json,
            spawning_session_id: opts.spawning_session_id.map(String::from),
            spawn_type: opts.spawn_type.map(String::from),
            spawn_task: opts.spawn_task.map(String::from),
        })
    }

    /// Get session by ID.
    pub fn get_by_id(conn: &Connection, session_id: &str) -> Result<Option<SessionRow>> {
        let row = conn
            .query_row(
                "SELECT * FROM sessions WHERE id = ?1",
                params![session_id],
                Self::map_row,
            )
            .optional()?;
        Ok(row)
    }

    /// List sessions with filtering.
    pub fn list(conn: &Connection, opts: &ListSessionsOptions<'_>) -> Result<Vec<SessionRow>> {
        use std::fmt::Write;
        let mut sql = String::from("SELECT * FROM sessions WHERE 1=1");
        let mut param_values: Vec<Box<dyn rusqlite::types::ToSql>> = Vec::new();

        if let Some(ws_id) = opts.workspace_id {
            let _ = write!(sql, " AND workspace_id = ?{}", param_values.len() + 1);
            param_values.push(Box::new(ws_id.to_string()));
        }
        if let Some(ended) = opts.ended {
            if ended {
                sql.push_str(" AND ended_at IS NOT NULL");
            } else {
                sql.push_str(" AND ended_at IS NULL");
            }
        }
        if opts.exclude_subagents == Some(true) {
            sql.push_str(" AND spawning_session_id IS NULL");
        }
        sql.push_str(" ORDER BY last_activity_at DESC");
        if let Some(limit) = opts.limit {
            let _ = write!(sql, " LIMIT {limit}");
        }
        if let Some(offset) = opts.offset {
            let _ = write!(sql, " OFFSET {offset}");
        }

        let mut stmt = conn.prepare(&sql)?;
        let params_refs: Vec<&dyn rusqlite::types::ToSql> =
            param_values.iter().map(Box::as_ref).collect();
        let rows = stmt
            .query_map(params_refs.as_slice(), Self::map_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Update head event ID and last activity.
    pub fn update_head(conn: &Connection, session_id: &str, head_event_id: &str) -> Result<bool> {
        let now = chrono::Utc::now().to_rfc3339();
        let changed = conn.execute(
            "UPDATE sessions SET head_event_id = ?1, last_activity_at = ?2 WHERE id = ?3",
            params![head_event_id, now, session_id],
        )?;
        Ok(changed > 0)
    }

    /// Update root event ID.
    pub fn update_root(conn: &Connection, session_id: &str, root_event_id: &str) -> Result<bool> {
        let changed = conn.execute(
            "UPDATE sessions SET root_event_id = ?1 WHERE id = ?2",
            params![root_event_id, session_id],
        )?;
        Ok(changed > 0)
    }

    /// Mark session as ended.
    pub fn mark_ended(conn: &Connection, session_id: &str) -> Result<bool> {
        let now = chrono::Utc::now().to_rfc3339();
        let changed = conn.execute(
            "UPDATE sessions SET ended_at = ?1, last_activity_at = ?2 WHERE id = ?3",
            params![now, now, session_id],
        )?;
        Ok(changed > 0)
    }

    /// Clear ended status (reactivate session).
    pub fn clear_ended(conn: &Connection, session_id: &str) -> Result<bool> {
        let now = chrono::Utc::now().to_rfc3339();
        let changed = conn.execute(
            "UPDATE sessions SET ended_at = NULL, last_activity_at = ?1 WHERE id = ?2",
            params![now, session_id],
        )?;
        Ok(changed > 0)
    }

    /// Update the latest model used.
    pub fn update_latest_model(conn: &Connection, session_id: &str, model: &str) -> Result<bool> {
        let now = chrono::Utc::now().to_rfc3339();
        let changed = conn.execute(
            "UPDATE sessions SET latest_model = ?1, last_activity_at = ?2 WHERE id = ?3",
            params![model, now, session_id],
        )?;
        Ok(changed > 0)
    }

    /// Update session title.
    pub fn update_title(conn: &Connection, session_id: &str, title: Option<&str>) -> Result<bool> {
        let changed = conn.execute(
            "UPDATE sessions SET title = ?1 WHERE id = ?2",
            params![title, session_id],
        )?;
        Ok(changed > 0)
    }

    /// Increment denormalized counters atomically.
    pub fn increment_counters(
        conn: &Connection,
        session_id: &str,
        counters: &IncrementCounters,
    ) -> Result<bool> {
        let mut updates = Vec::new();

        if let Some(v) = counters.event_count {
            updates.push(format!("event_count = event_count + {v}"));
        }
        if let Some(v) = counters.message_count {
            updates.push(format!("message_count = message_count + {v}"));
        }
        if let Some(v) = counters.turn_count {
            updates.push(format!("turn_count = turn_count + {v}"));
        }
        if let Some(v) = counters.input_tokens {
            updates.push(format!("total_input_tokens = total_input_tokens + {v}"));
        }
        if let Some(v) = counters.output_tokens {
            updates.push(format!("total_output_tokens = total_output_tokens + {v}"));
        }
        if let Some(v) = counters.last_turn_input_tokens {
            updates.push(format!("last_turn_input_tokens = {v}"));
        }
        if let Some(v) = counters.cost {
            updates.push(format!("total_cost = total_cost + {v}"));
        }
        if let Some(v) = counters.cache_read_tokens {
            updates.push(format!(
                "total_cache_read_tokens = total_cache_read_tokens + {v}"
            ));
        }
        if let Some(v) = counters.cache_creation_tokens {
            updates.push(format!(
                "total_cache_creation_tokens = total_cache_creation_tokens + {v}"
            ));
        }

        if updates.is_empty() {
            return Ok(false);
        }

        let now = chrono::Utc::now().to_rfc3339();
        updates.push(format!("last_activity_at = '{now}'"));

        let sql = format!("UPDATE sessions SET {} WHERE id = ?1", updates.join(", "));
        let changed = conn.execute(&sql, params![session_id])?;
        Ok(changed > 0)
    }

    /// Check if session exists.
    pub fn exists(conn: &Connection, session_id: &str) -> Result<bool> {
        let exists: bool = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM sessions WHERE id = ?1)",
            params![session_id],
            |row| row.get(0),
        )?;
        Ok(exists)
    }

    /// Delete a session.
    pub fn delete(conn: &Connection, session_id: &str) -> Result<bool> {
        let changed = conn.execute("DELETE FROM sessions WHERE id = ?1", params![session_id])?;
        Ok(changed > 0)
    }

    /// Batch-fetch sessions by IDs.
    ///
    /// Returns a map of `session_id → SessionRow`. Missing IDs are silently omitted.
    /// Uses dynamic `IN (?)` placeholders — safe for reasonable batch sizes (<1000).
    pub fn get_by_ids(
        conn: &Connection,
        session_ids: &[&str],
    ) -> Result<std::collections::HashMap<String, SessionRow>> {
        let mut result = std::collections::HashMap::new();
        if session_ids.is_empty() {
            return Ok(result);
        }

        let placeholders: Vec<String> = (1..=session_ids.len()).map(|i| format!("?{i}")).collect();
        let sql = format!(
            "SELECT * FROM sessions WHERE id IN ({})",
            placeholders.join(", ")
        );

        let mut stmt = conn.prepare(&sql)?;
        let params: Vec<&dyn rusqlite::types::ToSql> = session_ids
            .iter()
            .map(|s| s as &dyn rusqlite::types::ToSql)
            .collect();
        let rows = stmt
            .query_map(params.as_slice(), Self::map_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;

        for row in rows {
            let _ = result.insert(row.id.clone(), row);
        }
        Ok(result)
    }

    /// Get message previews (last user prompt and assistant response) for a list of sessions.
    ///
    /// Uses a window function to find the most recent message of each type per session.
    /// Returns a map of `session_id → MessagePreview`.
    pub fn get_message_previews(
        conn: &Connection,
        session_ids: &[&str],
    ) -> Result<std::collections::HashMap<String, MessagePreview>> {
        let mut result = std::collections::HashMap::new();
        if session_ids.is_empty() {
            return Ok(result);
        }

        // Initialize all sessions with empty previews
        for &sid in session_ids {
            let _ = result.insert(sid.to_string(), MessagePreview::default());
        }

        let placeholders: Vec<String> = (1..=session_ids.len()).map(|i| format!("?{i}")).collect();
        let sql = format!(
            "WITH ranked AS (
               SELECT
                 session_id,
                 type,
                 payload,
                 ROW_NUMBER() OVER (PARTITION BY session_id, type ORDER BY sequence DESC) as rn
               FROM events
               WHERE session_id IN ({})
                 AND type IN ('message.user', 'message.assistant')
             )
             SELECT session_id, type, payload
             FROM ranked
             WHERE rn = 1",
            placeholders.join(", ")
        );

        let mut stmt = conn.prepare(&sql)?;
        let params: Vec<&dyn rusqlite::types::ToSql> = session_ids
            .iter()
            .map(|s| s as &dyn rusqlite::types::ToSql)
            .collect();
        let rows = stmt
            .query_map(params.as_slice(), |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                ))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;

        for (session_id, event_type, payload_str) in rows {
            let text = extract_text_from_payload(&payload_str);
            if let Some(preview) = result.get_mut(&session_id) {
                match event_type.as_str() {
                    "message.user" => preview.last_user_prompt = Some(text),
                    "message.assistant" => preview.last_assistant_response = Some(text),
                    _ => {}
                }
            }
        }

        Ok(result)
    }

    /// List subagent sessions for a parent.
    pub fn list_subagents(conn: &Connection, spawning_session_id: &str) -> Result<Vec<SessionRow>> {
        let mut stmt = conn.prepare(
            "SELECT * FROM sessions WHERE spawning_session_id = ?1 ORDER BY created_at DESC",
        )?;
        let rows = stmt
            .query_map(params![spawning_session_id], Self::map_row)?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    fn map_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<SessionRow> {
        Ok(SessionRow {
            id: row.get("id")?,
            workspace_id: row.get("workspace_id")?,
            head_event_id: row.get("head_event_id")?,
            root_event_id: row.get("root_event_id")?,
            title: row.get("title")?,
            latest_model: row.get("latest_model")?,
            working_directory: row.get("working_directory")?,
            parent_session_id: row.get("parent_session_id")?,
            fork_from_event_id: row.get("fork_from_event_id")?,
            created_at: row.get("created_at")?,
            last_activity_at: row.get("last_activity_at")?,
            ended_at: row.get("ended_at")?,
            event_count: row.get("event_count")?,
            message_count: row.get("message_count")?,
            turn_count: row.get("turn_count")?,
            total_input_tokens: row.get("total_input_tokens")?,
            total_output_tokens: row.get("total_output_tokens")?,
            last_turn_input_tokens: row.get("last_turn_input_tokens")?,
            total_cost: row.get("total_cost")?,
            total_cache_read_tokens: row.get("total_cache_read_tokens")?,
            total_cache_creation_tokens: row.get("total_cache_creation_tokens")?,
            tags: row.get("tags")?,
            spawning_session_id: row.get("spawning_session_id")?,
            spawn_type: row.get("spawn_type")?,
            spawn_task: row.get("spawn_task")?,
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

    fn setup() -> (Connection, String) {
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
        (conn, ws.id)
    }

    fn create_default_session<'a>(conn: &Connection, ws_id: &'a str) -> SessionRow {
        SessionRepo::create(
            conn,
            &CreateSessionOptions {
                workspace_id: ws_id,
                model: "claude-opus-4-6",
                working_directory: "/tmp/test",
                title: Some("Test Session"),
                tags: None,
                parent_session_id: None,
                fork_from_event_id: None,
                spawning_session_id: None,
                spawn_type: None,
                spawn_task: None,
            },
        )
        .unwrap()
    }

    #[test]
    fn create_session() {
        let (conn, ws_id) = setup();
        let sess = create_default_session(&conn, &ws_id);

        assert!(sess.id.starts_with("sess_"));
        assert_eq!(sess.workspace_id, ws_id);
        assert_eq!(sess.latest_model, "claude-opus-4-6");
        assert_eq!(sess.title.as_deref(), Some("Test Session"));
        assert_eq!(sess.event_count, 0);
        assert!(sess.ended_at.is_none());
    }

    #[test]
    fn get_by_id() {
        let (conn, ws_id) = setup();
        let sess = create_default_session(&conn, &ws_id);

        let found = SessionRepo::get_by_id(&conn, &sess.id).unwrap().unwrap();
        assert_eq!(found.id, sess.id);
        assert_eq!(found.latest_model, "claude-opus-4-6");
    }

    #[test]
    fn get_by_id_not_found() {
        let (conn, _) = setup();
        let found = SessionRepo::get_by_id(&conn, "sess_nonexistent").unwrap();
        assert!(found.is_none());
    }

    #[test]
    fn list_sessions() {
        let (conn, ws_id) = setup();
        create_default_session(&conn, &ws_id);
        create_default_session(&conn, &ws_id);

        let sessions = SessionRepo::list(&conn, &ListSessionsOptions::default()).unwrap();
        assert_eq!(sessions.len(), 2);
    }

    #[test]
    fn list_by_workspace() {
        let (conn, ws_id) = setup();
        create_default_session(&conn, &ws_id);

        let ws2 = WorkspaceRepo::create(
            &conn,
            &CreateWorkspaceOptions {
                path: "/tmp/other",
                name: None,
            },
        )
        .unwrap();
        SessionRepo::create(
            &conn,
            &CreateSessionOptions {
                workspace_id: &ws2.id,
                model: "claude-3",
                working_directory: "/tmp/other",
                title: None,
                tags: None,
                parent_session_id: None,
                fork_from_event_id: None,
                spawning_session_id: None,
                spawn_type: None,
                spawn_task: None,
            },
        )
        .unwrap();

        let sessions = SessionRepo::list(
            &conn,
            &ListSessionsOptions {
                workspace_id: Some(&ws_id),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(sessions.len(), 1);
    }

    #[test]
    fn list_ended_filter() {
        let (conn, ws_id) = setup();
        let s1 = create_default_session(&conn, &ws_id);
        create_default_session(&conn, &ws_id);

        SessionRepo::mark_ended(&conn, &s1.id).unwrap();

        let active = SessionRepo::list(
            &conn,
            &ListSessionsOptions {
                ended: Some(false),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(active.len(), 1);

        let ended = SessionRepo::list(
            &conn,
            &ListSessionsOptions {
                ended: Some(true),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(ended.len(), 1);
    }

    #[test]
    fn update_head_and_root() {
        let (conn, ws_id) = setup();
        let sess = create_default_session(&conn, &ws_id);

        SessionRepo::update_head(&conn, &sess.id, "evt_head").unwrap();
        SessionRepo::update_root(&conn, &sess.id, "evt_root").unwrap();

        let found = SessionRepo::get_by_id(&conn, &sess.id).unwrap().unwrap();
        assert_eq!(found.head_event_id.as_deref(), Some("evt_head"));
        assert_eq!(found.root_event_id.as_deref(), Some("evt_root"));
    }

    #[test]
    fn mark_and_clear_ended() {
        let (conn, ws_id) = setup();
        let sess = create_default_session(&conn, &ws_id);

        SessionRepo::mark_ended(&conn, &sess.id).unwrap();
        let found = SessionRepo::get_by_id(&conn, &sess.id).unwrap().unwrap();
        assert!(found.ended_at.is_some());

        SessionRepo::clear_ended(&conn, &sess.id).unwrap();
        let found = SessionRepo::get_by_id(&conn, &sess.id).unwrap().unwrap();
        assert!(found.ended_at.is_none());
    }

    #[test]
    fn update_latest_model() {
        let (conn, ws_id) = setup();
        let sess = create_default_session(&conn, &ws_id);

        SessionRepo::update_latest_model(&conn, &sess.id, "claude-sonnet-4-5-20250929").unwrap();
        let found = SessionRepo::get_by_id(&conn, &sess.id).unwrap().unwrap();
        assert_eq!(found.latest_model, "claude-sonnet-4-5-20250929");
    }

    #[test]
    fn update_title() {
        let (conn, ws_id) = setup();
        let sess = create_default_session(&conn, &ws_id);

        SessionRepo::update_title(&conn, &sess.id, Some("New Title")).unwrap();
        let found = SessionRepo::get_by_id(&conn, &sess.id).unwrap().unwrap();
        assert_eq!(found.title.as_deref(), Some("New Title"));

        SessionRepo::update_title(&conn, &sess.id, None).unwrap();
        let found = SessionRepo::get_by_id(&conn, &sess.id).unwrap().unwrap();
        assert!(found.title.is_none());
    }

    #[test]
    fn increment_counters() {
        let (conn, ws_id) = setup();
        let sess = create_default_session(&conn, &ws_id);

        SessionRepo::increment_counters(
            &conn,
            &sess.id,
            &IncrementCounters {
                event_count: Some(5),
                message_count: Some(2),
                turn_count: Some(1),
                input_tokens: Some(1000),
                output_tokens: Some(500),
                cost: Some(0.05),
                cache_read_tokens: Some(200),
                ..Default::default()
            },
        )
        .unwrap();

        let found = SessionRepo::get_by_id(&conn, &sess.id).unwrap().unwrap();
        assert_eq!(found.event_count, 5);
        assert_eq!(found.message_count, 2);
        assert_eq!(found.turn_count, 1);
        assert_eq!(found.total_input_tokens, 1000);
        assert_eq!(found.total_output_tokens, 500);
        assert!((found.total_cost - 0.05).abs() < f64::EPSILON);
        assert_eq!(found.total_cache_read_tokens, 200);
    }

    #[test]
    fn increment_counters_accumulates() {
        let (conn, ws_id) = setup();
        let sess = create_default_session(&conn, &ws_id);

        SessionRepo::increment_counters(
            &conn,
            &sess.id,
            &IncrementCounters {
                event_count: Some(3),
                ..Default::default()
            },
        )
        .unwrap();
        SessionRepo::increment_counters(
            &conn,
            &sess.id,
            &IncrementCounters {
                event_count: Some(2),
                ..Default::default()
            },
        )
        .unwrap();

        let found = SessionRepo::get_by_id(&conn, &sess.id).unwrap().unwrap();
        assert_eq!(found.event_count, 5);
    }

    #[test]
    fn last_turn_input_tokens_is_set_not_increment() {
        let (conn, ws_id) = setup();
        let sess = create_default_session(&conn, &ws_id);

        SessionRepo::increment_counters(
            &conn,
            &sess.id,
            &IncrementCounters {
                last_turn_input_tokens: Some(500),
                ..Default::default()
            },
        )
        .unwrap();
        SessionRepo::increment_counters(
            &conn,
            &sess.id,
            &IncrementCounters {
                last_turn_input_tokens: Some(300),
                ..Default::default()
            },
        )
        .unwrap();

        let found = SessionRepo::get_by_id(&conn, &sess.id).unwrap().unwrap();
        assert_eq!(found.last_turn_input_tokens, 300); // SET, not 800
    }

    #[test]
    fn exists_session() {
        let (conn, ws_id) = setup();
        let sess = create_default_session(&conn, &ws_id);

        assert!(SessionRepo::exists(&conn, &sess.id).unwrap());
        assert!(!SessionRepo::exists(&conn, "sess_nonexistent").unwrap());
    }

    #[test]
    fn delete_session() {
        let (conn, ws_id) = setup();
        let sess = create_default_session(&conn, &ws_id);

        assert!(SessionRepo::delete(&conn, &sess.id).unwrap());
        assert!(!SessionRepo::exists(&conn, &sess.id).unwrap());
    }

    #[test]
    fn list_subagents() {
        let (conn, ws_id) = setup();
        let parent = create_default_session(&conn, &ws_id);

        SessionRepo::create(
            &conn,
            &CreateSessionOptions {
                workspace_id: &ws_id,
                model: "claude-3",
                working_directory: "/tmp/test",
                title: None,
                tags: None,
                parent_session_id: None,
                fork_from_event_id: None,
                spawning_session_id: Some(&parent.id),
                spawn_type: Some("query"),
                spawn_task: Some("do something"),
            },
        )
        .unwrap();

        let subagents = SessionRepo::list_subagents(&conn, &parent.id).unwrap();
        assert_eq!(subagents.len(), 1);
        assert_eq!(subagents[0].spawn_type.as_deref(), Some("query"));
    }

    #[test]
    fn exclude_subagents_filter() {
        let (conn, ws_id) = setup();
        let parent = create_default_session(&conn, &ws_id);

        SessionRepo::create(
            &conn,
            &CreateSessionOptions {
                workspace_id: &ws_id,
                model: "claude-3",
                working_directory: "/tmp/test",
                title: None,
                tags: None,
                parent_session_id: None,
                fork_from_event_id: None,
                spawning_session_id: Some(&parent.id),
                spawn_type: Some("query"),
                spawn_task: None,
            },
        )
        .unwrap();

        let all = SessionRepo::list(&conn, &ListSessionsOptions::default()).unwrap();
        assert_eq!(all.len(), 2);

        let no_subagents = SessionRepo::list(
            &conn,
            &ListSessionsOptions {
                exclude_subagents: Some(true),
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(no_subagents.len(), 1);
    }

    // ── Batch operations ─────────────────────────────────────────────

    #[test]
    fn get_by_ids_basic() {
        let (conn, ws_id) = setup();
        let s1 = create_default_session(&conn, &ws_id);
        let s2 = create_default_session(&conn, &ws_id);

        let ids = [s1.id.as_str(), s2.id.as_str()];
        let map = SessionRepo::get_by_ids(&conn, &ids).unwrap();
        assert_eq!(map.len(), 2);
        assert!(map.contains_key(&s1.id));
        assert!(map.contains_key(&s2.id));
    }

    #[test]
    fn get_by_ids_empty() {
        let (conn, _) = setup();
        let map = SessionRepo::get_by_ids(&conn, &[]).unwrap();
        assert!(map.is_empty());
    }

    #[test]
    fn get_by_ids_missing_ids_omitted() {
        let (conn, ws_id) = setup();
        let s1 = create_default_session(&conn, &ws_id);

        let ids = [s1.id.as_str(), "sess_nonexistent"];
        let map = SessionRepo::get_by_ids(&conn, &ids).unwrap();
        assert_eq!(map.len(), 1);
        assert!(map.contains_key(&s1.id));
    }

    // ── Message previews ─────────────────────────────────────────────

    fn insert_event(
        conn: &Connection,
        session_id: &str,
        ws_id: &str,
        seq: i64,
        event_type: &str,
        payload: &str,
    ) {
        conn.execute(
            "INSERT INTO events (id, session_id, sequence, type, timestamp, payload, workspace_id)
             VALUES (?1, ?2, ?3, ?4, datetime('now'), ?5, ?6)",
            rusqlite::params![
                format!("evt_{seq}_{session_id}"),
                session_id,
                seq,
                event_type,
                payload,
                ws_id,
            ],
        )
        .unwrap();
    }

    #[test]
    fn get_message_previews_basic() {
        let (conn, ws_id) = setup();
        let s1 = create_default_session(&conn, &ws_id);

        insert_event(
            &conn,
            &s1.id,
            &ws_id,
            1,
            "message.user",
            r#"{"content": "Hello world"}"#,
        );
        insert_event(
            &conn,
            &s1.id,
            &ws_id,
            2,
            "message.assistant",
            r#"{"content": "Hi there!"}"#,
        );

        let ids = [s1.id.as_str()];
        let previews = SessionRepo::get_message_previews(&conn, &ids).unwrap();
        let preview = previews.get(&s1.id).unwrap();
        assert_eq!(preview.last_user_prompt.as_deref(), Some("Hello world"));
        assert_eq!(
            preview.last_assistant_response.as_deref(),
            Some("Hi there!")
        );
    }

    #[test]
    fn get_message_previews_array_content() {
        let (conn, ws_id) = setup();
        let s1 = create_default_session(&conn, &ws_id);

        insert_event(
            &conn,
            &s1.id,
            &ws_id,
            1,
            "message.user",
            r#"{"content": "Hello"}"#,
        );
        insert_event(
            &conn,
            &s1.id,
            &ws_id,
            2,
            "message.assistant",
            r#"{"content": [{"type": "text", "text": "Part 1"}, {"type": "text", "text": " Part 2"}]}"#,
        );

        let ids = [s1.id.as_str()];
        let previews = SessionRepo::get_message_previews(&conn, &ids).unwrap();
        let preview = previews.get(&s1.id).unwrap();
        assert_eq!(
            preview.last_assistant_response.as_deref(),
            Some("Part 1 Part 2")
        );
    }

    #[test]
    fn get_message_previews_uses_latest() {
        let (conn, ws_id) = setup();
        let s1 = create_default_session(&conn, &ws_id);

        insert_event(
            &conn,
            &s1.id,
            &ws_id,
            1,
            "message.user",
            r#"{"content": "First"}"#,
        );
        insert_event(
            &conn,
            &s1.id,
            &ws_id,
            2,
            "message.user",
            r#"{"content": "Second"}"#,
        );

        let ids = [s1.id.as_str()];
        let previews = SessionRepo::get_message_previews(&conn, &ids).unwrap();
        let preview = previews.get(&s1.id).unwrap();
        assert_eq!(preview.last_user_prompt.as_deref(), Some("Second"));
    }

    #[test]
    fn get_message_previews_empty() {
        let (conn, _) = setup();
        let previews = SessionRepo::get_message_previews(&conn, &[]).unwrap();
        assert!(previews.is_empty());
    }

    #[test]
    fn get_message_previews_no_messages() {
        let (conn, ws_id) = setup();
        let s1 = create_default_session(&conn, &ws_id);

        let ids = [s1.id.as_str()];
        let previews = SessionRepo::get_message_previews(&conn, &ids).unwrap();
        let preview = previews.get(&s1.id).unwrap();
        assert!(preview.last_user_prompt.is_none());
        assert!(preview.last_assistant_response.is_none());
    }

    #[test]
    fn get_message_previews_multiple_sessions() {
        let (conn, ws_id) = setup();
        let s1 = create_default_session(&conn, &ws_id);
        let s2 = create_default_session(&conn, &ws_id);

        insert_event(
            &conn,
            &s1.id,
            &ws_id,
            1,
            "message.user",
            r#"{"content": "S1 user"}"#,
        );
        insert_event(
            &conn,
            &s2.id,
            &ws_id,
            1,
            "message.user",
            r#"{"content": "S2 user"}"#,
        );

        let ids = [s1.id.as_str(), s2.id.as_str()];
        let previews = SessionRepo::get_message_previews(&conn, &ids).unwrap();
        assert_eq!(
            previews.get(&s1.id).unwrap().last_user_prompt.as_deref(),
            Some("S1 user")
        );
        assert_eq!(
            previews.get(&s2.id).unwrap().last_user_prompt.as_deref(),
            Some("S2 user")
        );
    }

    // ── Text extraction helper ───────────────────────────────────────

    #[test]
    fn extract_text_string_content() {
        let text = extract_text_from_payload(r#"{"content": "hello"}"#);
        assert_eq!(text, "hello");
    }

    #[test]
    fn extract_text_array_content() {
        let text = extract_text_from_payload(
            r#"{"content": [{"type": "text", "text": "a"}, {"type": "text", "text": "b"}]}"#,
        );
        assert_eq!(text, "ab");
    }

    #[test]
    fn extract_text_skips_non_text_blocks() {
        let text = extract_text_from_payload(
            r#"{"content": [{"type": "text", "text": "hi"}, {"type": "tool_use", "name": "bash"}]}"#,
        );
        assert_eq!(text, "hi");
    }

    #[test]
    fn extract_text_invalid_json() {
        let text = extract_text_from_payload("not json");
        assert_eq!(text, "");
    }

    #[test]
    fn extract_text_missing_content() {
        let text = extract_text_from_payload(r#"{"other": "field"}"#);
        assert_eq!(text, "");
    }
}
