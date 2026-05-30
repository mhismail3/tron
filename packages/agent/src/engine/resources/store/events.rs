//! Resource-store event and id generation helpers.

use chrono::Utc;
use serde_json::Value;
use uuid::Uuid;

use crate::engine::ids::{InvocationId, TraceId};
use crate::engine::resources::types::EngineResourceEvent;

pub(super) fn resource_event(
    resource_id: &str,
    event_type: &str,
    payload: Value,
    invocation_id: Option<InvocationId>,
    trace_id: TraceId,
) -> EngineResourceEvent {
    EngineResourceEvent {
        event_id: generated_id("revt"),
        resource_id: resource_id.to_owned(),
        event_type: event_type.to_owned(),
        payload,
        invocation_id,
        trace_id,
        occurred_at: Utc::now(),
    }
}

pub(super) fn generated_id(prefix: &str) -> String {
    format!("{prefix}_{}", Uuid::now_v7())
}
