//! Small factory helpers for common agent lifecycle events.

use super::{BaseEvent, TronEvent};

/// Create an agent-start event.
#[must_use]
pub fn agent_start_event(session_id: impl Into<String>) -> TronEvent {
    TronEvent::AgentStart {
        base: BaseEvent::now(session_id),
    }
}

/// Create an agent-end event.
#[must_use]
pub fn agent_end_event(session_id: impl Into<String>) -> TronEvent {
    TronEvent::AgentEnd {
        base: BaseEvent::now(session_id),
        error: None,
    }
}

/// Create an agent-ready event.
#[must_use]
pub fn agent_ready_event(session_id: impl Into<String>) -> TronEvent {
    TronEvent::AgentReady {
        base: BaseEvent::now(session_id),
    }
}

/// Create a session-processing-changed event.
#[must_use]
pub fn session_processing_changed_event(
    session_id: impl Into<String>,
    is_processing: bool,
) -> TronEvent {
    TronEvent::SessionProcessingChanged {
        base: BaseEvent::now(session_id),
        is_processing,
    }
}

// ─────────────────────────────────────────────────────────────────────────────
