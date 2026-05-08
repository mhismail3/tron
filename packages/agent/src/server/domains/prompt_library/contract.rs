//! Capability contracts owned by the prompt_library domain worker.

#[allow(unused_imports)]
use serde_json::json;

use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    Result as EngineResult, RiskLevel,
};
use crate::server::domains::catalog::CapabilitySpec;
use crate::server::domains::contract::CapabilityContract;

pub(crate) const STREAM_TOPICS: &[&str] = &["prompt_library.changes"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("prompt_library::history_list", "prompt_library", EffectClass::PureRead, RiskLevel::Low, Some("prompt_library.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"cursor":{"type":"string"},"limit":{"type":"integer"},"query":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"items":{"items":{"additionalProperties":true,"type":"object"},"type":"array"},"nextCursor":{"type":["string","null"]}},"required":["items","nextCursor"],"type":"object"}))
            .build()?,
        CapabilityContract::new("prompt_library::history_delete", "prompt_library", EffectClass::IrreversibleSideEffect, RiskLevel::High, Some("prompt_library.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"id":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["id"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"deleted":{"type":"boolean"}},"required":["deleted"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::ExternalIrreversible, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":false,"resourceLock":{"idTemplate":"not-required","kind":"documented-by-domain","reason":"existing domain guardrails own serialization; this metadata prevents high-risk generic triggers from omitting an explicit safety contract","required":false,"ttlMs":0},"rollbackOrCompensation":"domain-specific tests preserve current rollback, no-op, or replay behavior","streamTopics": STREAM_TOPICS,"version":1}))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("prompt_library::history_clear", "prompt_library", EffectClass::IrreversibleSideEffect, RiskLevel::High, Some("prompt_library.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"deletedCount":{"type":"integer"}},"required":["deletedCount"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
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
            .response_schema(json!({"additionalProperties":false,"properties":{"snippet":{"additionalProperties":true,"type":"object"}},"required":["snippet"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("prompt_library::snippet_update", "prompt_library", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("prompt_library.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"id":{"type":"string"},"name":{"type":"string"},"sessionId":{"type":"string"},"text":{"type":"string"},"workspaceId":{"type":"string"}},"required":["id"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"snippet":{"additionalProperties":true,"type":"object"}},"required":["snippet"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("prompt_library::snippet_delete", "prompt_library", EffectClass::IrreversibleSideEffect, RiskLevel::High, Some("prompt_library.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"id":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["id"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"deleted":{"type":"boolean"}},"required":["deleted"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_system_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::ExternalIrreversible, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":false,"resourceLock":{"idTemplate":"not-required","kind":"documented-by-domain","reason":"existing domain guardrails own serialization; this metadata prevents high-risk generic triggers from omitting an explicit safety contract","required":false,"ttlMs":0},"rollbackOrCompensation":"domain-specific tests preserve current rollback, no-op, or replay behavior","streamTopics": STREAM_TOPICS,"version":1}))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?
    ])
}
