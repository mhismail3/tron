//! Events handlers: getHistory, getSince, subscribe, append.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;
use tron_events::sqlite::row_types::EventRow;

use crate::context::RpcContext;
use crate::errors::{self, RpcError};
use crate::handlers::{require_param, require_string_param};
use crate::registry::MethodHandler;

/// Convert an `EventRow` to wire format (camelCase).
fn event_row_to_wire(row: &EventRow) -> Value {
    let mut obj = serde_json::json!({
        "id": row.id,
        "type": row.event_type,
        "sessionId": row.session_id,
        "timestamp": row.timestamp,
        "sequence": row.sequence,
        "depth": row.depth,
        "workspaceId": row.workspace_id,
    });

    let m = obj.as_object_mut().unwrap();

    if let Some(ref parent_id) = row.parent_id {
        let _ = m.insert("parentId".into(), Value::String(parent_id.clone()));
    }
    if let Some(ref role) = row.role {
        let _ = m.insert("role".into(), Value::String(role.clone()));
    }
    if let Some(ref tool_name) = row.tool_name {
        let _ = m.insert("toolName".into(), Value::String(tool_name.clone()));
    }
    if let Some(ref tool_call_id) = row.tool_call_id {
        let _ = m.insert("toolCallId".into(), Value::String(tool_call_id.clone()));
    }
    if let Some(turn) = row.turn {
        let _ = m.insert("turn".into(), Value::Number(turn.into()));
    }
    if let Some(input_tokens) = row.input_tokens {
        let _ = m.insert("inputTokens".into(), Value::Number(input_tokens.into()));
    }
    if let Some(output_tokens) = row.output_tokens {
        let _ = m.insert("outputTokens".into(), Value::Number(output_tokens.into()));
    }
    if let Some(ref model) = row.model {
        let _ = m.insert("model".into(), Value::String(model.clone()));
    }
    if let Some(latency_ms) = row.latency_ms {
        let _ = m.insert("latencyMs".into(), Value::Number(latency_ms.into()));
    }
    if let Some(ref stop_reason) = row.stop_reason {
        let _ = m.insert("stopReason".into(), Value::String(stop_reason.clone()));
    }
    if let Some(has_thinking) = row.has_thinking {
        let _ = m.insert("hasThinking".into(), Value::Bool(has_thinking != 0));
    }
    if let Some(ref provider_type) = row.provider_type {
        let _ = m.insert("providerType".into(), Value::String(provider_type.clone()));
    }
    if let Some(cost) = row.cost {
        let _ = m.insert("cost".into(), serde_json::json!(cost));
    }

    // Parse payload JSON string into a Value
    if let Ok(payload) = serde_json::from_str::<Value>(&row.payload) {
        let _ = m.insert("payload".into(), payload);
    }

    obj
}

/// Get full event history for a session.
pub struct GetHistoryHandler;

#[async_trait]
impl MethodHandler for GetHistoryHandler {
    #[instrument(skip(self, ctx), fields(method = "events.getHistory", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        // Verify session exists
        let _ = ctx
            .event_store
            .get_session(&session_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?
            .ok_or_else(|| RpcError::NotFound {
                code: errors::SESSION_NOT_FOUND.into(),
                message: format!("Session '{session_id}' not found"),
            })?;

        // Extract optional filters
        let limit = params
            .as_ref()
            .and_then(|p| p.get("limit"))
            .and_then(Value::as_i64);

        let type_filter: Option<Vec<String>> = params
            .as_ref()
            .and_then(|p| p.get("types"))
            .and_then(|v| v.as_array())
            .map(|arr| arr.iter().filter_map(|v| v.as_str().map(String::from)).collect());

        let before_event_id = params
            .as_ref()
            .and_then(|p| p.get("beforeEventId"))
            .and_then(Value::as_str);

        let events = if let Some(ref types) = type_filter {
            let type_strs: Vec<&str> = types.iter().map(String::as_str).collect();
            ctx.event_store
                .get_events_by_type(&session_id, &type_strs, limit)
                .map_err(|e| RpcError::Internal {
                    message: e.to_string(),
                })?
        } else {
            let opts = tron_events::sqlite::repositories::event::ListEventsOptions {
                limit,
                offset: None,
            };
            ctx.event_store
                .get_events_by_session(&session_id, &opts)
                .map_err(|e| RpcError::Internal {
                    message: e.to_string(),
                })?
        };

        // Apply beforeEventId filter (pagination backward)
        let events = if let Some(before_id) = before_event_id {
            events
                .into_iter()
                .take_while(|e| e.id != before_id)
                .collect::<Vec<_>>()
        } else {
            events
        };

        let has_more = limit.is_some_and(|l| {
            i64::try_from(events.len()).unwrap_or(0) >= l
        });

        let wire_events: Vec<Value> = events.iter().map(event_row_to_wire).collect();

        Ok(serde_json::json!({
            "sessionId": session_id,
            "events": wire_events,
            "hasMore": has_more,
        }))
    }
}

/// Get events since a given sequence number.
pub struct GetSinceHandler;

#[async_trait]
impl MethodHandler for GetSinceHandler {
    #[instrument(skip(self, ctx), fields(method = "events.getSince", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        // Accept either "afterSequence" (number) or "timestamp" (string, for compat)
        let after_sequence = params
            .as_ref()
            .and_then(|p| p.get("afterSequence"))
            .and_then(Value::as_i64)
            .unwrap_or(0);

        let limit = params
            .as_ref()
            .and_then(|p| p.get("limit"))
            .and_then(Value::as_i64);

        let mut events = ctx
            .event_store
            .get_events_since(&session_id, after_sequence)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        let has_more = limit.is_some_and(|l| {
            i64::try_from(events.len()).unwrap_or(0) > l
        });

        if let Some(l) = limit {
            events.truncate(usize::try_from(l).unwrap_or(usize::MAX));
        }

        let wire_events: Vec<Value> = events.iter().map(event_row_to_wire).collect();

        Ok(serde_json::json!({
            "events": wire_events,
            "hasMore": has_more,
        }))
    }
}

/// Subscribe to real-time events for a session.
pub struct SubscribeHandler;

#[async_trait]
impl MethodHandler for SubscribeHandler {
    #[instrument(skip(self, _ctx), fields(method = "events.subscribe", session_id))]
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        // Subscription is handled at the WebSocket layer; this just acknowledges.
        Ok(serde_json::json!({ "subscribed": true }))
    }
}

/// Unsubscribe from real-time events for a session.
pub struct UnsubscribeHandler;

#[async_trait]
impl MethodHandler for UnsubscribeHandler {
    #[instrument(skip(self, _ctx), fields(method = "events.unsubscribe", session_id))]
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        Ok(serde_json::json!({ "unsubscribed": true }))
    }
}

/// Append an event to a session.
pub struct AppendHandler;

#[async_trait]
impl MethodHandler for AppendHandler {
    #[instrument(skip(self, ctx), fields(method = "events.append", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let event_type_str = require_string_param(params.as_ref(), "type")?;
        let payload = require_param(params.as_ref(), "payload")?;

        let event_type: tron_events::EventType =
            event_type_str.parse().map_err(|_| RpcError::InvalidParams {
                message: format!("Unknown event type: {event_type_str}"),
            })?;

        let parent_id = params
            .as_ref()
            .and_then(|p| p.get("parentId"))
            .and_then(Value::as_str);

        let event = ctx
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &session_id,
                event_type,
                payload: payload.clone(),
                parent_id,
            })
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        let session = ctx
            .event_store
            .get_session(&session_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?;

        let new_head = session.and_then(|s| s.head_event_id);

        Ok(serde_json::json!({
            "event": event_row_to_wire(&event),
            "newHeadEventId": new_head,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn get_history_empty_session() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = GetHistoryHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();

        let events = result["events"].as_array().unwrap();
        // Should have the session.start root event
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["type"], "session.start");
    }

    #[tokio::test]
    async fn get_history_with_events() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        // Append a user message
        let _ = ctx
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MessageUser,
                payload: json!({"text": "hello"}),
                parent_id: None,
            })
            .unwrap();

        let result = GetHistoryHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();

        let events = result["events"].as_array().unwrap();
        assert_eq!(events.len(), 2); // session.start + message.user
        assert_eq!(events[0]["type"], "session.start");
        assert_eq!(events[1]["type"], "message.user");
    }

    #[tokio::test]
    async fn get_history_type_filter() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let _ = ctx
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MessageUser,
                payload: json!({"text": "hello"}),
                parent_id: None,
            })
            .unwrap();

        let result = GetHistoryHandler
            .handle(
                Some(json!({"sessionId": sid, "types": ["message.user"]})),
                &ctx,
            )
            .await
            .unwrap();

        let events = result["events"].as_array().unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["type"], "message.user");
    }

    #[tokio::test]
    async fn get_history_limit() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        for i in 0..5 {
            let _ = ctx
                .event_store
                .append(&tron_events::AppendOptions {
                    session_id: &sid,
                    event_type: tron_events::EventType::MessageUser,
                    payload: json!({"text": format!("msg {i}")}),
                    parent_id: None,
                })
                .unwrap();
        }

        let result = GetHistoryHandler
            .handle(Some(json!({"sessionId": sid, "limit": 3})), &ctx)
            .await
            .unwrap();

        let events = result["events"].as_array().unwrap();
        assert_eq!(events.len(), 3);
        assert_eq!(result["hasMore"], true);
    }

    #[tokio::test]
    async fn get_history_missing_session() {
        let ctx = make_test_context();
        let err = GetHistoryHandler
            .handle(Some(json!({"sessionId": "nope"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "SESSION_NOT_FOUND");
    }

    #[tokio::test]
    async fn get_since_no_new_events() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        // afterSequence=999 → nothing after that
        let result = GetSinceHandler
            .handle(
                Some(json!({"sessionId": sid, "afterSequence": 999})),
                &ctx,
            )
            .await
            .unwrap();

        assert!(result["events"].as_array().unwrap().is_empty());
    }

    #[tokio::test]
    async fn get_since_with_new_events() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let _ = ctx
            .event_store
            .append(&tron_events::AppendOptions {
                session_id: &sid,
                event_type: tron_events::EventType::MessageUser,
                payload: json!({"text": "hello"}),
                parent_id: None,
            })
            .unwrap();

        // afterSequence=0 → get events after the root event
        let result = GetSinceHandler
            .handle(
                Some(json!({"sessionId": sid, "afterSequence": 0})),
                &ctx,
            )
            .await
            .unwrap();

        let events = result["events"].as_array().unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["type"], "message.user");
    }

    #[tokio::test]
    async fn get_since_with_limit() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        for _ in 0..5 {
            let _ = ctx
                .event_store
                .append(&tron_events::AppendOptions {
                    session_id: &sid,
                    event_type: tron_events::EventType::MessageUser,
                    payload: json!({"text": "hello"}),
                    parent_id: None,
                })
                .unwrap();
        }

        let result = GetSinceHandler
            .handle(
                Some(json!({"sessionId": sid, "afterSequence": 0, "limit": 2})),
                &ctx,
            )
            .await
            .unwrap();

        let events = result["events"].as_array().unwrap();
        assert_eq!(events.len(), 2);
        assert_eq!(result["hasMore"], true);
    }

    #[tokio::test]
    async fn subscribe_returns_subscribed() {
        let ctx = make_test_context();
        let result = SubscribeHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["subscribed"], true);
    }

    #[tokio::test]
    async fn unsubscribe_returns_success() {
        let ctx = make_test_context();
        let result = UnsubscribeHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["unsubscribed"], true);
    }

    #[tokio::test]
    async fn unsubscribe_requires_session_id() {
        let ctx = make_test_context();
        let err = UnsubscribeHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn append_event() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = AppendHandler
            .handle(
                Some(json!({
                    "sessionId": sid,
                    "type": "message.user",
                    "payload": {"text": "hello"}
                })),
                &ctx,
            )
            .await
            .unwrap();

        assert!(result["event"]["id"].is_string());
        assert_eq!(result["event"]["type"], "message.user");
        assert!(result["newHeadEventId"].is_string());
    }

    #[tokio::test]
    async fn append_event_returns_wire_format() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = AppendHandler
            .handle(
                Some(json!({
                    "sessionId": sid,
                    "type": "message.user",
                    "payload": {"text": "hello"}
                })),
                &ctx,
            )
            .await
            .unwrap();

        let event = &result["event"];
        // Check camelCase fields
        assert!(event["id"].is_string());
        assert!(event["sessionId"].is_string());
        assert!(event["timestamp"].is_string());
        assert!(event["sequence"].is_number());
    }

    #[tokio::test]
    async fn append_missing_session() {
        let ctx = make_test_context();
        let err = AppendHandler
            .handle(
                Some(json!({
                    "sessionId": "nonexistent",
                    "type": "message.user",
                    "payload": {"text": "hi"}
                })),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INTERNAL_ERROR");
    }

    #[tokio::test]
    async fn append_missing_required_params() {
        let ctx = make_test_context();
        let err = AppendHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn event_row_to_wire_format() {
        let row = EventRow {
            id: "evt_1".into(),
            session_id: "s1".into(),
            parent_id: Some("evt_0".into()),
            sequence: 1,
            depth: 1,
            event_type: "message.user".into(),
            timestamp: "2026-01-01T00:00:00Z".into(),
            payload: r#"{"text":"hello"}"#.into(),
            content_blob_id: None,
            workspace_id: "ws_1".into(),
            role: Some("user".into()),
            tool_name: None,
            tool_call_id: None,
            turn: Some(1),
            input_tokens: None,
            output_tokens: None,
            cache_read_tokens: None,
            cache_creation_tokens: None,
            checksum: None,
            model: None,
            latency_ms: None,
            stop_reason: None,
            has_thinking: None,
            provider_type: None,
            cost: None,
        };

        let wire = event_row_to_wire(&row);
        assert_eq!(wire["id"], "evt_1");
        assert_eq!(wire["type"], "message.user");
        assert_eq!(wire["sessionId"], "s1");
        assert_eq!(wire["parentId"], "evt_0");
        assert_eq!(wire["timestamp"], "2026-01-01T00:00:00Z");
        assert_eq!(wire["payload"]["text"], "hello");
        assert_eq!(wire["role"], "user");
        assert_eq!(wire["turn"], 1);
    }

    #[tokio::test]
    async fn event_row_to_wire_skips_none_fields() {
        let row = EventRow {
            id: "evt_1".into(),
            session_id: "s1".into(),
            parent_id: None,
            sequence: 0,
            depth: 0,
            event_type: "session.start".into(),
            timestamp: "2026-01-01T00:00:00Z".into(),
            payload: "{}".into(),
            content_blob_id: None,
            workspace_id: "ws_1".into(),
            role: None,
            tool_name: None,
            tool_call_id: None,
            turn: None,
            input_tokens: None,
            output_tokens: None,
            cache_read_tokens: None,
            cache_creation_tokens: None,
            checksum: None,
            model: None,
            latency_ms: None,
            stop_reason: None,
            has_thinking: None,
            provider_type: None,
            cost: None,
        };

        let wire = event_row_to_wire(&row);
        assert!(wire.get("parentId").is_none());
        assert!(wire.get("role").is_none());
        assert!(wire.get("toolName").is_none());
        assert!(wire.get("turn").is_none());
    }
}
