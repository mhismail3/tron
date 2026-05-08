//! Capability contracts owned by the tools domain worker.

#[allow(unused_imports)]
use serde_json::json;

use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    Result as EngineResult, RiskLevel,
};
use crate::server::domains::catalog::CapabilitySpec;
use crate::server::domains::contract::CapabilityContract;

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("tool::result", "tool", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("tool.write"))
            .domain_module("tools")
            .request_schema(json!({"additionalProperties":false,"properties":{"result":{},"sessionId":{"type":"string"},"toolUseId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","toolUseId","result"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"success":{"type":"boolean"},"toolCallId":{"type":"string"}},"required":["success","toolCallId"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?
    ])
}
