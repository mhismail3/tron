//! Real `EventStoreQuery` backed by `crate::events::EventStore`.
//!
//! Provides the Remember tool with actual database access for session queries,
//! event lookups, blob retrieval, and schema introspection.
//! Memory recall uses hybrid vector + FTS search via `memory_vectors`.

use std::collections::HashMap;
use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};
use crate::embeddings::{HybridSearchOptions, apply_temporal_decay};
use crate::events::EventStore;
use crate::events::sqlite::repositories::event::ListEventsOptions;
use crate::tools::errors::ToolError;
use crate::core::logging::store::LogStore;
use crate::core::logging::types::{LogLevel, LogQueryOptions, SortOrder};
use crate::tools::traits::{EventStoreQuery, MemoryEntry, SessionInfo};

/// Real event store query backed by `SQLite` via `EventStore`.
pub struct SqliteEventStoreQuery {
    store: Arc<EventStore>,
    embedding_controller: Option<Arc<tokio::sync::Mutex<crate::embeddings::EmbeddingController>>>,
}

impl SqliteEventStoreQuery {
    /// Create a new event store query.
    pub fn new(store: Arc<EventStore>) -> Self {
        Self {
            store,
            embedding_controller: None,
        }
    }

    /// Set the embedding controller for semantic recall.
    #[must_use]
    pub fn with_embedding_controller(
        mut self,
        ec: Arc<tokio::sync::Mutex<crate::embeddings::EmbeddingController>>,
    ) -> Self {
        self.embedding_controller = Some(ec);
        self
    }
}

fn tool_err(msg: impl std::fmt::Display) -> ToolError {
    ToolError::internal(msg)
}

#[async_trait]
impl EventStoreQuery for SqliteEventStoreQuery {
    async fn recall_memory(
        &self,
        query: &str,
        workspace_id: Option<&str>,
        limit: u32,
    ) -> Result<Vec<MemoryEntry>, ToolError> {
        if query.is_empty() {
            return Ok(Vec::new());
        }

        // Hybrid search via memory_vectors (vector + FTS on embeddings table)
        if let Some(ref ec) = self.embedding_controller {
            let ctrl = ec.lock().await;
            if ctrl.is_ready() {
                let half_life_days = ctrl.config().half_life_days;
                let cross_project_top_k = ctrl.config().cross_project_top_k;

                // Local hybrid search (vector + memory_vectors FTS)
                let local_opts = crate::embeddings::SearchOptions {
                    limit: limit as usize * 2,
                    workspace_id: workspace_id.map(String::from),
                    ..Default::default()
                };
                let mut all_results = ctrl
                    .hybrid_search(
                        query,
                        &[], // no external FTS results
                        &HybridSearchOptions {
                            limit: limit as usize,
                            ..Default::default()
                        },
                        &local_opts,
                    )
                    .await
                    .unwrap_or_default();

                // Cross-project search (vector-only, excludes current workspace)
                if let Some(ws) = workspace_id
                    && cross_project_top_k > 0
                {
                    let cross_opts = crate::embeddings::SearchOptions {
                        limit: cross_project_top_k * 2,
                        exclude_workspace_id: Some(ws.to_string()),
                        ..Default::default()
                    };
                    if let Ok(mut cross) = ctrl
                        .hybrid_search(
                            query,
                            &[],
                            &HybridSearchOptions {
                                limit: cross_project_top_k,
                                ..Default::default()
                            },
                            &cross_opts,
                        )
                        .await
                    {
                        all_results.append(&mut cross);
                    }
                }

                if !all_results.is_empty() {
                    // Apply temporal decay
                    let now = chrono::Utc::now();
                    let mut timestamps: HashMap<String, chrono::DateTime<chrono::Utc>> =
                        HashMap::new();
                    for r in &all_results {
                        if let Ok(Some(event)) = self.store.get_event(&r.event_id)
                            && let Ok(ts) = chrono::DateTime::parse_from_rfc3339(&event.timestamp)
                        {
                            let _ = timestamps
                                .insert(r.event_id.clone(), ts.with_timezone(&chrono::Utc));
                        }
                    }
                    apply_temporal_decay(&mut all_results, &timestamps, half_life_days, now);

                    // Convert to MemoryEntry (capped at limit)
                    let entries: Vec<MemoryEntry> = all_results
                        .into_iter()
                        .take(limit as usize)
                        .filter_map(|r| {
                            let event = self.store.get_event(&r.event_id).ok().flatten()?;
                            let payload: Value = serde_json::from_str(&event.payload).ok()?;
                            let title = payload
                                .get("title")
                                .and_then(Value::as_str)
                                .unwrap_or("Untitled");
                            let lessons = payload
                                .get("lessons")
                                .and_then(Value::as_array)
                                .map(|arr| {
                                    arr.iter()
                                        .filter_map(Value::as_str)
                                        .collect::<Vec<_>>()
                                        .join("; ")
                                })
                                .unwrap_or_default();
                            let content = if lessons.is_empty() {
                                title.to_string()
                            } else {
                                format!("{title}: {lessons}")
                            };
                            // Normalize RRF score to 0-100 (max theoretical = 2/60 ≈ 0.033)
                            #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
                            let normalized = ((r.score / 0.034) * 100.0).round().min(100.0) as u32;
                            Some(MemoryEntry {
                                content,
                                session_id: Some(event.session_id),
                                score: Some(normalized),
                                timestamp: Some(event.timestamp),
                            })
                        })
                        .collect();
                    if !entries.is_empty() {
                        return Ok(entries);
                    }
                }
            }
        }

        Ok(Vec::new())
    }

    async fn list_sessions(&self, limit: u32, offset: u32) -> Result<Vec<SessionInfo>, ToolError> {
        let opts = crate::events::sqlite::repositories::session::ListSessionsOptions {
            workspace_id: None,
            ended: None,
            exclude_subagents: Some(true),
            limit: Some(i64::from(limit)),
            offset: Some(i64::from(offset)),
            origin: None,
            user_only: None,
        };
        let rows = self.store.list_sessions(&opts).map_err(tool_err)?;
        Ok(rows
            .into_iter()
            .map(|r| SessionInfo {
                session_id: r.id,
                title: r.title,
                created_at: Some(r.created_at),
                archived: r.ended_at.as_ref().map(|_| true),
                event_count: Some(r.event_count.unsigned_abs()),
            })
            .collect())
    }

    async fn get_session(&self, session_id: &str) -> Result<Option<SessionInfo>, ToolError> {
        let row = self.store.get_session(session_id).map_err(tool_err)?;
        Ok(row.map(|r| SessionInfo {
            session_id: r.id,
            title: r.title,
            created_at: Some(r.created_at),
            archived: r.ended_at.as_ref().map(|_| true),
            event_count: Some(r.event_count.unsigned_abs()),
        }))
    }

    async fn get_events(
        &self,
        session_id: &str,
        event_type: Option<&str>,
        turn: Option<u32>,
        limit: u32,
        _offset: u32,
    ) -> Result<Vec<Value>, ToolError> {
        let rows = if let Some(et) = event_type {
            let types: Vec<&str> = vec![et];
            self.store
                .get_events_by_type(session_id, &types, Some(i64::from(limit)))
                .map_err(tool_err)?
        } else {
            let opts = ListEventsOptions {
                limit: Some(i64::from(limit)),
                offset: None,
            };
            self.store
                .get_events_by_session(session_id, &opts)
                .map_err(tool_err)?
        };

        let filtered: Vec<Value> = rows
            .into_iter()
            .filter(|r| {
                if let Some(t) = turn {
                    r.turn.is_none_or(|rt| rt == i64::from(t))
                } else {
                    true
                }
            })
            .map(|r| {
                json!({
                    "id": r.id,
                    "type": r.event_type,
                    "timestamp": r.timestamp,
                    "turn": r.turn,
                    "toolName": r.tool_name,
                    "sequence": r.sequence,
                })
            })
            .collect();
        Ok(filtered)
    }

    async fn get_messages(&self, session_id: &str, limit: u32) -> Result<Vec<Value>, ToolError> {
        let types: Vec<&str> = vec!["message.user", "message.assistant"];
        let rows = self
            .store
            .get_events_by_type(session_id, &types, Some(i64::from(limit)))
            .map_err(tool_err)?;

        Ok(rows
            .into_iter()
            .map(|r| {
                let payload: Value = serde_json::from_str(&r.payload).unwrap_or_else(|e| {
                    tracing::warn!(event_type = %r.event_type, error = %e, "corrupt event payload");
                    Value::Null
                });
                json!({
                    "type": r.event_type,
                    "turn": r.turn,
                    "timestamp": r.timestamp,
                    "content": payload.get("content").cloned().unwrap_or(Value::Null),
                })
            })
            .collect())
    }

    async fn get_tool_calls(&self, session_id: &str, limit: u32) -> Result<Vec<Value>, ToolError> {
        let types: Vec<&str> = vec!["tool_use_batch"];
        let rows = self
            .store
            .get_events_by_type(session_id, &types, Some(i64::from(limit)))
            .map_err(tool_err)?;

        Ok(rows
            .into_iter()
            .map(|r| {
                let payload: Value = serde_json::from_str(&r.payload).unwrap_or_else(|e| {
                    tracing::warn!(tool_name = ?r.tool_name, error = %e, "corrupt tool payload");
                    Value::Null
                });
                json!({
                    "toolName": r.tool_name,
                    "turn": r.turn,
                    "timestamp": r.timestamp,
                    "arguments": payload.get("arguments").cloned().unwrap_or(Value::Null),
                })
            })
            .collect())
    }

    async fn get_logs(
        &self,
        session_id: &str,
        level: Option<&str>,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<Value>, ToolError> {
        let conn = self.store.pool().get().map_err(tool_err)?;
        let log_store = LogStore::new(&conn);

        let min_level = level.map(|l| LogLevel::from_str_lossy(l).as_num());

        let opts = LogQueryOptions {
            session_id: if session_id.is_empty() {
                None
            } else {
                Some(session_id.to_string())
            },
            min_level,
            limit: Some(limit as usize),
            offset: if offset > 0 {
                Some(offset as usize)
            } else {
                None
            },
            order: Some(SortOrder::Desc),
            ..Default::default()
        };

        let entries = log_store.query(&opts);

        Ok(entries
            .into_iter()
            .map(|e| {
                let mut obj = json!({
                    "timestamp": e.timestamp,
                    "level": e.level.to_string(),
                    "component": e.component,
                    "message": e.message,
                });
                let map = obj.as_object_mut().unwrap();
                if let Some(ref sid) = e.session_id {
                    let _ = map.insert("sessionId".into(), json!(sid));
                }
                if let Some(ref err) = e.error_message {
                    let _ = map.insert("errorMessage".into(), json!(err));
                }
                if let Some(ref data) = e.data {
                    let _ = map.insert("data".into(), data.clone());
                }
                if let Some(turn) = e.turn {
                    let _ = map.insert("turn".into(), json!(turn));
                }
                obj
            })
            .collect())
    }

    async fn get_stats(&self) -> Result<Value, ToolError> {
        let conn = self.store.pool().get().map_err(tool_err)?;
        let session_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM sessions", [], |r| r.get(0))
            .map_err(tool_err)?;
        let event_count: i64 = conn
            .query_row("SELECT COUNT(*) FROM events", [], |r| r.get(0))
            .map_err(tool_err)?;
        let total_tokens: i64 = conn
            .query_row(
                "SELECT COALESCE(SUM(total_input_tokens + total_output_tokens), 0) FROM sessions",
                [],
                |r| r.get(0),
            )
            .map_err(tool_err)?;
        let total_cost: f64 = conn
            .query_row(
                "SELECT COALESCE(SUM(total_cost), 0) FROM sessions",
                [],
                |r| r.get(0),
            )
            .map_err(tool_err)?;

        Ok(json!({
            "sessions": session_count,
            "events": event_count,
            "totalTokens": total_tokens,
            "totalCost": format!("${total_cost:.4}"),
        }))
    }

    async fn get_schema(&self) -> Result<String, ToolError> {
        let conn = self.store.pool().get().map_err(tool_err)?;
        let mut stmt = conn
            .prepare("SELECT sql FROM sqlite_master WHERE type='table' ORDER BY name")
            .map_err(tool_err)?;
        let schemas: Vec<String> = stmt
            .query_map([], |row| row.get(0))
            .map_err(tool_err)?
            .filter_map(Result::ok)
            .collect();
        Ok(schemas.join("\n\n"))
    }

    async fn read_blob(&self, blob_id: &str) -> Result<String, ToolError> {
        match self.store.get_blob_content(blob_id).map_err(tool_err)? {
            Some(bytes) => Ok(String::from_utf8_lossy(&bytes).into_owned()),
            None => Err(ToolError::Internal {
                message: format!("Blob not found: {blob_id}"),
            }),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::events::{ConnectionConfig, EventStore};

    fn setup_store() -> Arc<EventStore> {
        let pool = crate::events::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = crate::events::run_migrations(&conn).unwrap();
        }
        Arc::new(EventStore::new(pool))
    }

    #[tokio::test]
    async fn search_empty_query_returns_empty() {
        let q = SqliteEventStoreQuery::new(setup_store());
        let r = q.recall_memory("", None, 10).await.unwrap();
        assert!(r.is_empty());
    }

    #[tokio::test]
    async fn list_sessions_empty_db() {
        let q = SqliteEventStoreQuery::new(setup_store());
        let r = q.list_sessions(10, 0).await.unwrap();
        assert!(r.is_empty());
    }

    #[tokio::test]
    async fn get_session_not_found() {
        let q = SqliteEventStoreQuery::new(setup_store());
        let r = q.get_session("nonexistent").await.unwrap();
        assert!(r.is_none());
    }

    #[tokio::test]
    async fn get_stats_empty_db() {
        let q = SqliteEventStoreQuery::new(setup_store());
        let stats = q.get_stats().await.unwrap();
        assert_eq!(stats["sessions"], 0);
        assert_eq!(stats["events"], 0);
    }

    #[tokio::test]
    async fn get_schema_returns_tables() {
        let q = SqliteEventStoreQuery::new(setup_store());
        let schema = q.get_schema().await.unwrap();
        assert!(schema.contains("events"));
        assert!(schema.contains("sessions"));
    }

    #[tokio::test]
    async fn blob_not_found() {
        let q = SqliteEventStoreQuery::new(setup_store());
        let r = q.read_blob("nonexistent").await;
        assert!(r.is_err());
    }

    fn insert_test_log(
        store: &Arc<EventStore>,
        level: &str,
        level_num: i32,
        component: &str,
        msg: &str,
        session_id: Option<&str>,
        error_message: Option<&str>,
    ) {
        let conn = store.pool().get().unwrap();
        conn.execute(
            "INSERT INTO logs (timestamp, level, level_num, component, message, session_id, error_message) \
             VALUES (datetime('now'), ?, ?, ?, ?, ?, ?)",
            rusqlite::params![level, level_num, component, msg, session_id, error_message],
        )
        .unwrap();
    }

    #[tokio::test]
    async fn get_logs_empty_db() {
        let q = SqliteEventStoreQuery::new(setup_store());
        let r = q.get_logs("s1", None, 10, 0).await.unwrap();
        assert!(r.is_empty());
    }

    #[tokio::test]
    async fn get_logs_by_session() {
        let store = setup_store();
        insert_test_log(&store, "error", 50, "llm", "API failed", Some("sess_1"), Some("401 Unauthorized"));
        insert_test_log(&store, "info", 30, "llm", "request ok", Some("sess_2"), None);
        insert_test_log(&store, "warn", 40, "llm", "rate limited", Some("sess_1"), None);

        let q = SqliteEventStoreQuery::new(store);
        let r = q.get_logs("sess_1", None, 10, 0).await.unwrap();
        assert_eq!(r.len(), 2);
        assert!(r.iter().all(|v| v["sessionId"] == "sess_1"));
    }

    #[tokio::test]
    async fn get_logs_level_filter() {
        let store = setup_store();
        insert_test_log(&store, "info", 30, "agent", "started", Some("s1"), None);
        insert_test_log(&store, "warn", 40, "agent", "slow", Some("s1"), None);
        insert_test_log(&store, "error", 50, "llm", "API 401", Some("s1"), Some("Unauthorized"));

        let q = SqliteEventStoreQuery::new(store);
        let r = q.get_logs("s1", Some("error"), 10, 0).await.unwrap();
        assert_eq!(r.len(), 1);
        assert_eq!(r[0]["level"], "error");
        assert_eq!(r[0]["errorMessage"], "Unauthorized");
    }

    #[tokio::test]
    async fn get_logs_no_session_returns_all() {
        let store = setup_store();
        insert_test_log(&store, "info", 30, "a", "m1", Some("s1"), None);
        insert_test_log(&store, "info", 30, "a", "m2", Some("s2"), None);

        let q = SqliteEventStoreQuery::new(store);
        let r = q.get_logs("", None, 10, 0).await.unwrap();
        assert_eq!(r.len(), 2);
    }

    #[tokio::test]
    async fn get_logs_trace_level_returns_all() {
        let store = setup_store();
        insert_test_log(&store, "trace", 10, "a", "t", None, None);
        insert_test_log(&store, "debug", 20, "a", "d", None, None);
        insert_test_log(&store, "info", 30, "a", "i", None, None);
        insert_test_log(&store, "error", 50, "a", "e", None, None);

        let q = SqliteEventStoreQuery::new(store);
        let r = q.get_logs("", Some("trace"), 10, 0).await.unwrap();
        assert_eq!(r.len(), 4);
    }

    #[tokio::test]
    async fn with_real_session() {
        let store = setup_store();
        // Create a session to query
        let result = store
            .create_session("claude-opus-4-6", "/tmp", Some("Test Session"), None, None)
            .unwrap();
        let sid = result.root_event.session_id;

        let q = SqliteEventStoreQuery::new(store.clone());

        // List sessions should find it
        let sessions = q.list_sessions(10, 0).await.unwrap();
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0].title.as_deref(), Some("Test Session"));

        // Get session should find it
        let session = q.get_session(&sid).await.unwrap();
        assert!(session.is_some());
        assert_eq!(session.unwrap().session_id, sid);

        // Get events should find the session.start event
        let events = q.get_events(&sid, None, None, 10, 0).await.unwrap();
        assert!(!events.is_empty());
    }
}
