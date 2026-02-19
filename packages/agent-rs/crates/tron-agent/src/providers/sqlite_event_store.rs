//! Real `EventStoreQuery` backed by `tron_events::EventStore`.
//!
//! Provides the Remember tool with actual database access for session queries,
//! event lookups, FTS search, blob retrieval, and schema introspection.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};
use tron_events::EventStore;
use tron_events::sqlite::repositories::event::ListEventsOptions;
use tron_tools::errors::ToolError;
use tron_tools::traits::{EventStoreQuery, MemoryEntry, SessionInfo};

/// Real event store query backed by `SQLite` via `EventStore`.
pub struct SqliteEventStoreQuery {
    store: Arc<EventStore>,
    embedding_controller: Option<Arc<tokio::sync::Mutex<tron_embeddings::EmbeddingController>>>,
}

impl SqliteEventStoreQuery {
    pub fn new(store: Arc<EventStore>) -> Self {
        Self {
            store,
            embedding_controller: None,
        }
    }

    /// Set the embedding controller for semantic recall.
    pub fn with_embedding_controller(
        mut self,
        ec: Arc<tokio::sync::Mutex<tron_embeddings::EmbeddingController>>,
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
    async fn recall_memory(&self, query: &str, limit: u32) -> Result<Vec<MemoryEntry>, ToolError> {
        if query.is_empty() {
            return Ok(Vec::new());
        }

        // Try semantic vector search first
        if let Some(ref ec) = self.embedding_controller {
            let ctrl = ec.lock().await;
            if ctrl.is_ready() {
                let opts = tron_embeddings::SearchOptions {
                    limit: limit as usize,
                    ..Default::default()
                };
                if let Ok(results) = ctrl.search(query, &opts).await {
                    if !results.is_empty() {
                        let entries: Vec<MemoryEntry> = results
                            .into_iter()
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
                                #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
                                let score = (r.similarity * 100.0).round() as u32;
                                Some(MemoryEntry {
                                    content,
                                    session_id: Some(event.session_id),
                                    score: Some(score.min(100)),
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
        }

        // Fall back to FTS
        self.search_memory(None, query, limit, 0).await
    }

    async fn search_memory(
        &self,
        session_id: Option<&str>,
        query: &str,
        limit: u32,
        offset: u32,
    ) -> Result<Vec<MemoryEntry>, ToolError> {
        if query.is_empty() {
            return Ok(Vec::new());
        }
        let opts = tron_events::sqlite::repositories::search::SearchOptions {
            workspace_id: None,
            session_id,
            types: None,
            limit: Some(i64::from(limit)),
            offset: Some(i64::from(offset)),
        };
        let results = self.store.search(query, &opts).map_err(tool_err)?;
        Ok(results
            .into_iter()
            .map(|r| {
                let content = if r.snippet.is_empty() {
                    r.event_type.to_string()
                } else {
                    r.snippet
                };
                // BM25 score is negative (lower = better); normalize to 0-100
                #[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
                let normalized = ((-r.score).min(20.0) / 20.0 * 100.0) as u32;
                MemoryEntry {
                    content,
                    session_id: Some(r.session_id),
                    score: Some(normalized.min(100)),
                    timestamp: Some(r.timestamp),
                }
            })
            .collect())
    }

    async fn list_sessions(&self, limit: u32, offset: u32) -> Result<Vec<SessionInfo>, ToolError> {
        let opts = tron_events::sqlite::repositories::session::ListSessionsOptions {
            workspace_id: None,
            ended: None,
            exclude_subagents: Some(true),
            limit: Some(i64::from(limit)),
            offset: Some(i64::from(offset)),
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
        _session_id: &str,
        _level: Option<&str>,
        _limit: u32,
        _offset: u32,
    ) -> Result<Vec<Value>, ToolError> {
        // Logs table may not exist in the Rust event store schema.
        // Return empty rather than error — log querying is secondary.
        Ok(Vec::new())
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
    use tron_events::{ConnectionConfig, EventStore};

    fn setup_store() -> Arc<EventStore> {
        let pool = tron_events::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = tron_events::run_migrations(&conn).unwrap();
        }
        Arc::new(EventStore::new(pool))
    }

    #[tokio::test]
    async fn search_empty_query_returns_empty() {
        let q = SqliteEventStoreQuery::new(setup_store());
        let r = q.recall_memory("", 10).await.unwrap();
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

    #[tokio::test]
    async fn get_logs_returns_empty() {
        let q = SqliteEventStoreQuery::new(setup_store());
        let r = q.get_logs("s1", None, 10, 0).await.unwrap();
        assert!(r.is_empty());
    }

    #[tokio::test]
    async fn with_real_session() {
        let store = setup_store();
        // Create a session to query
        let result = store
            .create_session("claude-opus-4-6", "/tmp", Some("Test Session"), None)
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
