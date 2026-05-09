//! Capability contracts owned by the logs domain worker.

#[allow(unused_imports)]
use serde_json::json;

use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    Result as EngineResult, RiskLevel,
};

pub(crate) const STREAM_TOPICS: &[&str] = &["logs.ingest"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("logs::ingest", "logs", EffectClass::AppendOnlyEvent, RiskLevel::Medium, Some("logs.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"entries":{"items":{"additionalProperties":false,"properties":{"category":{"type":"string"},"level":{"type":"string"},"message":{"type":"string"},"timestamp":{"type":"string"}},"required":["timestamp","level","category","message"],"type":"object"},"maxItems":10000,"type":"array"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["entries"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"inserted":{"type":"integer"},"success":{"type":"boolean"}},"required":["success","inserted"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::EventSourced, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("logs::recent", "logs", EffectClass::PureRead, RiskLevel::Low, Some("logs.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"limit":{"type":"integer"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"count":{"type":"integer"},"entries":{"items":{"additionalProperties":true,"type":"object"},"type":"array"}},"required":["entries","count"],"type":"object"}))
            .build()?
    ])
}
