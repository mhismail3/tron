//! Event bridge for RenderUI events.

use serde_json::json;
use crate::core::events::TronEvent;
use super::routed::{BridgedEvent, session_scoped};

pub(super) fn convert(event: &TronEvent) -> Option<BridgedEvent> {
    match event {
        TronEvent::RenderUIStarted {
            canvas_id,
            url,
            title,
            tool_call_id,
            ..
        } => {
            let mut data = json!({
                "canvasId": canvas_id,
                "url": url,
                "toolCallId": tool_call_id,
            });
            if let Some(t) = title {
                data["title"] = json!(t);
            }
            Some(session_scoped(event, "render_ui.started", Some(data)))
        }
        TronEvent::RenderUIReady {
            canvas_id,
            url,
            ..
        } => Some(session_scoped(
            event,
            "render_ui.ready",
            Some(json!({
                "canvasId": canvas_id,
                "url": url,
            })),
        )),
        TronEvent::RenderUIError {
            canvas_id,
            error,
            ..
        } => Some(session_scoped(
            event,
            "render_ui.error",
            Some(json!({
                "canvasId": canvas_id,
                "error": error,
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
    fn converts_render_ui_started() {
        let event = TronEvent::RenderUIStarted {
            base: BaseEvent::now("s1"),
            canvas_id: "c1".into(),
            url: "http://localhost:9250/canvas/c1".into(),
            title: Some("My UI".into()),
            tool_call_id: "call-1".into(),
        };
        let bridged = convert(&event).unwrap();
        assert_eq!(bridged.rpc_event.event_type, "render_ui.started");
        let data = bridged.rpc_event.data.unwrap();
        assert_eq!(data["canvasId"], "c1");
        assert_eq!(data["url"], "http://localhost:9250/canvas/c1");
        assert_eq!(data["title"], "My UI");
        assert_eq!(data["toolCallId"], "call-1");
    }

    #[test]
    fn converts_render_ui_started_without_title() {
        let event = TronEvent::RenderUIStarted {
            base: BaseEvent::now("s1"),
            canvas_id: "c1".into(),
            url: "http://localhost:9250/canvas/c1".into(),
            title: None,
            tool_call_id: "call-1".into(),
        };
        let bridged = convert(&event).unwrap();
        let data = bridged.rpc_event.data.unwrap();
        assert!(data.get("title").is_none());
    }

    #[test]
    fn converts_render_ui_ready() {
        let event = TronEvent::RenderUIReady {
            base: BaseEvent::now("s1"),
            canvas_id: "c1".into(),
            url: "http://localhost:9250/canvas/c1".into(),
        };
        let bridged = convert(&event).unwrap();
        assert_eq!(bridged.rpc_event.event_type, "render_ui.ready");
        let data = bridged.rpc_event.data.unwrap();
        assert_eq!(data["canvasId"], "c1");
    }

    #[test]
    fn converts_render_ui_error() {
        let event = TronEvent::RenderUIError {
            base: BaseEvent::now("s1"),
            canvas_id: "c1".into(),
            error: "container died".into(),
        };
        let bridged = convert(&event).unwrap();
        assert_eq!(bridged.rpc_event.event_type, "render_ui.error");
        let data = bridged.rpc_event.data.unwrap();
        assert_eq!(data["error"], "container died");
    }

    #[test]
    fn ignores_non_render_ui_events() {
        let event = TronEvent::AgentStart {
            base: BaseEvent::now("s1"),
        };
        assert!(convert(&event).is_none());
    }
}
