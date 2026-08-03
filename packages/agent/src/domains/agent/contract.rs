//! Function contracts owned by the agent domain worker.

use serde_json::json;

use crate::domains::registration::contract::FunctionContract;
use crate::engine::{
    EffectClass, FunctionDefinition, FunctionVisibility, IdempotencyContract,
    Result as EngineResult, RiskLevel,
};

pub(crate) const RUNTIME_STREAM_TOPIC: &str = "agent.runtime";

/// Canonical function contracts exposed by this domain worker.
pub(crate) fn function_definitions() -> EngineResult<Vec<FunctionDefinition>> {
    let mut specs = vec![
        FunctionContract::new("agent::prompt", "agent", EffectClass::ExternalSideEffect, RiskLevel::High)
            .request_schema(json!({"additionalProperties":false,"properties":{"attachments":{"items":{"additionalProperties":true,"type":"object"},"type":"array"},"prompt":{"type":"string"},"reasoningLevel":{"type":"string"},"sessionId":{"type":"string"}},"required":["sessionId","prompt"],"type":"object"}))
            .response_schema(agent_prompt_response_schema())
            .idempotency(IdempotencyContract::session())
            .build()?,
        FunctionContract::new("agent::abort", "agent", EffectClass::ReversibleSideEffect, RiskLevel::High)
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::session())
            .build()?,
        FunctionContract::new("agent::abort_invocation", "agent", EffectClass::ReversibleSideEffect, RiskLevel::Medium)
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"},"invocationId":{"type":"string"}},"required":["sessionId","invocationId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .idempotency(IdempotencyContract::session())
            .build()?,
        FunctionContract::new("agent::status", "agent", EffectClass::PureRead, RiskLevel::Low)
            .request_schema(json!({"additionalProperties":false,"properties":{"sessionId":{"type":"string"}},"required":["sessionId"],"type":"object"}))
            .response_schema(json!({"additionalProperties":true,"type":"object"}))
            .build()?
    ];
    specs.extend(internal_function_definitions()?);
    Ok(specs)
}

fn internal_function_definitions() -> EngineResult<Vec<FunctionDefinition>> {
    Ok(vec![
        FunctionContract::new(
            "agent::prompt_apply",
            "agent",
            EffectClass::ExternalSideEffect,
            RiskLevel::High,
        )
        .visibility(FunctionVisibility::Internal)
        .request_schema(agent_prompt_apply_request_schema())
        .response_schema(agent_prompt_response_schema())
        .idempotency(IdempotencyContract::session())
        .build()?,
        FunctionContract::new(
            "agent::run_turn",
            "agent",
            EffectClass::ExternalSideEffect,
            RiskLevel::High,
        )
        .visibility(FunctionVisibility::Internal)
        .request_schema(agent_prompt_apply_request_schema())
        .response_schema(agent_prompt_response_schema())
        .idempotency(IdempotencyContract::session())
        .build()?,
        FunctionContract::new(
            "agent::delivery_wake",
            "agent",
            EffectClass::ExternalSideEffect,
            RiskLevel::High,
        )
        .visibility(FunctionVisibility::Internal)
        .request_schema(json!({
            "type":"object",
            "additionalProperties":false,
            "required":["sessionId"],
            "properties":{"sessionId":{"type":"string"}}
        }))
        .response_schema(json!({
            "type":"object",
            "additionalProperties":false,
            "required":["acknowledged"],
            "properties":{
                "acknowledged":{"type":"boolean"},
                "runId":{"type":"string"},
                "reason":{"type":"string"}
            }
        }))
        .idempotency(IdempotencyContract::session())
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
            "attachments": {"type": "array", "items": {"type": "object", "additionalProperties": true}}
        }
    })
}

fn agent_prompt_response_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["acknowledged", "runId"],
        "additionalProperties": false,
        "properties": {
            "acknowledged": {"type": "boolean", "const": true},
            "runId": {"type": "string"}
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn agent_contract_exposes_only_prompt_transport_and_hidden_runtime() {
        let specs = function_definitions().expect("agent contracts");
        let ids = specs
            .iter()
            .map(|definition| definition.id.as_str())
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
                "agent::delivery_wake",
            ]
        );
    }

    #[test]
    fn prompt_contracts_admit_only_affirmative_acknowledgements() {
        let specs = function_definitions().expect("agent contracts");
        for function_id in ["agent::prompt", "agent::prompt_apply", "agent::run_turn"] {
            let spec = specs
                .iter()
                .find(|definition| definition.id.as_str() == function_id)
                .expect("prompt tool should be registered");
            let schema = spec
                .response_schema
                .as_ref()
                .expect("prompt tool should declare its response schema");
            assert_eq!(
                schema["properties"]["acknowledged"]["const"],
                json!(true),
                "{function_id} must not encode rejection as a successful response"
            );
        }
    }

    #[test]
    fn agent_contracts_contain_only_behavioral_inputs() {
        let specs = function_definitions().expect("agent contracts");
        let expected = [
            (
                "agent::prompt",
                vec!["attachments", "prompt", "reasoningLevel", "sessionId"],
            ),
            ("agent::abort", vec!["sessionId"]),
            ("agent::abort_invocation", vec!["invocationId", "sessionId"]),
            ("agent::status", vec!["sessionId"]),
            (
                "agent::prompt_apply",
                vec![
                    "attachments",
                    "prompt",
                    "reasoningLevel",
                    "runId",
                    "sessionId",
                ],
            ),
            (
                "agent::run_turn",
                vec![
                    "attachments",
                    "prompt",
                    "reasoningLevel",
                    "runId",
                    "sessionId",
                ],
            ),
            ("agent::delivery_wake", vec!["sessionId"]),
        ];
        for (function_id, expected_properties) in expected {
            let schema = specs
                .iter()
                .find(|definition| definition.id.as_str() == function_id)
                .and_then(|definition| definition.request_schema.as_ref())
                .unwrap_or_else(|| panic!("request schema for {function_id}"));
            let properties = schema["properties"]
                .as_object()
                .expect("object properties")
                .keys()
                .map(String::as_str)
                .collect::<Vec<_>>();
            assert_eq!(properties, expected_properties, "{function_id}");
        }
    }
}
