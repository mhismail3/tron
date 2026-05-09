use crate::shared::events::TronEvent;
use serde_json::json;

use super::routed::{ProjectedEvent, session_scoped, set_opt};

pub(super) fn convert(event: &TronEvent) -> Option<ProjectedEvent> {
    match event {
        TronEvent::HookTriggered {
            hook_names,
            hook_event,
            tool_name,
            tool_call_id,
            ..
        } => {
            let mut data = json!({
                "hookNames": hook_names,
                "hookEvent": hook_event,
            });
            set_opt(&mut data, "toolName", tool_name);
            set_opt(&mut data, "toolCallId", tool_call_id);
            Some(session_scoped(event, "hook.triggered", Some(data)))
        }
        TronEvent::HookCompleted {
            hook_names,
            hook_event,
            result,
            duration,
            reason,
            tool_name,
            tool_call_id,
            ..
        } => {
            let mut data = json!({
                "hookNames": hook_names,
                "hookEvent": hook_event,
                "result": result,
            });
            set_opt(&mut data, "duration", duration);
            set_opt(&mut data, "reason", reason);
            set_opt(&mut data, "toolName", tool_name);
            set_opt(&mut data, "toolCallId", tool_call_id);
            Some(session_scoped(event, "hook.completed", Some(data)))
        }
        TronEvent::HookBackgroundStarted {
            hook_names,
            hook_event,
            execution_id,
            ..
        } => Some(session_scoped(
            event,
            "hook.background_started",
            Some(json!({
                "hookNames": hook_names,
                "hookEvent": hook_event,
                "executionId": execution_id,
            })),
        )),
        TronEvent::HookBackgroundCompleted {
            hook_names,
            hook_event,
            execution_id,
            result,
            duration,
            error,
            ..
        } => {
            let mut data = json!({
                "hookNames": hook_names,
                "hookEvent": hook_event,
                "executionId": execution_id,
                "result": result,
                "duration": duration,
            });
            set_opt(&mut data, "error", error);
            Some(session_scoped(
                event,
                "hook.background_completed",
                Some(data),
            ))
        }
        TronEvent::LlmHookResult {
            hook_name,
            hook_id,
            hook_event,
            output,
            duration_ms,
            model,
            input_tokens,
            output_tokens,
            success,
            error,
            suggestions,
            ..
        } => {
            let mut data = json!({
                "hookName": hook_name,
                "hookId": hook_id,
                "hookEvent": hook_event,
                "durationMs": duration_ms,
                "model": model,
                "inputTokens": input_tokens,
                "outputTokens": output_tokens,
                "success": success,
            });
            set_opt(&mut data, "output", output);
            set_opt(&mut data, "error", error);
            if let Some(suggestions) = suggestions {
                data["suggestions"] = json!(suggestions);
            }
            Some(session_scoped(event, "hook.llm_result", Some(data)))
        }
        _ => None,
    }
}
