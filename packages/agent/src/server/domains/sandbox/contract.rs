//! Capability contracts owned by the sandbox domain worker.

#[allow(unused_imports)]
use serde_json::json;

use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    ResourceLeaseRequirement, Result as EngineResult, RiskLevel,
};
use crate::server::domains::catalog::CapabilitySpec;
use crate::server::domains::contract::CapabilityContract;

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("sandbox::list_containers", "sandbox", EffectClass::PureRead, RiskLevel::Low, Some("sandbox.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?,
        CapabilityContract::new("sandbox::start_container", "sandbox", EffectClass::ExternalSideEffect, RiskLevel::High, Some("sandbox.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"name":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["name"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"success":{"type":"boolean"}},"required":["success"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .resource_lease(ResourceLeaseRequirement::exclusive_template("sandbox", "container:{name}", 300000))
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "inverse container lifecycle command can be run manually if the runtime is still available"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"container:{name}","kind":"sandbox","reason":"serializes lifecycle operations for one local sandbox container","required":true,"ttlMs":300000},"rollbackOrCompensation":"inverse container lifecycle command can be run manually if the runtime is still available","streamTopics":["resource.leases","catalog.changes"],"version":1}))
            .stream_topics(vec!["resource.leases", "catalog.changes"])
            .build()?,
        CapabilityContract::new("sandbox::stop_container", "sandbox", EffectClass::ExternalSideEffect, RiskLevel::High, Some("sandbox.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"name":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["name"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"success":{"type":"boolean"}},"required":["success"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .resource_lease(ResourceLeaseRequirement::exclusive_template("sandbox", "container:{name}", 300000))
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "inverse container lifecycle command can be run manually if the runtime is still available"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"container:{name}","kind":"sandbox","reason":"serializes lifecycle operations for one local sandbox container","required":true,"ttlMs":300000},"rollbackOrCompensation":"inverse container lifecycle command can be run manually if the runtime is still available","streamTopics":["resource.leases","catalog.changes"],"version":1}))
            .stream_topics(vec!["resource.leases", "catalog.changes"])
            .build()?,
        CapabilityContract::new("sandbox::kill_container", "sandbox", EffectClass::IrreversibleSideEffect, RiskLevel::High, Some("sandbox.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"name":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["name"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"success":{"type":"boolean"}},"required":["success"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .resource_lease(ResourceLeaseRequirement::exclusive_template("sandbox", "container:{name}", 300000))
            .compensation(CompensationContract::new(CompensationKind::ExternalIrreversible, "sandbox kill/remove is external and may require manual container recreation"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"container:{name}","kind":"sandbox","reason":"serializes lifecycle operations for one local sandbox container","required":true,"ttlMs":300000},"rollbackOrCompensation":"sandbox kill/remove is external and may require manual container recreation","streamTopics":["resource.leases","catalog.changes"],"version":1}))
            .stream_topics(vec!["resource.leases", "catalog.changes"])
            .build()?,
        CapabilityContract::new("sandbox::remove_container", "sandbox", EffectClass::IrreversibleSideEffect, RiskLevel::High, Some("sandbox.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"name":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["name"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"success":{"type":"boolean"}},"required":["success"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .resource_lease(ResourceLeaseRequirement::exclusive_template("sandbox", "container:{name}", 300000))
            .compensation(CompensationContract::new(CompensationKind::ExternalIrreversible, "sandbox kill/remove is external and may require manual container recreation"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"container:{name}","kind":"sandbox","reason":"serializes lifecycle operations for one local sandbox container","required":true,"ttlMs":300000},"rollbackOrCompensation":"sandbox kill/remove is external and may require manual container recreation","streamTopics":["resource.leases","catalog.changes"],"version":1}))
            .stream_topics(vec!["resource.leases", "catalog.changes"])
            .build()?
    ])
}
