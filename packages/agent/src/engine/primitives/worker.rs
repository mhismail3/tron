//! Worker primitive contracts.

use serde_json::{Value, json};

use super::{
    PrimitiveFunctionRegistration, WORKER_WORKER_ID, host_dispatched_registration,
    primitive_compensation, primitive_function,
};
use crate::engine::{
    AuthorityRequirement, CompensationKind, EffectClass, IdempotencyContract, Result, RiskLevel,
};

pub(crate) const LIST_FUNCTION: &str = "worker::list";
pub(crate) const GET_FUNCTION: &str = "worker::get";
pub(crate) const DISCONNECT_FUNCTION: &str = "worker::disconnect";
pub(crate) const HEALTH_FUNCTION: &str = "worker::health";

pub(super) fn registrations() -> Result<Vec<PrimitiveFunctionRegistration>> {
    Ok(vec![
        host_dispatched_registration(
            primitive_function(
                LIST_FUNCTION,
                WORKER_WORKER_ID,
                "list live engine workers",
                EffectClass::PureRead,
                "worker.read",
            )
            .with_request_schema(list_schema())
            .with_response_schema(json!({
                "type": "object",
                "required": ["catalogRevision", "workers"],
                "additionalProperties": false,
                "properties": {
                    "catalogRevision": {"type": "integer"},
                    "workers": {"type": "array"}
                }
            })),
        ),
        host_dispatched_registration(
            primitive_function(
                GET_FUNCTION,
                WORKER_WORKER_ID,
                "inspect one live engine worker",
                EffectClass::PureRead,
                "worker.read",
            )
            .with_request_schema(worker_id_schema())
            .with_response_schema(super::nullable_response_schema("worker")),
        ),
        host_dispatched_registration(
            primitive_function(
                DISCONNECT_FUNCTION,
                WORKER_WORKER_ID,
                "disconnect a volatile local worker and unregister its entries",
                EffectClass::IdempotentWrite,
                "worker.write",
            )
            .with_idempotency(IdempotencyContract::caller_system_engine_ledger())
            .with_required_authority(AuthorityRequirement::scope("worker.write"))
            .with_risk(RiskLevel::High)
            .with_compensation(primitive_compensation(
                CompensationKind::ManualOnly,
                "worker disconnect unregisters volatile catalog entries; reconnecting the worker restores capabilities from its own registration handshake",
            ))
            .with_request_schema(disconnect_schema())
            .with_response_schema(super::boolean_response_schema("disconnected")),
        ),
        host_dispatched_registration(
            primitive_function(
                HEALTH_FUNCTION,
                WORKER_WORKER_ID,
                "report worker health and owned catalog entries",
                EffectClass::PureRead,
                "worker.read",
            )
            .with_request_schema(worker_id_schema())
            .with_response_schema(json!({
                "type": "object",
                "required": ["worker", "functions", "triggers", "health"],
                "additionalProperties": false,
                "properties": {
                    "worker": {},
                    "functions": {"type": "array"},
                    "triggers": {"type": "array"},
                    "health": {"type": "string"}
                }
            })),
        ),
    ])
}

fn list_schema() -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "includeInternal": {"type": "boolean"},
            "visibility": {"type": "string"}
        }
    })
}

fn worker_id_schema() -> Value {
    json!({
        "type": "object",
        "required": ["workerId"],
        "additionalProperties": false,
        "properties": {"workerId": {"type": "string"}}
    })
}

fn disconnect_schema() -> Value {
    json!({
        "type": "object",
        "required": ["workerId"],
        "additionalProperties": false,
        "properties": {
            "workerId": {"type": "string"},
            "reason": {"type": "string"}
        }
    })
}
