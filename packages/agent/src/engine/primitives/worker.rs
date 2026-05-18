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
pub(crate) const PROTOCOL_GUIDE_FUNCTION: &str = "worker::protocol_guide";

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
            .with_required_authority(
                AuthorityRequirement::scope("worker.write").with_approval_required(),
            )
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
        host_dispatched_registration(worker_protocol_guide_function()),
    ])
}

fn worker_protocol_guide_function() -> crate::engine::FunctionDefinition {
    let mut definition = primitive_function(
        PROTOCOL_GUIDE_FUNCTION,
        WORKER_WORKER_ID,
        "return the model-readable /engine/workers authoring and registration guide",
        EffectClass::PureRead,
        "worker.read",
    )
    .with_request_schema(protocol_guide_schema())
    .with_response_schema(json!({
        "type": "object",
        "required": [
            "protocolVersion",
            "endpoint",
            "environment",
            "messageFlow",
            "functionDefinitionShape",
            "pythonTemplate",
            "spawnWorkerPayloadExample",
            "rules"
        ],
        "additionalProperties": false,
        "properties": {
            "protocolVersion": {"type": "integer"},
            "endpoint": {"type": "string"},
            "environment": {"type": "object"},
            "messageFlow": {"type": "array"},
            "functionDefinitionShape": {"type": "object"},
            "pythonTemplate": {"type": "string"},
            "spawnWorkerPayloadExample": {"type": "object"},
            "rules": {"type": "array", "items": {"type": "string"}}
        }
    }))
    .with_tags(vec![
        "worker".to_owned(),
        "workers".to_owned(),
        "protocol".to_owned(),
        "register".to_owned(),
        "registration".to_owned(),
        "capability".to_owned(),
        "capabilities".to_owned(),
        "sandbox".to_owned(),
        "spawn".to_owned(),
    ]);
    definition.metadata = json!({
        "agentGuidance": [
            "Use worker::protocol_guide before authoring a sandbox-created worker.",
            "Write a local worker script from the returned template, then invoke worker::spawn with command, args, workerId, expectedFunctionIds, visibility, and idempotencyKey.",
            "Do not search Tron source or probe HTTP paths to learn the worker protocol."
        ],
        "relatedCapabilities": [
            "worker::spawn",
            "sandbox::list_spawned_workers",
            "sandbox::stop_spawned_worker",
            "catalog::list",
            "catalog::watch_snapshot",
            "observability::trace_get"
        ]
    });
    definition
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

fn protocol_guide_schema() -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "language": {
                "type": "string",
                "enum": ["python", "Python", "python3", "node", "Node", "nodejs", "node.js", "javascript", "JavaScript", "typescript", "TypeScript", "js", "ts"],
                "description": "Requested template language. The current executable worker template is Python; JavaScript/TypeScript aliases are accepted so agents receive the current template instead of source-searching after a schema rejection."
            },
            "functionId": {
                "type": "string",
                "description": "Optional function id to include in examples, for example demo::echo."
            },
            "workerId": {
                "type": "string",
                "description": "Optional worker id to include in examples."
            }
        }
    })
}
