use serde_json::json;
use tron_core::events::TronEvent;

use super::routed::{BridgedEvent, session_scoped};

pub(super) fn convert(event: &TronEvent) -> Option<BridgedEvent> {
    match event {
        TronEvent::MessageUpdate { content, .. } => Some(session_scoped(
            event,
            "agent.text_delta",
            Some(json!({ "delta": content })),
        )),
        TronEvent::MessageDeleted {
            target_event_id,
            target_type,
            target_turn,
            reason,
            ..
        } => Some(session_scoped(
            event,
            "agent.message_deleted",
            Some(json!({
                "targetEventId": target_event_id,
                "targetType": target_type,
                "targetTurn": target_turn,
                "reason": reason,
            })),
        )),
        _ => None,
    }
}
