//! Capability contracts owned by the transcription domain worker.

#[allow(unused_imports)]
use serde_json::json;

use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    ResourceLeaseRequirement, Result as EngineResult, RiskLevel,
};

pub(crate) const STREAM_TOPICS: &[&str] = &["transcription.jobs"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("transcription::audio", "transcription", EffectClass::ExternalSideEffect, RiskLevel::Medium, Some("transcription.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"audioBase64":{"type":"string"},"mimeType":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["audioBase64"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"cleanupMode":{"type":"string"},"computeType":{"type":"string"},"device":{"type":"string"},"durationSeconds":{"type":"number"},"language":{"type":"string"},"model":{"type":"string"},"processingTimeMs":{"type":"integer"},"rawText":{"type":"string"},"text":{"type":"string"}},"required":["text","rawText","language","durationSeconds","processingTimeMs","model","device","computeType","cleanupMode"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .resource_lease(ResourceLeaseRequirement::exclusive_template("transcription", "transcription:audio", 300000))
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("transcription::list_models", "transcription", EffectClass::PureRead, RiskLevel::Low, Some("transcription.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?,
        CapabilityContract::new("transcription::download_model", "transcription", EffectClass::ExternalSideEffect, RiskLevel::Medium, Some("transcription.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"message":{"type":"string"},"reason":{"type":"string"},"started":{"type":"boolean"}},"required":["started","reason"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .resource_lease(ResourceLeaseRequirement::exclusive_template("transcription", "transcription:model-cache", 900000))
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?
    ])
}
