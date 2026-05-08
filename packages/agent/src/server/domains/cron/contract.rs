//! Capability contracts owned by the cron domain worker.

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
        CapabilityContract::new("cron::list", "cron", EffectClass::PureRead, RiskLevel::Low, Some("cron.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"enabled":{"type":"boolean"},"sessionId":{"type":"string"},"tags":{"items":{"type":"string"},"type":"array"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?,
        CapabilityContract::new("cron::get", "cron", EffectClass::PureRead, RiskLevel::Low, Some("cron.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"jobId":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["jobId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?,
        CapabilityContract::new("cron::create", "cron", EffectClass::ReversibleSideEffect, RiskLevel::High, Some("cron.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"job":{"additionalProperties":true,"type":"object"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["job"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"not-required","kind":"documented-by-domain","reason":"existing domain guardrails own serialization; this metadata prevents high-risk generic triggers from omitting an explicit safety contract","required":false,"ttlMs":0},"rollbackOrCompensation":"domain-specific tests preserve current rollback, no-op, or replay behavior","streamTopics":["resource.leases","catalog.changes"],"version":1}))
            .stream_topics(vec!["resource.leases", "catalog.changes"])
            .build()?,
        CapabilityContract::new("cron::update", "cron", EffectClass::ReversibleSideEffect, RiskLevel::High, Some("cron.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"autoDisableAfter":{"type":"integer"},"delivery":{"items":{"additionalProperties":true,"type":"object"},"type":"array"},"description":{"type":["string","null"]},"enabled":{"type":"boolean"},"jobId":{"type":"string"},"maxRetries":{"type":"integer"},"misfirePolicy":{"type":"string"},"name":{"type":"string"},"overlapPolicy":{"type":"string"},"payload":{"additionalProperties":true,"type":"object"},"schedule":{"additionalProperties":true,"type":"object"},"sessionId":{"type":"string"},"stuckTimeoutSecs":{"type":"integer"},"tags":{"items":{"type":"string"},"type":"array"},"toolRestrictions":{"additionalProperties":true,"type":["object","null"]},"workspaceId":{"type":["string","null"]}},"required":["jobId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"not-required","kind":"documented-by-domain","reason":"existing domain guardrails own serialization; this metadata prevents high-risk generic triggers from omitting an explicit safety contract","required":false,"ttlMs":0},"rollbackOrCompensation":"domain-specific tests preserve current rollback, no-op, or replay behavior","streamTopics":["resource.leases","catalog.changes"],"version":1}))
            .stream_topics(vec!["resource.leases", "catalog.changes"])
            .build()?,
        CapabilityContract::new("cron::delete", "cron", EffectClass::IrreversibleSideEffect, RiskLevel::High, Some("cron.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"jobId":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["jobId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"deleted":{"type":"boolean"}},"required":["deleted"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::ExternalIrreversible, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"not-required","kind":"documented-by-domain","reason":"existing domain guardrails own serialization; this metadata prevents high-risk generic triggers from omitting an explicit safety contract","required":false,"ttlMs":0},"rollbackOrCompensation":"domain-specific tests preserve current rollback, no-op, or replay behavior","streamTopics":["resource.leases","catalog.changes"],"version":1}))
            .stream_topics(vec!["resource.leases", "catalog.changes"])
            .build()?,
        CapabilityContract::new("cron::run", "cron", EffectClass::ExternalSideEffect, RiskLevel::High, Some("cron.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"jobId":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["jobId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"jobId":{"type":"string"},"triggered":{"type":"boolean"}},"required":["triggered","jobId"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"not-required","kind":"documented-by-domain","reason":"existing domain guardrails own serialization; this metadata prevents high-risk generic triggers from omitting an explicit safety contract","required":false,"ttlMs":0},"rollbackOrCompensation":"domain-specific tests preserve current rollback, no-op, or replay behavior","streamTopics":["resource.leases","catalog.changes"],"version":1}))
            .stream_topics(vec!["resource.leases", "catalog.changes"])
            .build()?,
        CapabilityContract::new("cron::status", "cron", EffectClass::PureRead, RiskLevel::Low, Some("cron.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?,
        CapabilityContract::new("cron::get_runs", "cron", EffectClass::PureRead, RiskLevel::Low, Some("cron.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"jobId":{"type":"string"},"limit":{"type":"integer"},"offset":{"type":"integer"},"sessionId":{"type":"string"},"status":{"type":"string"},"workspaceId":{"type":"string"}},"required":["jobId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?
    ])
}
