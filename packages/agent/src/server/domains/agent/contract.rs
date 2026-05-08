//! Capability contracts owned by the agent domain worker.

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
        CapabilityContract::new("agent::prompt", "agent", EffectClass::ExternalSideEffect, RiskLevel::High, Some("agent.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"attachments":{"items":{"additionalProperties":true,"type":"object"},"type":"array"},"images":{"items":{"additionalProperties":true,"type":"object"},"type":"array"},"prompt":{"type":"string"},"reasoningLevel":{"type":"string"},"sessionId":{"type":"string"},"source":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","prompt"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"acknowledged":{"type":"boolean"},"runId":{"type":"string"}},"required":["acknowledged","runId"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"not-required","kind":"documented-by-domain","reason":"existing domain guardrails own serialization; this metadata prevents high-risk generic triggers from omitting an explicit safety contract","required":false,"ttlMs":0},"rollbackOrCompensation":"domain-specific tests preserve current rollback, no-op, or replay behavior","streamTopics":["resource.leases","catalog.changes"],"version":1}))
            .stream_topics(vec!["resource.leases", "catalog.changes"])
            .build()?,
        CapabilityContract::new("agent::abort", "agent", EffectClass::ReversibleSideEffect, RiskLevel::High, Some("agent.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"not-required","kind":"documented-by-domain","reason":"existing domain guardrails own serialization; this metadata prevents high-risk generic triggers from omitting an explicit safety contract","required":false,"ttlMs":0},"rollbackOrCompensation":"domain-specific tests preserve current rollback, no-op, or replay behavior","streamTopics":["resource.leases","catalog.changes"],"version":1}))
            .stream_topics(vec!["resource.leases", "catalog.changes"])
            .build()?,
        CapabilityContract::new("agent::abort_tool", "agent", EffectClass::ReversibleSideEffect, RiskLevel::Medium, Some("agent.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"toolCallId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","toolCallId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("agent::status", "agent", EffectClass::PureRead, RiskLevel::Low, Some("agent.read"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?,
        CapabilityContract::new("agent::queue_prompt", "agent", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("agent.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"prompt":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","prompt"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("agent::dequeue_prompt", "agent", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("agent.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"queueId":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","queueId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("agent::clear_queue", "agent", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("agent.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("agent::deliver_subagent_results", "agent", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("agent.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("agent::submit_confirmation", "agent", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("agent.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"action":{"type":"string"},"decision":{"type":"string"},"note":{"type":"string"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","action","decision"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?,
        CapabilityContract::new("agent::submit_answers", "agent", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("agent.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"questions":{"items":{"additionalProperties":false,"properties":{"otherValue":{"type":"string"},"question":{"type":"string"},"selectedValues":{"items":{"type":"string"},"type":"array"}},"required":["question"],"type":"object"},"type":"array"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","questions"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?
    ])
}
