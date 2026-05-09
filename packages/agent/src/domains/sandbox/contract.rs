//! Capability contracts owned by the sandbox domain worker.

#[allow(unused_imports)]
use serde_json::json;

use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    ResourceLeaseRequirement, Result as EngineResult, RiskLevel,
};

pub(crate) const STREAM_TOPICS: &[&str] = &["sandbox.lifecycle"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("sandbox::list_containers", "sandbox", EffectClass::PureRead, RiskLevel::Low, Some("sandbox.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?,
        CapabilityContract::new("sandbox::spawn_worker", "sandbox", EffectClass::ExternalSideEffect, RiskLevel::High, Some("sandbox.write"))
            .approval_required(true)
            .request_schema(json!({
                "additionalProperties": false,
                "properties": {
                    "workerId": {"type": "string"},
                    "command": {"type": "string"},
                    "args": {"type": "array", "items": {"type": "string"}, "maxItems": 64},
                    "workingDirectory": {"type": "string"},
                    "expectedFunctionIds": {"type": "array", "items": {"type": "string"}, "maxItems": 128},
                    "timeoutMs": {"type": "integer", "minimum": 100, "maximum": 60000},
                    "visibility": {"type": "string", "enum": ["session", "workspace", "system"]},
                    "sessionId": {"type": "string"},
                    "workspaceId": {"type": "string"}
                },
                "required": ["workerId", "command"],
                "type": "object"
            }))
            .response_schema(json!({
                "additionalProperties": false,
                "properties": {
                    "workerId": {"type": "string"},
                    "processId": {"type": ["integer", "null"]},
                    "registeredFunctionIds": {"type": "array", "items": {"type": "string"}},
                    "catalogRevision": {"type": "integer"},
                    "visibility": {"type": "string"},
                    "workerEndpoint": {"type": "string"},
                    "streamTopic": {"type": "string"}
                },
                "required": ["workerId", "registeredFunctionIds", "catalogRevision", "visibility", "workerEndpoint", "streamTopic"],
                "type": "object"
            }))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .resource_lease(ResourceLeaseRequirement::exclusive_template("sandbox-worker", "worker:{workerId}", 300000))
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "if worker launch fails the spawned process is killed and partial volatile catalog entries are unregistered; successful workers can be disconnected with worker::disconnect"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"worker:{workerId}","kind":"sandbox-worker","reason":"serializes lifecycle operations for one sandbox-created worker","required":true,"ttlMs":300000},"rollbackOrCompensation":"failed launches kill the process and unregister partial volatile catalog entries; successful workers can be disconnected with worker::disconnect","streamTopics": STREAM_TOPICS,"version":1}))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("sandbox::list_spawned_workers", "sandbox", EffectClass::PureRead, RiskLevel::Low, Some("sandbox.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"workers":{"type":"array"}},"required":["workers"],"type":"object"}))
            .build()?,
        CapabilityContract::new("sandbox::get_spawned_worker", "sandbox", EffectClass::PureRead, RiskLevel::Low, Some("sandbox.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"workerId":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["workerId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"worker":{"type":["object","null"]}},"required":["worker"],"type":"object"}))
            .build()?,
        CapabilityContract::new("sandbox::stop_spawned_worker", "sandbox", EffectClass::ExternalSideEffect, RiskLevel::High, Some("sandbox.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"workerId":{"type":"string"},"reason":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["workerId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"worker":{"type":"object"},"catalogRevision":{"type":"integer"},"stopped":{"type":"boolean"},"streamTopic":{"type":"string"}},"required":["worker","catalogRevision","stopped","streamTopic"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .resource_lease(ResourceLeaseRequirement::exclusive_template("sandbox-worker", "worker:{workerId}", 300000))
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "stop kills the sandbox-created process and unregisters volatile catalog entries through worker::disconnect; manual cleanup may be required if the process cannot be signaled"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"worker:{workerId}","kind":"sandbox-worker","reason":"serializes lifecycle operations for one sandbox-created worker","required":true,"ttlMs":300000},"rollbackOrCompensation":"manual process cleanup may be required if the worker process cannot be signaled","streamTopics": STREAM_TOPICS,"version":1}))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("sandbox::start_container", "sandbox", EffectClass::ExternalSideEffect, RiskLevel::High, Some("sandbox.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"name":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["name"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"success":{"type":"boolean"}},"required":["success"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .resource_lease(ResourceLeaseRequirement::exclusive_template("sandbox", "container:{name}", 300000))
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "inverse container lifecycle command can be run manually if the runtime is still available"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"container:{name}","kind":"sandbox","reason":"serializes lifecycle operations for one local sandbox container","required":true,"ttlMs":300000},"rollbackOrCompensation":"inverse container lifecycle command can be run manually if the runtime is still available","streamTopics": STREAM_TOPICS,"version":1}))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("sandbox::stop_container", "sandbox", EffectClass::ExternalSideEffect, RiskLevel::High, Some("sandbox.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"name":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["name"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"success":{"type":"boolean"}},"required":["success"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .resource_lease(ResourceLeaseRequirement::exclusive_template("sandbox", "container:{name}", 300000))
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "inverse container lifecycle command can be run manually if the runtime is still available"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"container:{name}","kind":"sandbox","reason":"serializes lifecycle operations for one local sandbox container","required":true,"ttlMs":300000},"rollbackOrCompensation":"inverse container lifecycle command can be run manually if the runtime is still available","streamTopics": STREAM_TOPICS,"version":1}))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("sandbox::kill_container", "sandbox", EffectClass::IrreversibleSideEffect, RiskLevel::High, Some("sandbox.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"name":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["name"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"success":{"type":"boolean"}},"required":["success"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .resource_lease(ResourceLeaseRequirement::exclusive_template("sandbox", "container:{name}", 300000))
            .compensation(CompensationContract::new(CompensationKind::ExternalIrreversible, "sandbox kill/remove is external and may require manual container recreation"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"container:{name}","kind":"sandbox","reason":"serializes lifecycle operations for one local sandbox container","required":true,"ttlMs":300000},"rollbackOrCompensation":"sandbox kill/remove is external and may require manual container recreation","streamTopics": STREAM_TOPICS,"version":1}))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("sandbox::remove_container", "sandbox", EffectClass::IrreversibleSideEffect, RiskLevel::High, Some("sandbox.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"name":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["name"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"success":{"type":"boolean"}},"required":["success"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .resource_lease(ResourceLeaseRequirement::exclusive_template("sandbox", "container:{name}", 300000))
            .compensation(CompensationContract::new(CompensationKind::ExternalIrreversible, "sandbox kill/remove is external and may require manual container recreation"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"container:{name}","kind":"sandbox","reason":"serializes lifecycle operations for one local sandbox container","required":true,"ttlMs":300000},"rollbackOrCompensation":"sandbox kill/remove is external and may require manual container recreation","streamTopics": STREAM_TOPICS,"version":1}))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?
    ])
}
