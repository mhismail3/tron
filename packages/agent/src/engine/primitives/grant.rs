//! Grant primitive worker contracts and handlers.
//!
//! `grant::*` is the only runtime surface that mutates the engine-owned
//! authority model. Callers may carry scope strings for audit context, but
//! invocation authority is resolved from these durable grants before handlers
//! run.

use std::sync::Arc;

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::{
    GRANT_WORKER_ID, PrimitiveFunctionRegistration, PrimitiveStores, handled_registration,
    optional_string, optional_u64, primitive_function, required_str, required_string_owned,
};
use crate::engine::{
    AuthorityGrantId, DeriveGrant, EffectClass, EngineError, EngineGrantLifecycle,
    IdempotencyContract, InProcessFunctionHandler, Invocation, ListGrants, Result, RiskLevel,
    VisibilityScope,
};

pub(crate) const DERIVE_FUNCTION: &str = "grant::derive";
pub(crate) const INSPECT_FUNCTION: &str = "grant::inspect";
pub(crate) const LIST_FUNCTION: &str = "grant::list";
pub(crate) const REVOKE_FUNCTION: &str = "grant::revoke";

pub(super) fn registrations(
    stores: &PrimitiveStores,
) -> Result<Vec<PrimitiveFunctionRegistration>> {
    let handler = Arc::new(GrantPrimitiveHandler {
        store: stores.grants.clone(),
    });
    let mut derive = primitive_function(
        DERIVE_FUNCTION,
        GRANT_WORKER_ID,
        "derive a narrower authority grant",
        EffectClass::IdempotentWrite,
        "grant.write",
    )
    .with_idempotency(IdempotencyContract::caller_system_engine_ledger())
    .with_request_schema(derive_schema())
    .with_response_schema(json!({
        "type": "object",
        "required": ["grant"],
        "additionalProperties": false,
        "properties": {"grant": {"type": "object"}}
    }));
    derive.visibility = VisibilityScope::Admin;

    let mut revoke = primitive_function(
        REVOKE_FUNCTION,
        GRANT_WORKER_ID,
        "revoke an authority grant",
        EffectClass::IdempotentWrite,
        "grant.write",
    )
    .with_idempotency(IdempotencyContract::caller_system_engine_ledger())
    .with_request_schema(json!({
        "type": "object",
        "required": ["grantId"],
        "additionalProperties": false,
        "properties": {"grantId": {"type": "string"}}
    }))
    .with_response_schema(json!({
        "type": "object",
        "required": ["grant"],
        "additionalProperties": false,
        "properties": {"grant": {"type": "object"}}
    }));
    revoke.visibility = VisibilityScope::Admin;

    let mut inspect = primitive_function(
        INSPECT_FUNCTION,
        GRANT_WORKER_ID,
        "inspect one authority grant",
        EffectClass::PureRead,
        "grant.read",
    )
    .with_request_schema(json!({
        "type": "object",
        "required": ["grantId"],
        "additionalProperties": false,
        "properties": {"grantId": {"type": "string"}}
    }))
    .with_response_schema(json!({
        "type": "object",
        "required": ["grant"],
        "additionalProperties": false,
        "properties": {"grant": {"type": ["object", "null"]}}
    }));
    inspect.visibility = VisibilityScope::Admin;

    let mut list = primitive_function(
        LIST_FUNCTION,
        GRANT_WORKER_ID,
        "list authority grants",
        EffectClass::PureRead,
        "grant.read",
    )
    .with_request_schema(list_schema())
    .with_response_schema(json!({
        "type": "object",
        "required": ["grants"],
        "additionalProperties": false,
        "properties": {"grants": {"type": "array"}}
    }));
    list.visibility = VisibilityScope::Admin;

    Ok(vec![
        handled_registration(derive, handler.clone()),
        handled_registration(inspect, handler.clone()),
        handled_registration(list, handler.clone()),
        handled_registration(revoke, handler),
    ])
}

struct GrantPrimitiveHandler {
    store: Arc<std::sync::Mutex<super::EngineGrantStoreBackend>>,
}

#[async_trait]
impl InProcessFunctionHandler for GrantPrimitiveHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        let mut store = self
            .store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("grant store lock poisoned".to_owned()))?;
        match invocation.function_id.as_str() {
            DERIVE_FUNCTION => {
                let request = DeriveGrant {
                    grant_id: optional_grant_id(&invocation.payload, "grantId")?,
                    parent_grant_id: grant_id(required_str(&invocation.payload, "parentGrantId")?)?,
                    subject_actor_id: optional_string(invocation.payload.get("subjectActorId"))?
                        .map(crate::engine::ActorId::new)
                        .transpose()?,
                    subject_worker_id: optional_string(invocation.payload.get("subjectWorkerId"))?
                        .map(crate::engine::WorkerId::new)
                        .transpose()?,
                    subject_invocation_id: optional_string(
                        invocation.payload.get("subjectInvocationId"),
                    )?
                    .map(crate::engine::InvocationId::new)
                    .transpose()?,
                    allowed_capabilities: string_array(&invocation.payload, "allowedCapabilities")?,
                    allowed_namespaces: string_array(&invocation.payload, "allowedNamespaces")?,
                    allowed_authority_scopes: string_array(
                        &invocation.payload,
                        "allowedAuthorityScopes",
                    )?,
                    allowed_resource_kinds: string_array(
                        &invocation.payload,
                        "allowedResourceKinds",
                    )?,
                    resource_selectors: optional_string_array(
                        &invocation.payload,
                        "resourceSelectors",
                    )?
                    .unwrap_or_else(|| vec!["*".to_owned()]),
                    file_roots: string_array(&invocation.payload, "fileRoots")?,
                    network_policy: required_string_owned(&invocation.payload, "networkPolicy")?,
                    max_risk: parse_risk(required_str(&invocation.payload, "maxRisk")?)?,
                    budget: invocation
                        .payload
                        .get("budget")
                        .cloned()
                        .unwrap_or_else(|| json!({})),
                    expires_at: optional_datetime(&invocation.payload, "expiresAt")?,
                    can_delegate: invocation
                        .payload
                        .get("canDelegate")
                        .and_then(Value::as_bool)
                        .unwrap_or(false),
                    provenance: invocation
                        .payload
                        .get("provenance")
                        .cloned()
                        .unwrap_or_else(|| json!({})),
                    trace_id: invocation.causal_context.trace_id.clone(),
                };
                Ok(json!({ "grant": store.derive(request)? }))
            }
            INSPECT_FUNCTION => {
                let grant_id = grant_id(required_str(&invocation.payload, "grantId")?)?;
                Ok(json!({ "grant": store.inspect(&grant_id)? }))
            }
            LIST_FUNCTION => {
                let filter = ListGrants {
                    parent_grant_id: optional_grant_id(&invocation.payload, "parentGrantId")?,
                    lifecycle: optional_string(invocation.payload.get("lifecycle"))?
                        .map(|value| parse_lifecycle(&value))
                        .transpose()?,
                    limit: optional_u64(invocation.payload.get("limit"))?.unwrap_or(100) as usize,
                };
                Ok(json!({ "grants": store.list(filter)? }))
            }
            REVOKE_FUNCTION => {
                let grant_id = grant_id(required_str(&invocation.payload, "grantId")?)?;
                Ok(json!({ "grant": store.revoke(&grant_id, invocation.causal_context.trace_id)? }))
            }
            _ => Err(EngineError::NotFound {
                kind: "function",
                id: invocation.function_id.to_string(),
            }),
        }
    }
}

fn derive_schema() -> Value {
    json!({
        "type": "object",
        "required": [
            "parentGrantId",
            "allowedCapabilities",
            "allowedNamespaces",
            "allowedAuthorityScopes",
            "allowedResourceKinds",
            "fileRoots",
            "networkPolicy",
            "maxRisk"
        ],
        "additionalProperties": false,
        "properties": {
            "grantId": {"type": "string"},
            "parentGrantId": {"type": "string"},
            "subjectActorId": {"type": "string"},
            "subjectWorkerId": {"type": "string"},
            "subjectInvocationId": {"type": "string"},
            "allowedCapabilities": string_array_schema(),
            "allowedNamespaces": string_array_schema(),
            "allowedAuthorityScopes": string_array_schema(),
            "allowedResourceKinds": string_array_schema(),
            "resourceSelectors": string_array_schema(),
            "fileRoots": string_array_schema(),
            "networkPolicy": {"type": "string", "enum": ["none", "loopback", "declared", "unrestricted"]},
            "maxRisk": {"type": "string", "enum": ["low", "medium", "high", "critical"]},
            "budget": {"type": "object"},
            "expiresAt": {"type": "string"},
            "canDelegate": {"type": "boolean"},
            "provenance": {"type": "object"}
        }
    })
}

fn list_schema() -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "parentGrantId": {"type": "string"},
            "lifecycle": {"type": "string", "enum": ["active", "revoked"]},
            "limit": {"type": "integer"}
        }
    })
}

fn string_array_schema() -> Value {
    json!({"type": "array", "items": {"type": "string"}, "minItems": 1})
}

fn string_array(payload: &Value, field: &str) -> Result<Vec<String>> {
    optional_string_array(payload, field)?.ok_or_else(|| {
        EngineError::PolicyViolation(format!("required field {field} must be a string array"))
    })
}

fn optional_string_array(payload: &Value, field: &str) -> Result<Option<Vec<String>>> {
    let Some(value) = payload.get(field) else {
        return Ok(None);
    };
    let Some(items) = value.as_array() else {
        return Err(EngineError::PolicyViolation(format!(
            "field {field} must be an array"
        )));
    };
    items
        .iter()
        .map(|item| {
            item.as_str().map(str::to_owned).ok_or_else(|| {
                EngineError::PolicyViolation(format!("field {field} must be a string array"))
            })
        })
        .collect::<Result<Vec<_>>>()
        .map(Some)
}

fn optional_grant_id(payload: &Value, field: &str) -> Result<Option<AuthorityGrantId>> {
    optional_string(payload.get(field))?
        .map(|value| grant_id(&value))
        .transpose()
}

fn optional_datetime(payload: &Value, field: &str) -> Result<Option<DateTime<Utc>>> {
    optional_string(payload.get(field))?
        .map(|value| {
            DateTime::parse_from_rfc3339(&value)
                .map(|value| value.with_timezone(&Utc))
                .map_err(|error| {
                    EngineError::PolicyViolation(format!("invalid {field} timestamp: {error}"))
                })
        })
        .transpose()
}

fn parse_lifecycle(value: &str) -> Result<EngineGrantLifecycle> {
    match value {
        "active" => Ok(EngineGrantLifecycle::Active),
        "revoked" => Ok(EngineGrantLifecycle::Revoked),
        other => Err(EngineError::PolicyViolation(format!(
            "unsupported grant lifecycle {other}"
        ))),
    }
}

fn parse_risk(value: &str) -> Result<RiskLevel> {
    match value {
        "low" => Ok(RiskLevel::Low),
        "medium" => Ok(RiskLevel::Medium),
        "high" => Ok(RiskLevel::High),
        "critical" => Ok(RiskLevel::Critical),
        other => Err(EngineError::PolicyViolation(format!(
            "unsupported grant risk {other}"
        ))),
    }
}

fn grant_id(value: &str) -> Result<AuthorityGrantId> {
    AuthorityGrantId::new(value)
}
