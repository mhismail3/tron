//! Capability contracts owned by the agent domain worker.

#[allow(unused_imports)]
use serde_json::json;

use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    Result as EngineResult, RiskLevel, VisibilityScope,
};

pub(crate) const STREAM_TOPICS: &[&str] = &["agent.runtime", "agent.queue"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    let mut specs = vec![
        CapabilityContract::new("agent::prompt", "agent", EffectClass::ExternalSideEffect, RiskLevel::High, Some("agent.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"attachments":{"items":{"additionalProperties":true,"type":"object"},"type":"array"},"images":{"items":{"additionalProperties":true,"type":"object"},"type":"array"},"prompt":{"type":"string"},"reasoningLevel":{"type":"string"},"sessionId":{"type":"string"},"source":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","prompt"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"acknowledged":{"type":"boolean"},"runId":{"type":"string"}},"required":["acknowledged","runId"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"not-required","kind":"documented-by-domain","reason":"existing domain guardrails own serialization; this metadata prevents high-risk generic triggers from omitting an explicit safety contract","required":false,"ttlMs":0},"rollbackOrCompensation":"domain-specific tests preserve current rollback, no-op, or replay behavior","streamTopics": STREAM_TOPICS,"version":1}))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("agent::abort", "agent", EffectClass::ReversibleSideEffect, RiskLevel::High, Some("agent.write"))
            .approval_required(true)
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .high_risk_contract(json!({"approvalRequiredForAgentVisibility":true,"resourceLock":{"idTemplate":"not-required","kind":"documented-by-domain","reason":"existing domain guardrails own serialization; this metadata prevents high-risk generic triggers from omitting an explicit safety contract","required":false,"ttlMs":0},"rollbackOrCompensation":"domain-specific tests preserve current rollback, no-op, or replay behavior","streamTopics": STREAM_TOPICS,"version":1}))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("agent::abort_invocation", "agent", EffectClass::ReversibleSideEffect, RiskLevel::Medium, Some("agent.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"invocationId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","invocationId"],"type":"object"}))
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
        CapabilityContract::new("agent::submit_answers", "agent", EffectClass::IdempotentWrite, RiskLevel::Medium, Some("agent.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"questions":{"items":{"additionalProperties":false,"properties":{"id":{"type":"string"},"otherValue":{"type":"string"},"question":{"type":"string"},"selectedValues":{"items":{"type":"string"},"type":"array"}},"required":["question"],"type":"object"},"type":"array"},"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","questions"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .build()?
    ];
    specs.extend(hidden_capabilities()?);
    Ok(specs)
}

fn hidden_capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    Ok(vec![
        CapabilityContract::new("agent::prompt_apply", "agent", EffectClass::ExternalSideEffect, RiskLevel::High, Some("agent.write"))
            .visibility(VisibilityScope::Internal)
            .request_schema(agent_prompt_apply_request_schema())
            .response_schema(agent_prompt_response_schema())
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(
                CompensationKind::ExternalIrreversible,
                "hidden prompt apply starts queued runtime work; event-store history remains authoritative and replay is ledger/idempotency controlled",
            ))
            .high_risk_contract(json!({
                "internal": true,
                "hiddenPromptRuntimeFunction": true,
                "rollbackOrCompensation": "hidden prompt apply starts queued runtime work; event-store history remains authoritative and replay is ledger/idempotency controlled",
                "streamTopics": STREAM_TOPICS,
                "version": 1
            }))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("agent::run_turn", "agent", EffectClass::ExternalSideEffect, RiskLevel::High, Some("agent.write"))
            .visibility(VisibilityScope::Internal)
            .request_schema(agent_prompt_apply_request_schema())
            .response_schema(agent_prompt_response_schema())
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(
                CompensationKind::ExternalIrreversible,
                "hidden run-turn starts live provider capability work; event-store history remains authoritative and replay is ledger/idempotency controlled",
            ))
            .high_risk_contract(json!({
                "internal": true,
                "hiddenPromptRuntimeFunction": true,
                "rollbackOrCompensation": "hidden run-turn starts live provider capability work; event-store history remains authoritative and replay is ledger/idempotency controlled",
                "streamTopics": STREAM_TOPICS,
                "version": 1
            }))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("agent::prompt_queue_drain", "agent", EffectClass::ExternalSideEffect, RiskLevel::High, Some("agent.write"))
            .visibility(VisibilityScope::Internal)
            .request_schema(agent_prompt_queue_drain_request_schema())
            .response_schema(agent_prompt_queue_drain_response_schema())
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(
                CompensationKind::ExternalIrreversible,
                "hidden prompt queue drain starts queued runtime work after a prior run completes; replay is ledger/idempotency controlled",
            ))
            .high_risk_contract(json!({
                "internal": true,
                "hiddenPromptRuntimeFunction": true,
                "rollbackOrCompensation": "hidden prompt queue drain starts queued runtime work after a prior run completes; replay is ledger/idempotency controlled",
                "streamTopics": STREAM_TOPICS,
                "version": 1
            }))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
    ])
}

fn agent_prompt_apply_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["runId", "sessionId", "prompt"],
        "additionalProperties": false,
        "properties": {
            "runId": {"type": "string"},
            "sessionId": {"type": "string"},
            "prompt": {"type": "string"},
            "reasoningLevel": {"type": "string"},
            "images": {"type": "array", "items": {"type": "object", "additionalProperties": true}},
            "attachments": {"type": "array", "items": {"type": "object", "additionalProperties": true}},
            "source": {"type": "string"},
            "workspaceId": {"type": "string"}
        }
    })
}

fn agent_prompt_response_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["acknowledged", "runId"],
        "additionalProperties": false,
        "properties": {
            "acknowledged": {"type": "boolean"},
            "runId": {"type": "string"}
        }
    })
}

fn agent_prompt_queue_drain_request_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["sessionId", "completedRunId"],
        "additionalProperties": false,
        "properties": {
            "sessionId": {"type": "string"},
            "completedRunId": {"type": "string"},
            "workspaceId": {"type": "string"}
        }
    })
}

fn agent_prompt_queue_drain_response_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["drained", "count"],
        "additionalProperties": false,
        "properties": {
            "drained": {"type": "boolean"},
            "count": {"type": "integer"},
            "runId": {"type": ["string", "null"]},
            "reason": {"type": ["string", "null"]}
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn submit_answers_contract_accepts_client_question_id() {
        let specs = capabilities().expect("agent contracts");
        let submit = specs
            .iter()
            .find(|spec| spec.function_id.as_str() == "agent::submit_answers")
            .expect("submit answers contract");
        let id_property = submit
            .request_schema
            .as_ref()
            .and_then(|schema| schema.pointer("/properties/questions/items/properties/id"));

        assert_eq!(
            id_property.and_then(|value| value.get("type")),
            Some(&json!("string"))
        );
    }
}
