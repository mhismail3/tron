//! Function contracts owned by the agent domain worker.

use serde_json::json;

use crate::domains::registration::contract::FunctionContract;
use crate::engine::{
    EffectClass, FunctionDefinition, FunctionVisibility, IdempotencyContract, ModelToolAudience,
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
            .build()?,
        FunctionContract::new(
            "agent::request_user_input",
            "agent",
            EffectClass::IdempotentWrite,
            RiskLevel::Low,
        )
        .request_schema(user_input_request_schema())
        .response_schema(json!({
            "type":"object","additionalProperties":false,
            "required":["invocationId","status"],
            "properties":{
                "invocationId":{"type":"string"},
                "status":{"type":"string","const":"pending"}
            }
        }))
        .idempotency(IdempotencyContract::session())
        .description("Ask the user one to three short, necessary questions through the native client. Provide two or three mutually exclusive choices per question; the client adds a free-form Other choice automatically. Use only when required intent cannot be inferred safely. Call this once, do not combine it with other tools, and stop until the user answers.")
        .model_tool(
            "request_user_input",
            ModelToolAudience::Ordinary,
            15,
            "user_interaction",
        )
        .build()?,
        FunctionContract::new(
            "agent::answer_user_input",
            "agent",
            EffectClass::ExternalSideEffect,
            RiskLevel::High,
        )
        .request_schema(user_input_answer_schema())
        .response_schema(user_input_answer_response_schema())
        .idempotency(IdempotencyContract::session())
        .build()?
    ];
    specs.extend(internal_function_definitions()?);
    Ok(specs)
}

fn user_input_request_schema() -> serde_json::Value {
    json!({
        "type":"object",
        "additionalProperties":false,
        "required":["questions"],
        "properties":{
            "questions":{
                "type":"array","minItems":1,"maxItems":3,
                "items":{
                    "type":"object","additionalProperties":false,
                    "required":["header","id","question","options"],
                    "properties":{
                        "header":{"type":"string","minLength":1,"maxLength":12},
                        "id":{"type":"string","pattern":"^[a-z][a-z0-9_]{0,63}$"},
                        "question":{"type":"string","minLength":1,"maxLength":500},
                        "options":{
                            "type":"array","minItems":2,"maxItems":3,
                            "items":{
                                "type":"object","additionalProperties":false,
                                "required":["label","description"],
                                "properties":{
                                    "label":{"type":"string","minLength":1,"maxLength":80},
                                    "description":{"type":"string","minLength":1,"maxLength":300}
                                }
                            }
                        }
                    }
                }
            }
        }
    })
}

fn user_input_answer_schema() -> serde_json::Value {
    json!({
        "type":"object",
        "additionalProperties":false,
        "required":["sessionId","invocationId","answers"],
        "properties":{
            "sessionId":{"type":"string","minLength":1},
            "invocationId":{"type":"string","minLength":1},
            "answers":{
                "type":"array","minItems":1,"maxItems":3,
                "items":{
                    "type":"object","additionalProperties":false,
                    "required":["questionId"],
                    "properties":{
                        "questionId":{"type":"string","minLength":1,"maxLength":64},
                        "selectedLabel":{"type":"string","minLength":1,"maxLength":80},
                        "freeText":{"type":"string","minLength":1,"maxLength":2000}
                    },
                    "anyOf":[{"required":["selectedLabel"]},{"required":["freeText"]}]
                }
            }
        }
    })
}

fn user_input_answer_response_schema() -> serde_json::Value {
    json!({
        "type":"object",
        "additionalProperties":false,
        "required":["acknowledged","runId"],
        "properties":{
            "acknowledged":{"type":"boolean","const":true},
            "runId":{"type":"string"},
            "alreadyAnswered":{"type":"boolean"}
        }
    })
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
            "properties":{
                "sessionId":{"type":"string"},
                "reasoningLevel":{"type":"string"},
                "deliveryIds":{
                    "type":"array","minItems":1,"maxItems":8,
                    "items":{"type":"string"}
                }
            }
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
            "attachments": {"type": "array", "items": {"type": "object", "additionalProperties": true}},
            "userInputAnswer": {"type":"object","additionalProperties":true}
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
                "agent::request_user_input",
                "agent::answer_user_input",
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
            ("agent::request_user_input", vec!["questions"]),
            (
                "agent::answer_user_input",
                vec!["answers", "invocationId", "sessionId"],
            ),
            (
                "agent::prompt_apply",
                vec![
                    "attachments",
                    "prompt",
                    "reasoningLevel",
                    "runId",
                    "sessionId",
                    "userInputAnswer",
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
                    "userInputAnswer",
                ],
            ),
            (
                "agent::delivery_wake",
                vec!["deliveryIds", "reasoningLevel", "sessionId"],
            ),
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
