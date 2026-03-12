use serde_json::json;
use tron_core::events::TronEvent;

use super::hook;
use super::message;
use super::routed::{BridgedEvent, make_rpc, session_scope};
use super::session;
use super::streaming;
use super::tool;
use super::turn;

#[cfg(test)]
pub(super) fn tron_event_to_rpc(event: &TronEvent) -> crate::rpc::types::RpcEvent {
    tron_event_to_bridged(event).rpc_event
}

pub(super) fn tron_event_to_bridged(event: &TronEvent) -> BridgedEvent {
    message::convert(event)
        .or_else(|| turn::convert(event))
        .or_else(|| tool::convert(event))
        .or_else(|| hook::convert(event))
        .or_else(|| streaming::convert(event))
        .or_else(|| session::convert(event))
        .unwrap_or_else(|| BridgedEvent {
            rpc_event: make_rpc(event, event.event_type(), Some(json!({}))),
            scope: session_scope(event.session_id()),
        })
}
