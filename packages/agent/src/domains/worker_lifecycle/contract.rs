use serde_json::{Value, json};

use crate::domains::registration::catalog::CapabilitySpec;
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    ResourceLeaseRequirement, RiskLevel,
};

use super::{
    APPLY_SCOPE, DISABLE_FUNCTION, ENABLE_FUNCTION, INSTALL_FUNCTION, LAUNCH_FUNCTION,
    PROPOSE_FUNCTION, PROPOSE_SCOPE, RETIRE_FUNCTION, STOP_FUNCTION, WORKER,
    WORKER_LIFECYCLE_TOPIC,
};

/// Canonical lifecycle capability contracts.
pub(super) fn capabilities() -> crate::engine::Result<Vec<CapabilitySpec>> {
    let lifecycle_compensation = || {
        CompensationContract::new(
            CompensationKind::EventSourced,
            "worker lifecycle changes are append-only resources and stream events with rollback records",
        )
    };
    let lifecycle_lease =
        || ResourceLeaseRequirement::exclusive_template(WORKER, "worker_lifecycle:package", 60000);
    let lifecycle_response = json!({
        "type": "object",
        "required": ["status"],
        "additionalProperties": true,
        "properties": {
            "status": {"type": "string"},
            "packageResourceId": {"type": "string"},
            "installationResourceId": {"type": "string"},
            "proposalResourceId": {"type": "string"},
            "launchAttemptResourceId": {"type": "string"},
            "conformanceReportResourceId": {"type": "string"},
            "streamCursor": {"type": "integer"},
            "workerToken": {"type": "object"}
        }
    });
    Ok(vec![
        CapabilityContract::new(
            PROPOSE_FUNCTION,
            WORKER,
            EffectClass::AppendOnlyEvent,
            RiskLevel::Medium,
            Some(PROPOSE_SCOPE),
        )
        .request_schema(json!({
            "type": "object",
            "required": ["manifest", "summary"],
            "additionalProperties": false,
            "properties": {
                "manifest": {"type": "object"},
                "summary": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }))
        .response_schema(lifecycle_response.clone())
        .idempotency(IdempotencyContract::caller_system_engine_ledger())
        .resource_lease(lifecycle_lease())
        .compensation(lifecycle_compensation())
        .stream_topics(vec![WORKER_LIFECYCLE_TOPIC])
        .build()?,
        CapabilityContract::new(
            INSTALL_FUNCTION,
            WORKER,
            EffectClass::IdempotentWrite,
            RiskLevel::High,
            Some(APPLY_SCOPE),
        )
        .request_schema(json!({
            "type": "object",
            "required": ["manifest"],
            "additionalProperties": false,
            "properties": {
                "manifest": {"type": "object"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }))
        .response_schema(lifecycle_response.clone())
        .idempotency(IdempotencyContract::caller_system_engine_ledger())
        .resource_lease(lifecycle_lease())
        .compensation(lifecycle_compensation())
        .stream_topics(vec![WORKER_LIFECYCLE_TOPIC])
        .build()?,
        CapabilityContract::new(
            ENABLE_FUNCTION,
            WORKER,
            EffectClass::IdempotentWrite,
            RiskLevel::High,
            Some(APPLY_SCOPE),
        )
        .request_schema(package_ref_schema())
        .response_schema(lifecycle_response.clone())
        .idempotency(IdempotencyContract::caller_system_engine_ledger())
        .resource_lease(lifecycle_lease())
        .compensation(lifecycle_compensation())
        .stream_topics(vec![WORKER_LIFECYCLE_TOPIC])
        .build()?,
        CapabilityContract::new(
            DISABLE_FUNCTION,
            WORKER,
            EffectClass::IdempotentWrite,
            RiskLevel::High,
            Some(APPLY_SCOPE),
        )
        .request_schema(package_ref_schema())
        .response_schema(lifecycle_response.clone())
        .idempotency(IdempotencyContract::caller_system_engine_ledger())
        .resource_lease(lifecycle_lease())
        .compensation(lifecycle_compensation())
        .stream_topics(vec![WORKER_LIFECYCLE_TOPIC])
        .build()?,
        CapabilityContract::new(
            LAUNCH_FUNCTION,
            WORKER,
            EffectClass::ExternalSideEffect,
            RiskLevel::Critical,
            Some(APPLY_SCOPE),
        )
        .request_schema(package_ref_schema())
        .response_schema(lifecycle_response.clone())
        .idempotency(IdempotencyContract::caller_system_engine_ledger())
        .resource_lease(lifecycle_lease())
        .compensation(CompensationContract::new(
            CompensationKind::InverseCommandAvailable,
            "worker_lifecycle::stop_worker records the inverse stop path for launched local workers",
        ))
        .stream_topics(vec![WORKER_LIFECYCLE_TOPIC])
        .build()?,
        CapabilityContract::new(
            STOP_FUNCTION,
            WORKER,
            EffectClass::ReversibleSideEffect,
            RiskLevel::High,
            Some(APPLY_SCOPE),
        )
        .request_schema(json!({
            "type": "object",
            "required": ["launchAttemptResourceId"],
            "additionalProperties": false,
            "properties": {
                "launchAttemptResourceId": {"type": "string"},
                "reason": {"type": "string"},
                "sessionId": {"type": "string"},
                "workspaceId": {"type": "string"}
            }
        }))
        .response_schema(lifecycle_response.clone())
        .idempotency(IdempotencyContract::caller_system_engine_ledger())
        .resource_lease(lifecycle_lease())
        .compensation(lifecycle_compensation())
        .stream_topics(vec![WORKER_LIFECYCLE_TOPIC])
        .build()?,
        CapabilityContract::new(
            RETIRE_FUNCTION,
            WORKER,
            EffectClass::IdempotentWrite,
            RiskLevel::High,
            Some(APPLY_SCOPE),
        )
        .request_schema(package_ref_schema())
        .response_schema(lifecycle_response)
        .idempotency(IdempotencyContract::caller_system_engine_ledger())
        .resource_lease(lifecycle_lease())
        .compensation(lifecycle_compensation())
        .stream_topics(vec![WORKER_LIFECYCLE_TOPIC])
        .build()?,
    ])
}

fn package_ref_schema() -> Value {
    json!({
        "type": "object",
        "required": ["packageId", "packageVersion"],
        "additionalProperties": false,
        "properties": {
            "packageId": {"type": "string"},
            "packageVersion": {"type": "string"},
            "reason": {"type": "string"},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"}
        }
    })
}
