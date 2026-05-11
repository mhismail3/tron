//! Stream primitive worker contracts and handlers.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};

use super::{
    PrimitiveFunctionRegistration, PrimitiveStores, STREAM_WORKER_ID, handled_registration,
    optional_u64, optional_visibility, primitive_function, required_str, required_string_owned,
};
use crate::engine::{
    EffectClass, EngineError, IdempotencyContract, InProcessFunctionHandler, Invocation,
    PublishStreamEvent, Result, StreamActorScope, StreamCursor, VisibilityScope,
};

pub(super) fn registrations(
    stores: &PrimitiveStores,
) -> Result<Vec<PrimitiveFunctionRegistration>> {
    let stream_handler = Arc::new(StreamPrimitiveHandler {
        store: stores.streams.clone(),
    });
    Ok(vec![
        handled_registration(
            primitive_function(
                "stream::subscribe",
                STREAM_WORKER_ID,
                "subscribe to a live stream; omit afterCursor to start at the topic tail",
                EffectClass::IdempotentWrite,
                "stream.write",
            )
            .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
            .with_request_schema(stream_subscribe_schema())
            .with_response_schema(stream_subscribe_response_schema()),
            stream_handler.clone(),
        ),
        handled_registration(
            primitive_function(
                "stream::poll",
                STREAM_WORKER_ID,
                "poll a stream subscription",
                EffectClass::PureRead,
                "stream.read",
            )
            .with_request_schema(stream_poll_schema())
            .with_response_schema(stream_poll_response_schema()),
            stream_handler.clone(),
        ),
        handled_registration(
            primitive_function(
                "stream::unsubscribe",
                STREAM_WORKER_ID,
                "unsubscribe from a stream",
                EffectClass::IdempotentWrite,
                "stream.write",
            )
            .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
            .with_request_schema(stream_unsubscribe_schema())
            .with_response_schema(super::boolean_response_schema("unsubscribed")),
            stream_handler.clone(),
        ),
        handled_registration(
            crate::engine::FunctionDefinition::new(
                super::function_id("stream::publish")?,
                super::worker_id(STREAM_WORKER_ID)?,
                "publish an internal stream event",
                VisibilityScope::Internal,
                EffectClass::AppendOnlyEvent,
            )
            .with_required_authority(crate::engine::AuthorityRequirement::scope("stream.write"))
            .with_idempotency(IdempotencyContract::caller_system_engine_ledger())
            .with_request_schema(stream_publish_schema())
            .with_response_schema(json!({
                "type": "object",
                "required": ["cursor"],
                "additionalProperties": false,
                "properties": {"cursor": {"type": "integer"}}
            })),
            stream_handler,
        ),
    ])
}

struct StreamPrimitiveHandler {
    store: Arc<std::sync::Mutex<super::StreamStoreBackend>>,
}

#[async_trait]
impl InProcessFunctionHandler for StreamPrimitiveHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        let mut store = self
            .store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("stream store lock poisoned".to_owned()))?;
        match invocation.function_id.as_str() {
            "stream::subscribe" => {
                let topic = required_string_owned(&invocation.payload, "topic")?;
                let subscription_id =
                    super::optional_string(invocation.payload.get("subscriptionId"))?
                        .unwrap_or_else(|| crate::engine::InvocationId::generate().to_string());
                let cursor = match optional_u64(invocation.payload.get("afterCursor"))? {
                    Some(cursor) => StreamCursor(cursor),
                    None => store.latest_cursor(&topic)?,
                };
                let visibility = optional_visibility(invocation.payload.get("visibility"))?
                    .unwrap_or(VisibilityScope::Session);
                let session_id = super::optional_string(invocation.payload.get("sessionId"))?
                    .or(invocation.causal_context.session_id.clone());
                let workspace_id = super::optional_string(invocation.payload.get("workspaceId"))?
                    .or(invocation.causal_context.workspace_id.clone());
                let subscription = store.subscribe(
                    subscription_id,
                    topic,
                    cursor,
                    visibility,
                    session_id,
                    workspace_id,
                )?;
                Ok(json!({
                    "subscriptionId": subscription.subscription_id,
                    "topic": subscription.topic,
                    "cursor": subscription.cursor.0,
                    "active": subscription.active,
                }))
            }
            "stream::poll" => {
                let subscription_id = required_str(&invocation.payload, "subscriptionId")?;
                let after = optional_u64(invocation.payload.get("afterCursor"))?.map(StreamCursor);
                let limit = optional_u64(invocation.payload.get("limit"))?.unwrap_or(100) as usize;
                let actor = StreamActorScope {
                    session_id: invocation.causal_context.session_id.clone(),
                    workspace_id: invocation.causal_context.workspace_id.clone(),
                    admin: invocation.causal_context.actor_kind.is_admin_like(),
                };
                let page = store.poll(subscription_id, after, limit, &actor)?;
                Ok(json!({
                    "events": page.events,
                    "nextCursor": page.next_cursor.0,
                    "hasMore": page.has_more,
                }))
            }
            "stream::unsubscribe" => {
                let subscription_id = required_str(&invocation.payload, "subscriptionId")?;
                let unsubscribed = store.unsubscribe(subscription_id)?;
                Ok(json!({ "unsubscribed": unsubscribed }))
            }
            "stream::publish" => {
                let topic = required_string_owned(&invocation.payload, "topic")?;
                let payload = invocation
                    .payload
                    .get("payload")
                    .cloned()
                    .unwrap_or(Value::Null);
                let visibility = optional_visibility(invocation.payload.get("visibility"))?
                    .unwrap_or(VisibilityScope::Session);
                let session_id = super::optional_string(invocation.payload.get("sessionId"))?
                    .or(invocation.causal_context.session_id.clone());
                let workspace_id = super::optional_string(invocation.payload.get("workspaceId"))?
                    .or(invocation.causal_context.workspace_id.clone());
                let producer = super::optional_string(invocation.payload.get("producer"))?
                    .unwrap_or_else(|| invocation.function_id.to_string());
                let cursor = store.publish(PublishStreamEvent {
                    topic,
                    payload,
                    visibility,
                    session_id,
                    workspace_id,
                    producer,
                    trace_id: Some(invocation.causal_context.trace_id.clone()),
                    parent_invocation_id: invocation.causal_context.parent_invocation_id.clone(),
                })?;
                Ok(json!({ "cursor": cursor.0 }))
            }
            _ => Err(EngineError::NotFound {
                kind: "function",
                id: invocation.function_id.to_string(),
            }),
        }
    }
}

fn stream_subscribe_schema() -> Value {
    json!({
        "type": "object",
        "required": ["topic"],
        "additionalProperties": false,
        "properties": {
            "topic": {"type": "string"},
            "subscriptionId": {"type": "string"},
            "afterCursor": {"type": "integer", "description": "Replay cursor. Omit to start at the current topic tail for live-only delivery."},
            "visibility": {"type": "string"},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"}
        }
    })
}

fn stream_subscribe_response_schema() -> Value {
    json!({
        "type": "object",
        "required": ["subscriptionId", "topic", "cursor", "active"],
        "additionalProperties": false,
        "properties": {
            "subscriptionId": {"type": "string"},
            "topic": {"type": "string"},
            "cursor": {"type": "integer"},
            "active": {"type": "boolean"}
        }
    })
}

fn stream_poll_schema() -> Value {
    json!({
        "type": "object",
        "required": ["subscriptionId"],
        "additionalProperties": false,
        "properties": {
            "subscriptionId": {"type": "string"},
            "afterCursor": {"type": "integer"},
            "limit": {"type": "integer"}
        }
    })
}

fn stream_poll_response_schema() -> Value {
    json!({
        "type": "object",
        "required": ["events", "nextCursor", "hasMore"],
        "additionalProperties": false,
        "properties": {
            "events": {"type": "array"},
            "nextCursor": {"type": "integer"},
            "hasMore": {"type": "boolean"}
        }
    })
}

fn stream_unsubscribe_schema() -> Value {
    json!({
        "type": "object",
        "required": ["subscriptionId"],
        "additionalProperties": false,
        "properties": {"subscriptionId": {"type": "string"}}
    })
}

fn stream_publish_schema() -> Value {
    json!({
        "type": "object",
        "required": ["topic", "payload"],
        "additionalProperties": false,
        "properties": {
            "topic": {"type": "string"},
            "payload": {},
            "visibility": {"type": "string"},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"},
            "producer": {"type": "string"}
        }
    })
}
