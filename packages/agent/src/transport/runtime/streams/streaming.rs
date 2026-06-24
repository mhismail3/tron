use crate::shared::protocol::events::TronEvent;
use serde_json::json;

use super::routed::{ProjectedEvent, session_scoped};

pub(super) fn convert(event: &TronEvent) -> Option<ProjectedEvent> {
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shared::protocol::events::BaseEvent;

    #[test]
    fn thinking_delta_projection_produces_correct_wire_type() {
        let event = TronEvent::ThinkingDelta {
            base: BaseEvent::now("sess-1"),
            delta: "thinking".into(),
        };
        let projected = convert(&event).expect("should convert");
        assert_eq!(projected.server_event.event_type, "agent.thinking_delta");
    }

    #[test]
    fn thinking_delta_projection_includes_delta() {
        let event = TronEvent::ThinkingDelta {
            base: BaseEvent::now("sess-1"),
            delta: "thinking".into(),
        };
        let projected = convert(&event).expect("should convert");
        let data = projected
            .server_event
            .data
            .as_ref()
            .expect("should have data");
        assert_eq!(data["delta"], "thinking");
    }

    #[test]
    fn thinking_delta_is_session_scoped() {
        let event = TronEvent::ThinkingDelta {
            base: BaseEvent::now("sess-42"),
            delta: "d".into(),
        };
        let projected = convert(&event).expect("should convert");
        assert_eq!(
            projected.server_event.session_id.as_deref(),
            Some("sess-42")
        );
    }

    #[test]
    fn unrelated_event_returns_none() {
        let event = TronEvent::AgentStart {
            base: BaseEvent::now("s1"),
        };
        assert!(convert(&event).is_none());
    }
}
