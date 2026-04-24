use crate::core::events::TronEvent;
use serde_json::json;

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
        TronEvent::MessageQueued {
            queue_id,
            text,
            position,
            ..
        } => Some(session_scoped(
            event,
            "agent.message_queued",
            Some(json!({
                "queueId": queue_id,
                "text": text,
                "position": position,
            })),
        )),
        TronEvent::MessageDequeued {
            queue_id, reason, ..
        } => Some(session_scoped(
            event,
            "agent.message_dequeued",
            Some(json!({
                "queueId": queue_id,
                "reason": reason,
            })),
        )),
        TronEvent::QueuedMessageSent { text, queue_id, .. } => Some(session_scoped(
            event,
            "agent.queued_message_sent",
            Some(json!({
                "text": text,
                "queueId": queue_id,
            })),
        )),
        _ => None,
    }
}
