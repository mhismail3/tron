//! Memory handlers: getLedger, updateLedger, search, getHandoffs.
//!
//! The ledger write pipeline is shared between two callers:
//! - **Auto path**: `MemoryManager.on_cycle_complete()` → `RuntimeMemoryDeps.write_ledger_entry()`
//! - **Manual path**: `UpdateLedgerHandler` (RPC `memory.updateLedger`)
//!
//! Both call [`execute_ledger_write()`] — the ONLY difference is what triggers the call.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

#[cfg(test)]
use tron_core::messages::{Message, UserMessageContent};

use crate::rpc::context::RpcContext;
use crate::rpc::errors::RpcError;
use crate::rpc::memory_ledger::{LedgerWriteDeps, execute_ledger_write};
#[cfg(test)]
use crate::rpc::memory_ledger::{
    build_cycle_snapshot as compute_cycle_messages, cron_assistant_text_len,
    prepare_cron_transcript,
};
use crate::rpc::registry::MethodHandler;

use super::{opt_array, opt_string, opt_u64};

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
// RPC Handlers
// =============================================================================

/// Transform an event row into the `LedgerEntryDTO` wire format.
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

/// Get ledger entries, optionally scoped to a workspace.
///
/// When `workingDirectory` is provided, returns entries for that workspace and
/// its children (prefix match). When omitted (or null), returns ALL ledger
/// entries across all workspaces.
pub struct GetLedgerHandler;

#[async_trait]
impl MethodHandler for GetLedgerHandler {
    #[instrument(skip(self, ctx), fields(method = "memory.getLedger"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let working_dir: Option<String> =
            opt_string(params.as_ref(), "workingDirectory").filter(|s| !s.is_empty());

        let limit = i64::try_from(opt_u64(params.as_ref(), "limit", 50)).unwrap_or(50);

        let offset = i64::try_from(opt_u64(params.as_ref(), "offset", 0)).unwrap_or(0);

        let tags_filter: Option<Vec<String>> = opt_array(params.as_ref(), "tags").map(|arr| {
            arr.iter()
                .filter_map(Value::as_str)
                .map(String::from)
                .collect()
        });

        let event_store = ctx.event_store.clone();
        ctx.run_blocking("memory.get_ledger", move || {
            // Fetch raw events — either workspace-scoped or global
            let (all_events_for_tags, count_and_page) = if let Some(ref dir) = working_dir {
                let workspaces = event_store
                    .find_workspaces_by_path_prefix(dir)
                    .unwrap_or_default();

                if workspaces.is_empty() {
                    return Ok(serde_json::json!({
                        "entries": [],
                        "hasMore": false,
                        "totalCount": 0,
                    }));
                }

                let workspace_ids: Vec<&str> = workspaces.iter().map(|w| w.id.as_str()).collect();

                if tags_filter.is_some() {
                    let events = event_store
                        .get_events_by_workspaces_and_types(
                            &workspace_ids,
                            &["memory.ledger"],
                            None,
                            None,
                        )
                        .unwrap_or_default();
                    (Some(events), None)
                } else {
                    let total_count = event_store
                        .count_events_by_workspaces_and_types(&workspace_ids, &["memory.ledger"])
                        .unwrap_or(0);
                    let events = event_store
                        .get_events_by_workspaces_and_types(
                            &workspace_ids,
                            &["memory.ledger"],
                            Some(limit),
                            Some(offset),
                        )
                        .unwrap_or_default();
                    (None, Some((events, total_count)))
                }
            } else if tags_filter.is_some() {
                let events = event_store
                    .get_all_events_by_types(&["memory.ledger"], None, None)
                    .unwrap_or_default();
                (Some(events), None)
            } else {
                let total_count = event_store
                    .count_all_events_by_types(&["memory.ledger"])
                    .unwrap_or(0);
                let events = event_store
                    .get_all_events_by_types(&["memory.ledger"], Some(limit), Some(offset))
                    .unwrap_or_default();
                (None, Some((events, total_count)))
            };

            if let Some(all_events) = all_events_for_tags {
                let tags = tags_filter.as_ref().ok_or_else(|| RpcError::Internal {
                    message: "memory tag filter state was inconsistent".into(),
                })?;
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
                        tags.iter().any(|tag| entry_tags.contains(tag))
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

            let (events, total_count) = count_and_page.ok_or_else(|| RpcError::Internal {
                message: "memory ledger pagination state was inconsistent".into(),
            })?;
            let entries: Vec<Value> = events.iter().map(event_to_ledger_dto).collect();
            #[allow(clippy::cast_possible_wrap)]
            let has_more = (offset + limit) < total_count;

            Ok(serde_json::json!({
                "entries": entries,
                "hasMore": has_more,
                "totalCount": total_count,
            }))
        })
        .await
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
        if let Some(sid) = opt_string(params.as_ref(), "sessionId") {
            session_id_owned = sid;
        } else if let Some(wd) = opt_string(params.as_ref(), "workingDirectory") {
            // Find most recent session for this workspace
            let filter = tron_runtime::SessionFilter {
                workspace_path: Some(wd),
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

        // Emit memory_updating immediately so clients can show a spinner
        let _ = ctx
            .orchestrator
            .broadcast()
            .emit(tron_core::events::TronEvent::MemoryUpdating {
                base: tron_core::events::BaseEvent::now(session_id),
            });

        // Delegate to the shared pipeline
        let deps = LedgerWriteDeps {
            event_store: ctx.event_store.clone(),
            subagent_manager: ctx.subagent_manager.clone(),
            embedding_controller: ctx.embedding_controller.clone(),
            shutdown_coordinator: ctx.shutdown_coordinator.clone(),
        };
        let result = execute_ledger_write(session_id, &deps, "manual").await;

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

/// Transform an event row into the `MemoryEntry` wire format.
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
        let search_text = opt_string(params.as_ref(), "searchText").unwrap_or_default();

        let type_filter = opt_string(params.as_ref(), "type");

        let limit = usize::try_from(opt_u64(params.as_ref(), "limit", 20)).unwrap_or(usize::MAX);

        let event_store = ctx.event_store.clone();
        let session_manager = ctx.session_manager.clone();
        ctx.run_blocking("memory.search", move || {
            let sessions = session_manager
                .list_sessions(&tron_runtime::SessionFilter {
                    include_archived: true,
                    ..Default::default()
                })
                .unwrap_or_default();

            let mut entries = Vec::new();
            let search_lower = search_text.to_lowercase();

            for session in sessions {
                let events = event_store
                    .get_events_by_type(&session.id, &["memory.ledger"], Some(100))
                    .unwrap_or_default();

                for event in events {
                    let payload: Value = match serde_json::from_str(&event.payload) {
                        Ok(value) => value,
                        Err(_) => continue,
                    };

                    if !search_lower.is_empty()
                        && !payload.to_string().to_lowercase().contains(&search_lower)
                    {
                        continue;
                    }

                    if let Some(type_filter) = type_filter.as_deref() {
                        let entry_type = payload
                            .get("entryType")
                            .and_then(Value::as_str)
                            .unwrap_or("");
                        if entry_type != type_filter {
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
        })
        .await
    }
}

/// Get handoff entries for recent sessions.
pub struct GetHandoffsHandler;

#[async_trait]
impl MethodHandler for GetHandoffsHandler {
    #[instrument(skip(self, ctx), fields(method = "memory.getHandoffs"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let limit = usize::try_from(opt_u64(params.as_ref(), "limit", 10)).unwrap_or(usize::MAX);
        let event_store = ctx.event_store.clone();
        let session_manager = ctx.session_manager.clone();
        ctx.run_blocking("memory.get_handoffs", move || {
            let sessions = session_manager
                .list_sessions(&tron_runtime::SessionFilter {
                    include_archived: true,
                    limit: Some(limit * 2),
                    ..Default::default()
                })
                .unwrap_or_default();

            let mut handoffs = Vec::new();

            for session in sessions {
                if let Some(event) = event_store
                    .get_latest_event_by_type(&session.id, "memory.ledger")
                    .unwrap_or_default()
                    && let Ok(parsed) = serde_json::from_str::<Value>(&event.payload)
                {
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

                if handoffs.len() >= limit {
                    break;
                }
            }

            Ok(serde_json::json!({
                "handoffs": handoffs,
            }))
        })
        .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use crate::rpc::memory_ledger::user_message_len;
    use serde_json::json;
    use std::sync::Arc;

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
            .handle(Some(json!({"workingDirectory": "/nonexistent/path"})), &ctx)
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

    // ── Path prefix matching tests ────────────────────────────────

    #[tokio::test]
    async fn get_ledger_includes_child_workspaces() {
        let ctx = make_test_context();
        let _ = seed_ledger_event(&ctx, "/tmp/proj", json!({"title": "Parent entry"}));
        let _ = seed_ledger_event(&ctx, "/tmp/proj/sub", json!({"title": "Child entry"}));

        let result = GetLedgerHandler
            .handle(Some(json!({"workingDirectory": "/tmp/proj"})), &ctx)
            .await
            .unwrap();

        let entries = result["entries"].as_array().unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(result["totalCount"], 2);
    }

    #[tokio::test]
    async fn get_ledger_excludes_unrelated_workspaces() {
        let ctx = make_test_context();
        let _ = seed_ledger_event(&ctx, "/tmp/proj", json!({"title": "Included"}));
        let _ = seed_ledger_event(&ctx, "/tmp/other", json!({"title": "Excluded"}));

        let result = GetLedgerHandler
            .handle(Some(json!({"workingDirectory": "/tmp/proj"})), &ctx)
            .await
            .unwrap();

        let entries = result["entries"].as_array().unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0]["title"].as_str().unwrap(), "Included");
    }

    #[tokio::test]
    async fn get_ledger_prefix_requires_separator() {
        let ctx = make_test_context();
        let _ = seed_ledger_event(&ctx, "/tmp/proj", json!({"title": "Match"}));
        let _ = seed_ledger_event(&ctx, "/tmp/projOther", json!({"title": "No match"}));

        let result = GetLedgerHandler
            .handle(Some(json!({"workingDirectory": "/tmp/proj"})), &ctx)
            .await
            .unwrap();

        let entries = result["entries"].as_array().unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0]["title"].as_str().unwrap(), "Match");
    }

    #[tokio::test]
    async fn get_ledger_parent_prefix() {
        let ctx = make_test_context();
        let _ = seed_ledger_event(&ctx, "/tmp/a/b", json!({"title": "B"}));
        let _ = seed_ledger_event(&ctx, "/tmp/a/c", json!({"title": "C"}));

        let result = GetLedgerHandler
            .handle(Some(json!({"workingDirectory": "/tmp/a"})), &ctx)
            .await
            .unwrap();

        let entries = result["entries"].as_array().unwrap();
        assert_eq!(entries.len(), 2);
        assert_eq!(result["totalCount"], 2);
    }

    #[tokio::test]
    async fn get_ledger_pagination_across_workspaces() {
        let ctx = make_test_context();
        let sid1 = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp/proj", Some("test"))
            .unwrap();
        for i in 0..3 {
            let _ = ctx.event_store.append(&tron_events::AppendOptions {
                session_id: &sid1,
                event_type: tron_events::EventType::MemoryLedger,
                payload: json!({"title": format!("Parent {i}")}),
                parent_id: None,
            });
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        let sid2 = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp/proj/sub", Some("test"))
            .unwrap();
        for i in 0..3 {
            let _ = ctx.event_store.append(&tron_events::AppendOptions {
                session_id: &sid2,
                event_type: tron_events::EventType::MemoryLedger,
                payload: json!({"title": format!("Child {i}")}),
                parent_id: None,
            });
            std::thread::sleep(std::time::Duration::from_millis(10));
        }

        let result = GetLedgerHandler
            .handle(
                Some(json!({"workingDirectory": "/tmp/proj", "limit": 4})),
                &ctx,
            )
            .await
            .unwrap();

        assert_eq!(result["entries"].as_array().unwrap().len(), 4);
        assert_eq!(result["totalCount"], 6);
        assert_eq!(result["hasMore"], true);
    }

    #[tokio::test]
    async fn get_ledger_tag_filter_across_workspaces() {
        let ctx = make_test_context();
        let sid1 = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp/proj", Some("test"))
            .unwrap();
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid1,
            event_type: tron_events::EventType::MemoryLedger,
            payload: json!({"title": "Parent tagged", "tags": ["ios"]}),
            parent_id: None,
        });
        let sid2 = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp/proj/sub", Some("test"))
            .unwrap();
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid2,
            event_type: tron_events::EventType::MemoryLedger,
            payload: json!({"title": "Child tagged", "tags": ["ios"]}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid2,
            event_type: tron_events::EventType::MemoryLedger,
            payload: json!({"title": "Child untagged", "tags": ["server"]}),
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
        assert_eq!(entries.len(), 2);
        assert_eq!(result["totalCount"], 2);
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

    // ── Optional workingDirectory (global query) tests ────────────

    #[tokio::test]
    async fn get_ledger_no_working_dir_returns_all() {
        let ctx = make_test_context();
        let _ = seed_ledger_event(&ctx, "/tmp/a", json!({"title": "Entry A1"}));
        let _ = seed_ledger_event(&ctx, "/tmp/a", json!({"title": "Entry A2"}));
        let _ = seed_ledger_event(&ctx, "/tmp/b", json!({"title": "Entry B1"}));

        let result = GetLedgerHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap();

        assert_eq!(result["entries"].as_array().unwrap().len(), 3);
        assert_eq!(result["totalCount"], 3);
    }

    #[tokio::test]
    async fn get_ledger_null_working_dir_returns_all() {
        let ctx = make_test_context();
        let _ = seed_ledger_event(&ctx, "/tmp/a", json!({"title": "Entry 1"}));
        let _ = seed_ledger_event(&ctx, "/tmp/b", json!({"title": "Entry 2"}));

        let result = GetLedgerHandler
            .handle(Some(json!({"workingDirectory": null})), &ctx)
            .await
            .unwrap();

        assert_eq!(result["entries"].as_array().unwrap().len(), 2);
        assert_eq!(result["totalCount"], 2);
    }

    #[tokio::test]
    async fn get_ledger_no_working_dir_respects_pagination() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp/a", Some("test"))
            .unwrap();
        for i in 0..3 {
            let _ = ctx.event_store.append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MemoryLedger,
                payload: json!({"title": format!("A{i}")}),
                parent_id: None,
            });
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        let sid2 = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp/b", Some("test"))
            .unwrap();
        for i in 0..2 {
            let _ = ctx.event_store.append(&tron_events::AppendOptions {
                session_id: &sid2,
                event_type: tron_events::EventType::MemoryLedger,
                payload: json!({"title": format!("B{i}")}),
                parent_id: None,
            });
            std::thread::sleep(std::time::Duration::from_millis(10));
        }

        let result = GetLedgerHandler
            .handle(Some(json!({"limit": 2, "offset": 1})), &ctx)
            .await
            .unwrap();

        assert_eq!(result["entries"].as_array().unwrap().len(), 2);
        assert_eq!(result["totalCount"], 5);
        assert_eq!(result["hasMore"], true);
    }

    #[tokio::test]
    async fn get_ledger_no_working_dir_with_tag_filter() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp/a", Some("test"))
            .unwrap();
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MemoryLedger,
            payload: json!({"title": "iOS tagged", "tags": ["ios"]}),
            parent_id: None,
        });
        let sid2 = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp/b", Some("test"))
            .unwrap();
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid2,
            event_type: tron_events::EventType::MemoryLedger,
            payload: json!({"title": "iOS tagged 2", "tags": ["ios"]}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid2,
            event_type: tron_events::EventType::MemoryLedger,
            payload: json!({"title": "Server tagged", "tags": ["server"]}),
            parent_id: None,
        });

        let result = GetLedgerHandler
            .handle(Some(json!({"tags": ["ios"]})), &ctx)
            .await
            .unwrap();

        assert_eq!(result["entries"].as_array().unwrap().len(), 2);
        assert_eq!(result["totalCount"], 2);
    }

    #[tokio::test]
    async fn get_ledger_no_working_dir_empty_db() {
        let ctx = make_test_context();
        let result = GetLedgerHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap();

        assert_eq!(result["entries"], json!([]));
        assert_eq!(result["hasMore"], false);
        assert_eq!(result["totalCount"], 0);
    }

    #[tokio::test]
    async fn get_ledger_with_working_dir_still_filters() {
        let ctx = make_test_context();
        let _ = seed_ledger_event(&ctx, "/tmp/a", json!({"title": "A entry"}));
        let _ = seed_ledger_event(&ctx, "/tmp/b", json!({"title": "B entry"}));

        let result = GetLedgerHandler
            .handle(Some(json!({"workingDirectory": "/tmp/a"})), &ctx)
            .await
            .unwrap();

        let entries = result["entries"].as_array().unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0]["title"].as_str().unwrap(), "A entry");
    }

    #[tokio::test]
    async fn get_ledger_no_params_returns_all() {
        let ctx = make_test_context();
        let _ = seed_ledger_event(&ctx, "/tmp/a", json!({"title": "Entry 1"}));
        let _ = seed_ledger_event(&ctx, "/tmp/b", json!({"title": "Entry 2"}));

        let result = GetLedgerHandler.handle(None, &ctx).await.unwrap();

        assert_eq!(result["entries"].as_array().unwrap().len(), 2);
        assert_eq!(result["totalCount"], 2);
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
            .handle(Some(json!({"searchText": "dark mode"})), &ctx)
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
        // Should NOT have "timestamp" — wire format uses "createdAt"
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
            subagent_manager: None,
            embedding_controller: None,
            shutdown_coordinator: None,
        };
        let result = execute_ledger_write(&sid, &deps, "manual").await;
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
            payload: json!({
                "title": "Implement dark mode",
                "entryType": "feature",
                "turnRange": {"firstTurn": 1, "lastTurn": 1}
            }),
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

        let cycle = compute_cycle_messages(&ctx.event_store, &sid)
            .unwrap()
            .expect("should return cycle");
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
            payload: json!({
                "title": "First cycle",
                "entryType": "feature",
                "turnRange": {"firstTurn": 1, "lastTurn": 1}
            }),
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

        let cycle = compute_cycle_messages(&ctx.event_store, &sid)
            .unwrap()
            .expect("should return cycle");
        // Only second cycle messages (after boundary)
        assert_eq!(cycle.messages.len(), 2); // 1 user + 1 assistant
        assert_eq!(cycle.first_turn, 2); // Prior cycle had 1 user turn
        assert_eq!(cycle.last_turn, 2);

        // Verify the message content is from second cycle
        if let Message::User { ref content, .. } = cycle.messages[0] {
            match content {
                UserMessageContent::Text(t) => assert_eq!(t, "Second request"),
                UserMessageContent::Blocks(_) => panic!("expected text content"),
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

        let cycle = compute_cycle_messages(&ctx.event_store, &sid).unwrap();
        // session.start event exists but no message events → cycle has no messages
        // compute_cycle_messages returns None or Some with empty messages
        assert!(cycle.is_none() || cycle.unwrap().messages.is_empty());
    }

    // ── execute_ledger_write with "cron" source ──

    use futures::stream;
    use tron_core::content::AssistantContent;
    use tron_core::events::{AssistantMessage, StreamEvent};
    use tron_core::messages::TokenUsage;
    use tron_llm::models::types::Provider as LlmProvider;
    use tron_llm::provider::{
        Provider, ProviderError, ProviderFactory, ProviderStreamOptions, StreamEventStream,
    };

    const LEDGER_JSON: &str = r#"{"title":"Cron source test","entryType":"research","input":"test","actions":["tested source"]}"#;

    struct LedgerMockProvider;
    #[async_trait]
    impl Provider for LedgerMockProvider {
        fn provider_type(&self) -> LlmProvider {
            LlmProvider::Anthropic
        }
        fn model(&self) -> &'static str {
            "mock-ledger"
        }
        async fn stream(
            &self,
            _c: &tron_core::messages::Context,
            _o: &ProviderStreamOptions,
        ) -> Result<StreamEventStream, ProviderError> {
            let s = stream::iter(vec![
                Ok(StreamEvent::Start),
                Ok(StreamEvent::TextDelta {
                    delta: LEDGER_JSON.into(),
                }),
                Ok(StreamEvent::Done {
                    message: AssistantMessage {
                        content: vec![AssistantContent::text(LEDGER_JSON)],
                        token_usage: Some(TokenUsage {
                            input_tokens: 10,
                            output_tokens: 5,
                            ..Default::default()
                        }),
                    },
                    stop_reason: "end_turn".into(),
                }),
            ]);
            Ok(Box::pin(s))
        }
    }

    struct LedgerMockProviderFactory;
    #[async_trait]
    impl ProviderFactory for LedgerMockProviderFactory {
        async fn create_for_model(&self, _model: &str) -> Result<Arc<dyn Provider>, ProviderError> {
            Ok(Arc::new(LedgerMockProvider))
        }
    }

    #[tokio::test]
    async fn execute_ledger_write_cron_source() {
        let ctx = make_test_context();

        // Seed a session with user + assistant messages
        let sid = ctx
            .session_manager
            .create_session("mock", "/tmp/cron-test", Some("cron source test"))
            .unwrap();
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"content": "Hello from cron"}),
            parent_id: None,
        });
        // Assistant text must be >= 500 chars to pass cron no-op filter
        let long_response = "x".repeat(600);
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({
                "content": [{"type": "text", "text": long_response}],
                "turn": 1,
                "tokenUsage": {"inputTokens": 10, "outputTokens": 5}
            }),
            parent_id: None,
        });
        ctx.session_manager.invalidate_session(&sid);

        // Build SubagentManager with mock LLM that returns valid ledger JSON
        let broadcast = Arc::new(tron_runtime::EventEmitter::new());
        let subagent = Arc::new(
            tron_runtime::orchestrator::subagent_manager::SubagentManager::new(
                ctx.session_manager.clone(),
                ctx.event_store.clone(),
                broadcast,
                Arc::new(LedgerMockProviderFactory),
                None,
                None,
            ),
        );
        subagent.set_tool_factory(Arc::new(tron_tools::registry::ToolRegistry::new));

        let deps = LedgerWriteDeps {
            event_store: ctx.event_store.clone(),
            subagent_manager: Some(subagent),
            embedding_controller: None,
            shutdown_coordinator: None,
        };

        let result = execute_ledger_write(&sid, &deps, "cron").await;
        assert!(result.written, "ledger write should succeed");

        // Verify persisted event has source: "cron"
        let events = ctx
            .event_store
            .get_events_by_type(&sid, &["memory.ledger"], Some(10))
            .unwrap();
        assert_eq!(events.len(), 1);
        let payload: Value = serde_json::from_str(&events[0].payload).unwrap();
        assert_eq!(payload["source"], "cron");
        assert_eq!(payload["title"], "Cron source test");
    }

    // ── prepare_cron_transcript tests ──

    #[test]
    fn prepare_cron_transcript_strips_long_user_message() {
        let long_text = "x".repeat(501);
        let messages = vec![
            Message::User {
                content: UserMessageContent::Text(long_text),
                timestamp: Some(1.0),
            },
            Message::Assistant {
                content: vec![tron_core::content::AssistantContent::Text {
                    text: "I did something".into(),
                }],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
        ];

        let result = prepare_cron_transcript(&messages);
        assert_eq!(result.len(), 2);

        match &result[0] {
            Message::User { content, timestamp } => {
                match content {
                    UserMessageContent::Text(t) => assert!(t.contains("omitted")),
                    UserMessageContent::Blocks(_) => panic!("expected Text variant"),
                }
                assert_eq!(*timestamp, None);
            }
            _ => panic!("expected User message"),
        }

        assert!(matches!(&result[1], Message::Assistant { .. }));
    }

    #[test]
    fn prepare_cron_transcript_keeps_short_user_message() {
        let short_text = "what's the weather?";
        let messages = vec![Message::User {
            content: UserMessageContent::Text(short_text.into()),
            timestamp: Some(2.0),
        }];

        let result = prepare_cron_transcript(&messages);
        match &result[0] {
            Message::User { content, timestamp } => {
                match content {
                    UserMessageContent::Text(t) => assert_eq!(t, short_text),
                    UserMessageContent::Blocks(_) => panic!("expected Text variant"),
                }
                assert_eq!(*timestamp, Some(2.0));
            }
            _ => panic!("expected User message"),
        }
    }

    #[test]
    fn prepare_cron_transcript_preserves_assistant_messages() {
        let messages = vec![
            Message::User {
                content: UserMessageContent::Text("x".repeat(600)),
                timestamp: None,
            },
            Message::Assistant {
                content: vec![
                    tron_core::content::AssistantContent::Text {
                        text: "response".into(),
                    },
                    tron_core::content::AssistantContent::ToolUse {
                        id: "t1".into(),
                        name: "search".into(),
                        arguments: serde_json::Map::new(),
                        thought_signature: None,
                    },
                ],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: Some("deep thoughts".into()),
            },
        ];

        let result = prepare_cron_transcript(&messages);
        match &result[1] {
            Message::Assistant {
                content, thinking, ..
            } => {
                assert_eq!(content.len(), 2);
                assert_eq!(thinking.as_deref(), Some("deep thoughts"));
            }
            _ => panic!("expected Assistant message"),
        }
    }

    #[test]
    fn prepare_cron_transcript_handles_empty() {
        let result = prepare_cron_transcript(&[]);
        assert!(result.is_empty());
    }

    #[test]
    fn prepare_cron_transcript_multiple_user_messages() {
        let messages = vec![
            Message::User {
                content: UserMessageContent::Text("x".repeat(600)),
                timestamp: None,
            },
            Message::User {
                content: UserMessageContent::Text("short follow-up".into()),
                timestamp: None,
            },
        ];

        let result = prepare_cron_transcript(&messages);
        match &result[0] {
            Message::User { content, .. } => match content {
                UserMessageContent::Text(t) => assert!(t.contains("omitted")),
                UserMessageContent::Blocks(_) => panic!("expected Text"),
            },
            _ => panic!("expected User"),
        }
        match &result[1] {
            Message::User { content, .. } => match content {
                UserMessageContent::Text(t) => assert_eq!(t, "short follow-up"),
                UserMessageContent::Blocks(_) => panic!("expected Text"),
            },
            _ => panic!("expected User"),
        }
    }

    #[test]
    fn prepare_cron_transcript_blocks_variant() {
        use tron_core::content::UserContent;
        let messages = vec![Message::User {
            content: UserMessageContent::Blocks(vec![
                UserContent::Text {
                    text: "x".repeat(300),
                },
                UserContent::Text {
                    text: "y".repeat(300),
                },
            ]),
            timestamp: None,
        }];

        let result = prepare_cron_transcript(&messages);
        match &result[0] {
            Message::User { content, .. } => match content {
                UserMessageContent::Text(t) => assert!(t.contains("omitted")),
                UserMessageContent::Blocks(_) => panic!("expected Text replacement"),
            },
            _ => panic!("expected User"),
        }
    }

    #[test]
    fn user_message_len_text() {
        let content = UserMessageContent::Text("hello".into());
        assert_eq!(user_message_len(&content), 5);
    }

    #[test]
    fn user_message_len_blocks() {
        use tron_core::content::UserContent;
        let content = UserMessageContent::Blocks(vec![
            UserContent::Text { text: "abc".into() },
            UserContent::Text { text: "de".into() },
        ]);
        assert_eq!(user_message_len(&content), 5);
    }

    #[test]
    fn user_message_len_empty_blocks() {
        use tron_core::content::UserContent;
        let content = UserMessageContent::Blocks(vec![UserContent::Image {
            data: "base64data".into(),
            mime_type: "image/png".into(),
        }]);
        assert_eq!(user_message_len(&content), 0);
    }

    // ── cron_assistant_text_len tests ──

    #[test]
    fn cron_assistant_text_len_sums_text_blocks() {
        use tron_core::content::AssistantContent;
        let messages = vec![
            Message::Assistant {
                content: vec![
                    AssistantContent::Text {
                        text: "hello".into(),
                    },
                    AssistantContent::ToolUse {
                        id: "t1".into(),
                        name: "Bash".into(),
                        arguments: serde_json::Map::new(),
                        thought_signature: None,
                    },
                    AssistantContent::Text {
                        text: "world".into(),
                    },
                ],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
            Message::Assistant {
                content: vec![AssistantContent::Text {
                    text: "more text".into(),
                }],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
        ];
        // "hello" (5) + "world" (5) + "more text" (9) = 19
        assert_eq!(cron_assistant_text_len(&messages), 19);
    }

    #[test]
    fn cron_assistant_text_len_ignores_user_and_tool_result_messages() {
        use tron_core::content::AssistantContent;
        let messages = vec![
            Message::User {
                content: UserMessageContent::Text("long user text that should not count".into()),
                timestamp: None,
            },
            Message::Assistant {
                content: vec![AssistantContent::Text {
                    text: "short".into(),
                }],
                usage: None,
                cost: None,
                stop_reason: None,
                thinking: None,
            },
            Message::ToolResult {
                tool_call_id: "t1".into(),
                content: tron_core::messages::ToolResultMessageContent::Text(
                    "tool output that should not count".into(),
                ),
                is_error: Some(false),
            },
        ];
        assert_eq!(cron_assistant_text_len(&messages), 5);
    }

    #[test]
    fn cron_assistant_text_len_empty() {
        assert_eq!(cron_assistant_text_len(&[]), 0);
    }

    #[test]
    fn cron_assistant_text_len_only_tool_use_no_text() {
        use tron_core::content::AssistantContent;
        let messages = vec![Message::Assistant {
            content: vec![AssistantContent::ToolUse {
                id: "t1".into(),
                name: "Remember".into(),
                arguments: serde_json::Map::new(),
                thought_signature: None,
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }];
        assert_eq!(cron_assistant_text_len(&messages), 0);
    }

    #[test]
    fn cron_assistant_text_len_boundary_500() {
        use tron_core::content::AssistantContent;
        let messages = vec![Message::Assistant {
            content: vec![AssistantContent::Text {
                text: "x".repeat(500),
            }],
            usage: None,
            cost: None,
            stop_reason: None,
            thinking: None,
        }];
        // Exactly 500 — below threshold, should be skippable
        assert_eq!(cron_assistant_text_len(&messages), 500);
    }
}
