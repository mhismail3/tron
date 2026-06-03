//! Capability contracts owned by the sandbox domain worker.

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
                    "resourceSelectors": {"type": "array", "items": {"type": "string"}, "description": "Optional child grant resource selectors. When workspaceAutonomyGrantId and workspaceId are supplied, omission defaults to workspace:<workspaceId>; otherwise omission defaults to *."},
                    "fileRoots": {"type": "array", "items": {"type": "string"}},
                    "workspaceAutonomyGrantId": {"type": "string"},
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
                    "authorityGrantParentId": {"type": "string"},
                    "processId": {"type": ["integer", "null"]},
                    "registeredFunctionIds": {"type": "array", "items": {"type": "string"}},
                    "catalogRevision": {"type": "integer"},
                    "visibility": {"type": "string"},
                    "workerEndpoint": {"type": "string"},
                    "streamTopic": {"type": "string"}
                },
                "required": ["workerId", "authorityGrantId", "authorityGrantRevision", "authorityGrantParentId", "registeredFunctionIds", "catalogRevision", "visibility", "workerEndpoint", "streamTopic"],
                "type": "object"
            }))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .resource_lease(ResourceLeaseRequirement::exclusive_template("sandbox-worker", "worker:{workerId}", 300000))
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "if worker launch fails the spawned process is killed and partial volatile catalog entries are unregistered; successful sandbox workers are stopped with sandbox::stop_spawned_worker"))
            .high_risk_contract(json!({"sandboxAutonomy":{"withoutUserApproval":true,"requiresIdempotency":true,"requiresLease":true,"requiresCompensation":true,"visibilityDefault":"session","workspaceAutonomyResourceSelectorDefault":"workspace:<workspaceId>","reason":"sandbox-created workers run under scoped worker identity and are audited by engine ledger, stream, lease, and cleanup records"},"resourceLock":{"idTemplate":"worker:{workerId}","kind":"sandbox-worker","reason":"serializes lifecycle operations for one sandbox-created worker","required":true,"ttlMs":300000},"rollbackOrCompensation":"failed launches kill the process and unregister partial volatile catalog entries; successful sandbox workers are stopped with sandbox::stop_spawned_worker","streamTopics": STREAM_TOPICS,"version":1}))
            .presentation_hints(json!({
                "displayName": "Create helper capability",
                "chipTitle": "Creating helper capability",
                "summary": "Local capability work",
                "generatingLabel": "Preparing helper capability",
                "runningLabel": "Creating helper capability",
                "approvalLabel": "Needs approval",
                "successLabel": "Capability added",
                "failureLabel": "Repair needed",
                "icon": "puzzlepiece.extension",
                "themeColor": "#A97BFF"
            }))
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
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "stop kills the sandbox-created process, unregisters volatile catalog entries through worker::disconnect, and leaves non-volatile registrations for the external worker manager to mark disconnected; manual cleanup may be required if the process cannot be signaled"))
            .high_risk_contract(json!({"sandboxAutonomy":{"withoutUserApproval":true,"requiresIdempotency":true,"requiresLease":true,"requiresCompensation":true,"visibilityDefault":"session","reason":"sandbox-created worker stop is scoped to one worker id and audited by engine ledger, stream, lease, and cleanup records"},"resourceLock":{"idTemplate":"worker:{workerId}","kind":"sandbox-worker","reason":"serializes lifecycle operations for one sandbox-created worker","required":true,"ttlMs":300000},"rollbackOrCompensation":"manual process cleanup may be required if the worker process cannot be signaled","streamTopics": STREAM_TOPICS,"version":1}))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn worker_spawn_has_plain_self_extension_presentation_hints() {
        let specs = capabilities().expect("sandbox capabilities build");
        let spawn = specs
            .iter()
            .find(|spec| spec.function_id.as_str() == "worker::spawn")
            .expect("worker::spawn spec exists");
        let hints = spawn
            .presentation_hints
            .as_ref()
            .and_then(serde_json::Value::as_object)
            .expect("worker::spawn presentation hints are object");

        assert_eq!(hints["displayName"], "Create helper capability");
        assert_eq!(hints["chipTitle"], "Creating helper capability");
        assert_eq!(hints["summary"], "Local capability work");
        assert_eq!(hints["runningLabel"], "Creating helper capability");
        assert_eq!(hints["successLabel"], "Capability added");
        assert_eq!(hints["failureLabel"], "Repair needed");
        assert!(
            !serde_json::to_string(hints)
                .expect("hints serialize")
                .contains("worker::spawn"),
            "main presentation hints must stay product-facing"
        );
    }
}
