use crate::server::rpc::types::RpcEvent;
use serde_json::json;
use crate::tools::cdp::types::BrowserEvent;

use super::routed::{BridgedEvent, BroadcastScope};

pub(super) fn browser_event_to_bridged(event: &BrowserEvent) -> BridgedEvent {
    match event {
        BrowserEvent::Frame {
            session_id, frame, ..
        } => BridgedEvent {
            rpc_event: RpcEvent {
                event_type: "browser.frame".to_string(),
                session_id: Some(session_id.clone()),
                timestamp: chrono::Utc::now().to_rfc3339(),
                data: Some(json!({
                    "sessionId": frame.session_id,
                    "data": frame.data,
                    "frameId": frame.frame_id,
                    "timestamp": frame.timestamp,
                    "metadata": frame.metadata,
                })),
                run_id: None,
            },
            scope: BroadcastScope::Session(session_id.clone()),
        },
        BrowserEvent::Closed { session_id } => BridgedEvent {
            rpc_event: RpcEvent {
                event_type: "browser.closed".to_string(),
                session_id: Some(session_id.clone()),
                timestamp: chrono::Utc::now().to_rfc3339(),
                data: Some(json!({
                    "sessionId": session_id,
                })),
                run_id: None,
            },
            scope: BroadcastScope::Session(session_id.clone()),
        },
    }
}
