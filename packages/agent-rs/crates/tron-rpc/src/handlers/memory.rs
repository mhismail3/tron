//! Memory handlers: getLedger, updateLedger, search, getHandoffs.

use async_trait::async_trait;
use serde_json::Value;
use tracing::{debug, instrument};

use tron_context::ledger_writer::{try_llm_ledger, LedgerParseResult};
use tron_context::summarizer::{KeywordSummarizer, Summarizer};
use tron_core::messages::Message;

use crate::context::RpcContext;
use crate::errors::RpcError;
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

/// Get ledger entries for a workspace.
pub struct GetLedgerHandler;

#[async_trait]
impl MethodHandler for GetLedgerHandler {
    #[instrument(skip(self, ctx), fields(method = "memory.getLedger"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let working_dir = require_string_param(params.as_ref(), "workingDirectory")?;

        let limit = params
            .as_ref()
            .and_then(|p| p.get("limit"))
            .and_then(serde_json::Value::as_u64)
            .unwrap_or(50);

        // Query ledger events from the event store for sessions matching this workspace
        let filter = tron_runtime::SessionFilter {
            workspace_path: Some(working_dir),
            ..Default::default()
        };

        let sessions = ctx
            .session_manager
            .list_sessions(&filter)
            .unwrap_or_default();

        let mut entries = Vec::new();
        let limit = usize::try_from(limit).unwrap_or(usize::MAX);

        for session in sessions {
            let events = ctx
                .event_store
                .get_events_by_type(
                    &session.id,
                    &["memory.ledger"],
                    Some(i64::try_from(limit).unwrap_or(i64::MAX)),
                )
                .unwrap_or_default();

            for event in events {
                if let Ok(parsed) = serde_json::from_str::<Value>(&event.payload) {
                    entries.push(parsed);
                }
            }
            if entries.len() >= limit {
                break;
            }
        }

        let total_count = entries.len();
        let has_more = entries.len() > limit;
        entries.truncate(limit);

        Ok(serde_json::json!({
            "entries": entries,
            "hasMore": has_more,
            "totalCount": total_count,
        }))
    }
}

/// Trigger a memory ledger update for a session.
pub struct UpdateLedgerHandler;

#[async_trait]
impl MethodHandler for UpdateLedgerHandler {
    #[instrument(skip(self, ctx), fields(method = "memory.updateLedger"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        // Accept either sessionId directly or workingDirectory (find most recent session)
        let session_id_owned: String;
        if let Some(sid) = params.as_ref().and_then(|p| p.get("sessionId")).and_then(Value::as_str)
        {
            session_id_owned = sid.to_owned();
        } else if let Some(wd) = params
            .as_ref()
            .and_then(|p| p.get("workingDirectory"))
            .and_then(Value::as_str)
        {
            // Find most recent session for this workspace
            let filter = tron_runtime::SessionFilter {
                workspace_path: Some(wd.to_owned()),
                limit: Some(1),
                ..Default::default()
            };
            let sessions = ctx.session_manager.list_sessions(&filter).unwrap_or_default();
            if let Some(s) = sessions.first() {
                session_id_owned = s.id.clone();
            } else {
                return Ok(serde_json::json!({
                    "written": false,
                    "title": null,
                    "entryType": null,
                    "reason": "no sessions found for workspace",
                }));
            }
        } else {
            return Err(RpcError::InvalidParams {
                message: "Missing required parameter: sessionId or workingDirectory".into(),
            });
        }
        let session_id = &session_id_owned;

        // Resume session to get messages
        let Ok(active) = ctx.session_manager.resume_session(session_id) else {
            debug!(session_id, "session not found or empty during resume");
            return Ok(serde_json::json!({
                "written": false,
                "title": null,
                "entryType": null,
                "reason": "session not found or empty",
            }));
        };

        let message_count = active.state.messages.len();
        debug!(session_id, message_count, "reconstructed session messages");

        // Need messages to summarize
        if active.state.messages.is_empty() {
            debug!(session_id, "no messages in session");
            return Ok(serde_json::json!({
                "written": false,
                "title": null,
                "entryType": null,
                "reason": "no_messages",
            }));
        }

        // Deduplication: skip if a memory.ledger event already exists for this session
        let existing_ledger = ctx
            .event_store
            .get_events_by_type(session_id, &["memory.ledger"], Some(1))
            .unwrap_or_default();
        if !existing_ledger.is_empty() {
            debug!(session_id, "ledger entry already exists, skipping duplicate write");
            return Ok(serde_json::json!({
                "written": false,
                "title": null,
                "entryType": null,
                "reason": "already_exists",
            }));
        }

        // Try LLM-based ledger writing (if provider available)
        let has_provider = ctx.agent_deps.is_some();
        debug!(session_id, has_provider, message_count, "attempting ledger update");
        let llm_result = if let Some(ref agent_deps) = ctx.agent_deps {
            try_llm_ledger(&*agent_deps.provider, &active.state.messages).await
        } else {
            debug!(session_id, "no LLM provider, falling back to keyword summarizer");
            None
        };

        match llm_result {
            Some(LedgerParseResult::Skip) => {
                debug!(session_id, "LLM classified interaction as trivial, skipping");
                return Ok(serde_json::json!({
                    "written": false,
                    "title": null,
                    "entryType": null,
                    "reason": "skipped",
                }));
            }
            Some(LedgerParseResult::Entry(ref entry)) => {
                // Get session metadata for the full payload
                let session_info = ctx.session_manager.get_session(session_id).ok().flatten();
                let (total_input, total_output) = session_info
                    .as_ref()
                    .map_or((0, 0), |s| (s.total_input_tokens, s.total_output_tokens));
                let model = session_info
                    .as_ref()
                    .map(|s| s.latest_model.clone())
                    .unwrap_or_default();
                let workspace = active
                    .state
                    .working_directory
                    .clone()
                    .unwrap_or_default();
                let head_event_id = session_info
                    .as_ref()
                    .and_then(|s| s.head_event_id.clone())
                    .unwrap_or_default();

                // Get first event ID
                let first_event_id = ctx
                    .event_store
                    .get_events_by_session(
                        session_id,
                        &tron_events::sqlite::repositories::event::ListEventsOptions {
                            limit: Some(1),
                            offset: None,
                        },
                    )
                    .ok()
                    .and_then(|events| events.first().map(|e| e.id.clone()))
                    .unwrap_or_default();

                // Count turns (user messages)
                #[allow(clippy::cast_possible_wrap)]
                let user_turns = active
                    .state
                    .messages
                    .iter()
                    .filter(|m| matches!(m, Message::User { .. }))
                    .count() as i64;

                // Build full MemoryLedgerPayload
                let payload = serde_json::json!({
                    "eventRange": {
                        "firstEventId": first_event_id,
                        "lastEventId": head_event_id,
                    },
                    "turnRange": {
                        "firstTurn": 1,
                        "lastTurn": user_turns,
                    },
                    "title": entry.title,
                    "entryType": entry.entry_type,
                    "status": entry.status,
                    "tags": entry.tags,
                    "input": entry.input,
                    "actions": entry.actions,
                    "files": entry.files.iter().map(|f| serde_json::json!({
                        "path": f.path,
                        "op": f.op,
                        "why": f.why,
                    })).collect::<Vec<_>>(),
                    "decisions": entry.decisions.iter().map(|d| serde_json::json!({
                        "choice": d.choice,
                        "reason": d.reason,
                    })).collect::<Vec<_>>(),
                    "lessons": entry.lessons,
                    "thinkingInsights": entry.thinking_insights,
                    "tokenCost": {
                        "input": total_input,
                        "output": total_output,
                    },
                    "model": model,
                    "workingDirectory": workspace,
                });

                // Persist as memory.ledger event
                let _ = ctx.event_store.append(&tron_events::AppendOptions {
                    session_id,
                    event_type: tron_events::EventType::MemoryLedger,
                    payload,
                    parent_id: None,
                });

                // Broadcast memory updated event
                let _ = ctx.orchestrator.broadcast().emit(
                    tron_core::events::TronEvent::MemoryUpdated {
                        base: tron_core::events::BaseEvent::now(session_id),
                        title: Some(entry.title.clone()),
                        entry_type: Some(entry.entry_type.clone()),
                    },
                );

                debug!(session_id, title = %entry.title, entry_type = %entry.entry_type, "LLM ledger entry written");
                return Ok(serde_json::json!({
                    "written": true,
                    "title": entry.title,
                    "entryType": entry.entry_type,
                    "reason": "written",
                }));
            }
            None => {
                // Fall through to keyword summarizer
            }
        }

        // ── Fallback: keyword summarizer ────────────────────────────────────
        // Used when no LLM provider is configured or the LLM call failed.

        // Derive title from first user message
        let title = active
            .state
            .messages
            .iter()
            .find_map(|m| match m {
                Message::User { content, .. } => {
                    let text = match content {
                        tron_core::messages::UserMessageContent::Text(t) => t.clone(),
                        tron_core::messages::UserMessageContent::Blocks(blocks) => blocks
                            .iter()
                            .filter_map(|b| b.as_text())
                            .collect::<Vec<_>>()
                            .join(" "),
                    };
                    let trimmed = text.trim();
                    if trimmed.is_empty() {
                        None
                    } else {
                        let t = trimmed.to_owned();
                        Some(if t.len() > 80 {
                            format!("{}...", &t[..77])
                        } else {
                            t
                        })
                    }
                }
                _ => None,
            })
            .unwrap_or_else(|| "Untitled session".to_owned());

        let summarizer = KeywordSummarizer::new();
        let summary_result = summarizer
            .summarize(&active.state.messages)
            .await
            .map_err(|e| RpcError::Internal {
                message: format!("Summarization failed: {e}"),
            })?;

        let entry_type = if summary_result
            .extracted_data
            .files_modified
            .is_empty()
        {
            "conversation"
        } else {
            "feature"
        };

        // Persist as memory.ledger event (sparse payload)
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id,
            event_type: tron_events::EventType::MemoryLedger,
            payload: serde_json::json!({
                "title": title,
                "summary": summary_result.narrative,
                "entryType": entry_type,
                "filesModified": summary_result.extracted_data.files_modified,
                "topicsDiscussed": summary_result.extracted_data.topics_discussed,
            }),
            parent_id: None,
        });

        // Broadcast memory updated event
        let _ = ctx.orchestrator.broadcast().emit(
            tron_core::events::TronEvent::MemoryUpdated {
                base: tron_core::events::BaseEvent::now(session_id),
                title: Some(title.clone()),
                entry_type: Some(entry_type.to_owned()),
            },
        );

        debug!(session_id, %title, entry_type, "keyword summarizer ledger entry written");
        Ok(serde_json::json!({
            "written": true,
            "title": title,
            "entryType": entry_type,
            "reason": "written",
        }))
    }
}

/// Search memory entries across sessions.
pub struct SearchMemoryHandler;

#[async_trait]
impl MethodHandler for SearchMemoryHandler {
    #[instrument(skip(self, ctx), fields(method = "memory.search"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let search_text = params
            .as_ref()
            .and_then(|p| p.get("searchText"))
            .and_then(Value::as_str)
            .unwrap_or("");

        let type_filter = params
            .as_ref()
            .and_then(|p| p.get("type"))
            .and_then(Value::as_str);

        let limit = params
            .as_ref()
            .and_then(|p| p.get("limit"))
            .and_then(Value::as_u64)
            .unwrap_or(20);
        let limit = usize::try_from(limit).unwrap_or(usize::MAX);

        // Query all sessions for memory.ledger events
        let sessions = ctx
            .session_manager
            .list_sessions(&tron_runtime::SessionFilter {
                include_archived: true,
                ..Default::default()
            })
            .unwrap_or_default();

        let mut entries = Vec::new();
        let search_lower = search_text.to_lowercase();

        for session in sessions {
            let events = ctx
                .event_store
                .get_events_by_type(&session.id, &["memory.ledger"], Some(100))
                .unwrap_or_default();

            for event in events {
                if let Ok(parsed) = serde_json::from_str::<Value>(&event.payload) {
                    // Text filter (case-insensitive)
                    if !search_lower.is_empty() {
                        let payload_text = parsed.to_string().to_lowercase();
                        if !payload_text.contains(&search_lower) {
                            continue;
                        }
                    }

                    // Type filter
                    if let Some(tf) = type_filter {
                        let entry_type = parsed
                            .get("entryType")
                            .and_then(Value::as_str)
                            .unwrap_or("");
                        if entry_type != tf {
                            continue;
                        }
                    }

                    let mut entry = parsed;
                    if let Some(obj) = entry.as_object_mut() {
                        let _ = obj.insert("sessionId".into(), serde_json::json!(session.id));
                        let _ = obj.insert("timestamp".into(), serde_json::json!(event.timestamp));
                    }
                    entries.push(entry);

                    if entries.len() >= limit {
                        break;
                    }
                }
            }
            if entries.len() >= limit {
                break;
            }
        }

        let total_count = entries.len();

        Ok(serde_json::json!({
            "entries": entries,
            "totalCount": total_count,
        }))
    }
}

/// Get handoff entries for recent sessions.
pub struct GetHandoffsHandler;

#[async_trait]
impl MethodHandler for GetHandoffsHandler {
    #[instrument(skip(self, ctx), fields(method = "memory.getHandoffs"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let limit = params
            .as_ref()
            .and_then(|p| p.get("limit"))
            .and_then(Value::as_u64)
            .unwrap_or(10);
        let limit = usize::try_from(limit).unwrap_or(usize::MAX);

        let sessions = ctx
            .session_manager
            .list_sessions(&tron_runtime::SessionFilter {
                include_archived: true,
                limit: Some(limit * 2), // overfetch to ensure enough with ledger entries
                ..Default::default()
            })
            .unwrap_or_default();

        let mut handoffs = Vec::new();

        for session in sessions {
            let events = ctx
                .event_store
                .get_events_by_type(&session.id, &["memory.ledger"], Some(1))
                .unwrap_or_default();

            if let Some(event) = events.first() {
                if let Ok(parsed) = serde_json::from_str::<Value>(&event.payload) {
                    handoffs.push(serde_json::json!({
                        "sessionId": session.id,
                        "title": parsed.get("title").and_then(Value::as_str).unwrap_or(""),
                        "timestamp": event.timestamp,
                        "summary": parsed.get("summary").and_then(Value::as_str).unwrap_or(""),
                        "lessons": parsed.get("lessons").cloned().unwrap_or(serde_json::json!([])),
                    }));
                }
            }

            if handoffs.len() >= limit {
                break;
            }
        }

        Ok(serde_json::json!({
            "handoffs": handoffs,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn get_ledger_returns_entries() {
        let ctx = make_test_context();
        let result = GetLedgerHandler
            .handle(
                Some(json!({"workingDirectory": "/tmp"})),
                &ctx,
            )
            .await
            .unwrap();
        assert!(result["entries"].is_array());
    }

    #[tokio::test]
    async fn get_ledger_returns_has_more() {
        let ctx = make_test_context();
        let result = GetLedgerHandler
            .handle(
                Some(json!({"workingDirectory": "/tmp"})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["hasMore"], false);
    }

    #[tokio::test]
    async fn get_ledger_returns_total_count() {
        let ctx = make_test_context();
        let result = GetLedgerHandler
            .handle(
                Some(json!({"workingDirectory": "/tmp"})),
                &ctx,
            )
            .await
            .unwrap();
        assert!(result["totalCount"].is_number());
    }

    #[tokio::test]
    async fn get_ledger_missing_working_dir() {
        let ctx = make_test_context();
        let err = GetLedgerHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn update_ledger_with_session_and_messages() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", Some("test"))
            .unwrap();

        // Add messages
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"content": "Fix the login bug"}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({
                "content": [{"type": "text", "text": "I'll fix that for you."}],
                "turn": 1,
                "tokenUsage": {"inputTokens": 10, "outputTokens": 5}
            }),
            parent_id: None,
        });
        ctx.session_manager.invalidate_session(&sid);

        let result = UpdateLedgerHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["written"], true);
        assert!(result["title"].is_string());
        assert!(result["entryType"].is_string());
    }

    #[tokio::test]
    async fn update_ledger_empty_session() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", Some("test"))
            .unwrap();

        let result = UpdateLedgerHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["written"], false);
    }

    #[tokio::test]
    async fn update_ledger_nonexistent_session() {
        let ctx = make_test_context();
        let result = UpdateLedgerHandler
            .handle(Some(json!({"sessionId": "nonexistent"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["written"], false);
    }

    #[tokio::test]
    async fn update_ledger_missing_params() {
        let ctx = make_test_context();
        let err = UpdateLedgerHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn search_memory_returns_empty() {
        let ctx = make_test_context();
        let result = SearchMemoryHandler
            .handle(None, &ctx)
            .await
            .unwrap();
        assert!(result["entries"].as_array().unwrap().is_empty());
        assert_eq!(result["totalCount"], 0);
    }

    #[tokio::test]
    async fn search_memory_with_params() {
        let ctx = make_test_context();
        let result = SearchMemoryHandler
            .handle(
                Some(json!({"searchText": "test", "type": "lesson", "limit": 10})),
                &ctx,
            )
            .await
            .unwrap();
        assert!(result["entries"].as_array().unwrap().is_empty());
    }

    #[tokio::test]
    async fn search_memory_missing_no_error() {
        let ctx = make_test_context();
        let result = SearchMemoryHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap();
        assert!(result["entries"].is_array());
    }

    #[tokio::test]
    async fn get_handoffs_returns_empty() {
        let ctx = make_test_context();
        let result = GetHandoffsHandler
            .handle(None, &ctx)
            .await
            .unwrap();
        assert!(result["handoffs"].as_array().unwrap().is_empty());
    }

    #[tokio::test]
    async fn get_handoffs_with_workspace() {
        let ctx = make_test_context();
        let result = GetHandoffsHandler
            .handle(
                Some(json!({"workingDirectory": "/tmp"})),
                &ctx,
            )
            .await
            .unwrap();
        assert!(result["handoffs"].as_array().unwrap().is_empty());
    }

    #[tokio::test]
    async fn update_ledger_empty_session_returns_reason() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", Some("test"))
            .unwrap();

        let result = UpdateLedgerHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["written"], false);
        assert_eq!(result["reason"], "no_messages");
    }

    #[tokio::test]
    async fn update_ledger_nonexistent_returns_reason() {
        let ctx = make_test_context();
        let result = UpdateLedgerHandler
            .handle(Some(json!({"sessionId": "nonexistent"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["written"], false);
        assert!(
            result.get("reason").is_some(),
            "Response must include 'reason' field"
        );
    }

    #[tokio::test]
    async fn update_ledger_success_returns_reason() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", Some("test"))
            .unwrap();

        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"content": "Implement dark mode for the dashboard"}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({
                "content": [{"type": "text", "text": "Done, dark mode is now active."}],
                "turn": 1,
                "tokenUsage": {"inputTokens": 50, "outputTokens": 20}
            }),
            parent_id: None,
        });
        ctx.session_manager.invalidate_session(&sid);

        let result = UpdateLedgerHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["written"], true);
        assert_eq!(result["reason"], "written");
    }

    #[tokio::test]
    async fn get_handoffs_missing_no_error() {
        let ctx = make_test_context();
        let result = GetHandoffsHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap();
        assert!(result["handoffs"].is_array());
    }

    // ── Ledger deduplication tests ──

    #[tokio::test]
    async fn update_ledger_deduplicates_existing_entry() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", Some("test"))
            .unwrap();

        // Add a user message
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"content": "Implement dark mode"}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({
                "content": [{"type": "text", "text": "Done."}],
                "turn": 1,
                "tokenUsage": {"inputTokens": 10, "outputTokens": 5}
            }),
            parent_id: None,
        });
        ctx.session_manager.invalidate_session(&sid);

        // First call should write
        let result = UpdateLedgerHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["written"], true);

        // Invalidate to force re-read
        ctx.session_manager.invalidate_session(&sid);

        // Second call should skip (duplicate)
        let result = UpdateLedgerHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["written"], false);
        assert_eq!(result["reason"], "already_exists");
    }

    // ── Whitespace-only user message tests ──

    #[tokio::test]
    async fn update_ledger_whitespace_only_user_message_gets_untitled() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", Some("test"))
            .unwrap();

        // Add a whitespace-only user message
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"content": "   \n\t  "}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({
                "content": [{"type": "text", "text": "Response here."}],
                "turn": 1,
                "tokenUsage": {"inputTokens": 10, "outputTokens": 5}
            }),
            parent_id: None,
        });
        ctx.session_manager.invalidate_session(&sid);

        let result = UpdateLedgerHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["written"], true);
        assert_eq!(result["title"], "Untitled session");
    }

    #[tokio::test]
    async fn update_ledger_title_trimmed() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", Some("test"))
            .unwrap();

        // Add a user message with leading/trailing whitespace
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"content": "  Fix the login bug  "}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({
                "content": [{"type": "text", "text": "Done."}],
                "turn": 1,
                "tokenUsage": {"inputTokens": 10, "outputTokens": 5}
            }),
            parent_id: None,
        });
        ctx.session_manager.invalidate_session(&sid);

        let result = UpdateLedgerHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["written"], true);
        assert_eq!(result["title"], "Fix the login bug");
    }
}
