//! Capability contracts owned by the display domain worker.

#[allow(unused_imports)]
use serde_json::json;

use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    ResourceLeaseRequirement, Result as EngineResult, RiskLevel,
};

pub(crate) const STREAM_TOPICS: &[&str] = &["display.stream"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("display::stop_stream", "display", EffectClass::ExternalSideEffect, RiskLevel::Medium, Some("display.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"streamId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["streamId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"stopped":{"type":"boolean"},"streamId":{"type":"string"}},"required":["streamId","stopped"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .resource_lease(ResourceLeaseRequirement::exclusive_template("display", "display:{streamId}", 60000))
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?
    ])
}
