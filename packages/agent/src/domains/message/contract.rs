//! Capability contracts owned by the message domain worker.

use serde_json::json;

use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    Result as EngineResult, RiskLevel,
};

pub(crate) const STREAM_TOPICS: &[&str] = &["message.events"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("message::delete", "message", EffectClass::IrreversibleSideEffect, RiskLevel::High, Some("message.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"reason":{"type":"string"},"sessionId":{"type":"string"},"targetEventId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","targetEventId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"deletionEventId":{"type":"string"},"success":{"type":"boolean"},"targetType":{"type":"string"}},"required":["success","deletionEventId","targetType"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::ExternalIrreversible, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?
    ])
}
