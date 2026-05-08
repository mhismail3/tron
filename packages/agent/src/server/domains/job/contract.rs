//! Capability contracts owned by the job domain worker.

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
        CapabilityContract::new("job::background", "job", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("job.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"jobId":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["jobId","sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"backgrounded":{"type":"boolean"},"jobId":{"type":"string"}},"required":["jobId","backgrounded"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("job::cancel", "job", EffectClass::IdempotentWrite, RiskLevel::High, Some("job.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"jobId":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["jobId","sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"cancelled":{"type":"boolean"},"jobId":{"type":"string"}},"required":["jobId","cancelled"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"not-required","kind":"documented-by-domain","reason":"existing domain guardrails own serialization; this metadata prevents high-risk generic triggers from omitting an explicit safety contract","required":false,"ttlMs":0},"rollbackOrCompensation":"domain-specific tests preserve current rollback, no-op, or replay behavior","streamTopics":["resource.leases","catalog.changes"],"version":1}))
            .stream_topics(vec!["resource.leases", "catalog.changes"])
            .build()?,
        CapabilityContract::new("job::list", "job", EffectClass::PureRead, RiskLevel::Low, Some("job.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"jobs":{"type":"array"}},"required":["jobs"],"type":"object"}))
            .build()?,
        CapabilityContract::new("job::subscribe", "job", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("job.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"jobId":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["jobId","sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"jobId":{"type":"string"},"subscribed":{"type":"boolean"}},"required":["subscribed","jobId"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("job::unsubscribe", "job", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("job.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"jobId":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["jobId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"jobId":{"type":"string"},"unsubscribed":{"type":"boolean"}},"required":["jobId","unsubscribed"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?
    ])
}
