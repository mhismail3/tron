use crate::server::rpc::types::RpcEvent;
use serde::Serialize;
use serde_json::{Value, json};
use crate::core::events::TronEvent;

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum BroadcastScope {
    All,
    Session(String),
}

#[derive(Debug, Clone)]
pub(super) struct BridgedEvent {
    pub(super) rpc_event: RpcEvent,
    pub(super) scope: BroadcastScope,
}

#[allow(clippy::ref_option)]
pub(super) fn set_opt<T: Serialize>(data: &mut Value, key: &str, val: &Option<T>) {
    if let Some(v) = val {
        data[key] = json!(v);
    }
}

pub(super) fn make_rpc(event: &TronEvent, wire_type: &str, data: Option<Value>) -> RpcEvent {
    let session_id = event.session_id();
    RpcEvent {
        event_type: wire_type.to_string(),
        session_id: if session_id.is_empty() {
            None
        } else {
            Some(session_id.to_string())
        },
        timestamp: event.timestamp().to_string(),
        data,
        run_id: None,
    }
}

pub(super) fn session_scope(session_id: &str) -> BroadcastScope {
    if session_id.is_empty() {
        BroadcastScope::All
    } else {
        BroadcastScope::Session(session_id.to_string())
    }
}

pub(super) fn with_scope(
    event: &TronEvent,
    wire_type: &str,
    data: Option<Value>,
    scope: BroadcastScope,
) -> BridgedEvent {
    BridgedEvent {
        rpc_event: make_rpc(event, wire_type, data),
        scope,
    }
}

pub(super) fn session_scoped(
    event: &TronEvent,
    wire_type: &str,
    data: Option<Value>,
) -> BridgedEvent {
    with_scope(event, wire_type, data, session_scope(event.session_id()))
}

pub(super) fn global(event: &TronEvent, wire_type: &str, data: Option<Value>) -> BridgedEvent {
    with_scope(event, wire_type, data, BroadcastScope::All)
}
