//! Capability contracts owned by the agent domain worker.

use serde_json::json;

use crate::domains::catalog::CapabilitySpec;
use crate::domains::contract::CapabilityContract;
use crate::engine::{
    CompensationContract, CompensationKind, EffectClass, IdempotencyContract,
    Result as EngineResult, RiskLevel, VisibilityScope,
};

pub(crate) const STREAM_TOPICS: &[&str] = &["agent.runtime"];

/// Canonical capability contracts exposed by this domain worker.
pub(crate) fn capabilities() -> EngineResult<Vec<CapabilitySpec>> {
    let mut specs = vec![
        CapabilityContract::new("agent::prompt", "agent", EffectClass::ExternalSideEffect, RiskLevel::High, Some("agent.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"attachments":{"items":{"additionalProperties":true,"type":"object"},"type":"array"},"images":{"items":{"additionalProperties":true,"type":"object"},"type":"array"},"prompt":{"type":"string"},"reasoningLevel":{"type":"string"},"sessionId":{"type":"string"},"source":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId","prompt"],"type":"object"}))
            .response_schema(json!({"additionalProperties":false,"properties":{"acknowledged":{"type":"boolean"},"runId":{"type":"string"}},"required":["acknowledged","runId"],"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::ManualOnly, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
            .stream_topics(STREAM_TOPICS.to_vec())
            .build()?,
        CapabilityContract::new("agent::abort", "agent", EffectClass::ReversibleSideEffect, RiskLevel::High, Some("agent.write"))
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"workspaceId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::caller_session_engine_ledger())
            .compensation(CompensationContract::new(CompensationKind::InverseCommandAvailable, "domain-specific tests preserve current rollback, no-op, or replay behavior"))
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn agent_contract_exposes_only_prompt_transport_and_hidden_runtime() {
        let specs = capabilities().expect("agent contracts");
        let ids = specs
            .iter()
            .map(|spec| spec.function_id.as_str())
            .collect::<Vec<_>>();
        assert_eq!(
            ids,
            vec![
                "agent::prompt",
                "agent::abort",
                "agent::abort_invocation",
                "agent::status",
                "agent::prompt_apply",
                "agent::run_turn",
            ]
        );
    }
}
