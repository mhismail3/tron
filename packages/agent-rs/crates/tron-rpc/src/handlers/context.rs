//! Context handlers: getSnapshot, getDetailedSnapshot, shouldCompact,
//! previewCompaction, confirmCompaction, canAcceptTurn, clear, compact.

use std::path::{Path, PathBuf};

use async_trait::async_trait;
use serde_json::{json, Value};
use tracing::instrument;

use tron_context::context_manager::ContextManager;
use tron_context::loader::{self, ContextLoader, ContextLoaderConfig};
use tron_context::summarizer::KeywordSummarizer;
use tron_context::types::{CompactionConfig, ContextManagerConfig};

use crate::context::RpcContext;
use crate::errors::{self, RpcError};
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

// =============================================================================
// Shared helper
// =============================================================================

/// Build a temporary `ContextManager` for a session by reconstructing state
/// from events and loading rules/memory from disk.
fn build_context_manager_for_session(
    session_id: &str,
    ctx: &RpcContext,
) -> Result<ContextManager, RpcError> {
    // 1. Get session metadata
    let session = ctx
        .session_manager
        .get_session(session_id)
        .map_err(|e| RpcError::Internal {
            message: e.to_string(),
        })?
        .ok_or_else(|| RpcError::NotFound {
            code: errors::SESSION_NOT_FOUND.into(),
            message: format!("Session '{session_id}' not found"),
        })?;

    // 2. Reconstruct state (messages, model, token usage)
    let state = match ctx.session_manager.resume_session(session_id) {
        Ok(active) => active.state.clone(),
        Err(_) => tron_runtime::ReconstructedState {
            model: session.latest_model.clone(),
            working_directory: Some(session.working_directory.clone()),
            ..Default::default()
        },
    };

    // 3. Load project rules from working directory
    let wd = &session.working_directory;
    let project_rules = {
        let wd_path = Path::new(wd);
        let mut ld = ContextLoader::new(ContextLoaderConfig {
            project_root: wd_path.to_path_buf(),
            ..Default::default()
        });
        ld.load(wd_path)
            .ok()
            .and_then(|c| if c.merged.is_empty() { None } else { Some(c.merged) })
    };

    // 4. Load global rules
    let home_dir = std::env::var("HOME").ok().map(PathBuf::from);
    let global_rules = home_dir
        .as_deref()
        .and_then(loader::load_global_rules);
    let rules = loader::merge_rules(global_rules, project_rules);

    // 5. Load workspace memory from ledger entries
    let memory = {
        let settings = tron_settings::get_settings();
        let auto_inject = &settings.context.memory.auto_inject;
        if auto_inject.enabled {
            ctx.event_store.get_workspace_by_path(wd).ok().flatten().and_then(|ws| {
                #[allow(clippy::cast_possible_wrap)]
                let count = auto_inject.count.clamp(1, 10) as i64;
                let events = ctx.event_store
                    .get_events_by_workspace_and_types(&ws.id, &["memory.ledger"], Some(count), None)
                    .unwrap_or_default();
                if events.is_empty() { return None; }
                let mut sections = vec!["# Memory\n\n## Recent sessions in this workspace".to_string()];
                for event in events.iter().rev() {
                    if let Ok(entry) = serde_json::from_str::<Value>(&event.payload) {
                        let title = entry.get("title").and_then(|v| v.as_str()).unwrap_or("Untitled");
                        let mut section = format!("\n### {title}");
                        if let Some(lessons) = entry.get("lessons").and_then(|v| v.as_array()) {
                            for lesson in lessons.iter().filter_map(|l| l.as_str()).filter(|t| !t.is_empty()) {
                                section.push_str(&format!("\n- {lesson}"));
                            }
                        }
                        sections.push(section);
                    }
                }
                let content = sections.join("\n");
                if content.trim().is_empty() { None } else { Some(content) }
            })
        } else {
            None
        }
    };

    // 6. Get tool definitions
    let tools = ctx
        .agent_deps
        .as_ref()
        .map(|d| (d.tool_factory)().definitions())
        .unwrap_or_default();

    // 7. Build ContextManager
    let context_limit = tron_tokens::get_context_limit(&state.model);
    let mut cm = ContextManager::new(ContextManagerConfig {
        model: state.model.clone(),
        system_prompt: None,
        working_directory: state.working_directory.clone(),
        tools,
        rules_content: rules,
        compaction: CompactionConfig {
            context_limit,
            ..CompactionConfig::default()
        },
    });

    // 8. Restore messages and memory
    if !state.messages.is_empty() {
        cm.set_messages(state.messages.clone());
    }
    if memory.is_some() {
        cm.set_memory_content(memory);
    }

    // 9. Set API tokens if available (ground truth from last turn's context window)
    // Use last_turn_input_tokens from session row (NOT accumulated totals)
    let last_turn = session.last_turn_input_tokens;
    if last_turn > 0 {
        #[allow(clippy::cast_sign_loss)]
        cm.set_api_context_tokens(last_turn as u64);
    }

    Ok(cm)
}

// =============================================================================
// Handlers
// =============================================================================

/// Get context snapshot for a session.
pub struct GetSnapshotHandler;

#[async_trait]
impl MethodHandler for GetSnapshotHandler {
    #[instrument(skip(self, ctx), fields(method = "context.getSnapshot", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let cm = build_context_manager_for_session(&session_id, ctx)?;
        let snapshot = cm.get_snapshot();
        Ok(json!({
            "currentTokens": snapshot.current_tokens,
            "contextLimit": snapshot.context_limit,
            "usagePercent": snapshot.usage_percent,
            "thresholdLevel": snapshot.threshold_level,
            "breakdown": {
                "systemPrompt": snapshot.breakdown.system_prompt,
                "tools": snapshot.breakdown.tools,
                "rules": snapshot.breakdown.rules,
                "messages": snapshot.breakdown.messages
            }
        }))
    }
}

/// Get detailed context snapshot.
pub struct GetDetailedSnapshotHandler;

#[async_trait]
impl MethodHandler for GetDetailedSnapshotHandler {
    #[instrument(skip(self, ctx), fields(method = "context.getDetailedSnapshot", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        // Get session metadata for working directory
        let session = ctx
            .session_manager
            .get_session(&session_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?
            .ok_or_else(|| RpcError::NotFound {
                code: errors::SESSION_NOT_FOUND.into(),
                message: format!("Session '{session_id}' not found"),
            })?;

        let cm = build_context_manager_for_session(&session_id, ctx)?;
        let detailed = cm.get_detailed_snapshot();

        // Build messages array matching iOS DetailedMessageInfo shape
        let messages: Vec<Value> = detailed
            .messages
            .iter()
            .map(|m| {
                let mut msg = json!({
                    "index": m.index,
                    "role": m.role,
                    "tokens": m.tokens,
                    "summary": m.summary,
                    "content": m.content,
                });
                if let Some(ref tc) = m.tool_calls {
                    msg["toolCalls"] = json!(tc.iter().map(|t| json!({
                        "id": t.id,
                        "name": t.name,
                        "tokens": t.tokens,
                        "arguments": t.arguments,
                    })).collect::<Vec<_>>());
                }
                if let Some(ref id) = m.tool_call_id {
                    msg["toolCallId"] = json!(id);
                }
                if let Some(err) = m.is_error {
                    msg["isError"] = json!(err);
                }
                if let Some(ref eid) = m.event_id {
                    msg["eventId"] = json!(eid);
                }
                msg
            })
            .collect();

        // Build addedSkills matching iOS AddedSkillInfo shape:
        // { name, source, addedVia, eventId, tokens }
        // Skills are event-sourced: skill.added / skill.removed events in this session.
        let added_skills: Vec<Value> = {
            let added_events = ctx
                .event_store
                .get_events_by_type(&session_id, &["skill.added"], None)
                .unwrap_or_default();
            let removed_events = ctx
                .event_store
                .get_events_by_type(&session_id, &["skill.removed"], None)
                .unwrap_or_default();

            // Collect removed skill names
            let removed_names: std::collections::HashSet<String> = removed_events
                .iter()
                .filter_map(|e| {
                    serde_json::from_str::<Value>(&e.payload)
                        .ok()
                        .and_then(|p| p.get("skillName").and_then(Value::as_str).map(String::from))
                })
                .collect();

            added_events
                .iter()
                .filter_map(|e| {
                    let payload: Value = serde_json::from_str(&e.payload).ok()?;
                    let name = payload.get("skillName")?.as_str()?;
                    // Skip if this skill was later removed
                    if removed_names.contains(name) {
                        return None;
                    }
                    let source = payload
                        .get("source")
                        .and_then(Value::as_str)
                        .unwrap_or("global");
                    let added_via = payload
                        .get("addedVia")
                        .and_then(Value::as_str)
                        .unwrap_or("mention");
                    let tokens = payload.get("tokens").and_then(Value::as_u64);

                    let mut skill = json!({
                        "name": name,
                        "source": source,
                        "addedVia": added_via,
                        "eventId": e.id,
                    });
                    if let Some(t) = tokens {
                        skill["tokens"] = json!(t);
                    }
                    Some(skill)
                })
                .collect()
        };

        // Build rules matching iOS LoadedRules shape: { files, totalFiles, tokens }
        let rules_info: Option<Value> = {
            let wd_path = Path::new(&session.working_directory);
            let mut ld = ContextLoader::new(ContextLoaderConfig {
                project_root: wd_path.to_path_buf(),
                ..Default::default()
            });
            let project_files = ld.load(wd_path).ok();

            let home_dir = std::env::var("HOME").ok().map(PathBuf::from);
            let has_global = home_dir.as_deref().and_then(loader::load_global_rules).is_some();

            let mut files = Vec::new();
            if has_global {
                if let Some(ref hd) = home_dir {
                    for name in &["AGENTS.md", "RULES.md", "CLAUDE.md"] {
                        let p = hd.join(".tron").join(name);
                        if p.is_file() {
                            files.push(json!({
                                "path": p.to_string_lossy(),
                                "relativePath": format!("~/.tron/{name}"),
                                "level": "global",
                                "depth": -1,
                            }));
                            break;
                        }
                    }
                }
            }
            if let Some(ref loaded) = project_files {
                for f in &loaded.files {
                    let rel = f
                        .path
                        .strip_prefix(wd_path)
                        .map_or_else(
                            |_| f.path.to_string_lossy().to_string(),
                            |p| p.to_string_lossy().to_string(),
                        );
                    let level = match f.level {
                        loader::ContextLevel::Project => "project",
                        loader::ContextLevel::Directory => "directory",
                    };
                    files.push(json!({
                        "path": f.path.to_string_lossy(),
                        "relativePath": rel,
                        "level": level,
                        "depth": f.depth,
                    }));
                }
            }

            let total_files = files.len();
            if total_files > 0 {
                Some(json!({
                    "files": files,
                    "totalFiles": total_files,
                    "tokens": detailed.snapshot.breakdown.rules,
                }))
            } else {
                None
            }
        };

        // Build memory matching iOS LoadedMemory shape: { count, tokens, entries }
        let memory_info: Option<Value> = {
            let settings = tron_settings::get_settings();
            let auto_inject = &settings.context.memory.auto_inject;
            if !auto_inject.enabled {
                None
            } else {
                ctx.event_store.get_workspace_by_path(&session.working_directory).ok().flatten().and_then(|ws| {
                    #[allow(clippy::cast_possible_wrap)]
                    let count = auto_inject.count.clamp(1, 10) as i64;
                    let events = ctx.event_store
                        .get_events_by_workspace_and_types(&ws.id, &["memory.ledger"], Some(count), None)
                        .unwrap_or_default();
                    if events.is_empty() { return None; }
                    let entries: Vec<Value> = events.iter().rev().filter_map(|e| {
                        let payload: Value = serde_json::from_str(&e.payload).ok()?;
                        let title = payload.get("title").and_then(Value::as_str).unwrap_or("Untitled");
                        let mut summary = format!("### {title}");
                        if let Some(lessons) = payload.get("lessons").and_then(Value::as_array) {
                            for lesson in lessons.iter().filter_map(|l| l.as_str()).filter(|t| !t.is_empty()) {
                                summary.push_str(&format!("\n- {lesson}"));
                            }
                        }
                        Some(json!({ "title": title, "content": summary }))
                    }).collect();
                    if entries.is_empty() { return None; }
                    let tokens = cm.get_full_memory_content().map(|c| c.len() / 4).unwrap_or(0);
                    Some(json!({ "count": entries.len(), "tokens": tokens, "entries": entries }))
                })
            }
        };

        // Build sessionMemories matching iOS LoadedMemory shape
        let session_memories: Option<Value> = {
            let mems = cm.get_session_memories();
            if mems.is_empty() {
                None
            } else {
                let entries: Vec<Value> = mems
                    .iter()
                    .map(|m| json!({ "title": m.title, "content": m.content }))
                    .collect();
                let total_tokens: u64 = mems.iter().map(|m| m.tokens).sum();
                Some(json!({
                    "count": mems.len(),
                    "tokens": total_tokens,
                    "entries": entries,
                }))
            }
        };

        // ADAPTER(ios-compat): iOS splits tools on ":" to show name + description.
        // REMOVE: revert to `"toolsContent": detailed.tools_content,`
        let tool_defs = ctx
            .agent_deps
            .as_ref()
            .map(|d| (d.tool_factory)().definitions())
            .unwrap_or_default();
        let tools_content =
            crate::adapters::adapt_tools_content(&detailed.tools_content, &tool_defs);

        Ok(json!({
            "currentTokens": detailed.snapshot.current_tokens,
            "contextLimit": detailed.snapshot.context_limit,
            "usagePercent": detailed.snapshot.usage_percent,
            "thresholdLevel": detailed.snapshot.threshold_level,
            "breakdown": {
                "systemPrompt": detailed.snapshot.breakdown.system_prompt,
                "tools": detailed.snapshot.breakdown.tools,
                "rules": detailed.snapshot.breakdown.rules,
                "messages": detailed.snapshot.breakdown.messages
            },
            "messages": messages,
            "systemPromptContent": detailed.system_prompt_content,
            "toolClarificationContent": detailed.tool_clarification_content,
            "toolsContent": tools_content,
            "addedSkills": added_skills,
            "rules": rules_info,
            "memory": memory_info,
            "sessionMemories": session_memories,
            "taskContext": null,
        }))
    }
}

/// Check if compaction is recommended.
pub struct ShouldCompactHandler;

#[async_trait]
impl MethodHandler for ShouldCompactHandler {
    #[instrument(skip(self, ctx), fields(method = "context.shouldCompact", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let cm = build_context_manager_for_session(&session_id, ctx)?;
        Ok(json!({ "shouldCompact": cm.should_compact() }))
    }
}

/// Preview what compaction would produce.
pub struct PreviewCompactionHandler;

#[async_trait]
impl MethodHandler for PreviewCompactionHandler {
    #[instrument(skip(self, ctx), fields(method = "context.previewCompaction", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let cm = build_context_manager_for_session(&session_id, ctx)?;

        let summarizer = KeywordSummarizer::new();
        let preview = cm
            .preview_compaction(&summarizer)
            .await
            .map_err(|e| RpcError::Internal {
                message: format!("Compaction preview failed: {e}"),
            })?;

        Ok(json!({
            "tokensBefore": preview.tokens_before,
            "tokensAfter": preview.tokens_after,
            "compressionRatio": preview.compression_ratio,
            "preservedTurns": preview.preserved_turns,
            "summarizedTurns": preview.summarized_turns,
            "summary": preview.summary,
            "extractedData": preview.extracted_data,
        }))
    }
}

/// Confirm and execute compaction with optional edited summary.
pub struct ConfirmCompactionHandler;

#[async_trait]
impl MethodHandler for ConfirmCompactionHandler {
    #[instrument(skip(self, ctx), fields(method = "context.confirmCompaction", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let edited_summary = params
            .as_ref()
            .and_then(|p| p.get("editedSummary"))
            .and_then(Value::as_str)
            .map(ToOwned::to_owned);

        let mut cm = build_context_manager_for_session(&session_id, ctx)?;
        let summarizer = KeywordSummarizer::new();

        let result = cm
            .execute_compaction(&summarizer, edited_summary.as_deref())
            .await
            .map_err(|e| RpcError::Internal {
                message: format!("Compaction failed: {e}"),
            })?;

        // Persist compaction event
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &session_id,
            event_type: tron_events::EventType::CompactSummary,
            payload: json!({
                "summary": result.summary,
                "tokensBefore": result.tokens_before,
                "tokensAfter": result.tokens_after,
                "compressionRatio": result.compression_ratio,
            }),
            parent_id: None,
        });

        // Broadcast compaction complete event
        let _ = ctx.orchestrator.broadcast().emit(
            tron_core::events::TronEvent::CompactionComplete {
                base: tron_core::events::BaseEvent::now(&session_id),
                success: result.success,
                tokens_before: result.tokens_before,
                tokens_after: result.tokens_after,
                compression_ratio: result.compression_ratio,
                reason: Some(tron_core::events::CompactionReason::Manual),
                summary: Some(result.summary.clone()),
                estimated_context_tokens: None,
            },
        );

        // Invalidate cached session
        ctx.session_manager.invalidate_session(&session_id);

        Ok(json!({
            "confirmed": true,
            "success": result.success,
            "tokensBefore": result.tokens_before,
            "tokensAfter": result.tokens_after,
            "compressionRatio": result.compression_ratio,
            "summary": result.summary,
        }))
    }
}

/// Check if the context can accept another turn.
pub struct CanAcceptTurnHandler;

#[async_trait]
impl MethodHandler for CanAcceptTurnHandler {
    #[instrument(skip(self, ctx), fields(method = "context.canAcceptTurn", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let cm = build_context_manager_for_session(&session_id, ctx)?;
        let v = cm.can_accept_turn(4_000);
        Ok(json!({ "canAcceptTurn": v.can_proceed }))
    }
}

/// Clear context for a session.
pub struct ClearHandler;

#[async_trait]
impl MethodHandler for ClearHandler {
    #[instrument(skip(self, ctx), fields(method = "context.clear", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        // Get tokens before clearing (best effort)
        let tokens_before = build_context_manager_for_session(&session_id, ctx)
            .map(|cm| cm.get_snapshot().current_tokens)
            .unwrap_or(0);

        // Persist context cleared event
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &session_id,
            event_type: tron_events::EventType::ContextCleared,
            payload: json!({
                "tokensBefore": tokens_before,
                "tokensAfter": 0,
            }),
            parent_id: None,
        });

        // Invalidate cached session
        ctx.session_manager.invalidate_session(&session_id);

        // Broadcast event
        #[allow(clippy::cast_possible_wrap)]
        let _ = ctx.orchestrator.broadcast().emit(
            tron_core::events::TronEvent::ContextCleared {
                base: tron_core::events::BaseEvent::now(&session_id),
                tokens_before: tokens_before as i64,
                tokens_after: 0,
            },
        );

        Ok(json!({
            "success": true,
            "tokensBefore": tokens_before,
            "tokensAfter": 0
        }))
    }
}

/// Trigger compaction for a session (without edited summary).
pub struct CompactHandler;

#[async_trait]
impl MethodHandler for CompactHandler {
    #[instrument(skip(self, ctx), fields(method = "context.compact", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let mut cm = build_context_manager_for_session(&session_id, ctx)?;

        let summarizer = KeywordSummarizer::new();
        let result = cm
            .execute_compaction(&summarizer, None)
            .await
            .map_err(|e| RpcError::Internal {
                message: format!("Compaction failed: {e}"),
            })?;

        // Persist compaction event
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &session_id,
            event_type: tron_events::EventType::CompactSummary,
            payload: json!({
                "summary": result.summary,
                "tokensBefore": result.tokens_before,
                "tokensAfter": result.tokens_after,
                "compressionRatio": result.compression_ratio,
            }),
            parent_id: None,
        });

        // Broadcast compaction complete event
        let _ = ctx.orchestrator.broadcast().emit(
            tron_core::events::TronEvent::CompactionComplete {
                base: tron_core::events::BaseEvent::now(&session_id),
                success: result.success,
                tokens_before: result.tokens_before,
                tokens_after: result.tokens_after,
                compression_ratio: result.compression_ratio,
                reason: Some(tron_core::events::CompactionReason::Manual),
                summary: Some(result.summary.clone()),
                estimated_context_tokens: None,
            },
        );

        // Invalidate cached session
        ctx.session_manager.invalidate_session(&session_id);

        Ok(json!({
            "success": result.success,
            "tokensBefore": result.tokens_before,
            "tokensAfter": result.tokens_after,
            "compressionRatio": result.compression_ratio,
            "summary": result.summary,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;

    // Helper: create a context with a real session
    fn ctx_with_session() -> (RpcContext, String) {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", Some("test"))
            .unwrap();
        (ctx, sid)
    }

    // ── GetSnapshotHandler ──

    #[tokio::test]
    async fn get_snapshot_returns_ios_shape() {
        let (ctx, sid) = ctx_with_session();
        let result = GetSnapshotHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert!(result["currentTokens"].is_number());
        assert!(result["contextLimit"].is_number());
        assert!(result["usagePercent"].is_number());
        assert!(result["thresholdLevel"].is_string());
        assert!(result["breakdown"].is_object());
    }

    #[tokio::test]
    async fn get_snapshot_threshold_is_string() {
        let (ctx, sid) = ctx_with_session();
        let result = GetSnapshotHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["thresholdLevel"], "normal");
    }

    #[tokio::test]
    async fn get_snapshot_has_system_prompt_tokens() {
        let (ctx, sid) = ctx_with_session();
        let result = GetSnapshotHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        // System prompt is non-empty (default TRON_CORE_PROMPT), so tokens > 0
        assert!(
            result["breakdown"]["systemPrompt"].as_u64().unwrap() > 0,
            "system prompt tokens should be > 0"
        );
    }

    #[tokio::test]
    async fn get_snapshot_real_context_limit() {
        let (ctx, sid) = ctx_with_session();
        let result = GetSnapshotHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let limit = result["contextLimit"].as_u64().unwrap();
        assert_eq!(limit, tron_tokens::get_context_limit("claude-opus-4-6"));
    }

    #[tokio::test]
    async fn get_snapshot_with_messages_has_message_tokens() {
        let (ctx, sid) = ctx_with_session();

        // Add message events using correct event store payload format
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"content": "hello world this is a test message"}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({
                "content": [{"type": "text", "text": "hi there, I can help you with that"}],
                "turn": 1,
                "tokenUsage": {"inputTokens": 100, "outputTokens": 50}
            }),
            parent_id: None,
        });

        // Invalidate cached session state so resume_session re-reconstructs
        ctx.session_manager.invalidate_session(&sid);

        let result = GetSnapshotHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();

        // With API token usage (input+output=150), current_tokens should reflect that
        let current = result["currentTokens"].as_u64().unwrap();
        assert!(current > 0, "currentTokens should be > 0 with messages");
    }

    #[tokio::test]
    async fn get_snapshot_session_not_found() {
        let ctx = make_test_context();
        let err = GetSnapshotHandler
            .handle(Some(json!({"sessionId": "nonexistent"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "SESSION_NOT_FOUND");
    }

    // ── GetDetailedSnapshotHandler ──

    #[tokio::test]
    async fn get_detailed_snapshot_returns_ios_shape() {
        let (ctx, sid) = ctx_with_session();
        let result = GetDetailedSnapshotHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert!(result["currentTokens"].is_number());
        assert!(result["breakdown"].is_object());
        assert!(result["messages"].is_array());
        assert!(result["systemPromptContent"].is_string());
        assert!(result["toolsContent"].is_array());
        assert!(result["addedSkills"].is_array());
    }

    #[tokio::test]
    async fn get_detailed_snapshot_all_14_ios_fields() {
        let (ctx, sid) = ctx_with_session();
        let result = GetDetailedSnapshotHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let required_fields = [
            "currentTokens", "contextLimit", "usagePercent", "thresholdLevel",
            "breakdown", "messages", "systemPromptContent", "toolsContent",
            "addedSkills",
        ];
        for field in &required_fields {
            assert!(
                result.get(field).is_some() && !result[field].is_null(),
                "missing required field: {field}"
            );
        }
        let optional_fields = [
            "toolClarificationContent", "rules", "memory",
            "sessionMemories", "taskContext",
        ];
        for field in &optional_fields {
            assert!(result.get(field).is_some(), "missing optional field: {field}");
        }
    }

    #[tokio::test]
    async fn get_detailed_snapshot_system_prompt_non_empty() {
        let (ctx, sid) = ctx_with_session();
        let result = GetDetailedSnapshotHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let content = result["systemPromptContent"].as_str().unwrap();
        assert!(!content.is_empty(), "systemPromptContent should be non-empty");
    }

    #[tokio::test]
    async fn get_detailed_snapshot_with_messages() {
        let (ctx, sid) = ctx_with_session();

        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"content": "hello"}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({
                "content": [{"type": "text", "text": "hi"}],
                "turn": 1,
                "tokenUsage": {"inputTokens": 10, "outputTokens": 5}
            }),
            parent_id: None,
        });

        ctx.session_manager.invalidate_session(&sid);

        let result = GetDetailedSnapshotHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let messages = result["messages"].as_array().unwrap();
        assert!(messages.len() >= 1, "expected at least 1 message, got {}", messages.len());
    }

    #[tokio::test]
    async fn get_detailed_snapshot_message_has_preview() {
        let (ctx, sid) = ctx_with_session();

        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"content": "hello world"}),
            parent_id: None,
        });

        ctx.session_manager.invalidate_session(&sid);

        let result = GetDetailedSnapshotHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let messages = result["messages"].as_array().unwrap();
        assert!(!messages.is_empty(), "expected at least 1 message");
        assert!(messages[0]["summary"].is_string());
    }

    #[tokio::test]
    async fn get_detailed_snapshot_rules_with_file() {
        let tmp = tempfile::tempdir().unwrap();
        let claude_dir = tmp.path().join(".claude");
        std::fs::create_dir_all(&claude_dir).unwrap();
        std::fs::write(claude_dir.join("AGENTS.md"), "# Test Rules\nBe helpful.").unwrap();

        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", tmp.path().to_str().unwrap(), None)
            .unwrap();

        let result = GetDetailedSnapshotHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let rules_obj = &result["rules"];
        assert!(rules_obj.is_object(), "rules should be an object, got: {rules_obj}");
        assert!(rules_obj["totalFiles"].as_u64().unwrap() > 0);
        assert!(rules_obj["tokens"].as_u64().unwrap() > 0);
        let files = rules_obj["files"].as_array().unwrap();
        assert!(!files.is_empty());
        assert!(
            result["breakdown"]["rules"].as_u64().unwrap() > 0,
            "rules tokens should be > 0"
        );
    }

    #[tokio::test]
    async fn get_detailed_snapshot_added_skills() {
        let (ctx, sid) = ctx_with_session();

        // Add a skill event
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::SkillAdded,
            payload: json!({"skillName": "web-search", "source": "global", "addedVia": "mention"}),
            parent_id: None,
        });

        let result = GetDetailedSnapshotHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let skills = result["addedSkills"].as_array().unwrap();
        assert_eq!(skills.len(), 1);
        assert_eq!(skills[0]["name"], "web-search");
        assert_eq!(skills[0]["source"], "global");
        assert_eq!(skills[0]["addedVia"], "mention");
        assert!(skills[0]["eventId"].is_string());
    }

    #[tokio::test]
    async fn get_detailed_snapshot_skill_removed_filtered() {
        let (ctx, sid) = ctx_with_session();

        // Add then remove a skill
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::SkillAdded,
            payload: json!({"skillName": "web-search", "source": "global", "addedVia": "explicit"}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::SkillRemoved,
            payload: json!({"skillName": "web-search"}),
            parent_id: None,
        });
        // Add another skill that stays
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::SkillAdded,
            payload: json!({"skillName": "commit", "source": "project", "addedVia": "explicit"}),
            parent_id: None,
        });

        let result = GetDetailedSnapshotHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let skills = result["addedSkills"].as_array().unwrap();
        assert_eq!(skills.len(), 1);
        assert_eq!(skills[0]["name"], "commit");
        assert_eq!(skills[0]["source"], "project");
    }

    // ── ShouldCompactHandler ──

    #[tokio::test]
    async fn should_compact_returns_boolean() {
        let (ctx, sid) = ctx_with_session();
        let result = ShouldCompactHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        // Empty session shouldn't need compaction
        assert_eq!(result["shouldCompact"], false);
    }

    #[tokio::test]
    async fn should_compact_true_when_high_usage() {
        let (ctx, sid) = ctx_with_session();

        // Add high token usage via events to simulate high context usage
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({
                "content": [{"type": "text", "text": "response"}],
                "turn": 1,
                "tokenUsage": {"inputTokens": 160_000, "outputTokens": 10_000}
            }),
            parent_id: None,
        });

        ctx.session_manager.invalidate_session(&sid);

        let result = ShouldCompactHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        // 170k / 200k = 0.85 which is >= 0.70 threshold
        assert_eq!(result["shouldCompact"], true);
    }

    // ── CanAcceptTurnHandler ──

    #[tokio::test]
    async fn can_accept_turn() {
        let (ctx, sid) = ctx_with_session();
        let result = CanAcceptTurnHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["canAcceptTurn"], true);
    }

    #[tokio::test]
    async fn can_accept_turn_false_when_critical() {
        let (ctx, sid) = ctx_with_session();

        // Add very high token usage
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({
                "content": [{"type": "text", "text": "r"}],
                "turn": 1,
                "tokenUsage": {"inputTokens": 180_000, "outputTokens": 10_000}
            }),
            parent_id: None,
        });

        ctx.session_manager.invalidate_session(&sid);

        let result = CanAcceptTurnHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        // 190k / 200k = 0.95 which is >= critical (0.85)
        assert_eq!(result["canAcceptTurn"], false);
    }

    // ── PreviewCompactionHandler ──

    #[tokio::test]
    async fn preview_compaction_returns_real_tokens() {
        let (ctx, sid) = ctx_with_session();
        let result = PreviewCompactionHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert!(result["tokensBefore"].is_number());
        assert!(result["tokensAfter"].is_number());
        assert!(result["compressionRatio"].is_number());
        assert!(result["preservedTurns"].is_number());
        assert!(result["summarizedTurns"].is_number());
        assert!(result["summary"].is_string());
    }

    #[tokio::test]
    async fn preview_compaction_session_not_found() {
        let ctx = make_test_context();
        let err = PreviewCompactionHandler
            .handle(Some(json!({"sessionId": "nonexistent"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "SESSION_NOT_FOUND");
    }

    // ── ConfirmCompactionHandler ──

    #[tokio::test]
    async fn confirm_compaction_persists_event() {
        let (ctx, sid) = ctx_with_session();

        // Add messages to compact
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"content": "hello"}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({
                "content": [{"type": "text", "text": "hi"}],
                "turn": 1,
                "tokenUsage": {"inputTokens": 10, "outputTokens": 5}
            }),
            parent_id: None,
        });
        ctx.session_manager.invalidate_session(&sid);

        let result = ConfirmCompactionHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["confirmed"], true);
        assert!(result["success"].as_bool().unwrap());
    }

    #[tokio::test]
    async fn confirm_compaction_with_edited_summary() {
        let (ctx, sid) = ctx_with_session();

        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageUser,
            payload: json!({"content": "test"}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &sid,
            event_type: tron_events::EventType::MessageAssistant,
            payload: json!({
                "content": [{"type": "text", "text": "reply"}],
                "turn": 1,
                "tokenUsage": {"inputTokens": 10, "outputTokens": 5}
            }),
            parent_id: None,
        });
        ctx.session_manager.invalidate_session(&sid);

        let result = ConfirmCompactionHandler
            .handle(
                Some(json!({"sessionId": sid, "editedSummary": "User edited summary"})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["confirmed"], true);
    }

    // ── CompactHandler ──

    #[tokio::test]
    async fn compact_uses_keyword_summarizer() {
        let (ctx, sid) = ctx_with_session();
        let result = CompactHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert!(result["success"].as_bool().unwrap());
        assert!(result["tokensBefore"].is_number());
        assert!(result["tokensAfter"].is_number());
    }

    #[tokio::test]
    async fn compact_session_not_found() {
        let ctx = make_test_context();
        let err = CompactHandler
            .handle(Some(json!({"sessionId": "nonexistent"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "SESSION_NOT_FOUND");
    }

    // ── ClearHandler ──

    #[tokio::test]
    async fn clear_returns_success_and_tokens() {
        let (ctx, sid) = ctx_with_session();
        let result = ClearHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["success"], true);
        assert!(result["tokensBefore"].is_number());
        assert_eq!(result["tokensAfter"], 0);
    }

    #[tokio::test]
    async fn clear_emits_context_cleared_event() {
        let (ctx, sid) = ctx_with_session();
        let mut rx = ctx.orchestrator.subscribe();

        let _ = ClearHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();

        let event = rx.try_recv().unwrap();
        assert_eq!(event.event_type(), "context_cleared");
    }

    #[tokio::test]
    async fn clear_invalidates_session() {
        let (ctx, sid) = ctx_with_session();

        // Session should be active before clear
        assert!(ctx.session_manager.is_active(&sid));

        let _ = ClearHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();

        // Session should be invalidated after clear
        assert!(!ctx.session_manager.is_active(&sid));
    }

    #[tokio::test]
    async fn clear_persists_context_cleared_event() {
        let (ctx, sid) = ctx_with_session();

        let _ = ClearHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();

        let events = ctx
            .event_store
            .get_events_by_type(&sid, &["context.cleared"], Some(10))
            .unwrap();
        assert!(!events.is_empty(), "context.cleared event should be persisted");
    }

    // ── Memory from workspace ledger ──

    #[tokio::test]
    async fn get_detailed_snapshot_memory_from_ledger() {
        let ctx = make_test_context();
        let workspace_path = "/tmp/memory-test-ws";

        // Create an older session in the same workspace with a ledger entry
        let older_sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", workspace_path, Some("older"))
            .unwrap();
        let _ = ctx.event_store.append(&tron_events::AppendOptions {
            session_id: &older_sid,
            event_type: tron_events::EventType::MemoryLedger,
            payload: json!({
                "title": "Implemented dark mode",
                "entryType": "feature",
                "lessons": ["Use CSS variables for theming", "Test both light and dark"],
            }),
            parent_id: None,
        });

        // Create the current session in the same workspace
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", workspace_path, Some("current"))
            .unwrap();

        let result = GetDetailedSnapshotHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();

        let memory = &result["memory"];
        assert!(memory.is_object(), "memory should be populated from ledger, got: {memory}");
        assert!(memory["count"].as_u64().unwrap() > 0);
        assert!(memory["tokens"].as_u64().is_some());

        let entries = memory["entries"].as_array().unwrap();
        assert!(!entries.is_empty());
        assert_eq!(entries[0]["title"], "Implemented dark mode");
        let content = entries[0]["content"].as_str().unwrap();
        assert!(content.contains("dark mode"), "entry content should contain title");
        assert!(content.contains("CSS variables"), "entry content should contain lessons");
    }

    #[tokio::test]
    async fn get_detailed_snapshot_memory_null_when_no_ledger() {
        let (ctx, sid) = ctx_with_session();

        let result = GetDetailedSnapshotHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();

        // /tmp has no workspace ledger entries → memory should be null
        assert!(result["memory"].is_null(), "memory should be null with no ledger entries");
    }
}
