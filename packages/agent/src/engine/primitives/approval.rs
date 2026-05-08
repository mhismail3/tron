//! Approval primitive worker contracts and handlers.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};

use super::{
    APPROVAL_GET_FUNCTION, APPROVAL_LIST_FUNCTION, APPROVAL_REQUEST_FUNCTION,
    APPROVAL_RESOLVE_FUNCTION, APPROVAL_WORKER_ID, PrimitiveFunctionRegistration, PrimitiveStores,
    approval_request_from_invocation, handled_registration, optional_string, optional_u64,
    parse_approval_status, primitive_compensation, primitive_function, required_str,
};
use crate::engine::{
    AuthorityRequirement, CompensationKind, EffectClass, EngineError, IdempotencyContract,
    InProcessFunctionHandler, Invocation, Result, RiskLevel, VisibilityScope,
};

pub(super) fn registrations(
    stores: &PrimitiveStores,
) -> Result<Vec<PrimitiveFunctionRegistration>> {
    let approval_handler = Arc::new(ApprovalPrimitiveHandler {
        store: stores.approvals.clone(),
    });
    Ok(vec![
        handled_registration(
            primitive_function(
                APPROVAL_REQUEST_FUNCTION,
                APPROVAL_WORKER_ID,
                "request approval for a high-risk invocation",
                EffectClass::IdempotentWrite,
                "approval.request",
            )
            .with_idempotency(IdempotencyContract::caller_session_engine_ledger())
            .with_risk(RiskLevel::Medium)
            .with_request_schema(approval_request_schema())
            .with_response_schema(approval_record_response_schema()),
            approval_handler.clone(),
        ),
        handled_registration(
            {
                let mut definition = primitive_function(
                    APPROVAL_RESOLVE_FUNCTION,
                    APPROVAL_WORKER_ID,
                    "resolve and optionally resume an approval",
                    EffectClass::IdempotentWrite,
                    "approval.resolve",
                )
                .with_required_authority(
                    AuthorityRequirement::scope("approval.resolve").with_approval_required(),
                )
                .with_idempotency(IdempotencyContract::caller_system_engine_ledger())
                .with_risk(RiskLevel::High)
                .with_compensation(primitive_compensation(
                    CompensationKind::EventSourced,
                    "approval resolution is event-sourced in the approval ledger; denied approvals are terminal and approved invocations keep their own compensation records",
                ))
                .with_request_schema(approval_resolve_schema())
                .with_response_schema(json!({
                    "type": "object",
                    "required": ["approval", "child"],
                    "additionalProperties": false,
                    "properties": {
                        "approval": {"type": "object"},
                        "child": {}
                    }
                }));
                definition.visibility = VisibilityScope::System;
                definition
            },
            approval_handler.clone(),
        ),
        handled_registration(
            {
                let mut definition = primitive_function(
                    APPROVAL_GET_FUNCTION,
                    APPROVAL_WORKER_ID,
                    "get one approval record",
                    EffectClass::PureRead,
                    "approval.read",
                )
                .with_request_schema(approval_get_schema())
                .with_response_schema(approval_nullable_response_schema());
                definition.visibility = VisibilityScope::System;
                definition
            },
            approval_handler.clone(),
        ),
        handled_registration(
            {
                let mut definition = primitive_function(
                    APPROVAL_LIST_FUNCTION,
                    APPROVAL_WORKER_ID,
                    "list approval records",
                    EffectClass::PureRead,
                    "approval.read",
                )
                .with_request_schema(approval_list_schema())
                .with_response_schema(json!({
                    "type": "object",
                    "required": ["approvals"],
                    "additionalProperties": false,
                    "properties": {"approvals": {"type": "array"}}
                }));
                definition.visibility = VisibilityScope::System;
                definition
            },
            approval_handler,
        ),
    ])
}

struct ApprovalPrimitiveHandler {
    store: Arc<std::sync::Mutex<super::ApprovalStoreBackend>>,
}

#[async_trait]
impl InProcessFunctionHandler for ApprovalPrimitiveHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        let mut store = self
            .store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("approval store lock poisoned".to_owned()))?;
        match invocation.function_id.as_str() {
            APPROVAL_REQUEST_FUNCTION => {
                let record = store.request(approval_request_from_invocation(&invocation)?)?;
                Ok(json!({ "approval": record }))
            }
            APPROVAL_GET_FUNCTION => {
                let approval_id = required_str(&invocation.payload, "approvalId")?;
                Ok(json!({ "approval": store.get(approval_id)? }))
            }
            APPROVAL_LIST_FUNCTION => {
                let status = optional_string(invocation.payload.get("status"))?
                    .map(|value| parse_approval_status(&value))
                    .transpose()?;
                let session_id = optional_string(invocation.payload.get("sessionId"))?;
                let limit = optional_u64(invocation.payload.get("limit"))?.unwrap_or(100) as usize;
                Ok(json!({
                    "approvals": store.list(status, session_id.as_deref(), limit)?
                }))
            }
            APPROVAL_RESOLVE_FUNCTION => Err(EngineError::PolicyViolation(
                "approval::resolve must execute through EngineHostHandle so the target invocation can resume".to_owned(),
            )),
            _ => Err(EngineError::NotFound {
                kind: "function",
                id: invocation.function_id.to_string(),
            }),
        }
    }
}

fn approval_request_schema() -> Value {
    json!({
        "type": "object",
        "required": ["functionId"],
        "additionalProperties": false,
        "properties": {
            "functionId": {"type": "string"},
            "payload": {}
        }
    })
}

fn approval_resolve_schema() -> Value {
    json!({
        "type": "object",
        "required": ["approvalId", "decision"],
        "additionalProperties": false,
        "properties": {
            "approvalId": {"type": "string"},
            "decision": {"type": "string", "enum": ["approve", "deny"]},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"}
        }
    })
}

fn approval_get_schema() -> Value {
    json!({
        "type": "object",
        "required": ["approvalId"],
        "additionalProperties": false,
        "properties": {
            "approvalId": {"type": "string"},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"}
        }
    })
}

fn approval_list_schema() -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "status": {"type": "string"},
            "sessionId": {"type": "string"},
            "limit": {"type": "integer"},
            "workspaceId": {"type": "string"}
        }
    })
}

fn approval_record_response_schema() -> Value {
    json!({
        "type": "object",
        "required": ["approval"],
        "additionalProperties": false,
        "properties": {"approval": {"type": "object"}}
    })
}

fn approval_nullable_response_schema() -> Value {
    json!({
        "type": "object",
        "required": ["approval"],
        "additionalProperties": false,
        "properties": {"approval": {}}
    })
}
