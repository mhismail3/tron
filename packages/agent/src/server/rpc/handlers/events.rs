//! Events handlers: subscribe, unsubscribe, append.
//!
//! `events.getHistory` and `events.getSince` are served by the engine bridge
//! generic trigger. This module keeps shared wire helpers and mutating/event
//! subscription handlers.

use crate::events::sqlite::row_types::EventRow;
use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::handlers::{
    map_event_store_error, opt_string, require_param, require_string_param,
};
use crate::server::rpc::registry::MethodHandler;

/// Convert an `EventRow` to wire format (camelCase).
pub(crate) fn event_row_to_wire(row: &EventRow) -> Value {
    let mut obj = serde_json::json!({
        "id": row.id,
        "type": row.event_type,
        "sessionId": row.session_id,
        "timestamp": row.timestamp,
        "sequence": row.sequence,
        "depth": row.depth,
        "workspaceId": row.workspace_id,
    });

    let m = obj.as_object_mut().expect("just created as object");

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
        let _ = m.insert("latency".into(), Value::Number(latency_ms.into()));
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

        let event_type: crate::events::EventType =
            event_type_str
                .parse()
                .map_err(|_| RpcError::InvalidParams {
                    message: format!("Unknown event type: {event_type_str}"),
                })?;

        let parent_id = opt_string(params.as_ref(), "parentId");

        let event = ctx
            .event_store
            .append(&crate::events::AppendOptions {
                session_id: &session_id,
                event_type,
                payload: payload.clone(),
                parent_id: parent_id.as_deref(),
                sequence: None,
            })
            .map_err(map_event_store_error)?;

        let session = ctx
            .event_store
            .get_session(&session_id)
            .map_err(map_event_store_error)?;

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
    use crate::server::rpc::handlers::test_helpers::make_test_context;
    use crate::server::rpc::registry::MethodRegistry;
    use crate::server::rpc::types::RpcRequest;
    use serde_json::json;

    async fn dispatch_ok(ctx: &RpcContext, method: &str, params: Value) -> Value {
        let mut registry = MethodRegistry::new();
        crate::server::rpc::handlers::register_all(&mut registry);
        let response = registry
            .dispatch(
                RpcRequest {
                    id: format!("test-{method}"),
                    method: method.to_owned(),
                    params: Some(params),
                },
                ctx,
            )
            .await;
        assert!(response.success, "{method}: {:?}", response.error);
        response.result.unwrap()
    }

    async fn dispatch_err(ctx: &RpcContext, method: &str, params: Value) -> RpcError {
        let mut registry = MethodRegistry::new();
        crate::server::rpc::handlers::register_all(&mut registry);
        let response = registry
            .dispatch(
                RpcRequest {
                    id: format!("test-{method}"),
                    method: method.to_owned(),
                    params: Some(params),
                },
                ctx,
            )
            .await;
        assert!(!response.success, "{method}: {:?}", response.result);
        let body = response.error.unwrap();
        RpcError::Custom {
            code: body.code,
            message: body.message,
            details: body.details,
        }
    }

    #[tokio::test]
    async fn get_history_empty_session() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"), None)
            .unwrap();

        let result = dispatch_ok(&ctx, "events.getHistory", json!({"sessionId": sid})).await;

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
            .create_session("m", "/tmp", Some("t"), None)
            .unwrap();

        // Append a user message
        let _ = ctx
            .event_store
            .append(&crate::events::AppendOptions {
                session_id: &sid,
                event_type: crate::events::EventType::MessageUser,
                payload: json!({"text": "hello"}),
                parent_id: None,
                sequence: None,
            })
            .unwrap();

        let result = dispatch_ok(&ctx, "events.getHistory", json!({"sessionId": sid})).await;

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
            .create_session("m", "/tmp", Some("t"), None)
            .unwrap();

        let _ = ctx
            .event_store
            .append(&crate::events::AppendOptions {
                session_id: &sid,
                event_type: crate::events::EventType::MessageUser,
                payload: json!({"text": "hello"}),
                parent_id: None,
                sequence: None,
            })
            .unwrap();

        let result = dispatch_ok(
            &ctx,
            "events.getHistory",
            json!({"sessionId": sid, "types": ["message.user"]}),
        )
        .await;

        let events = result["events"].as_array().unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["type"], "message.user");
    }

    #[tokio::test]
    async fn get_history_limit() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"), None)
            .unwrap();

        for i in 0..5 {
            let _ = ctx
                .event_store
                .append(&crate::events::AppendOptions {
                    session_id: &sid,
                    event_type: crate::events::EventType::MessageUser,
                    payload: json!({"text": format!("msg {i}")}),
                    parent_id: None,
                    sequence: None,
                })
                .unwrap();
        }

        let result = dispatch_ok(
            &ctx,
            "events.getHistory",
            json!({"sessionId": sid, "limit": 3}),
        )
        .await;

        let events = result["events"].as_array().unwrap();
        assert_eq!(events.len(), 3);
        assert_eq!(result["hasMore"], true);
    }

    #[tokio::test]
    async fn get_history_missing_session() {
        let ctx = make_test_context();
        let err = dispatch_err(&ctx, "events.getHistory", json!({"sessionId": "nope"})).await;
        assert_eq!(err.code(), "SESSION_NOT_FOUND");
    }

    #[tokio::test]
    async fn get_since_no_new_events() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"), None)
            .unwrap();

        // afterSequence=999 → nothing after that
        let result = dispatch_ok(
            &ctx,
            "events.getSince",
            json!({"sessionId": sid, "afterSequence": 999}),
        )
        .await;

        assert!(result["events"].as_array().unwrap().is_empty());
    }

    #[tokio::test]
    async fn get_since_unknown_session_matches_legacy_empty_page() {
        let ctx = make_test_context();
        let result = dispatch_ok(
            &ctx,
            "events.getSince",
            json!({"sessionId": "missing-session"}),
        )
        .await;
        assert!(result["events"].as_array().unwrap().is_empty());
        assert_eq!(result["hasMore"], false);
        assert_eq!(result["nextCursor"], Value::Null);
    }

    #[tokio::test]
    async fn get_since_with_new_events() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"), None)
            .unwrap();

        let _ = ctx
            .event_store
            .append(&crate::events::AppendOptions {
                session_id: &sid,
                event_type: crate::events::EventType::MessageUser,
                payload: json!({"text": "hello"}),
                parent_id: None,
                sequence: None,
            })
            .unwrap();

        // afterSequence=0 → get events after the root event
        let result = dispatch_ok(
            &ctx,
            "events.getSince",
            json!({"sessionId": sid, "afterSequence": 0}),
        )
        .await;

        let events = result["events"].as_array().unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["type"], "message.user");
    }

    #[tokio::test]
    async fn get_since_with_limit() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"), None)
            .unwrap();

        for _ in 0..5 {
            let _ = ctx
                .event_store
                .append(&crate::events::AppendOptions {
                    session_id: &sid,
                    event_type: crate::events::EventType::MessageUser,
                    payload: json!({"text": "hello"}),
                    parent_id: None,
                    sequence: None,
                })
                .unwrap();
        }

        let result = dispatch_ok(
            &ctx,
            "events.getSince",
            json!({"sessionId": sid, "afterSequence": 0, "limit": 2}),
        )
        .await;

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
            .create_session("m", "/tmp", Some("t"), None)
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
            .create_session("m", "/tmp", Some("t"), None)
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
        // Appending to a session that doesn't exist surfaces the typed
        // SESSION_NOT_FOUND code via map_event_store_error. Clients can
        // disambiguate "wrong id" from "server bug" without parsing
        // the message string.
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
        assert_eq!(err.code(), "SESSION_NOT_FOUND");
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

    #[tokio::test]
    async fn get_since_after_event_id() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"), None)
            .unwrap();

        // Append 3 events
        let mut event_ids = Vec::new();
        for i in 0..3 {
            let evt = ctx
                .event_store
                .append(&crate::events::AppendOptions {
                    session_id: &sid,
                    event_type: crate::events::EventType::MessageUser,
                    payload: json!({"text": format!("msg {i}")}),
                    parent_id: None,
                    sequence: None,
                })
                .unwrap();
            event_ids.push(evt.id.clone());
        }

        // Use afterEventId to get events after the first user message
        let result = dispatch_ok(
            &ctx,
            "events.getSince",
            json!({"sessionId": sid, "afterEventId": event_ids[0]}),
        )
        .await;

        let events = result["events"].as_array().unwrap();
        assert_eq!(events.len(), 2); // msg 1 and msg 2 (after msg 0)
        assert!(result["nextCursor"].is_string());
    }

    #[tokio::test]
    async fn get_since_no_cursor_returns_all_events() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"), None)
            .unwrap();

        let _ = ctx
            .event_store
            .append(&crate::events::AppendOptions {
                session_id: &sid,
                event_type: crate::events::EventType::MessageUser,
                payload: json!({"text": "hello"}),
                parent_id: None,
                sequence: None,
            })
            .unwrap();

        // No afterEventId or afterSequence → returns ALL events including session.start
        let result = dispatch_ok(&ctx, "events.getSince", json!({"sessionId": sid})).await;

        let events = result["events"].as_array().unwrap();
        assert_eq!(events.len(), 2); // session.start + message.user
        assert_eq!(events[0]["type"], "session.start");
    }

    #[tokio::test]
    async fn get_since_unknown_event_id_returns_all() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"), None)
            .unwrap();

        // Unknown afterEventId → returns all events
        let result = dispatch_ok(
            &ctx,
            "events.getSince",
            json!({"sessionId": sid, "afterEventId": "nonexistent"}),
        )
        .await;

        let events = result["events"].as_array().unwrap();
        assert_eq!(events.len(), 1); // session.start
    }

    #[tokio::test]
    async fn get_history_has_oldest_event_id() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"), None)
            .unwrap();

        let result = dispatch_ok(&ctx, "events.getHistory", json!({"sessionId": sid})).await;

        assert!(result["oldestEventId"].is_string());
    }

    #[tokio::test]
    async fn get_since_has_next_cursor() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"), None)
            .unwrap();

        let _ = ctx
            .event_store
            .append(&crate::events::AppendOptions {
                session_id: &sid,
                event_type: crate::events::EventType::MessageUser,
                payload: json!({"text": "hello"}),
                parent_id: None,
                sequence: None,
            })
            .unwrap();

        let result = dispatch_ok(&ctx, "events.getSince", json!({"sessionId": sid})).await;

        // nextCursor should be the ID of the last event returned
        let events = result["events"].as_array().unwrap();
        let last_id = events.last().unwrap()["id"].as_str().unwrap();
        assert_eq!(result["nextCursor"].as_str().unwrap(), last_id);
    }
}
