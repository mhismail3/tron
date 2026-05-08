//! State primitive worker contracts and handlers.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};

use super::{
    PrimitiveFunctionRegistration, PrimitiveStores, STATE_WORKER_ID, handled_registration,
    optional_string, optional_u64, primitive_function, required_str, required_string_owned,
    state_scope_from_payload,
};
use crate::engine::{
    EffectClass, EngineError, IdempotencyContract, InProcessFunctionHandler, Invocation, Result,
};

pub(super) fn registrations(
    stores: &PrimitiveStores,
) -> Result<Vec<PrimitiveFunctionRegistration>> {
    let state_handler = Arc::new(StatePrimitiveHandler {
        store: stores.state.clone(),
    });
    Ok(vec![
        handled_registration(
            primitive_function(
                "state::get",
                STATE_WORKER_ID,
                "read scoped engine state",
                EffectClass::PureRead,
                "state.read",
            )
            .with_request_schema(state_key_schema())
            .with_response_schema(state_entry_response_schema(true)),
            state_handler.clone(),
        ),
        handled_registration(
            primitive_function(
                "state::set",
                STATE_WORKER_ID,
                "write scoped engine state",
                EffectClass::IdempotentWrite,
                "state.write",
            )
            .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
            .with_request_schema(state_set_schema())
            .with_response_schema(state_entry_response_schema(false)),
            state_handler.clone(),
        ),
        handled_registration(
            primitive_function(
                "state::delete",
                STATE_WORKER_ID,
                "delete scoped engine state",
                EffectClass::IdempotentWrite,
                "state.write",
            )
            .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
            .with_request_schema(state_key_schema())
            .with_response_schema(super::boolean_response_schema("deleted")),
            state_handler.clone(),
        ),
        handled_registration(
            primitive_function(
                "state::compare_and_set",
                STATE_WORKER_ID,
                "conditionally update scoped engine state",
                EffectClass::IdempotentWrite,
                "state.write",
            )
            .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
            .with_request_schema(state_compare_and_set_schema())
            .with_response_schema(state_entry_response_schema(false)),
            state_handler.clone(),
        ),
        handled_registration(
            primitive_function(
                "state::list",
                STATE_WORKER_ID,
                "list scoped engine state",
                EffectClass::PureRead,
                "state.read",
            )
            .with_request_schema(state_list_schema())
            .with_response_schema(json!({
                "type": "object",
                "required": ["entries"],
                "additionalProperties": false,
                "properties": {"entries": {"type": "array"}}
            })),
            state_handler,
        ),
    ])
}

struct StatePrimitiveHandler {
    store: Arc<std::sync::Mutex<super::StateStoreBackend>>,
}

#[async_trait]
impl InProcessFunctionHandler for StatePrimitiveHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        let mut store = self
            .store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("state store lock poisoned".to_owned()))?;
        match invocation.function_id.as_str() {
            "state::get" => {
                let scope = state_scope_from_payload(&invocation)?;
                let namespace = required_str(&invocation.payload, "namespace")?;
                let key = required_str(&invocation.payload, "key")?;
                Ok(json!({ "entry": store.get(scope, namespace, key)? }))
            }
            "state::set" => {
                let scope = state_scope_from_payload(&invocation)?;
                let namespace = required_string_owned(&invocation.payload, "namespace")?;
                let key = required_string_owned(&invocation.payload, "key")?;
                let value = invocation
                    .payload
                    .get("value")
                    .cloned()
                    .unwrap_or(Value::Null);
                Ok(json!({ "entry": store.set(scope, namespace, key, value)? }))
            }
            "state::delete" => {
                let scope = state_scope_from_payload(&invocation)?;
                let namespace = required_str(&invocation.payload, "namespace")?;
                let key = required_str(&invocation.payload, "key")?;
                Ok(json!({ "deleted": store.delete(scope, namespace, key)? }))
            }
            "state::compare_and_set" => {
                let scope = state_scope_from_payload(&invocation)?;
                let namespace = required_string_owned(&invocation.payload, "namespace")?;
                let key = required_string_owned(&invocation.payload, "key")?;
                let expected_revision = optional_u64(invocation.payload.get("expectedRevision"))?;
                let value = invocation
                    .payload
                    .get("value")
                    .cloned()
                    .unwrap_or(Value::Null);
                Ok(json!({
                    "entry": store.compare_and_set(scope, namespace, key, expected_revision, value)?
                }))
            }
            "state::list" => {
                let scope = state_scope_from_payload(&invocation)?;
                let namespace = required_str(&invocation.payload, "namespace")?;
                let key_prefix = optional_string(invocation.payload.get("keyPrefix"))?;
                let limit = optional_u64(invocation.payload.get("limit"))?.unwrap_or(100) as usize;
                Ok(json!({
                    "entries": store.list(scope, namespace, key_prefix.as_deref(), limit)?
                }))
            }
            _ => Err(EngineError::NotFound {
                kind: "function",
                id: invocation.function_id.to_string(),
            }),
        }
    }
}

fn state_scope_properties() -> Value {
    json!({
        "scope": {"type": "string", "enum": ["system", "workspace", "session"]},
        "sessionId": {"type": "string"},
        "workspaceId": {"type": "string"},
        "namespace": {"type": "string"},
        "key": {"type": "string"}
    })
}

fn state_key_schema() -> Value {
    json!({
        "type": "object",
        "required": ["namespace", "key"],
        "additionalProperties": false,
        "properties": state_scope_properties()
    })
}

fn state_set_schema() -> Value {
    let mut properties = state_scope_properties();
    properties["value"] = json!({});
    json!({
        "type": "object",
        "required": ["namespace", "key", "value"],
        "additionalProperties": false,
        "properties": properties
    })
}

fn state_compare_and_set_schema() -> Value {
    let mut properties = state_scope_properties();
    properties["value"] = json!({});
    properties["expectedRevision"] = json!({"type": "integer"});
    json!({
        "type": "object",
        "required": ["namespace", "key", "value"],
        "additionalProperties": false,
        "properties": properties
    })
}

fn state_list_schema() -> Value {
    json!({
        "type": "object",
        "required": ["namespace"],
        "additionalProperties": false,
        "properties": {
            "scope": {"type": "string", "enum": ["system", "workspace", "session"]},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"},
            "namespace": {"type": "string"},
            "keyPrefix": {"type": "string"},
            "limit": {"type": "integer"}
        }
    })
}

fn state_entry_response_schema(nullable: bool) -> Value {
    let entry_schema = if nullable {
        json!({})
    } else {
        json!({"type": "object"})
    };
    json!({
        "type": "object",
        "required": ["entry"],
        "additionalProperties": false,
        "properties": {"entry": entry_schema}
    })
}
