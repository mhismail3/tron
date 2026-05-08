use crate::core::events::TronEvent;
use crate::server::shared::events::ServerEventPayload;
use serde::Serialize;
use serde_json::{Value, json};

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum StreamScope {
    All,
    Session(String),
}

#[derive(Debug, Clone)]
pub(super) struct ProjectedEvent {
    pub(super) server_event: ServerEventPayload,
    pub(super) scope: StreamScope,
}

#[allow(clippy::ref_option)]
pub(super) fn set_opt<T: Serialize>(data: &mut Value, key: &str, val: &Option<T>) {
    if let Some(v) = val {
        data[key] = json!(v);
    }
}

pub(super) fn make_server_event(
    event: &TronEvent,
    wire_type: &str,
    data: Option<Value>,
) -> ServerEventPayload {
    let session_id = event.session_id();
    let session_id = if session_id.is_empty() {
        None
    } else {
        Some(session_id.to_string())
    };
    let mut payload = ServerEventPayload::new(wire_type.to_string(), session_id, data);
    payload.timestamp = event.timestamp().to_string();
    payload.sequence = event.sequence();
    if let Some(sequence) = event.sequence() {
        payload.source_sequence = Some(sequence);
    }
    payload
}

pub(super) fn session_scope(session_id: &str) -> StreamScope {
    if session_id.is_empty() {
        StreamScope::All
    } else {
        StreamScope::Session(session_id.to_string())
    }
}

pub(super) fn with_scope(
    event: &TronEvent,
    wire_type: &str,
    data: Option<Value>,
    scope: StreamScope,
) -> ProjectedEvent {
    ProjectedEvent {
        server_event: make_server_event(event, wire_type, data),
        scope,
    }
}

pub(super) fn session_scoped(
    event: &TronEvent,
    wire_type: &str,
    data: Option<Value>,
) -> ProjectedEvent {
    with_scope(event, wire_type, data, session_scope(event.session_id()))
}

pub(super) fn global(event: &TronEvent, wire_type: &str, data: Option<Value>) -> ProjectedEvent {
    with_scope(event, wire_type, data, StreamScope::All)
}
