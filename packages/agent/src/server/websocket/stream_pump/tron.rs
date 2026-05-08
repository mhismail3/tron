use crate::core::events::TronEvent;
use serde_json::json;

use super::hook;
use super::message;
use super::routed::{ProjectedEvent, make_server_event, session_scope};
use super::session;
use super::streaming;
use super::tool;
use super::turn;

#[cfg(test)]
pub(super) fn tron_event_to_rpc(
    event: &TronEvent,
) -> crate::server::transport::json_rpc::types::JsonRpcEvent {
    tron_event_to_projected(event)
        .server_event
        .to_json_rpc_event()
}

pub(super) fn tron_event_to_projected(event: &TronEvent) -> ProjectedEvent {
    message::convert(event)
        .or_else(|| turn::convert(event))
        .or_else(|| tool::convert(event))
        .or_else(|| hook::convert(event))
        .or_else(|| streaming::convert(event))
        .or_else(|| session::convert(event))
        .unwrap_or_else(|| ProjectedEvent {
            server_event: make_server_event(event, event.event_type(), Some(json!({}))),
            scope: session_scope(event.session_id()),
        })
}
