use serde_json::json;
use crate::core::events::TronEvent;

use super::routed::{BridgedEvent, session_scoped, set_opt};

pub(super) fn convert(event: &TronEvent) -> Option<BridgedEvent> {
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
        _ => None,
    }
}
