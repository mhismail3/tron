use crate::core::events::TronEvent;
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
        TronEvent::ProcessSpawned {
            process_id,
            label,
            kind,
            background,
            tool_call_id,
            ..
        } => Some(session_scoped(
            event,
            "process.spawned",
            Some(json!({
                "processId": process_id,
                "label": label,
                "kind": kind,
                "background": background,
                "toolCallId": tool_call_id,
            })),
        )),
        TronEvent::ProcessStatusUpdate {
            process_id, status, ..
        } => Some(session_scoped(
            event,
            "process.status_update",
            Some(json!({
                "processId": process_id,
                "status": status,
            })),
        )),
        TronEvent::ProcessCompleted {
            parent_session_id,
            process_id,
            label,
            success,
            exit_code,
            duration,
            result_summary,
            blob_id,
            completed_at,
            ..
        } => Some(session_scoped(
            event,
            "process.completed",
            Some(json!({
                "parentSessionId": parent_session_id,
                "processId": process_id,
                "label": label,
                "success": success,
                "exitCode": exit_code,
                "duration": duration,
                "resultSummary": result_summary,
                "blobId": blob_id,
                "completedAt": completed_at,
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
    fn display_frame_projection_produces_correct_wire_type() {
        let event = TronEvent::DisplayFrame {
            base: BaseEvent::now("sess-1"),
            stream_id: "stream-1".into(),
            tool_call_id: "call-1".into(),
            data: "b64data".into(),
            frame_id: 5,
            width: 1280,
            height: 720,
        };
        let projected = convert(&event).expect("should convert");
        assert_eq!(projected.rpc_event.event_type, "display.frame");
    }

    #[test]
    fn display_frame_projection_includes_all_fields() {
        let event = TronEvent::DisplayFrame {
            base: BaseEvent::now("sess-1"),
            stream_id: "stream-1".into(),
            tool_call_id: "call-1".into(),
            data: "b64data".into(),
            frame_id: 5,
            width: 1280,
            height: 720,
        };
        let projected = convert(&event).expect("should convert");
        let data = projected.rpc_event.data.as_ref().expect("should have data");
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
        let projected = convert(&event).expect("should convert");
        assert_eq!(projected.rpc_event.session_id.as_deref(), Some("sess-42"));
    }

    #[test]
    fn unrelated_event_returns_none() {
        let event = TronEvent::AgentStart {
            base: BaseEvent::now("s1"),
        };
        assert!(convert(&event).is_none());
    }

    // ── Process stream pump tests ──

    #[test]
    fn process_spawned_projection_wire_type() {
        let event = TronEvent::ProcessSpawned {
            base: BaseEvent::now("sess-1"),
            process_id: "proc-1".into(),
            label: "cargo build".into(),
            kind: "shell".into(),
            background: true,
            tool_call_id: "tc-1".into(),
        };
        let projected = convert(&event).expect("should convert");
        assert_eq!(projected.rpc_event.event_type, "process.spawned");
    }

    #[test]
    fn process_spawned_projection_fields() {
        let event = TronEvent::ProcessSpawned {
            base: BaseEvent::now("sess-1"),
            process_id: "proc-abc".into(),
            label: "npm test".into(),
            kind: "shell".into(),
            background: false,
            tool_call_id: "tc-42".into(),
        };
        let projected = convert(&event).expect("should convert");
        let data = projected.rpc_event.data.as_ref().unwrap();
        assert_eq!(data["processId"], "proc-abc");
        assert_eq!(data["label"], "npm test");
        assert_eq!(data["kind"], "shell");
        assert_eq!(data["background"], false);
        assert_eq!(data["toolCallId"], "tc-42");
    }

    #[test]
    fn process_spawned_is_session_scoped() {
        let event = TronEvent::ProcessSpawned {
            base: BaseEvent::now("sess-99"),
            process_id: "p".into(),
            label: "l".into(),
            kind: "shell".into(),
            background: true,
            tool_call_id: "t".into(),
        };
        let projected = convert(&event).expect("should convert");
        assert_eq!(projected.rpc_event.session_id.as_deref(), Some("sess-99"));
    }

    #[test]
    fn process_status_update_projection_wire_type() {
        let event = TronEvent::ProcessStatusUpdate {
            base: BaseEvent::now("s1"),
            process_id: "proc-1".into(),
            status: "background".into(),
        };
        let projected = convert(&event).expect("should convert");
        assert_eq!(projected.rpc_event.event_type, "process.status_update");
        let data = projected.rpc_event.data.as_ref().unwrap();
        assert_eq!(data["processId"], "proc-1");
        assert_eq!(data["status"], "background");
    }

    #[test]
    fn process_completed_projection_wire_type() {
        let event = TronEvent::ProcessCompleted {
            base: BaseEvent::now("sess-1"),
            parent_session_id: "sess-1".into(),
            process_id: "proc-1".into(),
            label: "build".into(),
            success: true,
            exit_code: Some(0),
            duration: 5000,
            result_summary: "ok".into(),
            blob_id: None,
            completed_at: "2026-03-29T12:00:00Z".into(),
        };
        let projected = convert(&event).expect("should convert");
        assert_eq!(projected.rpc_event.event_type, "process.completed");
    }

    #[test]
    fn process_completed_projection_all_fields() {
        let event = TronEvent::ProcessCompleted {
            base: BaseEvent::now("sess-1"),
            parent_session_id: "sess-1".into(),
            process_id: "proc-abc".into(),
            label: "npm test".into(),
            success: false,
            exit_code: Some(1),
            duration: 12000,
            result_summary: "3 failed".into(),
            blob_id: Some("blob-xyz".into()),
            completed_at: "2026-03-29T15:00:00Z".into(),
        };
        let projected = convert(&event).expect("should convert");
        let data = projected.rpc_event.data.as_ref().unwrap();
        assert_eq!(data["parentSessionId"], "sess-1");
        assert_eq!(data["processId"], "proc-abc");
        assert_eq!(data["label"], "npm test");
        assert_eq!(data["success"], false);
        assert_eq!(data["exitCode"], 1);
        assert_eq!(data["duration"], 12000);
        assert_eq!(data["resultSummary"], "3 failed");
        assert_eq!(data["blobId"], "blob-xyz");
        assert_eq!(data["completedAt"], "2026-03-29T15:00:00Z");
    }

    #[test]
    fn process_completed_nullable_blob_id() {
        let event = TronEvent::ProcessCompleted {
            base: BaseEvent::now("s1"),
            parent_session_id: "s1".into(),
            process_id: "p".into(),
            label: "l".into(),
            success: true,
            exit_code: None,
            duration: 100,
            result_summary: "ok".into(),
            blob_id: None,
            completed_at: "2026-01-01T00:00:00Z".into(),
        };
        let projected = convert(&event).expect("should convert");
        let data = projected.rpc_event.data.as_ref().unwrap();
        assert!(data["exitCode"].is_null());
        assert!(data["blobId"].is_null());
    }
}
