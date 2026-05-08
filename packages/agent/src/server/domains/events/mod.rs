//! events domain worker.
//!
//! This module owns canonical function execution for the events namespace and keeps
//! domain contracts, services, and tests beside the worker that uses them.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;
pub(super) use handlers::handle;

use super::*;

pub(crate) fn worker_module(
    deps: &DomainSetupContext,
) -> crate::engine::Result<DomainWorkerModule> {
    super::domain_worker_module(
        "events",
        contract::STREAM_TOPICS,
        contract::capabilities()?,
        Deps::from_engine(deps),
        super::events_handler,
    )
}

use crate::server::shared::events as event_wire;

async fn events_subscribe_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let subscription_id = format!("events.session:{session_id}");
    deps.engine_host
        .subscribe_stream(
            subscription_id,
            "events.session".to_owned(),
            crate::engine::StreamCursor(0),
            crate::engine::VisibilityScope::Session,
            Some(session_id),
            invocation.causal_context.workspace_id.clone(),
        )
        .await
        .map_err(crate::server::shared::error_mapping::engine_error_to_capability_error)?;
    Ok(json!({ "subscribed": true }))
}

async fn events_unsubscribe_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let subscription_id = format!("events.session:{session_id}");
    let _ = deps
        .engine_host
        .unsubscribe_stream(&subscription_id)
        .await
        .map_err(crate::server::shared::error_mapping::engine_error_to_capability_error)?;
    Ok(json!({ "unsubscribed": true }))
}

async fn events_get_history_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    deps.event_store
        .get_session(&session_id)
        .map_err(map_event_store_error)?
        .ok_or_else(|| CapabilityError::NotFound {
            code: errors::SESSION_NOT_FOUND.into(),
            message: format!("Session '{session_id}' not found"),
        })?;

    let limit = params.and_then(|p| p.get("limit")).and_then(Value::as_i64);
    let type_filter: Option<Vec<String>> = opt_array(params, "types").map(|arr| {
        arr.iter()
            .filter_map(|v| v.as_str().map(String::from))
            .collect()
    });
    let before_event_id = opt_string(params, "beforeEventId");

    let events = if let Some(ref types) = type_filter {
        let type_strs: Vec<&str> = types.iter().map(String::as_str).collect();
        deps.event_store
            .get_events_by_type(&session_id, &type_strs, limit)
            .map_err(map_event_store_error)?
    } else {
        let opts = crate::events::sqlite::repositories::event::ListEventsOptions {
            limit,
            offset: None,
        };
        deps.event_store
            .get_events_by_session(&session_id, &opts)
            .map_err(map_event_store_error)?
    };

    let events = if let Some(before_id) = before_event_id {
        events
            .into_iter()
            .take_while(|e| e.id != before_id)
            .collect::<Vec<_>>()
    } else {
        events
    };

    let has_more = limit.is_some_and(|l| i64::try_from(events.len()).unwrap_or(0) >= l);
    let oldest_event_id = events.first().map(|e| e.id.clone());
    let mut wire_events: Vec<Value> = events.iter().map(event_wire::event_row_to_wire).collect();
    crate::server::domains::tools::interactive_enrichment::enrich_interactive_tool_statuses(
        &mut wire_events,
    );

    Ok(json!({
        "sessionId": session_id,
        "events": wire_events,
        "hasMore": has_more,
        "oldestEventId": oldest_event_id,
    }))
}

async fn events_get_since_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let after_sequence = if let Some(event_id) = opt_string(params, "afterEventId") {
        deps.event_store
            .get_event(&event_id)
            .map_err(map_event_store_error)?
            .map_or(-1, |row| row.sequence)
    } else {
        params
            .and_then(|p| p.get("afterSequence"))
            .and_then(Value::as_i64)
            .unwrap_or(-1)
    };
    let limit = params.and_then(|p| p.get("limit")).and_then(Value::as_i64);
    let mut events = deps
        .event_store
        .get_events_since(&session_id, after_sequence)
        .map_err(map_event_store_error)?;
    let has_more = limit.is_some_and(|l| i64::try_from(events.len()).unwrap_or(0) >= l);
    if let Some(l) = limit {
        events.truncate(usize::try_from(l).unwrap_or(usize::MAX));
    }
    let mut wire_events: Vec<Value> = events.iter().map(event_wire::event_row_to_wire).collect();
    crate::server::domains::tools::interactive_enrichment::enrich_interactive_tool_statuses(
        &mut wire_events,
    );
    let next_cursor = events.last().map(|r| r.id.clone());
    Ok(json!({
        "events": wire_events,
        "hasMore": has_more,
        "nextCursor": next_cursor,
    }))
}

async fn events_append_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let event_type_str = require_string_param(params, "type")?;
    let payload = require_param(params, "payload")?;
    let event_type: crate::events::EventType =
        event_type_str
            .parse()
            .map_err(|_| CapabilityError::InvalidParams {
                message: format!("Unknown event type: {event_type_str}"),
            })?;
    let parent_id = opt_string(params, "parentId");

    let event = deps
        .event_store
        .append(&crate::events::AppendOptions {
            session_id: &session_id,
            event_type,
            payload: payload.clone(),
            parent_id: parent_id.as_deref(),
            sequence: None,
        })
        .map_err(map_event_store_error)?;
    let new_head = deps
        .event_store
        .get_session(&session_id)
        .map_err(map_event_store_error)?
        .and_then(|session| session.head_event_id);
    let _ = deps
        .engine_host
        .publish_stream_event(crate::engine::PublishStreamEvent {
            topic: "events.session".to_owned(),
            payload: json!({
                "serverEvent": event_wire::event_row_to_server_payload(&event),
                "sourceEventType": event.event_type.clone(),
                "sourceSequence": event.sequence,
            }),
            visibility: crate::engine::VisibilityScope::Session,
            session_id: Some(session_id.clone()),
            workspace_id: invocation_workspace(params),
            producer: "events::append".to_owned(),
            trace_id: Some(invocation.causal_context.trace_id.clone()),
            parent_invocation_id: Some(invocation.id.clone()),
        })
        .await;

    Ok(json!({
        "event": event_wire::event_row_to_wire(&event),
        "newHeadEventId": new_head,
    }))
}

fn invocation_workspace(params: Option<&Value>) -> Option<String> {
    opt_string(params, "workspaceId")
}
