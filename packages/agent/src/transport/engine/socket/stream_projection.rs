//! Engine stream record projection into `/engine` protocol events.

use serde_json::Value;

use crate::engine::VisibilityScope;
use crate::shared::server::events::ServerEventPayload;
use crate::transport::engine::EngineTransportContext;

use super::wire::ProtocolEvent;

pub(super) fn visibility_for_context(context: &EngineTransportContext) -> VisibilityScope {
    if context.session_id.is_some() {
        VisibilityScope::Session
    } else if context.workspace_id.is_some() {
        VisibilityScope::Workspace
    } else {
        VisibilityScope::System
    }
}

pub(super) fn protocol_event_value(
    event: &crate::engine::EngineStreamEvent,
    subscription_id: Option<String>,
) -> Value {
    serde_json::to_value(ProtocolEvent {
        message_type: "event",
        subscription_id,
        topic: event.topic.clone(),
        cursor: event.cursor.0,
        event: server_payload_from_stream_event(event),
    })
    .expect("protocol event serializes")
}

pub(super) fn server_payload_from_stream_event(
    event: &crate::engine::EngineStreamEvent,
) -> ServerEventPayload {
    if let Some(value) = event.payload.get("serverEvent")
        && let Ok(mut payload) = serde_json::from_value::<ServerEventPayload>(value.clone())
    {
        payload.stream_cursor = Some(event.cursor.0);
        if payload.trace_id.is_none() {
            payload.trace_id = event.trace_id.as_ref().map(ToString::to_string);
        }
        if payload.parent_invocation_id.is_none() {
            payload.parent_invocation_id =
                event.parent_invocation_id.as_ref().map(ToString::to_string);
        }
        return payload;
    }
    let event_type = event
        .payload
        .get("type")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| format!("engine.{}", event.topic.replace('.', "_")));
    let mut payload = ServerEventPayload::new(
        event_type,
        event.session_id.clone(),
        Some(event.payload.clone()),
    );
    payload.workspace_id.clone_from(&event.workspace_id);
    payload.timestamp = event
        .created_at
        .to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
    payload.trace_id = event.trace_id.as_ref().map(ToString::to_string);
    payload.parent_invocation_id = event.parent_invocation_id.as_ref().map(ToString::to_string);
    payload.stream_cursor = Some(event.cursor.0);
    payload
}

pub(super) fn stream_event_matches_filters(
    event: &crate::engine::EngineStreamEvent,
    filters: Option<&Value>,
) -> bool {
    let Some(filters) = filters else {
        return true;
    };
    let Some(object) = filters.as_object() else {
        return false;
    };
    if let Some(session_id) = object.get("sessionId").and_then(Value::as_str)
        && stream_event_session_id(event).as_deref() != Some(session_id)
    {
        return false;
    }
    if let Some(workspace_id) = object.get("workspaceId").and_then(Value::as_str)
        && stream_event_workspace_id(event).as_deref() != Some(workspace_id)
    {
        return false;
    }
    if let Some(event_type) = object.get("eventType").and_then(Value::as_str) {
        return server_payload_from_stream_event(event).event_type == event_type;
    }
    if let Some(types) = object.get("eventTypes").and_then(Value::as_array) {
        let event_type = server_payload_from_stream_event(event).event_type;
        return types
            .iter()
            .any(|value| value.as_str() == Some(event_type.as_str()));
    }
    true
}

fn stream_event_session_id(event: &crate::engine::EngineStreamEvent) -> Option<String> {
    event.session_id.clone().or_else(|| {
        server_payload_from_stream_event(event)
            .session_id
            .as_ref()
            .map(ToOwned::to_owned)
    })
}

fn stream_event_workspace_id(event: &crate::engine::EngineStreamEvent) -> Option<String> {
    event.workspace_id.clone().or_else(|| {
        server_payload_from_stream_event(event)
            .workspace_id
            .as_ref()
            .map(ToOwned::to_owned)
    })
}
