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
        CapabilityContract::new("spawn_worker", "sandbox", EffectClass::ExternalSideEffect, RiskLevel::High, Some("worker.write"))
            .function_id("worker::spawn")
            .request_schema(json!({
                "additionalProperties": false,
                "properties": {
                    "workerId": {"type": "string"},
                    "grantId": {"type": "string"},
                    "command": {"type": "string"},
                    "args": {"type": "array", "items": {"type": "string"}, "maxItems": 64},
                    "workingDirectory": {"type": "string"},
                    "expectedFunctionIds": {"type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": 128},
                    "allowedAuthorityScopes": {"type": "array", "items": {"type": "string"}},
                    "allowedResourceKinds": {"type": "array", "items": {"type": "string"}},
                    "resourceSelectors": {"type": "array", "items": {"type": "string"}},
                    "fileRoots": {"type": "array", "items": {"type": "string"}},
                    "networkPolicy": {"type": "string", "enum": ["none", "loopback", "declared", "unrestricted"]},
                    "maxRisk": {"type": "string", "enum": ["low", "medium", "high", "critical"]},
                    "budget": {"type": "object"},
                    "approvalRequired": {"type": "boolean"},
                    "timeoutMs": {"type": "integer", "minimum": 100, "maximum": 60000},
                    "visibility": {"type": "string", "enum": ["session", "workspace", "system"]},
                    "sessionId": {"type": "string"},
                    "workspaceId": {"type": "string"}
                },
                "required": ["workerId", "command", "expectedFunctionIds"],
                "type": "object"
            }))
            .response_schema(json!({
                "additionalProperties": false,
                "properties": {
                    "workerId": {"type": "string"},
                    "authorityGrantId": {"type": "string"},
                    "authorityGrantRevision": {"type": "integer"},
                    "processId": {"type": ["integer", "null"]},
                    "registeredFunctionIds": {"type": "array", "items": {"type": "string"}},
                    "catalogRevision": {"type": "integer"},
                    "visibility": {"type": "string"},
                    "workerEndpoint": {"type": "string"},
                    "streamTopic": {"type": "string"}
                },
                "required": ["workerId", "authorityGrantId", "authorityGrantRevision", "registeredFunctionIds", "catalogRevision", "visibility", "workerEndpoint", "streamTopic"],
                "type": "object"
            }))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .resource_lease(ResourceLeaseRequirement::exclusive_template("sandbox-worker", "worker:{workerId}", 300000))
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "if worker launch fails the spawned process is killed and partial volatile catalog entries are unregistered; successful workers can be disconnected with worker::disconnect"))
            .high_risk_contract(json!({"sandboxAutonomy":{"withoutUserApproval":true,"requiresIdempotency":true,"requiresLease":true,"requiresCompensation":true,"visibilityDefault":"session","reason":"sandbox-created workers run under scoped worker identity and are audited by engine ledger, stream, lease, and cleanup records"},"resourceLock":{"idTemplate":"worker:{workerId}","kind":"sandbox-worker","reason":"serializes lifecycle operations for one sandbox-created worker","required":true,"ttlMs":300000},"rollbackOrCompensation":"failed launches kill the process and unregister partial volatile catalog entries; successful workers can be disconnected with worker::disconnect","streamTopics": STREAM_TOPICS,"version":1}))
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
            .request_schema(json!({"additionalProperties":false,"properties":{"workerId":{"type":"string"},"reason":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["workerId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"worker":{"type":"object"},"catalogRevision":{"type":"integer"},"stopped":{"type":"boolean"},"streamTopic":{"type":"string"}},"required":["worker","catalogRevision","stopped","streamTopic"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .resource_lease(ResourceLeaseRequirement::exclusive_template("sandbox-worker", "worker:{workerId}", 300000))
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "stop kills the sandbox-created process and unregisters volatile catalog entries through worker::disconnect; manual cleanup may be required if the process cannot be signaled"))
            .high_risk_contract(json!({"sandboxAutonomy":{"withoutUserApproval":true,"requiresIdempotency":true,"requiresLease":true,"requiresCompensation":true,"visibilityDefault":"session","reason":"sandbox-created worker stop is scoped to one worker id and audited by engine ledger, stream, lease, and cleanup records"},"resourceLock":{"idTemplate":"worker:{workerId}","kind":"sandbox-worker","reason":"serializes lifecycle operations for one sandbox-created worker","required":true,"ttlMs":300000},"rollbackOrCompensation":"manual process cleanup may be required if the worker process cannot be signaled","streamTopics": STREAM_TOPICS,"version":1}))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?
    ])
}
