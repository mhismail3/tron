//! Capability contracts owned by the voice_notes domain worker.

use serde_json::json;

use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, DurableOutputContract, EffectClass,
    IdempotencyContract, ResourceLeaseRequirement, Result as EngineResult, RiskLevel,
};

pub(crate) const STREAM_TOPICS: &[&str] = &["voice_notes.changes"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("voice_notes::save", "voice_notes", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("voice_notes.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"audioBase64":{"type":"string"},"mimeType":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["audioBase64"],"type":"object"}))
            .response_schema(voice_note_resource_backed_response(json!({"filename":{"type":"string"},"filepath":{"type":"string"},"success":{"type":"boolean"},"transcription":{"additionalProperties":true,"type":"object"}}), vec!["success", "filename", "filepath", "transcription"]))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .output_contract(DurableOutputContract::resource_backed(["materialized_file", "artifact"]))
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
            .response_schema(voice_note_resource_backed_response(json!({"filename":{"type":"string"},"success":{"type":"boolean"}}), vec!["success", "filename"]))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .output_contract(DurableOutputContract::resource_backed(["artifact", "materialized_file"]))
            .resource_lease(ResourceLeaseRequirement::exclusive_template("voice_notes", "voice-note:{filename}", 60000))
            .compensation(CompensationContract::new(CompensationKind::ExternalIrreversible, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"voice-note:{filename}","kind":"voice_notes","reason":"serializes deletion of one local voice-note file","required":true,"ttlMs":60000},"rollbackOrCompensation":"domain-specific tests preserve current rollback, no-op, or replay behavior","streamTopics": STREAM_TOPICS,"version":1}))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?
    ])
}

fn voice_note_resource_backed_response(
    properties: serde_json::Value,
    mut required: Vec<&'static str>,
) -> serde_json::Value {
    let mut properties = properties.as_object().cloned().unwrap_or_default();
    properties.insert("resourceRefs".to_owned(), resource_refs_schema());
    required.push("resourceRefs");
    json!({
        "additionalProperties": false,
        "properties": properties,
        "required": required,
        "type": "object"
    })
}

fn resource_refs_schema() -> serde_json::Value {
    json!({
        "type": "array",
        "items": {
            "type": "object",
            "required": ["resourceId", "kind", "role"],
            "additionalProperties": false,
            "properties": {
                "resourceId": {"type": "string"},
                "kind": {"type": "string"},
                "versionId": {"type": "string"},
                "role": {"type": "string"},
                "contentHash": {"type": "string"},
                "relation": {"type": "string"}
            }
        }
    })
}
