//! Capability contracts owned by the transcription domain worker.

use serde_json::json;

use crate::domains::registration::catalog::CapabilitySpec;
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    ResourceLeaseRequirement, Result as EngineResult, RiskLevel,
};

pub(crate) const STREAM_TOPICS: &[&str] = &["transcription.jobs"];

pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new(
            "transcription::audio",
            "transcription",
            EffectClass::ExternalSideEffect,
            RiskLevel::Medium,
            Some("transcription.write"),
        )
        .request_schema(json!({"additionalProperties":false,"properties":{"audioBase64":{"type":"string"},"mimeType":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["audioBase64"],"type":"object"}))
        .response_schema(json!({"additionalProperties":false,"properties":{"cleanupMode":{"type":"string"},"computeType":{"type":"string"},"device":{"type":"string"},"durationSeconds":{"type":"number"},"language":{"type":"string"},"model":{"type":"string"},"processingTimeMs":{"type":"integer"},"rawText":{"type":"string"},"text":{"type":"string"}},"required":["text","rawText","language","durationSeconds","processingTimeMs","model","device","computeType","cleanupMode"],"type":"object"}))
        .idempotency(IdempotencyContract::caller_system_engine_ledger())
        .resource_lease(ResourceLeaseRequirement::exclusive_template("transcription", "transcription:audio", 300000))
        .compensation(CompensationContract::new(CompensationKind::ManualOnly, "temporary request audio is deleted automatically; no durable server state is created"))
        .stream_topics(STREAM_TOPICS.to_vec())
        .build()?,
        CapabilityContract::new(
            "transcription::list_models",
            "transcription",
            EffectClass::PureRead,
            RiskLevel::Low,
            Some("transcription.read"),
        )
        .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
        .response_schema(json!({"additionalProperties":true,"type":"object"}))
        .build()?,
        CapabilityContract::new(
            "transcription::download_model",
            "transcription",
            EffectClass::ExternalSideEffect,
            RiskLevel::Medium,
            Some("transcription.write"),
        )
        .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
        .response_schema(json!({"additionalProperties":false,"properties":{"message":{"type":"string"},"reason":{"type":"string"},"started":{"type":"boolean"}},"required":["started","reason"],"type":"object"}))
        .idempotency(IdempotencyContract::caller_system_engine_ledger())
        .resource_lease(ResourceLeaseRequirement::exclusive_template("transcription", "transcription:model-cache", 900000))
        .compensation(CompensationContract::new(CompensationKind::ManualOnly, "model cache downloads are managed by the local sidecar and retried by server restart"))
        .stream_topics(STREAM_TOPICS.to_vec())
        .build()?,
    ])
}
