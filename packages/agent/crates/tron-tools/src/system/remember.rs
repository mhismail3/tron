//! `Remember` tool — event store query with 12 action types.
//!
//! Routes memory actions to the [`EventStoreQuery`] trait, formatting results
//! for the LLM.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};
use tron_core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult, error_result};

use crate::errors::ToolError;
use crate::traits::{EventStoreQuery, ToolContext, TronTool};
use crate::utils::schema::ToolSchemaBuilder;
use crate::utils::validation::{get_optional_string, get_optional_u64, validate_required_string};

const VALID_ACTIONS: &[&str] = &[
    "recall",
    "search",
    "memory",
    "schema",
    "sessions",
    "session",
    "events",
    "messages",
    "tools",
    "logs",
    "stats",
    "read_blob",
];
const DEFAULT_LIMIT: u32 = 20;
const MAX_LIMIT: u32 = 500;

/// The `Remember` tool queries the event store for memory and session data.
pub struct RememberTool {
    store: Arc<dyn EventStoreQuery>,
}

impl RememberTool {
    /// Create a new `Remember` tool with the given event store.
    pub fn new(store: Arc<dyn EventStoreQuery>) -> Self {
        Self { store }
    }
}

fn clamp_limit(limit: Option<u64>) -> u32 {
    #[allow(clippy::cast_possible_truncation)]
    limit.map_or(DEFAULT_LIMIT, |l| (l as u32).min(MAX_LIMIT))
}

fn format_entries(entries: &[crate::traits::MemoryEntry]) -> String {
    if entries.is_empty() {
        return "No results found.".into();
    }
    entries
        .iter()
        .enumerate()
        .map(|(i, e)| {
            let score_str = e
                .score
                .map_or(String::new(), |s| format!(" (relevance: {s}%)"));
            format!("{}. {}{score_str}", i + 1, e.content)
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

fn format_sessions(sessions: &[crate::traits::SessionInfo]) -> String {
    if sessions.is_empty() {
        return "No sessions found.".into();
    }
    sessions
        .iter()
        .map(|s| {
            let title = s.title.as_deref().unwrap_or("(untitled)");
            let created = s.created_at.as_deref().unwrap_or("unknown");
            format!("- {} | {} | {created}", s.session_id, title)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn format_json_entries(entries: &[Value]) -> String {
    if entries.is_empty() {
        return "No results found.".into();
    }
    entries
        .iter()
        .map(|v| serde_json::to_string_pretty(v).unwrap_or_else(|_| v.to_string()))
        .collect::<Vec<_>>()
        .join("\n---\n")
}

#[async_trait]
#[allow(clippy::too_many_lines)]
impl TronTool for RememberTool {
    fn name(&self) -> &str {
        "Remember"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn definition(&self) -> Tool {
        ToolSchemaBuilder::new(
            "Remember",
            "Your memory and self-analysis tool. Query your internal database to recall past work, \
review session history, and retrieve stored content.\n\n\
Available actions:\n\
- recall (default): Semantic memory search — \"find memories about X\". Uses vector similarity to find \
the most relevant past work even when exact keywords don't match. ALWAYS provide a query.\n\
- search: Keyword search via exact term matching in memory ledger entries.\n\
- sessions: List recent sessions (title, tokens, cost)\n\
- session: Get details for a specific session\n\
- events: Get raw events (filter by session_id, type, turn)\n\
- messages: Get conversation messages for a session\n\
- tools: Get tool calls and results for a session\n\
- logs: Get application logs\n\
- stats: Get database statistics\n\
- schema: List database tables and columns\n\
- read_blob: Read stored content from blob storage\n\n\
Search strategy: Use \"recall\" for finding relevant past work (semantic). Use \"search\" for exact \
keyword matching. Start narrow (query + small limit), then broaden if needed.\n\
Use read_blob to retrieve full content when tool results reference a blob_id.",
        )
        .required_property("action", json!({
            "type": "string",
            "enum": VALID_ACTIONS,
            "description": "The query action to perform"
        }))
        .property("query", json!({"type": "string", "description": "Search query"}))
        .property("session_id", json!({"type": "string", "description": "Session ID to query"}))
        .property("blob_id", json!({"type": "string", "description": "Blob ID to read"}))
        .property("type", json!({"type": "string", "description": "Event type filter"}))
        .property("turn", json!({"type": "number", "description": "Turn number filter"}))
        .property("level", json!({"type": "string", "description": "Log level filter"}))
        .property("limit", json!({"type": "number", "description": "Max results (default 20, max 500)"}))
        .property("offset", json!({"type": "number", "description": "Pagination offset"}))
        .build()
    }

    async fn execute(
        &self,
        params: Value,
        _ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let action = match validate_required_string(&params, "action", "query action") {
            Ok(a) => a,
            Err(e) => return Ok(e),
        };

        if !VALID_ACTIONS.contains(&action.as_str()) {
            return Ok(error_result(format!(
                "Invalid action: \"{action}\". Valid actions: {}",
                VALID_ACTIONS.join(", ")
            )));
        }

        let limit = clamp_limit(get_optional_u64(&params, "limit"));
        #[allow(clippy::cast_possible_truncation)]
        let offset = get_optional_u64(&params, "offset").unwrap_or(0) as u32;
        let query = get_optional_string(&params, "query");
        let session_id = get_optional_string(&params, "session_id");

        let content = match action.as_str() {
            "recall" => {
                let q = query.unwrap_or_default();
                let entries = self.store.recall_memory(&q, limit).await?;
                format_entries(&entries)
            }
            "search" | "memory" => {
                let q = query.unwrap_or_default();
                let entries = self
                    .store
                    .search_memory(session_id.as_deref(), &q, limit, offset)
                    .await?;
                format_entries(&entries)
            }
            "sessions" => {
                let sessions = self.store.list_sessions(limit, offset).await?;
                format_sessions(&sessions)
            }
            "session" => {
                let Some(sid) = &session_id else {
                    return Ok(error_result("session action requires session_id parameter"));
                };
                match self.store.get_session(sid).await? {
                    Some(s) => {
                        serde_json::to_string_pretty(&s).unwrap_or_else(|_| format!("{s:?}"))
                    }
                    None => format!("Session not found: {sid}"),
                }
            }
            "events" => {
                let sid = session_id.as_deref().unwrap_or("");
                let event_type = get_optional_string(&params, "type");
                #[allow(clippy::cast_possible_truncation)]
                let turn = get_optional_u64(&params, "turn").map(|v| v as u32);
                let entries = self
                    .store
                    .get_events(sid, event_type.as_deref(), turn, limit, offset)
                    .await?;
                format_json_entries(&entries)
            }
            "messages" => {
                let Some(sid) = &session_id else {
                    return Ok(error_result(
                        "messages action requires session_id parameter",
                    ));
                };
                let entries = self.store.get_messages(sid, limit).await?;
                format_json_entries(&entries)
            }
            "tools" => {
                let Some(sid) = &session_id else {
                    return Ok(error_result("tools action requires session_id parameter"));
                };
                let entries = self.store.get_tool_calls(sid, limit).await?;
                format_json_entries(&entries)
            }
            "logs" => {
                let sid = session_id.as_deref().unwrap_or("");
                let level = get_optional_string(&params, "level");
                let entries = self
                    .store
                    .get_logs(sid, level.as_deref(), limit, offset)
                    .await?;
                format_json_entries(&entries)
            }
            "stats" => {
                let stats = self.store.get_stats().await?;
                serde_json::to_string_pretty(&stats).unwrap_or_else(|_| stats.to_string())
            }
            "schema" => self.store.get_schema().await?,
            "read_blob" => {
                let Some(blob_id) = get_optional_string(&params, "blob_id") else {
                    return Ok(error_result("read_blob action requires blob_id parameter"));
                };
                self.store.read_blob(&blob_id).await?
            }
            _ => unreachable!(),
        };

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![tron_core::content::ToolResultContent::text(
                content,
            )]),
            details: Some(json!({"action": action})),
            is_error: None,
            stop_turn: None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::{extract_text, make_ctx};
    use crate::traits::{MemoryEntry, SessionInfo};

    struct MockStore;

    #[async_trait]
    impl EventStoreQuery for MockStore {
        async fn recall_memory(
            &self,
            _query: &str,
            _limit: u32,
        ) -> Result<Vec<MemoryEntry>, ToolError> {
            Ok(vec![MemoryEntry {
                content: "recalled memory".into(),
                session_id: None,
                score: Some(85),
                timestamp: None,
            }])
        }
        async fn search_memory(
            &self,
            _sid: Option<&str>,
            _q: &str,
            _limit: u32,
            _offset: u32,
        ) -> Result<Vec<MemoryEntry>, ToolError> {
            Ok(vec![MemoryEntry {
                content: "searched memory".into(),
                session_id: None,
                score: None,
                timestamp: None,
            }])
        }
        async fn list_sessions(
            &self,
            _limit: u32,
            _offset: u32,
        ) -> Result<Vec<SessionInfo>, ToolError> {
            Ok(vec![SessionInfo {
                session_id: "s1".into(),
                title: Some("Test".into()),
                created_at: Some("2026-01-01".into()),
                archived: None,
                event_count: None,
            }])
        }
        async fn get_session(&self, sid: &str) -> Result<Option<SessionInfo>, ToolError> {
            if sid == "s1" {
                Ok(Some(SessionInfo {
                    session_id: "s1".into(),
                    title: Some("Test".into()),
                    created_at: None,
                    archived: None,
                    event_count: None,
                }))
            } else {
                Ok(None)
            }
        }
        async fn get_events(
            &self,
            _sid: &str,
            _et: Option<&str>,
            _turn: Option<u32>,
            _limit: u32,
            _offset: u32,
        ) -> Result<Vec<Value>, ToolError> {
            Ok(vec![json!({"type": "agent.message", "turn": 1})])
        }
        async fn get_messages(&self, _sid: &str, _limit: u32) -> Result<Vec<Value>, ToolError> {
            Ok(vec![json!({"role": "user", "content": "hello"})])
        }
        async fn get_tool_calls(&self, _sid: &str, _limit: u32) -> Result<Vec<Value>, ToolError> {
            Ok(vec![json!({"tool": "Bash", "result": "ok"})])
        }
        async fn get_logs(
            &self,
            _sid: &str,
            _level: Option<&str>,
            _limit: u32,
            _offset: u32,
        ) -> Result<Vec<Value>, ToolError> {
            Ok(vec![json!({"level": "info", "msg": "started"})])
        }
        async fn get_stats(&self) -> Result<Value, ToolError> {
            Ok(json!({"sessions": 42, "events": 1000}))
        }
        async fn get_schema(&self) -> Result<String, ToolError> {
            Ok("CREATE TABLE events (...)".into())
        }
        async fn read_blob(&self, _id: &str) -> Result<String, ToolError> {
            Ok("blob content here".into())
        }
    }

    fn tool() -> RememberTool {
        RememberTool::new(Arc::new(MockStore))
    }

    #[tokio::test]
    async fn recall_action() {
        let r = tool()
            .execute(json!({"action": "recall", "query": "test"}), &make_ctx())
            .await
            .unwrap();
        assert!(extract_text(&r).contains("recalled memory"));
        assert!(extract_text(&r).contains("relevance: 85%"));
    }

    #[tokio::test]
    async fn search_action() {
        let r = tool()
            .execute(json!({"action": "search", "query": "test"}), &make_ctx())
            .await
            .unwrap();
        assert!(extract_text(&r).contains("searched memory"));
    }

    #[tokio::test]
    async fn memory_alias_for_search() {
        let r = tool()
            .execute(json!({"action": "memory", "query": "test"}), &make_ctx())
            .await
            .unwrap();
        assert!(extract_text(&r).contains("searched memory"));
    }

    #[tokio::test]
    async fn sessions_action() {
        let r = tool()
            .execute(json!({"action": "sessions"}), &make_ctx())
            .await
            .unwrap();
        assert!(extract_text(&r).contains("s1"));
        assert!(extract_text(&r).contains("Test"));
    }

    #[tokio::test]
    async fn session_action() {
        let r = tool()
            .execute(
                json!({"action": "session", "session_id": "s1"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(extract_text(&r).contains("s1"));
    }

    #[tokio::test]
    async fn events_action() {
        let r = tool()
            .execute(json!({"action": "events", "session_id": "s1"}), &make_ctx())
            .await
            .unwrap();
        assert!(extract_text(&r).contains("agent.message"));
    }

    #[tokio::test]
    async fn messages_action() {
        let r = tool()
            .execute(
                json!({"action": "messages", "session_id": "s1"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(extract_text(&r).contains("hello"));
    }

    #[tokio::test]
    async fn tools_action() {
        let r = tool()
            .execute(json!({"action": "tools", "session_id": "s1"}), &make_ctx())
            .await
            .unwrap();
        assert!(extract_text(&r).contains("Bash"));
    }

    #[tokio::test]
    async fn logs_action() {
        let r = tool()
            .execute(json!({"action": "logs", "session_id": "s1"}), &make_ctx())
            .await
            .unwrap();
        assert!(extract_text(&r).contains("started"));
    }

    #[tokio::test]
    async fn stats_action() {
        let r = tool()
            .execute(json!({"action": "stats"}), &make_ctx())
            .await
            .unwrap();
        assert!(extract_text(&r).contains("42"));
    }

    #[tokio::test]
    async fn schema_action() {
        let r = tool()
            .execute(json!({"action": "schema"}), &make_ctx())
            .await
            .unwrap();
        assert!(extract_text(&r).contains("CREATE TABLE"));
    }

    #[tokio::test]
    async fn read_blob_action() {
        let r = tool()
            .execute(json!({"action": "read_blob", "blob_id": "b1"}), &make_ctx())
            .await
            .unwrap();
        assert!(extract_text(&r).contains("blob content"));
    }

    #[tokio::test]
    async fn missing_action() {
        let r = tool().execute(json!({}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn invalid_action() {
        let r = tool()
            .execute(json!({"action": "invalid"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("Invalid action"));
    }
}
