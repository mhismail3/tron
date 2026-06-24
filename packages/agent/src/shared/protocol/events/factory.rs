//! Small factory helpers for common agent lifecycle events.

use super::{BaseEvent, TronEvent};
use crate::shared::server::failure::FailureEnvelope;

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

/// Create a canonical turn-failed event from a failure envelope.
#[must_use]
pub fn turn_failed_event(
    base: BaseEvent,
    turn: u32,
    failure: &FailureEnvelope,
    partial_content: Option<String>,
) -> TronEvent {
    TronEvent::TurnFailed {
        base,
        turn,
        error: failure.message.clone(),
        code: Some(failure.code.clone()),
        category: Some(failure.category.as_str().to_owned()),
        retryable: Some(failure.retryable),
        recoverable: failure.recoverable,
        origin: Some(failure.origin.as_str().to_owned()),
        details: Some(failure.details_with_failure()),
        partial_content,
    }
}

/// Create a canonical error event from a failure envelope.
#[must_use]
pub fn error_event(
    base: BaseEvent,
    failure: &FailureEnvelope,
    context: Option<String>,
) -> TronEvent {
    TronEvent::Error {
        base,
        error: failure.message.clone(),
        context,
        code: Some(failure.code.clone()),
        provider: failure.provider.clone(),
        category: Some(failure.category.as_str().to_owned()),
        suggestion: failure.suggestion.clone(),
        retryable: Some(failure.retryable),
        recoverable: Some(failure.recoverable),
        origin: Some(failure.origin.as_str().to_owned()),
        details: Some(failure.details_with_failure()),
        status_code: failure.status_code,
        error_type: failure.error_type.clone(),
        model: failure.model.clone(),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
