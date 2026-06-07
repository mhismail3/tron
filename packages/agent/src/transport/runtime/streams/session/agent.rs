use super::*;

pub(super) fn convert(event: &TronEvent) -> Option<ProjectedEvent> {
    match event {
        TronEvent::AgentStart { .. } => Some(session_scoped(event, "agent.start", Some(json!({})))),
        TronEvent::AgentEnd { error, .. } => {
            let mut data = json!({ "agentPhase": "postProcessing" });
            if let Some(message) = error {
                data["error"] = json!(message);
            }
            Some(global(event, "agent.complete", Some(data)))
        }
        TronEvent::AgentReady { .. } => Some(global(
            event,
            "agent.ready",
            Some(json!({ "agentPhase": "idle" })),
        )),
        TronEvent::Error {
            error,
            context,
            code,
            provider,
            category,
            suggestion,
            retryable,
            status_code,
            error_type,
            model,
            ..
        } => {
            let mut data = json!({ "message": error });
            set_opt(&mut data, "context", context);
            set_opt(&mut data, "code", code);
            set_opt(&mut data, "provider", provider);
            set_opt(&mut data, "category", category);
            set_opt(&mut data, "suggestion", suggestion);
            set_opt(&mut data, "retryable", retryable);
            set_opt(&mut data, "statusCode", status_code);
            set_opt(&mut data, "errorType", error_type);
            set_opt(&mut data, "model", model);
            Some(global(event, "agent.error", Some(data)))
        }
        TronEvent::CompactionStart {
            reason,
            tokens_before,
            ..
        } => Some(session_scoped(
            event,
            "agent.compaction_started",
            Some(json!({
                "reason": reason,
                "tokensBefore": tokens_before,
            })),
        )),
        TronEvent::CompactionComplete {
            success,
            tokens_before,
            tokens_after,
            compression_ratio,
            reason,
            summary,
            estimated_context_tokens,
            preserved_turns,
            summarized_turns,
            ..
        } => {
            let mut data = json!({
                "success": success,
                "tokensBefore": tokens_before,
                "tokensAfter": tokens_after,
                "compressionRatio": compression_ratio,
            });
            if let Some(reason) = reason {
                data["reason"] = serde_json::to_value(reason).unwrap_or_default();
            }
            set_opt(&mut data, "summary", summary);
            set_opt(
                &mut data,
                "estimatedContextTokens",
                estimated_context_tokens,
            );
            set_opt(&mut data, "preservedTurns", preserved_turns);
            set_opt(&mut data, "summarizedTurns", summarized_turns);
            Some(session_scoped(event, "agent.compaction", Some(data)))
        }
        TronEvent::ContextWarning {
            usage_percent,
            message,
            ..
        } => Some(session_scoped(
            event,
            "context.warning",
            Some(json!({
                "usagePercent": usage_percent,
                "message": message,
            })),
        )),
        TronEvent::ContextCleared {
            tokens_before,
            tokens_after,
            ..
        } => Some(session_scoped(
            event,
            "agent.context_cleared",
            Some(json!({
                "tokensBefore": tokens_before,
                "tokensAfter": tokens_after,
            })),
        )),
        _ => None,
    }
}
