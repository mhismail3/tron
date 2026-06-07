//! Capability contracts owned by the model domain worker.

use serde_json::json;

use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
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
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "previousModel is returned and persisted in config.model_switch for manual reversal"))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("config::set_reasoning_level", "config", EffectClass::ReversibleSideEffect, RiskLevel::High, Some("config.write"))
            .domain_module("model")
            .request_schema(json!({"additionalProperties":false,"properties":{"level":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","level"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"changed":{"type":"boolean"},"newLevel":{"type":"string"},"previousLevel":{"type":["string","null"]}},"required":["previousLevel","newLevel","changed"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .resource_lease(ResourceLeaseRequirement::exclusive_template("session", "session:{sessionId}:reasoning", 60000))
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "previousLevel is returned and persisted in config.reasoning_level for manual reversal"))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?
    ])
}
