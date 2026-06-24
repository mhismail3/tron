use serde_json::json;

use crate::domains::registration::catalog::{CapabilitySpec, TransportIdempotencyMode};
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{DurableOutputContract, EffectClass, IdempotencyContract, RiskLevel};

use super::{
    GOAL_ANSWER_KIND, GOAL_CANCEL_FUNCTION, GOAL_CREATE_FUNCTION, GOAL_INSPECT_FUNCTION, GOAL_KIND,
    GOAL_LIST_FUNCTION, GOALS_LIFECYCLE_TOPIC, QUESTION_ANSWER_FUNCTION, QUESTION_CREATE_FUNCTION,
    QUESTION_INSPECT_FUNCTION, QUESTION_LIST_FUNCTION, READ_SCOPE, USER_QUESTION_KIND, WORKER,
    WRITE_SCOPE,
};

pub(crate) fn capabilities() -> crate::engine::Result<Vec<CapabilitySpec>> {
    Ok(vec![
        write_contract(
            GOAL_CREATE_FUNCTION,
            "Create a durable goal resource with bounded queue/resource/stream/replay evidence.",
        )
        .request_schema(goal_create_schema())
        .response_schema(goal_response_schema())
        .output_contract(DurableOutputContract::resource_backed([GOAL_KIND]))
        .build()?,
        read_contract(GOAL_LIST_FUNCTION, "List durable goal resources in scope.")
            .request_schema(list_schema(["open", "cancelled", "archived"]))
            .response_schema(list_response_schema("goals"))
            .build()?,
        read_contract(GOAL_INSPECT_FUNCTION, "Inspect one durable goal resource.")
            .request_schema(resource_id_schema("goalResourceId"))
            .response_schema(goal_inspect_response_schema())
            .build()?,
        write_contract(GOAL_CANCEL_FUNCTION, "Cancel one open durable goal resource.")
            .request_schema(cancel_schema())
            .response_schema(goal_response_schema())
            .output_contract(DurableOutputContract::resource_backed([GOAL_KIND]))
            .build()?,
        write_contract(
            QUESTION_CREATE_FUNCTION,
            "Create a durable user_question resource, optionally attached to a goal.",
        )
        .request_schema(question_create_schema())
        .response_schema(question_response_schema())
        .output_contract(DurableOutputContract::resource_backed([USER_QUESTION_KIND, GOAL_KIND]))
        .build()?,
        read_contract(
            QUESTION_LIST_FUNCTION,
            "List durable user_question resources in scope.",
        )
        .request_schema(question_list_schema())
        .response_schema(list_response_schema("questions"))
        .build()?,
        read_contract(
            QUESTION_INSPECT_FUNCTION,
            "Inspect one durable user_question resource.",
        )
        .request_schema(resource_id_schema("questionResourceId"))
        .response_schema(question_inspect_response_schema())
        .build()?,
        write_contract(
            QUESTION_ANSWER_FUNCTION,
            "Answer one pending user_question exactly once with expected-version and provenance evidence.",
        )
        .request_schema(question_answer_schema())
        .response_schema(question_answer_response_schema())
        .output_contract(DurableOutputContract::resource_backed([
            USER_QUESTION_KIND,
            GOAL_ANSWER_KIND,
            GOAL_KIND,
        ]))
        .build()?,
    ])
}

fn read_contract(function_id: &'static str, description: &'static str) -> CapabilityContract {
    CapabilityContract::new(
        function_id,
        WORKER,
        EffectClass::PureRead,
        RiskLevel::Low,
        Some(READ_SCOPE),
    )
    .description(description)
    .tags(vec!["goals", "questions", "resource", "replay"])
    .domain_module("goals")
    .presentation_hints(json!({"systemImage": "checklist"}))
}

fn write_contract(function_id: &'static str, description: &'static str) -> CapabilityContract {
    CapabilityContract::new(
        function_id,
        WORKER,
        EffectClass::AppendOnlyEvent,
        RiskLevel::Medium,
        Some(WRITE_SCOPE),
    )
    .description(description)
    .tags(vec!["goals", "questions", "resource", "lifecycle"])
    .domain_module("goals")
    .idempotency(IdempotencyContract::caller_session_engine_ledger())
    .idempotency_mode(TransportIdempotencyMode::ExplicitRequired)
    .stream_topics(vec![GOALS_LIFECYCLE_TOPIC])
    .presentation_hints(json!({"systemImage": "checklist"}))
}

fn goal_create_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["objective"],
        "additionalProperties": false,
        "properties": {
            "objective": {"type": "string"},
            "successCriteria": {"type": "array", "items": {"type": "string"}},
            "constraints": {"type": "object"},
            "planRefs": {"type": "array"},
            "evidenceRefs": {"type": "array"},
            "idempotencyKey": {"type": "string"}
        }
    })
}

fn resource_id_schema(field: &'static str) -> serde_json::Value {
    json!({
        "type": "object",
        "required": [field],
        "additionalProperties": false,
        "properties": {field: {"type": "string"}}
    })
}

fn cancel_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["goalResourceId", "reason"],
        "additionalProperties": false,
        "properties": {
            "goalResourceId": {"type": "string"},
            "reason": {"type": "string"},
            "idempotencyKey": {"type": "string"}
        }
    })
}

fn question_create_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["prompt"],
        "additionalProperties": false,
        "properties": {
            "prompt": {"type": "string"},
            "goalResourceId": {"type": "string"},
            "scope": {"type": "object"},
            "answerOptions": {"type": "array", "items": {"type": "string"}},
            "allowFreeForm": {"type": "boolean"},
            "expiresAt": {"type": "string"},
            "idempotencyKey": {"type": "string"}
        }
    })
}

fn question_list_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "state": {"type": "string", "enum": ["pending", "answered", "expired", "cancelled", "archived"]},
            "goalResourceId": {"type": "string"},
            "limit": {"type": "integer", "minimum": 1}
        }
    })
}

fn question_answer_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["questionResourceId", "expectedQuestionVersionId", "text", "reason"],
        "additionalProperties": false,
        "properties": {
            "questionResourceId": {"type": "string"},
            "expectedQuestionVersionId": {"type": "string"},
            "text": {"type": "string"},
            "reason": {"type": "string"},
            "idempotencyKey": {"type": "string"}
        }
    })
}

fn list_schema(states: [&'static str; 3]) -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "state": {"type": "string", "enum": states},
            "limit": {"type": "integer", "minimum": 1}
        }
    })
}

fn goal_response_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["schemaVersion", "status", "goal", "resourceRefs"],
        "additionalProperties": true,
        "properties": {
            "schemaVersion": {"type": "string"},
            "status": {"type": "string"},
            "goal": {"type": "object"},
            "streamCursor": {"type": "integer"},
            "queueRefs": {"type": "array"},
            "resourceRefs": {"type": "array"}
        }
    })
}

fn goal_inspect_response_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["schemaVersion", "status", "goal", "resourceRefs"],
        "additionalProperties": true,
        "properties": {
            "schemaVersion": {"type": "string"},
            "status": {"type": "string"},
            "goal": {"type": "object"},
            "resourceRefs": {"type": "array"}
        }
    })
}

fn question_response_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["schemaVersion", "status", "question", "resourceRefs"],
        "additionalProperties": true,
        "properties": {
            "schemaVersion": {"type": "string"},
            "status": {"type": "string"},
            "question": {"type": "object"},
            "streamCursor": {"type": "integer"},
            "resourceRefs": {"type": "array"}
        }
    })
}

fn question_inspect_response_schema() -> serde_json::Value {
    question_response_schema()
}

fn question_answer_response_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["schemaVersion", "status", "question", "answer", "resourceRefs"],
        "additionalProperties": true,
        "properties": {
            "schemaVersion": {"type": "string"},
            "status": {"type": "string"},
            "question": {"type": "object"},
            "answer": {"type": "object"},
            "streamCursor": {"type": "integer"},
            "resourceRefs": {"type": "array"}
        }
    })
}

fn list_response_schema(field: &'static str) -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["schemaVersion", "status", field, "truncated", "limit"],
        "additionalProperties": false,
        "properties": {
            "schemaVersion": {"type": "string"},
            "status": {"type": "string"},
            field: {"type": "array"},
            "truncated": {"type": "boolean"},
            "limit": {"type": "integer"}
        }
    })
}
