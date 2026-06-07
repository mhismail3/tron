//! Trigger primitive worker contracts and handlers.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};

use super::{
    PrimitiveFunctionRegistration, PrimitiveStores, TRIGGER_WORKER_ID, handled_registration,
    optional_string, primitive_function, required_str,
};
use crate::engine::{
    DeliveryMode, EffectClass, EngineError, EngineTriggerRuntime, IdempotencyContract,
    InProcessFunctionHandler, Invocation, Result, TriggerDispatchRequest, TriggerId,
};

pub(super) fn registrations(
    stores: &PrimitiveStores,
) -> Result<Vec<PrimitiveFunctionRegistration>> {
    Ok(vec![handled_registration(
        primitive_function(
            "trigger::dispatch",
            TRIGGER_WORKER_ID,
            "dispatch a registered trigger through the engine trigger runtime",
            EffectClass::IdempotentWrite,
            "trigger.dispatch",
        )
        .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
        .with_request_schema(trigger_dispatch_schema())
        .with_response_schema(trigger_dispatch_response_schema()),
        Arc::new(TriggerPrimitiveHandler {
            stores: stores.clone(),
        }),
    )])
}

struct TriggerPrimitiveHandler {
    stores: PrimitiveStores,
}

#[async_trait]
impl InProcessFunctionHandler for TriggerPrimitiveHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        match invocation.function_id.as_str() {
            "trigger::dispatch" => self.dispatch(invocation).await,
            _ => Err(EngineError::NotFound {
                kind: "function",
                id: invocation.function_id.to_string(),
            }),
        }
    }
}

impl TriggerPrimitiveHandler {
    async fn dispatch(&self, invocation: Invocation) -> Result<Value> {
        let trigger_id = TriggerId::new(required_str(&invocation.payload, "triggerId")?)?;
        let payload = invocation
            .payload
            .get("payload")
            .cloned()
            .unwrap_or(Value::Null);
        let delivery_mode = optional_delivery_mode(invocation.payload.get("deliveryMode"))?;
        let target_idempotency_key =
            optional_string(invocation.payload.get("targetIdempotencyKey"))?
                .or(invocation.causal_context.idempotency_key.clone());

        let mut request = TriggerDispatchRequest::new(
            trigger_id.clone(),
            payload,
            invocation.causal_context.actor_id.clone(),
            invocation.causal_context.actor_kind.clone(),
        );
        request.authority_scopes = invocation.causal_context.authority_scopes.clone();
        request.runtime_metadata = invocation.causal_context.runtime_metadata.clone();
        request.trace_id = Some(invocation.causal_context.trace_id.clone());
        request.parent_invocation_id = Some(invocation.id.clone());
        request.session_id = invocation.causal_context.session_id.clone();
        request.workspace_id = invocation.causal_context.workspace_id.clone();
        request.idempotency_key = target_idempotency_key;
        request.delivery_mode = delivery_mode;

        let requested_delivery = request.delivery_mode;
        let result = EngineTriggerRuntime::dispatch(&self.stores.engine_host()?, request).await;
        if let Some(error) = result.error {
            return Err(error);
        }
        let target_result = result.value.unwrap_or(Value::Null);
        let mut response = json!({
            "dispatched": true,
            "triggerId": trigger_id.as_str(),
            "invocationId": result.invocation_id.as_str(),
            "traceId": result.trace_id.as_str(),
            "result": target_result,
        });
        if let Some(delivery_mode) = requested_delivery {
            response["deliveryMode"] = json!(delivery_mode.as_str());
        }
        if let Some(replayed_from) = result.replayed_from {
            response["replayedFrom"] = json!(replayed_from.as_str());
        }
        if let Some(receipt_id) = response
            .get("result")
            .and_then(|value| value.get("receiptId"))
            .cloned()
        {
            response["receiptId"] = receipt_id;
            response["queued"] = json!(true);
        } else {
            response["queued"] = json!(false);
        }
        Ok(response)
    }
}

fn optional_delivery_mode(value: Option<&Value>) -> Result<Option<DeliveryMode>> {
    value
        .map(|value| {
            value
                .as_str()
                .ok_or_else(|| {
                    EngineError::PolicyViolation("deliveryMode must be a string".to_owned())
                })
                .and_then(parse_delivery_mode)
        })
        .transpose()
}

fn parse_delivery_mode(value: &str) -> Result<DeliveryMode> {
    match value {
        "sync" | "Sync" => Ok(DeliveryMode::Sync),
        "void" | "Void" => Ok(DeliveryMode::Void),
        "enqueue" | "Enqueue" => Ok(DeliveryMode::Enqueue),
        other => Err(EngineError::PolicyViolation(format!(
            "unsupported deliveryMode {other}"
        ))),
    }
}

fn trigger_dispatch_schema() -> Value {
    json!({
        "type": "object",
        "required": ["triggerId", "payload"],
        "additionalProperties": false,
        "properties": {
            "triggerId": {"type": "string"},
            "payload": {},
            "deliveryMode": {"type": "string", "enum": ["sync", "Sync", "void", "Void", "enqueue", "Enqueue"]},
            "targetIdempotencyKey": {"type": "string"}
        }
    })
}

fn trigger_dispatch_response_schema() -> Value {
    json!({
        "type": "object",
        "required": ["dispatched", "triggerId", "invocationId", "traceId", "queued", "result"],
        "additionalProperties": false,
        "properties": {
            "dispatched": {"type": "boolean"},
            "triggerId": {"type": "string"},
            "invocationId": {"type": "string"},
            "traceId": {"type": "string"},
            "deliveryMode": {"type": "string"},
            "queued": {"type": "boolean"},
            "receiptId": {"type": "string"},
            "replayedFrom": {"type": "string"},
            "result": {}
        }
    })
}
