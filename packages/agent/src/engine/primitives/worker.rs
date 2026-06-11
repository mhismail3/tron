//! Worker primitive contracts.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};

use super::worker_activation::issue_activation_schema;
use super::{
    PrimitiveFunctionRegistration, PrimitiveStores, WORKER_WORKER_ID, handled_registration,
    host_dispatched_registration, primitive_compensation, primitive_function,
};
use crate::engine::runtime::worker_orchestration::EngineWorkerOrchestrationRuntime;
use crate::engine::{
    AuthorityRequirement, CompensationKind, EffectClass, EngineError, IdempotencyContract,
    InProcessFunctionHandler, Invocation, Result, RiskLevel, VisibilityScope,
};

pub(in crate::engine::primitives) use super::worker_activation::issue_activation;

pub(crate) const LIST_FUNCTION: &str = "worker::list";
pub(crate) const GET_FUNCTION: &str = "worker::get";
pub(crate) const DISCONNECT_FUNCTION: &str = "worker::disconnect";
pub(crate) const HEALTH_FUNCTION: &str = "worker::health";
pub(crate) const ISSUE_ACTIVATION_FUNCTION: &str = "worker::issue_activation";
pub(crate) const LAUNCH_ACTIVATION_FUNCTION: &str = "worker::launch_activation";
pub(crate) const LAUNCH_FROM_TRIGGER_FUNCTION: &str = "worker::launch_from_trigger";
pub(crate) const STOP_PROCESS_FUNCTION: &str = "worker::stop_process";

pub(super) fn registrations(
    stores: &PrimitiveStores,
) -> Result<Vec<PrimitiveFunctionRegistration>> {
    let orchestration_handler = Arc::new(WorkerOrchestrationPrimitiveHandler {
        stores: stores.clone(),
    });
    let mut issue_activation = primitive_function(
        ISSUE_ACTIVATION_FUNCTION,
        WORKER_WORKER_ID,
        "issue a governed loopback worker activation bundle",
        EffectClass::IdempotentWrite,
        "worker.activate",
    )
    .with_idempotency(IdempotencyContract::caller_system_engine_ledger())
    .with_required_authority(AuthorityRequirement::scope("worker.activate"))
    .with_risk(RiskLevel::High)
    .with_compensation(primitive_compensation(
        CompensationKind::ManualOnly,
        "worker activation issues a scoped expiring grant and auditable activation resource; revocation is performed by revoking the derived grant and resource lifecycle",
    ))
    .with_request_schema(issue_activation_schema())
    .with_response_schema(json!({
        "type": "object",
        "required": ["activationResourceId", "workerId", "expiresAt", "activationBundle"],
        "additionalProperties": false,
        "properties": {
            "activationResourceId": {"type": "string"},
            "workerId": {"type": "string"},
            "expiresAt": {"type": "string"},
            "activationBundle": {
                "type": "object",
                "required": ["workerHello", "scopedWorkerToken", "expectedFunctionDefinition"],
                "additionalProperties": false,
                "properties": {
                    "workerHello": {"type": "object"},
                    "scopedWorkerToken": {"type": "object"},
                    "expectedFunctionDefinition": {"type": "object"}
                }
            }
        }
    }));
    issue_activation.visibility = VisibilityScope::Admin;

    let mut launch_activation = primitive_function(
        LAUNCH_ACTIVATION_FUNCTION,
        WORKER_WORKER_ID,
        "launch a reviewed local process for an issued worker activation",
        EffectClass::IdempotentWrite,
        "worker.launch",
    )
    .with_idempotency(IdempotencyContract::caller_system_engine_ledger())
    .with_required_authority(AuthorityRequirement::scope("worker.launch"))
    .with_risk(RiskLevel::High)
    .with_compensation(primitive_compensation(
        CompensationKind::ManualOnly,
        "worker launch starts a local supervised process; stop_process terminates it and volatile readiness cleanup is enforced through the external-worker runtime",
    ))
    .with_request_schema(launch_activation_schema())
    .with_response_schema(json!({
        "type": "object",
        "required": [
            "workerProcessResourceId",
            "activationResourceId",
            "workerId",
            "functionId",
            "launchStatus",
            "processHandle",
            "expectedReadinessMarkers"
        ],
        "additionalProperties": false,
        "properties": {
            "workerProcessResourceId": {"type": "string"},
            "activationResourceId": {"type": "string"},
            "workerId": {"type": "string"},
            "functionId": {"type": "string"},
            "launchStatus": {"type": "string"},
            "processHandle": {"type": ["object", "null"]},
            "expectedReadinessMarkers": {"type": "array", "items": {"type": "string"}}
        }
    }));
    launch_activation.visibility = VisibilityScope::Admin;

    let mut launch_from_trigger = primitive_function(
        LAUNCH_FROM_TRIGGER_FUNCTION,
        WORKER_WORKER_ID,
        "launch a reviewed local worker process from trusted trigger causal context",
        EffectClass::IdempotentWrite,
        "worker.launch",
    )
    .with_idempotency(IdempotencyContract::caller_system_engine_ledger())
    .with_required_authority(AuthorityRequirement {
        scopes: vec!["worker.activate".to_owned(), "worker.launch".to_owned()],
    })
    .with_risk(RiskLevel::High)
    .with_compensation(primitive_compensation(
        CompensationKind::ManualOnly,
        "trigger launch issues a fresh activation and consumes it through the reviewed stdin launch path; duplicate trigger delivery replays the recorded attempt by idempotency key",
    ))
    .with_request_schema(launch_from_trigger_schema())
    .with_response_schema(json!({
        "type": "object",
        "required": [
            "triggerLaunchAttemptResourceId",
            "triggerId",
            "autostartPlanResourceId",
            "activationResourceId",
            "workerProcessResourceId",
            "status",
            "processState"
        ],
        "additionalProperties": true,
        "properties": {
            "triggerLaunchAttemptResourceId": {"type": "string"},
            "triggerId": {"type": "string"},
            "autostartPlanResourceId": {"type": "string"},
            "activationResourceId": {"type": ["string", "null"]},
            "workerProcessResourceId": {"type": ["string", "null"]},
            "status": {"type": "string"},
            "processState": {"type": "string"},
            "launch": {"type": "object"},
            "replayed": {"type": "boolean"}
        }
    }));
    launch_from_trigger.visibility = VisibilityScope::Admin;

    let mut stop_process = primitive_function(
        STOP_PROCESS_FUNCTION,
        WORKER_WORKER_ID,
        "stop an orchestrated local worker process",
        EffectClass::IdempotentWrite,
        "worker.launch",
    )
    .with_idempotency(IdempotencyContract::caller_system_engine_ledger())
    .with_required_authority(AuthorityRequirement::scope("worker.launch"))
    .with_risk(RiskLevel::High)
    .with_compensation(primitive_compensation(
        CompensationKind::ManualOnly,
        "worker stop is terminal for the process resource; relaunch requires a new idempotent launch request or process plan review",
    ))
    .with_request_schema(stop_process_schema())
    .with_response_schema(json!({
        "type": "object",
        "required": ["workerProcessResourceId", "status", "terminal"],
        "additionalProperties": false,
        "properties": {
            "workerProcessResourceId": {"type": "string"},
            "status": {"type": "string"},
            "terminal": {"type": "boolean"}
        }
    }));
    stop_process.visibility = VisibilityScope::Admin;

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
                "required": ["workers"],
                "additionalProperties": false,
                "properties": {
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
        host_dispatched_registration(issue_activation),
        handled_registration(launch_activation, orchestration_handler.clone()),
        handled_registration(launch_from_trigger, orchestration_handler.clone()),
        handled_registration(stop_process, orchestration_handler),
    ])
}

struct WorkerOrchestrationPrimitiveHandler {
    stores: PrimitiveStores,
}

#[async_trait]
impl InProcessFunctionHandler for WorkerOrchestrationPrimitiveHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value> {
        let host = self.stores.engine_host()?;
        let runtime = EngineWorkerOrchestrationRuntime::new(
            host,
            self.stores.worker_process_supervisors.clone(),
        );
        match invocation.function_id.as_str() {
            LAUNCH_ACTIVATION_FUNCTION => runtime.launch_activation(invocation).await,
            LAUNCH_FROM_TRIGGER_FUNCTION => runtime.launch_from_trigger(invocation).await,
            STOP_PROCESS_FUNCTION => runtime.stop_process(invocation).await,
            other => Err(EngineError::NotFound {
                kind: "function",
                id: other.to_owned(),
            }),
        }
    }
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

fn launch_activation_schema() -> Value {
    json!({
        "type": "object",
        "required": ["activationResourceId", "launchPlanResourceId", "idempotencyKey"],
        "additionalProperties": false,
        "properties": {
            "activationResourceId": {"type": "string", "minLength": 1},
            "launchPlanResourceId": {"type": "string", "minLength": 1},
            "startupTimeoutMs": {"type": "integer", "minimum": 1},
            "launchReason": {"type": "string"},
            "idempotencyKey": {"type": "string", "minLength": 1}
        }
    })
}

fn launch_from_trigger_schema() -> Value {
    json!({
        "type": "object",
        "required": ["autostartPlanResourceId"],
        "additionalProperties": false,
        "properties": {
            "autostartPlanResourceId": {"type": "string", "minLength": 1},
            "startupTimeoutMs": {"type": "integer", "minimum": 1},
            "launchReason": {"type": "string"}
        }
    })
}

fn stop_process_schema() -> Value {
    json!({
        "type": "object",
        "required": ["workerProcessResourceId", "idempotencyKey"],
        "additionalProperties": false,
        "properties": {
            "workerProcessResourceId": {"type": "string", "minLength": 1},
            "reason": {"type": "string"},
            "idempotencyKey": {"type": "string", "minLength": 1}
        }
    })
}
