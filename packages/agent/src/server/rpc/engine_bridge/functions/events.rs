use super::*;

use crate::server::rpc::handlers::events as rpc_events;

pub(super) async fn handle(
    method: &str,
    invocation: &Invocation,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let payload = &invocation.payload;
    match method {
        "events.getHistory" => events_get_history_value(Some(payload), deps).await,
        "events.getSince" => events_get_since_value(Some(payload), deps).await,
        "events.append" => events_append_value(Some(payload), deps).await,
        _ => Err(RpcError::Internal {
            message: format!("events method {method} is not engine-owned"),
        }),
    }
}

async fn events_get_history_value(
    params: Option<&Value>,
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let session_id = require_string_param(params, "sessionId")?;
    deps.event_store
        .get_session(&session_id)
        .map_err(map_event_store_error)?
        .ok_or_else(|| RpcError::NotFound {
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
    let mut wire_events: Vec<Value> = events.iter().map(rpc_events::event_row_to_wire).collect();
    crate::server::rpc::interactive_tool_enrichment::enrich_interactive_tool_statuses(
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
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
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
    let mut wire_events: Vec<Value> = events.iter().map(rpc_events::event_row_to_wire).collect();
    crate::server::rpc::interactive_tool_enrichment::enrich_interactive_tool_statuses(
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
    deps: &RpcEngineDeps,
) -> Result<Value, RpcError> {
    let session_id = require_string_param(params, "sessionId")?;
    let event_type_str = require_string_param(params, "type")?;
    let payload = require_param(params, "payload")?;
    let event_type: crate::events::EventType =
        event_type_str
            .parse()
            .map_err(|_| RpcError::InvalidParams {
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

    Ok(json!({
        "event": rpc_events::event_row_to_wire(&event),
        "newHeadEventId": new_head,
    }))
}
