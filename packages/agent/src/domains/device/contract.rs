//! Capability contracts owned by the device domain worker.

#[allow(unused_imports)]
use serde_json::json;

use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    ResourceLeaseRequirement, Result as EngineResult, RiskLevel,
};

pub(crate) const STREAM_TOPICS: &[&str] = &["device.events"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("device::register", "device", EffectClass::ExternalSideEffect, RiskLevel::Medium, Some("device.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"bundleId":{"type":"string"},"deviceToken":{"type":"string"},"environment":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["deviceToken","bundleId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"created":{"type":"boolean"},"id":{"type":"string"}},"required":["id","created"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .resource_lease(ResourceLeaseRequirement::exclusive_template("device", "device:{deviceToken}", 60000))
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("device::unregister", "device", EffectClass::ExternalSideEffect, RiskLevel::Medium, Some("device.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"deviceToken":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["deviceToken"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"success":{"type":"boolean"}},"required":["success"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .resource_lease(ResourceLeaseRequirement::exclusive_template("device", "device:{deviceToken}", 60000))
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("device::respond", "device", EffectClass::ExternalSideEffect, RiskLevel::Medium, Some("device.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"requestId":{"type":"string"},"result":{},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["requestId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"resolved":{"type":"boolean"}},"required":["resolved"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .resource_lease(ResourceLeaseRequirement::exclusive_template("device", "device-request:{requestId}", 60000))
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?
    ])
}
