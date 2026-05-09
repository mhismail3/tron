//! Capability contracts owned by the message domain worker.

#[allow(unused_imports)]
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
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"reason":{"type":"string"},"sessionId":{"type":"string"},"targetEventId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","targetEventId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"deletionEventId":{"type":"string"},"success":{"type":"boolean"},"targetType":{"type":"string"}},"required":["success","deletionEventId","targetType"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::ExternalIrreversible, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"not-required","kind":"documented-by-domain","reason":"existing domain guardrails own serialization; this metadata prevents high-risk generic triggers from omitting an explicit safety contract","required":false,"ttlMs":0},"rollbackOrCompensation":"domain-specific tests preserve current rollback, no-op, or replay behavior","streamTopics": STREAM_TOPICS,"version":1}))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?
    ])
}
