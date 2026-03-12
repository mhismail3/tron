use serde_json::json;
use tron_core::events::TronEvent;

use super::routed::{BridgedEvent, session_scoped};

pub(super) fn convert(event: &TronEvent) -> Option<BridgedEvent> {
    match event {
        TronEvent::ThinkingStart { .. } => Some(session_scoped(
            event,
            "agent.thinking_start",
            Some(json!({})),
        )),
        TronEvent::ThinkingDelta { delta, .. } => Some(session_scoped(
            event,
            "agent.thinking_delta",
            Some(json!({ "delta": delta })),
        )),
        TronEvent::ThinkingEnd { thinking, .. } => Some(session_scoped(
            event,
            "agent.thinking_end",
            Some(json!({ "thinking": thinking })),
        )),
        _ => None,
    }
}
