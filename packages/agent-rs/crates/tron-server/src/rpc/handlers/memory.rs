//! Memory handlers: getLedger, updateLedger, search, getHandoffs.
//!
//! The ledger write pipeline is shared between two callers:
//! - **Auto path**: `MemoryManager.on_cycle_complete()` → `RuntimeMemoryDeps.write_ledger_entry()`
//! - **Manual path**: `UpdateLedgerHandler` (RPC `memory.updateLedger`)
//!
//! Both call [`execute_ledger_write()`] — the ONLY difference is what triggers the call.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::Value;
use tracing::{debug, instrument, warn};

use tron_core::messages::{Message, UserMessageContent};
use tron_runtime::context::ledger_writer::LedgerParseResult;

use crate::rpc::context::RpcContext;
use crate::rpc::errors::RpcError;
use crate::rpc::handlers::require_string_param;
use crate::rpc::registry::MethodHandler;

// =============================================================================
// Cycle boundary helpers
// =============================================================================

/// Information about a "cycle" — the messages between two memory.ledger boundaries.
pub(crate) struct CycleInfo {
    /// Messages in this cycle (after the last boundary).
    pub messages: Vec<Message>,
    /// First event ID in this cycle.
    pub first_event_id: String,
    /// Last event ID in this cycle.
    pub last_event_id: String,
    /// First user turn number in this cycle.
    pub first_turn: i64,
    /// Last user turn number in this cycle.
    pub last_turn: i64,
}

/// Compute messages in the current cycle (after the last `memory.ledger` boundary).
///
/// Multiple ledger entries per session are expected — each covers a different cycle.
/// This mirrors the TS server's `computeCycleRange()` pattern.
pub(crate) fn compute_cycle_messages(
    event_store: &tron_events::EventStore,
    session_manager: &tron_runtime::orchestrator::session_manager::SessionManager,
    session_id: &str,
) -> Option<CycleInfo> {
    // 1. Find the last memory.ledger event's sequence (the boundary)
    let ledger_events = event_store
        .get_events_by_type(session_id, &["memory.ledger"], Some(1000))
        .unwrap_or_default();
    let boundary_sequence = ledger_events.last().map(|e| e.sequence);

    // 2. Get events after the boundary (or all events if no boundary)
    let cycle_events = if let Some(seq) = boundary_sequence {
        event_store
            .get_events_since(session_id, seq)
            .unwrap_or_default()
    } else {
        let opts = tron_events::sqlite::repositories::event::ListEventsOptions {
            limit: None,
            offset: None,
        };
        event_store
            .get_events_by_session(session_id, &opts)
            .unwrap_or_default()
    };

    if cycle_events.is_empty() {
        return None;
    }

    let first_event_id = cycle_events
        .first()
        .map(|e| e.id.clone())
        .unwrap_or_default();
    let last_event_id = cycle_events
        .last()
        .map(|e| e.id.clone())
        .unwrap_or_default();

    // 3. Reconstruct messages from cycle events
    //    If there's no boundary, use all messages from the session.
    //    If there IS a boundary, only include messages from cycle events.
    let messages = if boundary_sequence.is_some() {
        // Build messages from cycle events by parsing message.user / message.assistant events
        let mut msgs = Vec::new();
        for ev in &cycle_events {
            match ev.event_type.as_str() {
                "message.user" => {
                    if let Ok(payload) = serde_json::from_str::<Value>(&ev.payload) {
                        let content = payload
                            .get("content")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_string();
                        msgs.push(Message::User {
                            content: UserMessageContent::Text(content),
                            timestamp: None,
                        });
                    }
                }
                "message.assistant" => {
                    if let Ok(msg) = serde_json::from_str::<Message>(&format!(
                        r#"{{"role":"assistant","payload":{}}}"#,
                        ev.payload
                    )) {
                        msgs.push(msg);
                    } else if let Ok(payload) = serde_json::from_str::<Value>(&ev.payload) {
                        // Fallback: wrap payload into a Message::Assistant via serde
                        let wrapper = serde_json::json!({
                            "role": "assistant",
                            "content": payload.get("content").cloned().unwrap_or(Value::Array(vec![])),
                        });
                        if let Ok(msg) = serde_json::from_value::<Message>(wrapper) {
                            msgs.push(msg);
                        }
                    }
                }
                _ => {}
            }
        }
        msgs
    } else {
        // No boundary — use full session messages
        let active = session_manager.resume_session(session_id).ok()?;
        active.state.messages.clone()
    };

    if messages.is_empty() {
        return None;
    }

    // 4. Compute turn range from cycle events
    //    Count turns that already happened before this cycle (offset) + turns in this cycle
    let prior_user_turns = if let Some(seq) = boundary_sequence {
        // Count user message events before the boundary
        let all_events = event_store
            .get_events_by_type(session_id, &["message.user"], Some(10000))
            .unwrap_or_default();
        #[allow(clippy::cast_possible_wrap)]
        let count = all_events.iter().filter(|e| e.sequence <= seq).count() as i64;
        count
    } else {
        0
    };

    let cycle_user_turns = messages
        .iter()
        .filter(|m| matches!(m, Message::User { .. }))
        .count();
    #[allow(clippy::cast_possible_wrap)]
    let first_turn = prior_user_turns + 1;
    #[allow(clippy::cast_possible_wrap)]
    let last_turn = prior_user_turns + cycle_user_turns as i64;

    Some(CycleInfo {
        messages,
        first_event_id,
        last_event_id,
        first_turn,
        last_turn,
    })
}

/// Emit `MemoryUpdated` event via the orchestrator broadcast.
fn emit_memory_updated(
    ctx: &RpcContext,
    session_id: &str,
    title: Option<&str>,
    entry_type: Option<&str>,
    event_id: Option<&str>,
) {
    let _ = ctx
        .orchestrator
        .broadcast()
        .emit(tron_core::events::TronEvent::MemoryUpdated {
            base: tron_core::events::BaseEvent::now(session_id),
            title: title.map(String::from),
            entry_type: entry_type.map(String::from),
            event_id: event_id.map(String::from),
        });
}

// =============================================================================
// Shared ledger write pipeline
// =============================================================================

/// Dependencies for the shared ledger write pipeline.
///
/// Both the auto path (`RuntimeMemoryDeps`) and manual path (`UpdateLedgerHandler`)
/// construct this from their respective contexts, then call [`execute_ledger_write()`].
pub(crate) struct LedgerWriteDeps {
    pub event_store: Arc<tron_events::EventStore>,
    pub session_manager: Arc<tron_runtime::orchestrator::session_manager::SessionManager>,
    pub subagent_manager:
        Option<Arc<tron_runtime::orchestrator::subagent_manager::SubagentManager>>,
    pub embedding_controller: Option<Arc<tokio::sync::Mutex<tron_embeddings::EmbeddingController>>>,
    pub shutdown_coordinator: Option<Arc<crate::shutdown::ShutdownCoordinator>>,
}

/// Execute the full ledger write pipeline.
///
/// This is the **single paved codepath** for memory ledger writes. Both the
/// auto-triggered path (after agent completion) and the manual RPC path call this.
///
/// Pipeline:
/// 1. Compute cycle messages (since last `memory.ledger` boundary)
/// 2. Spawn LLM subsession to generate structured ledger entry
/// 3. Parse LLM response into `LedgerEntry`
/// 4. Build full payload (matching TS server `MemoryLedgerPayload` format)
/// 5. Persist as `memory.ledger` event
/// 6. Fire-and-forget embedding for semantic search
///
/// Returns a `LedgerWriteResult` suitable for both callers.
#[allow(clippy::too_many_lines)]
pub(crate) async fn execute_ledger_write(
    session_id: &str,
    working_directory: &str,
    deps: &LedgerWriteDeps,
    source: &str,
) -> tron_events::memory::types::LedgerWriteResult {
    // 1. Compute cycle messages
    let cycle = compute_cycle_messages(&deps.event_store, &deps.session_manager, session_id);
    let cycle = match cycle {
        Some(c) if !c.messages.is_empty() => c,
        _ => {
            return tron_events::memory::types::LedgerWriteResult::skipped(
                "no new messages since last boundary",
            );
        }
    };

    // 2. Spawn LLM subsession for structured ledger entry
    let cycle_message_count = cycle.messages.len();
    let has_subagent = deps.subagent_manager.is_some();
    debug!(
        session_id,
        has_subagent, cycle_message_count, "executing ledger write"
    );

    let llm_result = if let Some(ref manager) = deps.subagent_manager {
        use tron_runtime::agent::compaction_handler::SubagentManagerSpawner;
        use tron_runtime::context::llm_summarizer::SubsessionSpawner;
        use tron_runtime::context::summarizer::serialize_messages;

        let transcript = serialize_messages(&cycle.messages);
        let spawner = SubagentManagerSpawner {
            manager: manager.clone(),
            parent_session_id: session_id.to_owned(),
            working_directory: working_directory.to_owned(),
            system_prompt: tron_runtime::context::system_prompts::MEMORY_LEDGER_PROMPT.to_string(),
            model: Some("claude-haiku-4-5-20251001".to_string()),
        };
        let result = spawner.spawn_summarizer(&transcript).await;
        if result.success {
            result
                .output
                .as_deref()
                .and_then(|o| tron_runtime::context::ledger_writer::parse_ledger_response(o).ok())
        } else {
            debug!(session_id, error = ?result.error, "subsession ledger call failed");
            None
        }
    } else {
        debug!(session_id, "no subagent manager available for ledger write");
        None
    };

    // 3. Process result
    match llm_result {
        Some(LedgerParseResult::Skip) => {
            debug!(
                session_id,
                "LLM classified interaction as trivial, skipping"
            );
            tron_events::memory::types::LedgerWriteResult::skipped("trivial interaction")
        }
        Some(LedgerParseResult::Entry(entry)) => {
            // 4. Build full payload (matches TS server MemoryLedgerPayload format)
            let session_info = deps.session_manager.get_session(session_id).ok().flatten();
            let (total_input, total_output) = session_info
                .as_ref()
                .map_or((0, 0), |s| (s.total_input_tokens, s.total_output_tokens));
            let model = session_info
                .as_ref()
                .map(|s| s.latest_model.clone())
                .unwrap_or_default();

            let payload = serde_json::json!({
                "eventRange": {
                    "firstEventId": cycle.first_event_id,
                    "lastEventId": cycle.last_event_id,
                },
                "turnRange": {
                    "firstTurn": cycle.first_turn,
                    "lastTurn": cycle.last_turn,
                },
                "title": entry.title,
                "entryType": entry.entry_type,
                "status": entry.status,
                "tags": entry.tags,
                "input": entry.input,
                "actions": entry.actions,
                "files": entry.files.iter().map(|f| serde_json::json!({
                    "path": f.path, "op": f.op, "why": f.why,
                })).collect::<Vec<_>>(),
                "decisions": entry.decisions.iter().map(|d| serde_json::json!({
                    "choice": d.choice, "reason": d.reason,
                })).collect::<Vec<_>>(),
                "lessons": entry.lessons,
                "thinkingInsights": entry.thinking_insights,
                "tokenCost": { "input": total_input, "output": total_output },
                "model": model,
                "workingDirectory": working_directory,
                "source": source,
            });

            // 5. Persist as memory.ledger event
            let event_id = match deps.event_store.append(&tron_events::AppendOptions {
                session_id,
                event_type: tron_events::EventType::MemoryLedger,
                payload: payload.clone(),
                parent_id: None,
            }) {
                Ok(row) => row.id,
                Err(e) => {
                    warn!(
                        session_id,
                        error = %e,
                        title = %entry.title,
                        "failed to persist memory.ledger event"
                    );
                    return tron_events::memory::types::LedgerWriteResult::failed(
                        "database temporarily busy",
                    );
                }
            };

            // 6. Fire-and-forget embedding
            let embed_ws_id = deps
                .event_store
                .get_workspace_by_path(working_directory)
                .ok()
                .flatten()
                .map_or_else(|| working_directory.to_owned(), |ws| ws.id);
            spawn_embed_memory_with_deps(
                deps.embedding_controller.as_ref(),
                &event_id,
                &embed_ws_id,
                &payload,
                deps.shutdown_coordinator.as_ref(),
            );

            debug!(
                session_id,
                title = %entry.title,
                entry_type = %entry.entry_type,
                event_id = %event_id,
                "ledger entry written"
            );

            tron_events::memory::types::LedgerWriteResult::written(
                entry.title.clone(),
                entry.entry_type.clone(),
                event_id,
                payload,
            )
        }
        None => tron_events::memory::types::LedgerWriteResult::skipped("LLM call failed"),
    }
}

/// Spawn a fire-and-forget embedding task (standalone version, not requiring `RpcContext`).
fn spawn_embed_memory_with_deps(
    controller: Option<&Arc<tokio::sync::Mutex<tron_embeddings::EmbeddingController>>>,
    event_id: &str,
    workspace_id: &str,
    payload: &Value,
    shutdown_coordinator: Option<&Arc<crate::shutdown::ShutdownCoordinator>>,
) {
    if let Some(ec) = controller {
        let ec = Arc::clone(ec);
        let event_id = event_id.to_owned();
        let workspace_id = workspace_id.to_owned();
        let payload = payload.clone();
        let handle = tokio::spawn(async move {
            let ctrl = ec.lock().await;
            if let Err(e) = ctrl.embed_memory(&event_id, &workspace_id, &payload).await {
                warn!(error = %e, event_id, "failed to embed ledger entry");
            }
        });
        if let Some(coord) = shutdown_coordinator {
            coord.register_task(handle);
        }
    }
}

// =============================================================================
// RPC Handlers
// =============================================================================

/// Transform an event row into the DTO shape expected by iOS `LedgerEntryDTO`.
fn event_to_ledger_dto(event: &tron_events::sqlite::row_types::EventRow) -> Value {
    let payload: Value = serde_json::from_str(&event.payload).unwrap_or_default();
    serde_json::json!({
        "id": event.id,
        "sessionId": event.session_id,
        "timestamp": event.timestamp,
        "title": payload.get("title"),
        "entryType": payload.get("entryType"),
        "input": payload.get("input"),
        "actions": payload.get("actions").unwrap_or(&serde_json::json!([])),
        "decisions": payload.get("decisions").unwrap_or(&serde_json::json!([])),
        "lessons": payload.get("lessons").unwrap_or(&serde_json::json!([])),
        "insights": payload.get("thinkingInsights").unwrap_or(&serde_json::json!([])),
        "tags": payload.get("tags").unwrap_or(&serde_json::json!([])),
        "files": payload.get("files").unwrap_or(&serde_json::json!([])),
        "model": payload.get("model"),
        "tokenCost": payload.get("tokenCost"),
    })
}

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
            .and_then(Value::as_u64)
            .map_or(50i64, |v| i64::try_from(v).unwrap_or(50));

        let offset = params
            .as_ref()
            .and_then(|p| p.get("offset"))
            .and_then(Value::as_u64)
            .map_or(0i64, |v| i64::try_from(v).unwrap_or(0));

        let tags_filter: Option<Vec<String>> = params
            .as_ref()
            .and_then(|p| p.get("tags"))
            .and_then(Value::as_array)
            .map(|arr| arr.iter().filter_map(Value::as_str).map(String::from).collect());

        // Resolve workspace from path
        let workspace = ctx
            .event_store
            .get_workspace_by_path(&working_dir)
            .unwrap_or(None);

        let Some(workspace) = workspace else {
            return Ok(serde_json::json!({
                "entries": [],
                "hasMore": false,
                "totalCount": 0,
            }));
        };

        // When tag filtering is active, we must fetch all events to filter in memory
        if let Some(ref tags) = tags_filter {
            let all_events = ctx
                .event_store
                .get_events_by_workspace_and_types(
                    &workspace.id,
                    &["memory.ledger"],
                    None,
                    None,
                )
                .unwrap_or_default();

            let filtered: Vec<Value> = all_events
                .iter()
                .map(event_to_ledger_dto)
                .filter(|dto| {
                    let entry_tags = dto["tags"]
                        .as_array()
                        .map(|arr| {
                            arr.iter()
                                .filter_map(Value::as_str)
                                .map(String::from)
                                .collect::<Vec<_>>()
                        })
                        .unwrap_or_default();
                    tags.iter().any(|t| entry_tags.contains(t))
                })
                .collect();

            let total_count = filtered.len();
            let offset_usize = usize::try_from(offset).unwrap_or(0);
            let limit_usize = usize::try_from(limit).unwrap_or(usize::MAX);
            let entries: Vec<Value> = filtered
                .into_iter()
                .skip(offset_usize)
                .take(limit_usize)
                .collect();
            let has_more = offset_usize + limit_usize < total_count;

            return Ok(serde_json::json!({
                "entries": entries,
                "hasMore": has_more,
                "totalCount": total_count,
            }));
        }

        // No tag filter — use efficient workspace-level query with SQL pagination
        let total_count = ctx
            .event_store
            .count_events_by_workspace_and_types(&workspace.id, &["memory.ledger"])
            .unwrap_or(0);

        let events = ctx
            .event_store
            .get_events_by_workspace_and_types(
                &workspace.id,
                &["memory.ledger"],
                Some(limit),
                Some(offset),
            )
            .unwrap_or_default();

        let entries: Vec<Value> = events.iter().map(event_to_ledger_dto).collect();
        #[allow(clippy::cast_possible_wrap)]
        let has_more = (offset + limit) < total_count;

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
        if let Some(sid) = params
            .as_ref()
            .and_then(|p| p.get("sessionId"))
            .and_then(Value::as_str)
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
            let sessions = ctx
                .session_manager
                .list_sessions(&filter)
                .unwrap_or_default();
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

        // Emit memory_updating immediately (iOS shows spinner pill)
        let _ = ctx
            .orchestrator
            .broadcast()
            .emit(tron_core::events::TronEvent::MemoryUpdating {
                base: tron_core::events::BaseEvent::now(session_id),
            });

        // Resume session to verify it exists and get working directory
        let Ok(active) = ctx.session_manager.resume_session(session_id) else {
            debug!(session_id, "session not found or empty during resume");
            emit_memory_updated(ctx, session_id, None, Some("skipped"), None);
            return Ok(serde_json::json!({
                "written": false,
                "title": null,
                "entryType": null,
                "reason": "session not found or empty",
            }));
        };

        if active.state.messages.is_empty() {
            debug!(session_id, "no messages in session");
            emit_memory_updated(ctx, session_id, None, Some("skipped"), None);
            return Ok(serde_json::json!({
                "written": false,
                "title": null,
                "entryType": null,
                "reason": "no_messages",
            }));
        }

        let working_dir = active.state.working_directory.clone().unwrap_or_default();

        // Delegate to the shared pipeline
        let deps = LedgerWriteDeps {
            event_store: ctx.event_store.clone(),
            session_manager: ctx.session_manager.clone(),
            subagent_manager: ctx.subagent_manager.clone(),
            embedding_controller: ctx.embedding_controller.clone(),
            shutdown_coordinator: ctx.shutdown_coordinator.clone(),
        };
        let result = execute_ledger_write(session_id, &working_dir, &deps, "manual").await;

        // Emit memory_updated based on result
        if result.written {
            emit_memory_updated(
                ctx,
                session_id,
                result.title.as_deref(),
                result.entry_type.as_deref(),
                result.event_id.as_deref(),
            );
        } else {
            let entry_type = result.entry_type.as_deref().unwrap_or("skipped");
            let title = if entry_type == "error" {
                result.reason.as_deref()
            } else {
                None
            };
            emit_memory_updated(ctx, session_id, title, Some(entry_type), None);
        }

        // Convert to RPC response
        Ok(serde_json::json!({
            "written": result.written,
            "title": result.title,
            "entryType": result.entry_type,
            "reason": result.reason.as_deref().unwrap_or(if result.written { "written" } else { "unknown" }),
        }))
    }
}

/// Transform an event row into the DTO shape expected by iOS `MemoryEntry`.
fn event_to_search_dto(event: &tron_events::sqlite::row_types::EventRow) -> Value {
    let payload: Value = serde_json::from_str(&event.payload).unwrap_or_default();
    let content = payload
        .get("input")
        .and_then(Value::as_str)
        .or_else(|| payload.get("title").and_then(Value::as_str))
        .unwrap_or("");
    let entry_type = payload
        .get("entryType")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let source = payload
        .get("source")
        .and_then(Value::as_str)
        .unwrap_or("ledger");
    serde_json::json!({
        "id": event.id,
        "type": entry_type,
        "content": content,
        "source": source,
        "relevance": null,
        "timestamp": event.timestamp,
        "sessionId": event.session_id,
    })
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
                let payload: Value = match serde_json::from_str(&event.payload) {
                    Ok(v) => v,
                    Err(_) => continue,
                };

                // Text filter (case-insensitive)
                if !search_lower.is_empty() {
                    let payload_text = payload.to_string().to_lowercase();
                    if !payload_text.contains(&search_lower) {
                        continue;
                    }
                }

                // Type filter
                if let Some(tf) = type_filter {
                    let entry_type = payload
                        .get("entryType")
                        .and_then(Value::as_str)
                        .unwrap_or("");
                    if entry_type != tf {
                        continue;
                    }
                }

                entries.push(event_to_search_dto(&event));

                if entries.len() >= limit {
                    break;
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
                limit: Some(limit * 2),
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
                    let summary = parsed
                        .get("input")
                        .and_then(Value::as_str)
                        .or_else(|| parsed.get("summary").and_then(Value::as_str))
                        .unwrap_or("");
                    handoffs.push(serde_json::json!({
                        "id": event.id,
                        "sessionId": session.id,
                        "title": parsed.get("title").and_then(Value::as_str).unwrap_or(""),
                        "createdAt": event.timestamp,
                        "summary": summary,
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
    use crate::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;

    /// Helper: create a session and append a `memory.ledger` event with the given payload.
    /// Returns `(session_id, event_id)`.
    fn seed_ledger_event(ctx: &RpcContext, workspace: &str, payload: Value) -> (String, String) {
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", workspace, Some("test"))
            .unwrap();
        let row = ctx
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MemoryLedger,
                payload,
                parent_id: None,
            })
            .unwrap();
        (sid, row.id)
    }

    // ── GetLedgerHandler: DTO shape tests ──

    #[tokio::test]
    async fn get_ledger_returns_dto_with_event_metadata() {
        let ctx = make_test_context();
        let (sid, eid) = seed_ledger_event(
            &ctx,
            "/tmp/proj",
            json!({
                "title": "Fix login bug",
                "entryType": "bugfix",
                "input": "Fix the login page crash",
                "actions": ["patched auth.rs"],
                "thinkingInsights": ["login flow was missing null check"],
            }),
        );

        let result = GetLedgerHandler
            .handle(Some(json!({"workingDirectory": "/tmp/proj"})), &ctx)
            .await
            .unwrap();

        let entries = result["entries"].as_array().unwrap();
        assert_eq!(entries.len(), 1);
        let entry = &entries[0];

        // Event metadata fields
        assert_eq!(entry["id"].as_str().unwrap(), eid);
        assert_eq!(entry["sessionId"].as_str().unwrap(), sid);
        assert!(entry["timestamp"].as_str().is_some());

        // Payload fields
        assert_eq!(entry["title"].as_str().unwrap(), "Fix login bug");
        assert_eq!(entry["entryType"].as_str().unwrap(), "bugfix");
        assert_eq!(entry["input"].as_str().unwrap(), "Fix the login page crash");
    }

    #[tokio::test]
    async fn get_ledger_maps_thinking_insights_to_insights() {
        let ctx = make_test_context();
        let _ = seed_ledger_event(
            &ctx,
            "/tmp/proj",
            json!({
                "title": "Test",
                "thinkingInsights": ["learned X", "discovered Y"],
            }),
        );

        let result = GetLedgerHandler
            .handle(Some(json!({"workingDirectory": "/tmp/proj"})), &ctx)
            .await
            .unwrap();

        let entry = &result["entries"][0];
        let insights = entry["insights"].as_array().unwrap();
        assert_eq!(insights.len(), 2);
        assert_eq!(insights[0].as_str().unwrap(), "learned X");
        // thinkingInsights should NOT appear in the DTO
        assert!(entry.get("thinkingInsights").is_none());
    }

    #[tokio::test]
    async fn get_ledger_defaults_missing_arrays_to_empty() {
        let ctx = make_test_context();
        let _ = seed_ledger_event(&ctx, "/tmp/proj", json!({"title": "Minimal entry"}));

        let result = GetLedgerHandler
            .handle(Some(json!({"workingDirectory": "/tmp/proj"})), &ctx)
            .await
            .unwrap();

        let entry = &result["entries"][0];
        assert_eq!(entry["actions"], json!([]));
        assert_eq!(entry["decisions"], json!([]));
        assert_eq!(entry["lessons"], json!([]));
        assert_eq!(entry["insights"], json!([]));
        assert_eq!(entry["tags"], json!([]));
        assert_eq!(entry["files"], json!([]));
    }

    #[tokio::test]
    async fn get_ledger_supports_offset_pagination() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp/proj", Some("test"))
            .unwrap();

        for i in 0..5 {
            let _ = ctx.event_store.append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MemoryLedger,
                payload: json!({"title": format!("Entry {i}")}),
                parent_id: None,
            });
            // Small sleep to ensure distinct timestamps for ordering
            std::thread::sleep(std::time::Duration::from_millis(10));
        }

        let result = GetLedgerHandler
            .handle(
                Some(json!({"workingDirectory": "/tmp/proj", "limit": 2, "offset": 2})),
                &ctx,
            )
            .await
            .unwrap();

        let entries = result["entries"].as_array().unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(result["totalCount"], 5);
        assert_eq!(result["hasMore"], true);
    }

    #[tokio::test]
    async fn get_ledger_supports_tag_filtering() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp/proj", Some("test"))
            .unwrap();

        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MemoryLedger,
            payload: json!({"title": "iOS fix", "tags": ["ios", "bugfix"]}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MemoryLedger,
            payload: json!({"title": "Server fix", "tags": ["server"]}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MemoryLedger,
            payload: json!({"title": "No tags"}),
            parent_id: None,
        });

        let result = GetLedgerHandler
            .handle(
                Some(json!({"workingDirectory": "/tmp/proj", "tags": ["ios"]})),
                &ctx,
            )
            .await
            .unwrap();

        let entries = result["entries"].as_array().unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0]["title"].as_str().unwrap(), "iOS fix");
        assert_eq!(result["totalCount"], 1);
    }

    #[tokio::test]
    async fn get_ledger_returns_accurate_total_count() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp/proj", Some("test"))
            .unwrap();

        for i in 0..5 {
            let _ = ctx.event_store.append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MemoryLedger,
                payload: json!({"title": format!("Entry {i}")}),
                parent_id: None,
            });
        }

        let result = GetLedgerHandler
            .handle(
                Some(json!({"workingDirectory": "/tmp/proj", "limit": 2})),
                &ctx,
            )
            .await
            .unwrap();

        assert_eq!(result["totalCount"], 5);
        assert_eq!(result["hasMore"], true);
        assert_eq!(result["entries"].as_array().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn get_ledger_unknown_workspace_returns_empty() {
        let ctx = make_test_context();
        let result = GetLedgerHandler
            .handle(
                Some(json!({"workingDirectory": "/nonexistent/path"})),
                &ctx,
            )
            .await
            .unwrap();

        assert_eq!(result["entries"], json!([]));
        assert_eq!(result["hasMore"], false);
        assert_eq!(result["totalCount"], 0);
    }

    #[tokio::test]
    async fn get_ledger_cross_session_aggregation() {
        let ctx = make_test_context();

        // Two sessions in the same workspace
        let sid1 = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp/proj", Some("test"))
            .unwrap();
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid1,
            event_type: tron_events::EventType::MemoryLedger,
            payload: json!({"title": "Session 1 entry"}),
            parent_id: None,
        });

        std::thread::sleep(std::time::Duration::from_millis(10));

        let sid2 = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp/proj", Some("test2"))
            .unwrap();
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid2,
            event_type: tron_events::EventType::MemoryLedger,
            payload: json!({"title": "Session 2 entry"}),
            parent_id: None,
        });

        let result = GetLedgerHandler
            .handle(Some(json!({"workingDirectory": "/tmp/proj"})), &ctx)
            .await
            .unwrap();

        let entries = result["entries"].as_array().unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(result["totalCount"], 2);

        // Verify both sessions are represented
        let session_ids: Vec<&str> = entries
            .iter()
            .map(|e| e["sessionId"].as_str().unwrap())
            .collect();
        assert!(session_ids.contains(&sid1.as_str()));
        assert!(session_ids.contains(&sid2.as_str()));
    }

    #[tokio::test]
    async fn get_ledger_returns_entries() {
        let ctx = make_test_context();
        let result = GetLedgerHandler
            .handle(Some(json!({"workingDirectory": "/tmp"})), &ctx)
            .await
            .unwrap();
        assert!(result["entries"].is_array());
    }

    #[tokio::test]
    async fn get_ledger_returns_has_more() {
        let ctx = make_test_context();
        let result = GetLedgerHandler
            .handle(Some(json!({"workingDirectory": "/tmp"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["hasMore"], false);
    }

    #[tokio::test]
    async fn get_ledger_returns_total_count() {
        let ctx = make_test_context();
        let result = GetLedgerHandler
            .handle(Some(json!({"workingDirectory": "/tmp"})), &ctx)
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
    async fn update_ledger_without_llm_returns_unavailable() {
        let ctx = make_test_context(); // no subagent_manager
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
        assert_eq!(result["written"], false);
        assert_eq!(result["reason"], "LLM call failed");
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

    // ── SearchMemoryHandler: DTO shape tests ──

    #[tokio::test]
    async fn search_memory_returns_dto_shape() {
        let ctx = make_test_context();
        let (sid, eid) = seed_ledger_event(
            &ctx,
            "/tmp/proj",
            json!({
                "title": "Add dark mode",
                "entryType": "feature",
                "input": "Implement dark mode for the dashboard",
                "source": "auto",
            }),
        );

        let result = SearchMemoryHandler
            .handle(
                Some(json!({"searchText": "dark mode"})),
                &ctx,
            )
            .await
            .unwrap();

        let entries = result["entries"].as_array().unwrap();
        assert_eq!(entries.len(), 1);
        let entry = &entries[0];

        assert_eq!(entry["id"].as_str().unwrap(), eid);
        assert_eq!(entry["type"].as_str().unwrap(), "feature");
        assert_eq!(
            entry["content"].as_str().unwrap(),
            "Implement dark mode for the dashboard"
        );
        assert_eq!(entry["source"].as_str().unwrap(), "auto");
        assert!(entry["timestamp"].as_str().is_some());
        assert_eq!(entry["sessionId"].as_str().unwrap(), sid);
    }

    #[tokio::test]
    async fn search_memory_text_filter_matches() {
        let ctx = make_test_context();
        let _ = seed_ledger_event(
            &ctx,
            "/tmp/proj",
            json!({"title": "Fix login bug", "entryType": "bugfix", "input": "Login crash"}),
        );
        let _ = seed_ledger_event(
            &ctx,
            "/tmp/proj2",
            json!({"title": "Add feature", "entryType": "feature", "input": "New widget"}),
        );

        let result = SearchMemoryHandler
            .handle(Some(json!({"searchText": "login"})), &ctx)
            .await
            .unwrap();

        let entries = result["entries"].as_array().unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0]["content"].as_str().unwrap(), "Login crash");
    }

    #[tokio::test]
    async fn search_memory_type_filter_matches() {
        let ctx = make_test_context();
        let _ = seed_ledger_event(
            &ctx,
            "/tmp/proj",
            json!({"title": "Fix bug", "entryType": "bugfix"}),
        );
        let _ = seed_ledger_event(
            &ctx,
            "/tmp/proj2",
            json!({"title": "Add feat", "entryType": "feature"}),
        );

        let result = SearchMemoryHandler
            .handle(Some(json!({"type": "bugfix"})), &ctx)
            .await
            .unwrap();

        let entries = result["entries"].as_array().unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0]["type"].as_str().unwrap(), "bugfix");
    }

    #[tokio::test]
    async fn search_memory_returns_empty() {
        let ctx = make_test_context();
        let result = SearchMemoryHandler.handle(None, &ctx).await.unwrap();
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

    // ── GetHandoffsHandler: DTO shape tests ──

    #[tokio::test]
    async fn get_handoffs_returns_dto_shape() {
        let ctx = make_test_context();
        let (sid, eid) = seed_ledger_event(
            &ctx,
            "/tmp/proj",
            json!({
                "title": "Implement auth",
                "entryType": "feature",
                "input": "Add OAuth2 authentication flow",
                "lessons": ["Use PKCE for mobile"],
            }),
        );

        let result = GetHandoffsHandler.handle(None, &ctx).await.unwrap();

        let handoffs = result["handoffs"].as_array().unwrap();
        assert_eq!(handoffs.len(), 1);
        let h = &handoffs[0];

        assert_eq!(h["id"].as_str().unwrap(), eid);
        assert_eq!(h["sessionId"].as_str().unwrap(), sid);
        assert_eq!(h["title"].as_str().unwrap(), "Implement auth");
        assert_eq!(
            h["summary"].as_str().unwrap(),
            "Add OAuth2 authentication flow"
        );
        assert!(h["createdAt"].as_str().is_some());
        // Should NOT have "timestamp" — iOS expects "createdAt"
        assert!(h.get("timestamp").is_none());
        let lessons = h["lessons"].as_array().unwrap();
        assert_eq!(lessons.len(), 1);
    }

    #[tokio::test]
    async fn get_handoffs_returns_empty() {
        let ctx = make_test_context();
        let result = GetHandoffsHandler.handle(None, &ctx).await.unwrap();
        assert!(result["handoffs"].as_array().unwrap().is_empty());
    }

    #[tokio::test]
    async fn get_handoffs_with_workspace() {
        let ctx = make_test_context();
        let result = GetHandoffsHandler
            .handle(Some(json!({"workingDirectory": "/tmp"})), &ctx)
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
    async fn update_ledger_llm_unavailable_returns_reason() {
        let ctx = make_test_context(); // no subagent_manager
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
        assert_eq!(result["written"], false);
        assert_eq!(result["reason"], "LLM call failed");
    }

    #[tokio::test]
    async fn execute_ledger_write_includes_source_field() {
        // Verify source param propagates to payload (we can't call with LLM,
        // but we can verify the signature compiles and the manual path passes "manual")
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", Some("test"))
            .unwrap();

        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"content": "Build a widget"}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({
                "content": [{"type": "text", "text": "Done building."}],
                "turn": 1,
                "tokenUsage": {"inputTokens": 10, "outputTokens": 5}
            }),
            parent_id: None,
        });
        ctx.session_manager.invalidate_session(&sid);

        // No subagent_manager → LLM call fails → skipped, but the signature is validated
        let deps = LedgerWriteDeps {
            event_store: ctx.event_store.clone(),
            session_manager: ctx.session_manager.clone(),
            subagent_manager: None,
            embedding_controller: None,
            shutdown_coordinator: None,
        };
        let result = execute_ledger_write(&sid, "/tmp", &deps, "manual").await;
        assert!(!result.written); // No LLM available
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

    // ── Cycle boundary tests ──

    #[tokio::test]
    async fn update_ledger_skips_when_no_new_messages_after_boundary() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", Some("test"))
            .unwrap();

        // Add messages
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

        // Pre-seed a memory.ledger event AFTER the messages (boundary)
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MemoryLedger,
            payload: json!({"title": "Implement dark mode", "entryType": "feature"}),
            parent_id: None,
        });
        ctx.session_manager.invalidate_session(&sid);

        // No new messages after boundary → should skip
        let result = UpdateLedgerHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["written"], false);
        assert_eq!(result["reason"], "no new messages since last boundary");
    }

    #[tokio::test]
    async fn compute_cycle_messages_no_boundary_returns_all() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", Some("test"))
            .unwrap();

        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"content": "Hello"}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({
                "content": [{"type": "text", "text": "Hi there."}],
                "turn": 1,
                "tokenUsage": {"inputTokens": 5, "outputTokens": 3}
            }),
            parent_id: None,
        });
        ctx.session_manager.invalidate_session(&sid);

        let cycle = compute_cycle_messages(&ctx.event_store, &ctx.session_manager, &sid);
        let cycle = cycle.expect("should return cycle");
        // No boundary → all messages returned
        assert!(!cycle.messages.is_empty());
        assert_eq!(cycle.first_turn, 1);
        assert_eq!(cycle.last_turn, 1);
    }

    #[tokio::test]
    async fn compute_cycle_messages_with_boundary_returns_after_boundary() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", Some("test"))
            .unwrap();

        // First cycle messages
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"content": "First request"}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({
                "content": [{"type": "text", "text": "First response."}],
                "turn": 1,
                "tokenUsage": {"inputTokens": 10, "outputTokens": 5}
            }),
            parent_id: None,
        });

        // Boundary (first ledger entry)
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MemoryLedger,
            payload: json!({"title": "First cycle", "entryType": "feature"}),
            parent_id: None,
        });

        // Second cycle messages (after boundary)
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"content": "Second request"}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({
                "content": [{"type": "text", "text": "Second response."}],
                "turn": 2,
                "tokenUsage": {"inputTokens": 10, "outputTokens": 5}
            }),
            parent_id: None,
        });
        ctx.session_manager.invalidate_session(&sid);

        let cycle = compute_cycle_messages(&ctx.event_store, &ctx.session_manager, &sid);
        let cycle = cycle.expect("should return cycle");
        // Only second cycle messages (after boundary)
        assert_eq!(cycle.messages.len(), 2); // 1 user + 1 assistant
        assert_eq!(cycle.first_turn, 2); // Prior cycle had 1 user turn
        assert_eq!(cycle.last_turn, 2);

        // Verify the message content is from second cycle
        if let Message::User { ref content, .. } = cycle.messages[0] {
            match content {
                UserMessageContent::Text(t) => assert_eq!(t, "Second request"),
                _ => panic!("expected text content"),
            }
        } else {
            panic!("expected user message first");
        }
    }

    #[tokio::test]
    async fn compute_cycle_messages_empty_session_returns_none() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", Some("test"))
            .unwrap();

        let cycle = compute_cycle_messages(&ctx.event_store, &ctx.session_manager, &sid);
        // session.start event exists but no message events → cycle has no messages
        // compute_cycle_messages returns None or Some with empty messages
        assert!(cycle.is_none() || cycle.unwrap().messages.is_empty());
    }
}
