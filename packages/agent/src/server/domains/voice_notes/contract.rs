//! Capability contracts owned by the voice_notes domain worker.

#[allow(unused_imports)]
use serde_json::json;

use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    ResourceLeaseRequirement, Result as EngineResult, RiskLevel,
};
use crate::server::domains::catalog::CapabilitySpec;
use crate::server::domains::contract::CapabilityContract;

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("voice_notes::save", "voice_notes", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("voice_notes.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"audioBase64":{"type":"string"},"mimeType":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["audioBase64"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"filename":{"type":"string"},"filepath":{"type":"string"},"success":{"type":"boolean"},"transcription":{"additionalProperties":true,"type":"object"}},"required":["success","filename","filepath","transcription"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .resource_lease(ResourceLeaseRequirement::exclusive_template("voice_notes", "voice-notes:inbox", 60000))
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("voice_notes::list", "voice_notes", EffectClass::PureRead, RiskLevel::Low, Some("voice_notes.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"limit":{"type":"integer"},"offset":{"type":"integer"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?,
        CapabilityContract::new("voice_notes::delete", "voice_notes", EffectClass::IrreversibleSideEffect, RiskLevel::High, Some("voice_notes.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"filename":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["filename"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"filename":{"type":"string"},"success":{"type":"boolean"}},"required":["success","filename"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .resource_lease(ResourceLeaseRequirement::exclusive_template("voice_notes", "voice-note:{filename}", 60000))
            .compensation(CompensationContract::new(CompensationKind::ExternalIrreversible, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"voice-note:{filename}","kind":"voice_notes","reason":"serializes deletion of one local voice-note file","required":true,"ttlMs":60000},"rollbackOrCompensation":"domain-specific tests preserve current rollback, no-op, or replay behavior","streamTopics":["resource.leases","catalog.changes"],"version":1}))
            .stream_topics(vec!["resource.leases", "catalog.changes"])
            .build()?
    ])
}
