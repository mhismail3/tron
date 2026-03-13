use serde_json::{Value, json};

use crate::rpc::context::RpcContext;
use crate::rpc::context_queries::prepare_session_context;
use crate::rpc::context_service::build_summarizer;
use crate::rpc::errors::RpcError;

pub(crate) struct ContextCommandService;

impl ContextCommandService {
    pub(crate) async fn confirm_compaction(
        ctx: &RpcContext,
        session_id: String,
        edited_summary: Option<String>,
    ) -> Result<Value, RpcError> {
        let result = execute_compaction(ctx, session_id, edited_summary).await?;
        Ok(json!({
            "confirmed": true,
            "success": result.success,
            "tokensBefore": result.tokens_before,
            "tokensAfter": result.tokens_after,
            "compressionRatio": result.compression_ratio,
            "summary": result.summary,
        }))
    }

    pub(crate) async fn clear(ctx: &RpcContext, session_id: String) -> Result<Value, RpcError> {
        let tokens_before =
            match prepare_session_context(ctx, "context.clear.snapshot", &session_id).await {
                Ok(prepared) => prepared.context_manager.get_snapshot().current_tokens,
                Err(_) => 0,
            };

        let event_store = ctx.event_store.clone();
        let session_id_for_event = session_id.clone();
        let _ = ctx
            .run_blocking("context.clear.persist", move || {
                let _ = event_store.append(&tron_events::AppendOptions {
                    session_id: &session_id_for_event,
                    event_type: tron_events::EventType::ContextCleared,
                    payload: json!({
                        "tokensBefore": tokens_before,
                        "tokensAfter": 0,
                    }),
                    parent_id: None,
                });
                Ok(())
            })
            .await;

        ctx.session_manager.invalidate_session(&session_id);

        #[allow(clippy::cast_possible_wrap)]
        let _ = ctx
            .orchestrator
            .broadcast()
            .emit(tron_core::events::TronEvent::ContextCleared {
                base: tron_core::events::BaseEvent::now(&session_id),
                tokens_before: tokens_before as i64,
                tokens_after: 0,
            });

        Ok(json!({
            "success": true,
            "tokensBefore": tokens_before,
            "tokensAfter": 0,
        }))
    }

    pub(crate) async fn compact(ctx: &RpcContext, session_id: String) -> Result<Value, RpcError> {
        let result = execute_compaction(ctx, session_id, None).await?;
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
    ctx: &RpcContext,
    session_id: String,
    edited_summary: Option<String>,
) -> Result<tron_runtime::context::types::CompactionResult, RpcError> {
    let prepared = prepare_session_context(ctx, "context.compaction.prepare", &session_id).await?;
    let mut context_manager = prepared.context_manager;
    let summarizer = build_summarizer(ctx, &session_id, &prepared.session.working_directory);

    let tokens_before = context_manager.get_current_tokens();
    let _ = ctx
        .orchestrator
        .broadcast()
        .emit(tron_core::events::TronEvent::CompactionStart {
            base: tron_core::events::BaseEvent::now(&session_id),
            reason: tron_core::events::CompactionReason::Manual,
            tokens_before,
        });

    let result = context_manager
        .execute_compaction(summarizer.as_ref(), edited_summary.as_deref())
        .await
        .map_err(|error| RpcError::Internal {
            message: format!("Compaction failed: {error}"),
        })?;

    let event_store = ctx.event_store.clone();
    let session_id_for_boundary = session_id.clone();
    let summary = result.summary.clone();
    let _ = ctx
        .run_blocking("context.compaction.persist_boundary", move || {
            let _ = event_store.append(&tron_events::AppendOptions {
                session_id: &session_id_for_boundary,
                event_type: tron_events::EventType::CompactBoundary,
                payload: json!({
                    "originalTokens": result.tokens_before,
                    "compactedTokens": result.tokens_after,
                    "compressionRatio": result.compression_ratio,
                    "reason": "Manual",
                    "summary": summary,
                    "estimatedContextTokens": result.tokens_after,
                }),
                parent_id: None,
            });
            Ok(())
        })
        .await;

    let _ = ctx
        .orchestrator
        .broadcast()
        .emit(tron_core::events::TronEvent::CompactionComplete {
            base: tron_core::events::BaseEvent::now(&session_id),
            success: result.success,
            tokens_before: result.tokens_before,
            tokens_after: result.tokens_after,
            compression_ratio: result.compression_ratio,
            reason: Some(tron_core::events::CompactionReason::Manual),
            summary: Some(result.summary.clone()),
            estimated_context_tokens: Some(result.tokens_after),
        });

    ctx.session_manager.invalidate_session(&session_id);

    Ok(result)
}
