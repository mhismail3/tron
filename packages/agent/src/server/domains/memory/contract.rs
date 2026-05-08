//! Capability contracts owned by the memory domain worker.

#[allow(unused_imports)]
use serde_json::json;

use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    ResourceLeaseRequirement, Result as EngineResult, RiskLevel, VisibilityScope,
};
use crate::server::domains::catalog::CapabilitySpec;
use crate::server::domains::contract::CapabilityContract;

pub(crate) const STREAM_TOPICS: &[&str] = &["memory.retain"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("memory::auto_retain_fire", "memory", EffectClass::ExternalSideEffect, RiskLevel::High, Some("memory.write"))
            .visibility(VisibilityScope::Internal)
            .request_schema(json!({"additionalProperties":false,"properties":{"runId":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":["string","null"]}},"required":["sessionId","runId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"fired":{"type":"boolean"},"reason":{"type":["string","null"]}},"required":["fired"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "auto-retain only schedules the memory retain pipeline after a successful agent run; retain guard/idempotency prevent duplicate retention"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":false,"resourceLock":{"idTemplate":"session:{sessionId}:memory-retain","kind":"session","reason":"serializes auto-retain scheduling through the memory domain retain guard","required":false,"ttlMs":300000},"rollbackOrCompensation":"auto-retain only schedules the memory retain pipeline after a successful agent run; retain guard/idempotency prevent duplicate retention","streamTopics": STREAM_TOPICS,"version":1}))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("memory::retain", "memory", EffectClass::ExternalSideEffect, RiskLevel::High, Some("memory.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"reason":{"type":"string"},"retained":{"type":"boolean"},"status":{"type":"string"}},"required":["retained"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .resource_lease(ResourceLeaseRequirement::exclusive_template("session", "session:{sessionId}:memory-retain", 300000))
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "background retain writes a memory.retained boundary; failures emit memory update completion without duplicate retention"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"session:{sessionId}:memory-retain","kind":"session","reason":"serializes retain startup before the existing background retain guard owns the long-running summarizer","required":true,"ttlMs":300000},"rollbackOrCompensation":"background retain writes a memory.retained boundary; failures emit memory update completion without duplicate retention","streamTopics": STREAM_TOPICS,"version":1}))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?
    ])
}
