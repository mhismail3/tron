//! Queue primitive worker contracts and handlers.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};

use super::{
    PrimitiveFunctionRegistration, PrimitiveStores, QUEUE_WORKER_ID, handled_registration,
    optional_u64, primitive_function, required_str, required_string_owned,
};
use crate::engine::queue::{queue_failure_event_type, queue_lifecycle_stream_event};
use crate::engine::{
    EffectClass, EngineError, FunctionRevision, IdempotencyContract, InProcessFunctionHandler,
    Invocation, Result,
};

pub(super) fn registrations(
    stores: &PrimitiveStores,
) -> Result<Vec<PrimitiveFunctionRegistration>> {
    let queue_handler = Arc::new(QueuePrimitiveHandler {
        store: stores.queue.clone(),
        streams: stores.streams.clone(),
    });
    Ok(vec![
        handled_registration(
            primitive_function(
                "queue::enqueue",
                QUEUE_WORKER_ID,
                "enqueue a durable engine invocation",
                EffectClass::IdempotentWrite,
                "queue.write",
            )
            .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
            .with_request_schema(queue_enqueue_schema())
            .with_response_schema(queue_item_response_schema()),
            queue_handler.clone(),
        ),
        handled_registration(
            primitive_function(
                "queue::claim",
                QUEUE_WORKER_ID,
                "claim a queued invocation",
                EffectClass::IdempotentWrite,
                "queue.write",
            )
            .with_idempotency(IdempotencyContract::caller_system_engine_ledger())
            .with_request_schema(queue_claim_schema())
            .with_response_schema(queue_item_response_schema()),
            queue_handler.clone(),
        ),
        handled_registration(
            primitive_function(
                "queue::complete",
                QUEUE_WORKER_ID,
                "complete a queued invocation",
                EffectClass::IdempotentWrite,
                "queue.write",
            )
            .with_idempotency(IdempotencyContract::caller_system_engine_ledger())
            .with_request_schema(queue_receipt_schema())
            .with_response_schema(super::boolean_response_schema("completed")),
            queue_handler.clone(),
        ),
        handled_registration(
            primitive_function(
                "queue::fail",
                QUEUE_WORKER_ID,
                "fail or retry a queued invocation",
                EffectClass::IdempotentWrite,
                "queue.write",
            )
            .with_idempotency(IdempotencyContract::caller_system_engine_ledger())
            .with_request_schema(queue_fail_schema())
            .with_response_schema(super::boolean_response_schema("failed")),
            queue_handler.clone(),
        ),
        handled_registration(
            primitive_function(
                "queue::cancel",
                QUEUE_WORKER_ID,
                "cancel a queued invocation",
                EffectClass::IdempotentWrite,
                "queue.write",
            )
            .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
            .with_request_schema(queue_receipt_schema())
            .with_response_schema(super::boolean_response_schema("cancelled")),
            queue_handler.clone(),
        ),
        handled_registration(
            primitive_function(
                "queue::get",
                QUEUE_WORKER_ID,
                "inspect a queued invocation",
                EffectClass::PureRead,
                "queue.read",
            )
            .with_request_schema(queue_receipt_schema())
            .with_response_schema(queue_item_response_schema()),
            queue_handler.clone(),
        ),
        handled_registration(
            primitive_function(
                "queue::list",
                QUEUE_WORKER_ID,
                "list queued invocations",
                EffectClass::PureRead,
                "queue.read",
            )
            .with_request_schema(queue_list_schema())
            .with_response_schema(json!({
                "type": "object",
                "required": ["items"],
                "additionalProperties": false,
                "properties": {"items": {"type": "array"}}
            })),
            queue_handler,
        ),
    ])
}

struct QueuePrimitiveHandler {
    store: Arc<std::sync::Mutex<super::QueueStoreBackend>>,
    streams: Arc<std::sync::Mutex<super::StreamStoreBackend>>,
}

impl QueuePrimitiveHandler {
    fn publish_lifecycle(
        &self,
        event_type: &str,
        item: &crate::engine::queue::EngineQueueItem,
    ) -> Result<()> {
        let mut streams = self
            .streams
            .lock()
            .map_err(|_| EngineError::HandlerFailed("stream store lock poisoned".to_owned()))?;
        streams.publish(queue_lifecycle_stream_event(event_type, item, None))?;
        Ok(())
    }
}

#[async_trait]
impl InProcessFunctionHandler for QueuePrimitiveHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        let mut store = self
            .store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("queue store lock poisoned".to_owned()))?;
        match invocation.function_id.as_str() {
            "queue::enqueue" => {
                let queue = required_string_owned(&invocation.payload, "queue")?;
                let function_id =
                    super::function_id(required_str(&invocation.payload, "functionId")?)?;
                let payload = invocation
                    .payload
                    .get("payload")
                    .cloned()
                    .unwrap_or(Value::Null);
                let item = store.enqueue(crate::engine::EnqueueInvocation {
                    queue,
                    function_id,
                    target_revision: optional_u64(invocation.payload.get("targetRevision"))?
                        .map(FunctionRevision),
                    payload,
                    actor_id: invocation.causal_context.actor_id.clone(),
                    actor_kind: invocation.causal_context.actor_kind.clone(),
                    authority_grant_id: invocation.causal_context.authority_grant_id.clone(),
                    authority_scopes: invocation.causal_context.authority_scopes.clone(),
                    runtime_metadata: invocation.causal_context.runtime_metadata.clone(),
                    trace_id: invocation.causal_context.trace_id.clone(),
                    parent_invocation_id: invocation.causal_context.parent_invocation_id.clone(),
                    trigger_id: invocation.causal_context.trigger_id.clone(),
                    session_id: invocation.causal_context.session_id.clone(),
                    workspace_id: invocation.causal_context.workspace_id.clone(),
                    idempotency_key: invocation.causal_context.idempotency_key.clone(),
                })?;
                drop(store);
                self.publish_lifecycle("enqueue", &item)?;
                Ok(json!({ "item": item }))
            }
            "queue::claim" => {
                let queue = required_str(&invocation.payload, "queue")?;
                let lease_owner = required_str(&invocation.payload, "leaseOwner")?;
                let lease_ms =
                    optional_u64(invocation.payload.get("leaseMs"))?.unwrap_or(30_000) as i64;
                Ok(json!({ "item": store.claim(queue, lease_owner, lease_ms)? }))
            }
            "queue::complete" => {
                let receipt_id = required_str(&invocation.payload, "receiptId")?;
                let completed = store.complete(receipt_id)?;
                let item = if completed {
                    store.get(receipt_id)?
                } else {
                    None
                };
                drop(store);
                if let Some(item) = item {
                    self.publish_lifecycle("complete", &item)?;
                }
                Ok(json!({ "completed": completed }))
            }
            "queue::fail" => {
                let receipt_id = required_str(&invocation.payload, "receiptId")?;
                let max_attempts =
                    optional_u64(invocation.payload.get("maxAttempts"))?.unwrap_or(3) as u32;
                let backoff_ms =
                    optional_u64(invocation.payload.get("backoffMs"))?.unwrap_or(0) as i64;
                let failed = store.fail(receipt_id, max_attempts, backoff_ms)?;
                let item = if failed { store.get(receipt_id)? } else { None };
                drop(store);
                if let Some(item) = item {
                    self.publish_lifecycle(queue_failure_event_type(&item), &item)?;
                }
                Ok(json!({ "failed": failed }))
            }
            "queue::cancel" => {
                let receipt_id = required_str(&invocation.payload, "receiptId")?;
                let cancelled = store.cancel(receipt_id)?;
                let item = if cancelled {
                    store.get(receipt_id)?
                } else {
                    None
                };
                drop(store);
                if let Some(item) = item {
                    self.publish_lifecycle("cancel", &item)?;
                }
                Ok(json!({ "cancelled": cancelled }))
            }
            "queue::get" => {
                let receipt_id = required_str(&invocation.payload, "receiptId")?;
                Ok(json!({ "item": store.get(receipt_id)? }))
            }
            "queue::list" => {
                let queue = required_str(&invocation.payload, "queue")?;
                let limit = optional_u64(invocation.payload.get("limit"))?.unwrap_or(100) as usize;
                Ok(json!({ "items": store.list(queue, limit)? }))
            }
            _ => Err(EngineError::NotFound {
                kind: "function",
                id: invocation.function_id.to_string(),
            }),
        }
    }
}

fn queue_enqueue_schema() -> Value {
    json!({
        "type": "object",
        "required": ["queue", "functionId", "payload"],
        "additionalProperties": false,
        "properties": {
            "queue": {"type": "string"},
            "functionId": {"type": "string"},
            "targetRevision": {"type": "integer"},
            "payload": {}
        }
    })
}

fn queue_claim_schema() -> Value {
    json!({
        "type": "object",
        "required": ["queue", "leaseOwner"],
        "additionalProperties": false,
        "properties": {
            "queue": {"type": "string"},
            "leaseOwner": {"type": "string"},
            "leaseMs": {"type": "integer"}
        }
    })
}

fn queue_receipt_schema() -> Value {
    json!({
        "type": "object",
        "required": ["receiptId"],
        "additionalProperties": false,
        "properties": {"receiptId": {"type": "string"}}
    })
}

fn queue_fail_schema() -> Value {
    json!({
        "type": "object",
        "required": ["receiptId"],
        "additionalProperties": false,
        "properties": {
            "receiptId": {"type": "string"},
            "maxAttempts": {"type": "integer"},
            "backoffMs": {"type": "integer"}
        }
    })
}

fn queue_list_schema() -> Value {
    json!({
        "type": "object",
        "required": ["queue"],
        "additionalProperties": false,
        "properties": {
            "queue": {"type": "string"},
            "limit": {"type": "integer"}
        }
    })
}

fn queue_item_response_schema() -> Value {
    json!({
        "type": "object",
        "required": ["item"],
        "additionalProperties": false,
        "properties": {"item": {}}
    })
}
