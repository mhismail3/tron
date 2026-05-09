//! Capability contracts owned by the settings domain worker.

#[allow(unused_imports)]
use serde_json::json;

use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    Result as EngineResult, RiskLevel,
};

pub(crate) const STREAM_TOPICS: &[&str] = &["settings.changes"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("settings::get", "settings", EffectClass::PureRead, RiskLevel::Low, Some("settings.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{},"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?,
        CapabilityContract::new("settings::update", "settings", EffectClass::ReversibleSideEffect, RiskLevel::High, Some("settings.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"settings":{"additionalProperties":true,"type":"object"},"workspaceId":{"type":"string"}},"required":["settings"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"success":{"type":"boolean"}},"required":["success"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"not-required","kind":"documented-by-domain","reason":"existing domain guardrails own serialization; this metadata prevents high-risk generic triggers from omitting an explicit safety contract","required":false,"ttlMs":0},"rollbackOrCompensation":"domain-specific tests preserve current rollback, no-op, or replay behavior","streamTopics": STREAM_TOPICS,"version":1}))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("settings::reset_to_defaults", "settings", EffectClass::ReversibleSideEffect, RiskLevel::High, Some("settings.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":true,"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"not-required","kind":"documented-by-domain","reason":"existing domain guardrails own serialization; this metadata prevents high-risk generic triggers from omitting an explicit safety contract","required":false,"ttlMs":0},"rollbackOrCompensation":"domain-specific tests preserve current rollback, no-op, or replay behavior","streamTopics": STREAM_TOPICS,"version":1}))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?
    ])
}
