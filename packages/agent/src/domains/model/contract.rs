//! Capability contracts owned by the model domain worker.

use serde_json::json;

use crate::domains::registration::catalog::CapabilitySpec;
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    ResourceLeaseRequirement, Result as EngineResult, RiskLevel,
};

pub(crate) const STREAM_TOPICS: &[&str] = &["model.config"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("model::list", "model", EffectClass::PureRead, RiskLevel::Low, Some("model.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"__capabilityContext":{"additionalProperties":false,"properties":{"authPath":{"type":"string"}},"type":"object"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"models":{"items":{"additionalProperties":true,"type":"object"},"type":"array"}},"required":["models"],"type":"object"}))
            .build()?,
        CapabilityContract::new("model::switch", "model", EffectClass::ReversibleSideEffect, RiskLevel::High, Some("model.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"model":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","model"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"newModel":{"type":"string"},"previousModel":{"type":"string"}},"required":["previousModel","newModel"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .resource_lease(ResourceLeaseRequirement::exclusive_template("session", "session:{sessionId}:model", 60000))
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "latest_model is updated in the primitive session row; reversal is an explicit model switch"))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?
    ])
}
