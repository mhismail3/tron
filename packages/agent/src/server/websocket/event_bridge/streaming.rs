use serde_json::json;
use crate::core::events::TronEvent;

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
        TronEvent::DisplayFrame {
            stream_id,
            tool_call_id,
            data,
            frame_id,
            width,
            height,
            ..
        } => Some(session_scoped(
            event,
            "display.frame",
            Some(json!({
                "streamId": stream_id,
                "toolCallId": tool_call_id,
                "data": data,
                "frameId": frame_id,
                "width": width,
                "height": height,
            })),
        )),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::core::events::BaseEvent;

    #[test]
    fn display_frame_bridge_produces_correct_wire_type() {
        let event = TronEvent::DisplayFrame {
            base: BaseEvent::now("sess-1"),
            stream_id: "stream-1".into(),
            tool_call_id: "call-1".into(),
            data: "b64data".into(),
            frame_id: 5,
            width: 1280,
            height: 720,
        };
        let bridged = convert(&event).expect("should convert");
        assert_eq!(bridged.rpc_event.event_type, "display.frame");
    }

    #[test]
    fn display_frame_bridge_includes_all_fields() {
        let event = TronEvent::DisplayFrame {
            base: BaseEvent::now("sess-1"),
            stream_id: "stream-1".into(),
            tool_call_id: "call-1".into(),
            data: "b64data".into(),
            frame_id: 5,
            width: 1280,
            height: 720,
        };
        let bridged = convert(&event).expect("should convert");
        let data = bridged.rpc_event.data.as_ref().expect("should have data");
        assert_eq!(data["streamId"], "stream-1");
        assert_eq!(data["toolCallId"], "call-1");
        assert_eq!(data["data"], "b64data");
        assert_eq!(data["frameId"], 5);
        assert_eq!(data["width"], 1280);
        assert_eq!(data["height"], 720);
    }

    #[test]
    fn display_frame_is_session_scoped() {
        let event = TronEvent::DisplayFrame {
            base: BaseEvent::now("sess-42"),
            stream_id: "s".into(),
            tool_call_id: "t".into(),
            data: "d".into(),
            frame_id: 1,
            width: 640,
            height: 480,
        };
        let bridged = convert(&event).expect("should convert");
        assert_eq!(bridged.rpc_event.session_id.as_deref(), Some("sess-42"));
    }

    #[test]
    fn unrelated_event_returns_none() {
        let event = TronEvent::AgentStart {
            base: BaseEvent::now("s1"),
        };
        assert!(convert(&event).is_none());
    }
}
