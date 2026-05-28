//! Capability contracts owned by the prompt_library domain worker.

use serde_json::json;

use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, DurableOutputContract, EffectClass,
    IdempotencyContract, Result as EngineResult, RiskLevel, VisibilityScope,
};

pub(crate) const STREAM_TOPICS: &[&str] = &["prompt_library.changes"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("prompt_library::history_record", "prompt_library", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("prompt_library.write"))
            .visibility(VisibilityScope::Internal)
            .request_schema(json!({"additionalProperties":false,"properties":{"prompt":{"type":"string"},"sessionId":{"type":"string"},"source":{"type":["string","null"]},"workspaceId":{"type":["string","null"]}},"required":["prompt"],"type":"object"}))
            .response_schema(resource_backed_response(json!({"recorded":{"type":"boolean"},"reason":{"type":["string","null"]}}), vec!["recorded", "resourceRefs"]))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .output_contract(optional_artifact_output_contract())
            .compensation(CompensationContract::new(CompensationKind::None, "prompt history record is idempotent metadata capture; skipped records are represented explicitly"))
            .build()?,
        CapabilityContract::new("prompt_library::history_list", "prompt_library", EffectClass::PureRead, RiskLevel::Low, Some("prompt_library.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"cursor":{"type":"string"},"limit":{"type":"integer"},"query":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"items":{"items":{"additionalProperties":true,"type":"object"},"type":"array"},"nextCursor":{"type":["string","null"]}},"required":["items","nextCursor"],"type":"object"}))
            .build()?,
        CapabilityContract::new("prompt_library::history_delete", "prompt_library", EffectClass::IrreversibleSideEffect, RiskLevel::High, Some("prompt_library.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"id":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["id"],"type":"object"}))
            .response_schema(resource_backed_response(json!({"deleted":{"type":"boolean"}}), vec!["deleted", "resourceRefs"]))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .output_contract(optional_artifact_output_contract())
            .compensation(CompensationContract::new(CompensationKind::ExternalIrreversible, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":false,"resourceLock":{"idTemplate":"not-required","kind":"documented-by-domain","reason":"existing domain guardrails own serialization; this metadata prevents high-risk generic triggers from omitting an explicit safety contract","required":false,"ttlMs":0},"rollbackOrCompensation":"domain-specific tests preserve current rollback, no-op, or replay behavior","streamTopics": STREAM_TOPICS,"version":1}))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("prompt_library::history_clear", "prompt_library", EffectClass::IrreversibleSideEffect, RiskLevel::High, Some("prompt_library.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(resource_backed_response(json!({"deletedCount":{"type":"integer"}}), vec!["deletedCount", "resourceRefs"]))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .output_contract(optional_artifact_output_contract())
            .compensation(CompensationContract::new(CompensationKind::ExternalIrreversible, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":false,"resourceLock":{"idTemplate":"not-required","kind":"documented-by-domain","reason":"existing domain guardrails own serialization; this metadata prevents high-risk generic triggers from omitting an explicit safety contract","required":false,"ttlMs":0},"rollbackOrCompensation":"domain-specific tests preserve current rollback, no-op, or replay behavior","streamTopics": STREAM_TOPICS,"version":1}))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("prompt_library::snippet_list", "prompt_library", EffectClass::PureRead, RiskLevel::Low, Some("prompt_library.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"items":{"items":{"additionalProperties":true,"type":"object"},"type":"array"}},"required":["items"],"type":"object"}))
            .build()?,
        CapabilityContract::new("prompt_library::snippet_get", "prompt_library", EffectClass::PureRead, RiskLevel::Low, Some("prompt_library.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"id":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["id"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"snippet":{"additionalProperties":true,"type":"object"}},"required":["snippet"],"type":"object"}))
            .build()?,
        CapabilityContract::new("prompt_library::snippet_create", "prompt_library", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("prompt_library.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"name":{"type":"string"},"sessionId":{"type":"string"},"text":{"type":"string"},"workspaceId":{"type":"string"}},"required":["name","text"],"type":"object"}))
            .response_schema(resource_backed_response(json!({"snippet":{"additionalProperties":true,"type":"object"}}), vec!["snippet", "resourceRefs"]))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .output_contract(DurableOutputContract::resource_backed(["artifact"]))
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("prompt_library::snippet_update", "prompt_library", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("prompt_library.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"id":{"type":"string"},"name":{"type":"string"},"sessionId":{"type":"string"},"text":{"type":"string"},"workspaceId":{"type":"string"}},"required":["id"],"type":"object"}))
            .response_schema(resource_backed_response(json!({"snippet":{"additionalProperties":true,"type":"object"}}), vec!["snippet", "resourceRefs"]))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .output_contract(DurableOutputContract::resource_backed(["artifact"]))
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("prompt_library::snippet_delete", "prompt_library", EffectClass::IrreversibleSideEffect, RiskLevel::High, Some("prompt_library.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"id":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["id"],"type":"object"}))
            .response_schema(resource_backed_response(json!({"deleted":{"type":"boolean"}}), vec!["deleted", "resourceRefs"]))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .output_contract(optional_artifact_output_contract())
            .compensation(CompensationContract::new(CompensationKind::ExternalIrreversible, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":false,"resourceLock":{"idTemplate":"not-required","kind":"documented-by-domain","reason":"existing domain guardrails own serialization; this metadata prevents high-risk generic triggers from omitting an explicit safety contract","required":false,"ttlMs":0},"rollbackOrCompensation":"domain-specific tests preserve current rollback, no-op, or replay behavior","streamTopics": STREAM_TOPICS,"version":1}))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?
    ])
}

fn optional_artifact_output_contract() -> DurableOutputContract {
    DurableOutputContract::ResourceBacked {
        produced_resource_kinds: vec!["artifact".to_owned()],
        required_resource_refs: false,
    }
}

fn resource_backed_response(
    properties: serde_json::Value,
    required: Vec<&'static str>,
) -> serde_json::Value {
    let mut properties = properties.as_object().cloned().unwrap_or_default();
    properties.insert("resourceRefs".to_owned(), resource_refs_schema());
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
