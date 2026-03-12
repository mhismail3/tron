use serde_json::{Value, json};
use tron_core::events::TronEvent;

use super::routed::{BridgedEvent, global, session_scoped, set_opt};

pub(super) fn convert(event: &TronEvent) -> Option<BridgedEvent> {
    match event {
        TronEvent::TurnStart { turn, .. } => Some(global(
            event,
            "agent.turn_start",
            Some(json!({ "turn": turn })),
        )),
        TronEvent::TurnEnd {
            turn,
            duration,
            token_usage,
            token_record,
            cost,
            stop_reason,
            context_limit,
            model,
            ..
        } => {
            let mut data = json!({
                "turn": turn,
                "duration": duration,
            });
            insert_token_usage(&mut data, token_usage.as_ref());
            if let Some(record) = token_record {
                data["tokenRecord"] = record.clone();
            }
            set_opt(&mut data, "cost", cost);
            set_opt(&mut data, "stopReason", stop_reason);
            set_opt(&mut data, "contextLimit", context_limit);
            set_opt(&mut data, "model", model);
            Some(session_scoped(event, "agent.turn_end", Some(data)))
        }
        TronEvent::TurnFailed {
            turn,
            error,
            code,
            category,
            recoverable,
            partial_content,
            ..
        } => {
            let mut data = json!({
                "turn": turn,
                "error": error,
                "recoverable": recoverable,
            });
            set_opt(&mut data, "code", code);
            set_opt(&mut data, "category", category);
            set_opt(&mut data, "partialContent", partial_content);
            Some(session_scoped(event, "agent.turn_failed", Some(data)))
        }
        TronEvent::ResponseComplete {
            turn,
            stop_reason,
            token_usage,
            has_tool_calls,
            tool_call_count,
            token_record,
            model,
            ..
        } => {
            let mut data = json!({
                "turn": turn,
                "stopReason": stop_reason,
                "hasToolCalls": has_tool_calls,
                "toolCallCount": tool_call_count,
            });
            insert_token_usage(&mut data, token_usage.as_ref());
            if let Some(record) = token_record {
                data["tokenRecord"] = record.clone();
            }
            set_opt(&mut data, "model", model);
            Some(session_scoped(event, "agent.response_complete", Some(data)))
        }
        TronEvent::AgentInterrupted {
            turn,
            partial_content,
            active_tool,
            ..
        } => {
            let mut data = json!({ "turn": turn });
            set_opt(&mut data, "partialContent", partial_content);
            set_opt(&mut data, "activeTool", active_tool);
            Some(session_scoped(event, "agent.interrupted", Some(data)))
        }
        TronEvent::ApiRetry {
            attempt,
            max_retries,
            delay_ms,
            error_category,
            error_message,
            ..
        } => Some(session_scoped(
            event,
            "agent.retry",
            Some(json!({
                "attempt": attempt,
                "maxRetries": max_retries,
                "delayMs": delay_ms,
                "errorCategory": error_category,
                "errorMessage": error_message,
            })),
        )),
        _ => None,
    }
}

fn insert_token_usage(data: &mut Value, token_usage: Option<&tron_core::events::TurnTokenUsage>) {
    if let Some(usage) = token_usage {
        data["tokenUsage"] = serde_json::to_value(usage).unwrap_or_default();
    }
}
