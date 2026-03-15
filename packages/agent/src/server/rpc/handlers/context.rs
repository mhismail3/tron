//! Context handlers: getSnapshot, getDetailedSnapshot, shouldCompact,
//! previewCompaction, confirmCompaction, canAcceptTurn, clear, compact.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::server::rpc::context::RpcContext;
use crate::server::rpc::context_commands::ContextCommandService;
use crate::server::rpc::context_queries::ContextQueryService;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::handlers::{opt_string, require_string_param};
use crate::server::rpc::registry::MethodHandler;

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
        ContextQueryService::get_snapshot(ctx, session_id).await
    }
}

/// Get detailed context snapshot.
pub struct GetDetailedSnapshotHandler;

#[async_trait]
impl MethodHandler for GetDetailedSnapshotHandler {
    #[instrument(
        skip(self, ctx),
        fields(method = "context.getDetailedSnapshot", session_id)
    )]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        ContextQueryService::get_detailed_snapshot(ctx, session_id).await
    }
}

/// Check if compaction is recommended.
pub struct ShouldCompactHandler;

#[async_trait]
impl MethodHandler for ShouldCompactHandler {
    #[instrument(skip(self, ctx), fields(method = "context.shouldCompact", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        ContextQueryService::should_compact(ctx, session_id).await
    }
}

/// Preview what compaction would produce.
pub struct PreviewCompactionHandler;

#[async_trait]
impl MethodHandler for PreviewCompactionHandler {
    #[instrument(
        skip(self, ctx),
        fields(method = "context.previewCompaction", session_id)
    )]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        ContextQueryService::preview_compaction(ctx, session_id).await
    }
}

/// Confirm and execute compaction with optional edited summary.
pub struct ConfirmCompactionHandler;

#[async_trait]
impl MethodHandler for ConfirmCompactionHandler {
    #[instrument(
        skip(self, ctx),
        fields(method = "context.confirmCompaction", session_id)
    )]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let edited_summary = opt_string(params.as_ref(), "editedSummary");
        ContextCommandService::confirm_compaction(ctx, session_id, edited_summary).await
    }
}

/// Check if the context can accept another turn.
pub struct CanAcceptTurnHandler;

#[async_trait]
impl MethodHandler for CanAcceptTurnHandler {
    #[instrument(skip(self, ctx), fields(method = "context.canAcceptTurn", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        ContextQueryService::can_accept_turn(ctx, session_id).await
    }
}

/// Clear context for a session.
pub struct ClearHandler;

#[async_trait]
impl MethodHandler for ClearHandler {
    #[instrument(skip(self, ctx), fields(method = "context.clear", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        ContextCommandService::clear(ctx, session_id).await
    }
}

/// Trigger compaction for a session (without edited summary).
pub struct CompactHandler;

#[async_trait]
impl MethodHandler for CompactHandler {
    #[instrument(skip(self, ctx), fields(method = "context.compact", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        ContextCommandService::compact(ctx, session_id).await
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::rpc::context_service::{
        build_active_skill_context, build_context_manager_for_session, tool_definitions,
    };
    use crate::server::rpc::handlers::test_helpers::make_test_context;
    use parking_lot::RwLock;
    use serde_json::json;
    use std::sync::Arc;
    use crate::skills::registry::SkillRegistry;

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
    async fn get_snapshot_returns_wire_format() {
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
        assert_eq!(limit, crate::llm::model_context_window("claude-opus-4-6"));
    }

    #[tokio::test]
    async fn get_snapshot_with_messages_has_message_tokens() {
        let (ctx, sid) = ctx_with_session();

        // Add message events using correct event store payload format
        let _ = ctx.event_store.append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::MessageUser,
            payload: json!({"content": "hello world this is a test message"}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::MessageAssistant,
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
    async fn get_detailed_snapshot_returns_wire_format() {
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
    async fn get_detailed_snapshot_all_wire_format_fields() {
        let (ctx, sid) = ctx_with_session();
        let result = GetDetailedSnapshotHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let required_fields = [
            "currentTokens",
            "contextLimit",
            "usagePercent",
            "thresholdLevel",
            "breakdown",
            "messages",
            "systemPromptContent",
            "toolsContent",
            "addedSkills",
            "composedSystemPrompt",
            "environment",
        ];
        for field in &required_fields {
            assert!(
                result.get(field).is_some() && !result[field].is_null(),
                "missing required field: {field}"
            );
        }
        let optional_fields = [
            "toolClarificationContent",
            "rules",
            "memory",
            "sessionMemories",
            "taskContext",
        ];
        for field in &optional_fields {
            assert!(
                result.get(field).is_some(),
                "missing optional field: {field}"
            );
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
        assert!(
            !content.is_empty(),
            "systemPromptContent should be non-empty"
        );
    }

    #[tokio::test]
    async fn get_detailed_snapshot_with_messages() {
        let (ctx, sid) = ctx_with_session();

        let _ = ctx.event_store.append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::MessageUser,
            payload: json!({"content": "hello"}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::MessageAssistant,
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
        assert!(
            !messages.is_empty(),
            "expected at least 1 message, got {}",
            messages.len()
        );
    }

    #[tokio::test]
    async fn get_detailed_snapshot_message_has_preview() {
        let (ctx, sid) = ctx_with_session();

        let _ = ctx.event_store.append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::MessageUser,
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
        assert!(
            rules_obj.is_object(),
            "rules should be an object, got: {rules_obj}"
        );
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
    async fn get_detailed_snapshot_dedupes_dynamic_rule_already_loaded() {
        let tmp = tempfile::tempdir().unwrap();
        let claude_dir = tmp.path().join(".claude");
        std::fs::create_dir_all(&claude_dir).unwrap();
        std::fs::write(claude_dir.join("AGENTS.md"), "# Test Rules\nBe helpful.").unwrap();

        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("claude-opus-4-6", tmp.path().to_str().unwrap(), None)
            .unwrap();

        let _ = ctx.event_store.append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::RulesActivated,
            payload: json!({
                "rules": [{
                    "relativePath": ".claude/AGENTS.md",
                    "scopeDir": ".claude",
                }],
                "totalActivated": 1,
            }),
            parent_id: None,
        });

        let result = GetDetailedSnapshotHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();

        let files = result["rules"]["files"].as_array().unwrap();
        let matching = files
            .iter()
            .filter(|file| file["relativePath"] == ".claude/AGENTS.md")
            .count();
        assert_eq!(matching, 1, "expected dynamic rule path to be deduped");
    }

    #[tokio::test]
    async fn get_detailed_snapshot_added_skills() {
        let (ctx, sid) = ctx_with_session();

        // Add a skill event
        let _ = ctx.event_store.append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::SkillAdded,
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
        let _ = ctx.event_store.append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::SkillAdded,
            payload: json!({"skillName": "web-search", "source": "global", "addedVia": "explicit"}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::SkillRemoved,
            payload: json!({"skillName": "web-search"}),
            parent_id: None,
        });
        // Add another skill that stays
        let _ = ctx.event_store.append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::SkillAdded,
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
        let _ = ctx.event_store.append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::MessageAssistant,
            payload: json!({
                "content": [{"type": "text", "text": "response"}],
                "turn": 1,
                "tokenUsage": {"inputTokens": 875_000, "outputTokens": 5_000}
            }),
            parent_id: None,
        });

        ctx.session_manager.invalidate_session(&sid);

        let result = ShouldCompactHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        // last_turn_input_tokens = 875k, context_limit = 1M → ratio 0.875 >= 0.85 threshold
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
        let _ = ctx.event_store.append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::MessageAssistant,
            payload: json!({
                "content": [{"type": "text", "text": "r"}],
                "turn": 1,
                "tokenUsage": {"inputTokens": 900_000, "outputTokens": 50_000}
            }),
            parent_id: None,
        });

        ctx.session_manager.invalidate_session(&sid);

        let result = CanAcceptTurnHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        // 950k / 1M = 0.95 which is >= critical (0.85)
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
        assert!(result["preservedMessages"].is_number());
        assert!(result["summarizedMessages"].is_number());
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
        let _ = ctx.event_store.append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::MessageUser,
            payload: json!({"content": "hello"}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::MessageAssistant,
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

        let _ = ctx.event_store.append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::MessageUser,
            payload: json!({"content": "test"}),
            parent_id: None,
        });
        let _ = ctx.event_store.append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: crate::events::EventType::MessageAssistant,
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
        assert!(
            !events.is_empty(),
            "context.cleared event should be persisted"
        );
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
        let _ = ctx.event_store.append(&crate::events::AppendOptions {
            session_id: &older_sid,
            event_type: crate::events::EventType::MemoryLedger,
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
        assert!(
            memory.is_object(),
            "memory should be populated from ledger, got: {memory}"
        );
        assert!(memory["count"].as_u64().unwrap() > 0);
        assert!(memory["tokens"].as_u64().is_some());

        let entries = memory["entries"].as_array().unwrap();
        assert!(!entries.is_empty());
        assert_eq!(entries[0]["title"], "Implemented dark mode");
        let content = entries[0]["content"].as_str().unwrap();
        assert!(
            content.contains("dark mode"),
            "entry content should contain title"
        );
        assert!(
            content.contains("CSS variables"),
            "entry content should contain lessons"
        );
    }

    #[tokio::test]
    async fn get_detailed_snapshot_memory_null_when_no_ledger() {
        let (ctx, sid) = ctx_with_session();

        let result = GetDetailedSnapshotHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();

        // /tmp has no workspace ledger entries → memory should be null
        assert!(
            result["memory"].is_null(),
            "memory should be null with no ledger entries"
        );
    }

    // ── composedSystemPrompt ──

    #[tokio::test]
    async fn get_detailed_snapshot_has_composed_system_prompt() {
        let (ctx, sid) = ctx_with_session();
        let result = GetDetailedSnapshotHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert!(
            result["composedSystemPrompt"].is_string(),
            "composedSystemPrompt should be a string"
        );
        assert!(
            !result["composedSystemPrompt"].as_str().unwrap().is_empty(),
            "composedSystemPrompt should be non-empty"
        );
    }

    #[tokio::test]
    async fn get_detailed_snapshot_composed_contains_system_prompt() {
        let (ctx, sid) = ctx_with_session();
        let result = GetDetailedSnapshotHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let composed = result["composedSystemPrompt"].as_str().unwrap();
        let raw = result["systemPromptContent"].as_str().unwrap();
        assert!(
            composed.contains(raw),
            "composed should contain the raw system prompt"
        );
    }

    #[tokio::test]
    async fn get_detailed_snapshot_composed_contains_working_dir() {
        let (ctx, sid) = ctx_with_session();
        let result = GetDetailedSnapshotHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let composed = result["composedSystemPrompt"].as_str().unwrap();
        assert!(
            composed.contains("Current working directory:"),
            "composed should contain working directory"
        );
    }

    #[tokio::test]
    async fn get_detailed_snapshot_composed_with_rules() {
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
        let composed = result["composedSystemPrompt"].as_str().unwrap();
        assert!(
            composed.contains("# Project Rules"),
            "composed should contain rules header"
        );
        assert!(
            composed.contains("Be helpful."),
            "composed should contain rules content"
        );
    }

    #[tokio::test]
    async fn get_detailed_snapshot_composed_without_rules_or_memory() {
        let (ctx, sid) = ctx_with_session();
        let result = GetDetailedSnapshotHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let composed = result["composedSystemPrompt"].as_str().unwrap();
        // Should still have system prompt and working directory even without rules/memory
        assert!(!composed.is_empty());
        assert!(composed.contains("Current working directory:"));
    }

    #[tokio::test]
    async fn get_detailed_snapshot_composed_no_server_origin() {
        let (ctx, sid) = ctx_with_session();
        let result = GetDetailedSnapshotHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let composed = result["composedSystemPrompt"].as_str().unwrap();
        // Default test session has no origin
        assert!(
            !composed.contains("Server:"),
            "composed should not contain Server: when origin is None"
        );
    }

    // ── environment ──

    #[tokio::test]
    async fn get_detailed_snapshot_environment_has_working_directory() {
        let (ctx, sid) = ctx_with_session();
        let result = GetDetailedSnapshotHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let env = &result["environment"];
        assert!(env.is_object());
        assert_eq!(env["workingDirectory"].as_str().unwrap(), "/tmp");
    }

    #[tokio::test]
    async fn get_detailed_snapshot_environment_server_origin_null() {
        let (ctx, sid) = ctx_with_session();
        let result = GetDetailedSnapshotHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert!(
            result["environment"]["serverOrigin"].is_null(),
            "serverOrigin should be null when session has no origin"
        );
    }

    #[tokio::test]
    async fn get_detailed_snapshot_composed_matches_compose_fn() {
        let (ctx, sid) = ctx_with_session();
        let result = GetDetailedSnapshotHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();

        // Manually build the same Context and compose — should match
        let prepared = build_context_manager_for_session(
            &sid,
            ctx.session_manager.as_ref(),
            ctx.event_store.as_ref(),
            ctx.context_artifacts.as_ref(),
            tool_definitions(&ctx),
        )
        .unwrap();
        let base = prepared.context_manager.build_base_context();
        let parts = crate::llm::compose_context_parts(&base);
        let expected = parts.join("\n\n");

        assert_eq!(
            result["composedSystemPrompt"].as_str().unwrap(),
            expected,
            "composedSystemPrompt should match compose_context_parts() output"
        );
    }

    // Helper: create a context with a session that has a server origin
    fn ctx_with_origin_session() -> (RpcContext, String) {
        use crate::server::rpc::context::RpcContext;
        use crate::events::EventStore;
        use crate::runtime::orchestrator::orchestrator::Orchestrator;
        use crate::runtime::orchestrator::session_manager::SessionManager;

        let pool = crate::events::new_in_memory(&crate::events::ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = crate::events::run_migrations(&conn).unwrap();
        }
        let store = Arc::new(EventStore::new(pool));
        let mgr =
            Arc::new(SessionManager::new(store.clone()).with_origin("localhost:9847".to_string()));
        let orch = Arc::new(Orchestrator::new(mgr.clone(), 10));
        let ctx = RpcContext {
            orchestrator: orch,
            session_manager: mgr.clone(),
            event_store: store,
            skill_registry: Arc::new(RwLock::new(SkillRegistry::new())),
            task_pool: None,
            settings_path: std::path::PathBuf::from("/tmp/tron-test-settings.json"),
            agent_deps: None,
            server_start_time: std::time::Instant::now(),
            browser_service: None,
            transcription_engine: Arc::new(std::sync::OnceLock::new()),
            embedding_controller: None,
            subagent_manager: None,
            health_tracker: Arc::new(crate::llm::ProviderHealthTracker::new()),
            shutdown_coordinator: None,
            origin: "localhost:9847".to_string(),
            cron_scheduler: None,
            worktree_coordinator: None,
            device_request_broker: None,
            context_artifacts: Arc::new(crate::server::rpc::session_context::ContextArtifactsService::new()),
        };
        let sid = mgr
            .create_session("claude-opus-4-6", "/tmp", Some("origin-test"))
            .unwrap();
        (ctx, sid)
    }

    #[tokio::test]
    async fn get_detailed_snapshot_environment_server_origin_present() {
        let (ctx, sid) = ctx_with_origin_session();
        let result = GetDetailedSnapshotHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert_eq!(
            result["environment"]["serverOrigin"].as_str().unwrap(),
            "localhost:9847",
            "serverOrigin should match the session's origin"
        );
    }

    #[tokio::test]
    async fn get_detailed_snapshot_composed_with_server_origin() {
        let (ctx, sid) = ctx_with_origin_session();
        let result = GetDetailedSnapshotHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        let composed = result["composedSystemPrompt"].as_str().unwrap();
        assert!(
            composed.contains("Server: localhost:9847"),
            "composed should contain Server: when origin is set"
        );
    }

    // ── build_active_skill_context ──

    #[test]
    fn build_active_skill_context_empty_names() {
        let registry = Arc::new(RwLock::new(SkillRegistry::new()));
        assert!(build_active_skill_context(&[], &registry).is_none());
    }

    #[test]
    fn build_active_skill_context_unknown_skill() {
        let registry = Arc::new(RwLock::new(SkillRegistry::new()));
        let names = vec!["nonexistent".to_string()];
        assert!(build_active_skill_context(&names, &registry).is_none());
    }
}
