//! Capability contracts owned by the model domain worker.

use serde_json::json;

use crate::domains::registration::catalog::CapabilitySpec;
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{EffectClass, IdempotencyContract, Result as EngineResult, RiskLevel};

pub(crate) const STREAM_TOPICS: &[&str] = &["model.config"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("model::list", "model", EffectClass::PureRead, RiskLevel::Low)
            .request_schema(json!({"additionalProperties":false,"properties":{"__capabilityContext":{"additionalProperties":false,"properties":{"authPath":{"type":"string"}},"type":"object"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"models":{"items":{"additionalProperties":true,"type":"object"},"type":"array"}},"required":["models"],"type":"object"}))
            .build()?,
        CapabilityContract::new("model::switch", "model", EffectClass::ReversibleSideEffect, RiskLevel::High)
            .request_schema(json!({"additionalProperties":false,"properties":{"model":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","model"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"newModel":{"type":"string"},"previousModel":{"type":"string"}},"required":["previousModel","newModel"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?
    ])
}
