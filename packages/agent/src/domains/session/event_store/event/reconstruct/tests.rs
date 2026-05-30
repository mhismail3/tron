#![allow(unused_results)]

use super::*;

/// Helper: create a minimal session event.
fn ev(event_type: EventType, payload: Value) -> SessionEvent {
    SessionEvent {
        id: format!("evt_{}", uuid::Uuid::now_v7()),
        parent_id: None,
        session_id: "sess_test".to_string(),
        workspace_id: "ws_test".to_string(),
        timestamp: chrono::Utc::now().to_rfc3339(),
        event_type,
        sequence: 0,
        checksum: None,
        payload,
    }
}

/// Helper: create a session event with a specific ID.
fn ev_with_id(id: &str, event_type: EventType, payload: Value) -> SessionEvent {
    SessionEvent {
        id: id.to_string(),
        parent_id: None,
        session_id: "sess_test".to_string(),
        workspace_id: "ws_test".to_string(),
        timestamp: chrono::Utc::now().to_rfc3339(),
        event_type,
        sequence: 0,
        checksum: None,
        payload,
    }
}

/// Helper: extract messages from reconstruction result.
fn get_messages(result: &ReconstructionResult) -> Vec<&Message> {
    result
        .messages_with_event_ids
        .iter()
        .map(|m| &m.message)
        .collect()
}

fn session_start() -> SessionEvent {
    ev(
        EventType::SessionStart,
        serde_json::json!({"workingDirectory": "/test", "model": "claude-opus-4-6"}),
    )
}

#[path = "tests/basic_capability.rs"]
mod basic_capability;
#[path = "tests/lifecycle_metadata.rs"]
mod lifecycle_metadata;
#[path = "tests/multimodal_performance.rs"]
mod multimodal_performance;
#[path = "tests/synthetic_interrupts.rs"]
mod synthetic_interrupts;
