use serde_json::{Value, json};

use crate::domains::context::Deps;
use crate::domains::context::queries::prepare_session_context;
use crate::domains::context::service::build_summarizer;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;

// NOTE: Event appends in this module use `let _ =` because they are supplementary
// audit-trail emissions. The capability response has already been determined; a failed
// append should not change the client-visible result.
pub(crate) struct ContextCommandService;

impl ContextCommandService {
    pub(crate) async fn confirm_compaction(
        deps: &Deps,
        session_id: String,
        edited_summary: Option<String>,
    ) -> Result<Value, CapabilityError> {
        let result = execute_compaction(deps, session_id, edited_summary).await?;
        Ok(json!({
            "confirmed": true,
            "success": result.success,
            "tokensBefore": result.tokens_before,
            "tokensAfter": result.tokens_after,
            "compressionRatio": result.compression_ratio,
            "summary": result.summary,
        }))
    }

    pub(crate) async fn clear(deps: &Deps, session_id: String) -> Result<Value, CapabilityError> {
        let tokens_before =
            match prepare_session_context(deps, "context.clear.snapshot", &session_id).await {
                Ok(prepared) => prepared.context_manager.get_snapshot().current_tokens,
                Err(_) => 0,
            };

        let event_store = deps.event_store.clone();
        let session_id_for_event = session_id.clone();
        let _ = run_blocking_task("context.clear.persist", move || {
            let _ = event_store.append(&crate::domains::session::event_store::AppendOptions {
                session_id: &session_id_for_event,
                event_type: crate::domains::session::event_store::EventType::ContextCleared,
                payload: json!({
                    "tokensBefore": tokens_before,
                    "tokensAfter": 0,
                }),
                parent_id: None,
                sequence: None,
            });
            Ok(())
        })
        .await;

        deps.session_manager.invalidate_session(&session_id);

        #[allow(clippy::cast_possible_wrap)]
        let _ =
            deps.orchestrator
                .broadcast()
                .emit(crate::shared::events::TronEvent::ContextCleared {
                    base: crate::shared::events::BaseEvent::now(&session_id),
                    tokens_before: tokens_before as i64,
                    tokens_after: 0,
                });

        Ok(json!({
            "success": true,
            "tokensBefore": tokens_before,
            "tokensAfter": 0,
        }))
    }

    pub(crate) async fn compact(deps: &Deps, session_id: String) -> Result<Value, CapabilityError> {
        let result = execute_compaction(deps, session_id, None).await?;
        Ok(json!({
            "success": result.success,
            "tokensBefore": result.tokens_before,
            "tokensAfter": result.tokens_after,
            "compressionRatio": result.compression_ratio,
            "summary": result.summary,
        }))
    }
}

async fn execute_compaction(
    deps: &Deps,
    session_id: String,
    edited_summary: Option<String>,
) -> Result<crate::domains::agent::runner::context::types::CompactionResult, CapabilityError> {
    // If an agent is actively running, check concurrency guard to prevent
    // racing with auto-compaction.
    if let Some(handler) = deps.orchestrator.get_compaction_handler(&session_id) {
        if handler.is_compacting() {
            return Err(CapabilityError::Internal {
                message: "Compaction already in progress".to_string(),
            });
        }
    }

    let prepared = prepare_session_context(deps, "context.compaction.prepare", &session_id).await?;
    let mut context_manager = prepared.context_manager;
    let summarizer = build_summarizer(deps, &session_id, &prepared.session.working_directory);

    let tokens_before = context_manager.get_current_tokens();
    let _ = deps
        .orchestrator
        .broadcast()
        .emit(crate::shared::events::TronEvent::CompactionStart {
            base: crate::shared::events::BaseEvent::now(&session_id),
            reason: crate::shared::events::CompactionReason::Manual,
            tokens_before,
        });

    let result = context_manager
        .execute_compaction(summarizer.as_ref(), edited_summary.as_deref())
        .await
        .map_err(|error| CapabilityError::Internal {
            message: format!("Compaction failed: {error}"),
        })?;

    // Total context tokens (system prompt + tools + rules + messages) — for the
    // progress pill. Distinct from result.tokens_after which is message-only.
    let total_context_after = context_manager.get_current_tokens();

    let event_store = deps.event_store.clone();
    let session_id_for_boundary = session_id.clone();
    let summary = result.summary.clone();
    let _ = run_blocking_task("context.compaction.persist_boundary", move || {
        let _ = event_store.append(&crate::domains::session::event_store::AppendOptions {
            session_id: &session_id_for_boundary,
            event_type: crate::domains::session::event_store::EventType::CompactBoundary,
            payload: json!({
                "originalTokens": result.tokens_before,
                "compactedTokens": result.tokens_after,
                "compressionRatio": result.compression_ratio,
                // snake_case mirrors `CompactionReason::Manual` serde encoding.
                "reason": "manual",
                "summary": summary,
                "estimatedContextTokens": total_context_after,
                "preservedTurns": result.preserved_turns,
                "summarizedTurns": result.summarized_turns,
                "preservedMessages": result.preserved_messages,
            }),
            parent_id: None,
            sequence: None,
        });
        Ok(())
    })
    .await;

    let _ =
        deps.orchestrator
            .broadcast()
            .emit(crate::shared::events::TronEvent::CompactionComplete {
                base: crate::shared::events::BaseEvent::now(&session_id),
                success: result.success,
                tokens_before: result.tokens_before,
                tokens_after: result.tokens_after,
                compression_ratio: result.compression_ratio,
                reason: Some(crate::shared::events::CompactionReason::Manual),
                summary: Some(result.summary.clone()),
                estimated_context_tokens: Some(total_context_after),
                preserved_turns: Some(result.preserved_turns),
                summarized_turns: Some(result.summarized_turns),
            });

    deps.session_manager.invalidate_session(&session_id);

    Ok(result)
}
