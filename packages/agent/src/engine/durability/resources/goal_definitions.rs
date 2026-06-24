//! Goal/question-owned built-in resource definitions.

use serde_json::json;

use super::types::{
    EngineResourceVersioningMode, GOAL_ANSWER_KIND, GOAL_ANSWER_SCHEMA_ID, RegisterResourceType,
    USER_QUESTION_KIND, USER_QUESTION_SCHEMA_ID,
};
use crate::engine::kernel::ids::WorkerId;

pub(super) fn goal_question_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![user_question_definition(), goal_answer_definition()]
}

fn user_question_definition() -> RegisterResourceType {
    RegisterResourceType {
        kind: USER_QUESTION_KIND.to_owned(),
        schema_id: USER_QUESTION_SCHEMA_ID.to_owned(),
        schema: json!({
            "type": "object",
            "required": [
                "schemaVersion",
                "state",
                "prompt",
                "scope",
                "allowFreeForm",
                "authority",
                "idempotency",
                "traceRefs",
                "replayRefs",
                "createdAt",
                "updatedAt",
                "revision"
            ],
            "additionalProperties": true,
            "properties": {
                "schemaVersion": {"type": "string"},
                "state": {"type": "string", "enum": ["pending", "answered", "expired", "cancelled", "archived"]},
                "prompt": {"type": "string"},
                "goalResourceId": {"type": ["string", "null"]},
                "scope": {"type": "object"},
                "answerOptions": {"type": "array", "items": {"type": "string"}},
                "allowFreeForm": {"type": "boolean"},
                "expiresAt": {"type": ["string", "null"]},
                "answer": {"type": ["object", "null"]},
                "authority": {"type": "object"},
                "idempotency": {"type": "object"},
                "traceRefs": {"type": "array"},
                "replayRefs": {"type": "array"},
                "createdAt": {"type": "string"},
                "updatedAt": {"type": "string"},
                "revision": {"type": "integer"}
            }
        }),
        lifecycle_states: ["pending", "answered", "expired", "cancelled", "archived"]
            .into_iter()
            .map(str::to_owned)
            .collect(),
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        allowed_link_relations: [
            "blocks",
            "answered_by",
            "evidence_for",
            "derived_from",
            "supersedes",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect(),
        default_retention: json!({"class": "project"}),
        redaction_rules: json!({"preview": "bounded_question_summary"}),
        materialization_rules: json!({"durableOutputsRequireResourceVersion": true}),
        required_capabilities: json!({
            "read": ["goals.read", "resource.read"],
            "write": ["goals.write", "resource.write"],
            "answer": ["goals.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("resource").expect("valid static worker id"),
    }
}

fn goal_answer_definition() -> RegisterResourceType {
    RegisterResourceType {
        kind: GOAL_ANSWER_KIND.to_owned(),
        schema_id: GOAL_ANSWER_SCHEMA_ID.to_owned(),
        schema: json!({
            "type": "object",
            "required": [
                "schemaVersion",
                "state",
                "questionResourceId",
                "questionVersionId",
                "text",
                "textPreview",
                "textTruncated",
                "reason",
                "authority",
                "idempotency",
                "traceRefs",
                "replayRefs",
                "createdAt",
                "revision"
            ],
            "additionalProperties": true,
            "properties": {
                "schemaVersion": {"type": "string"},
                "state": {"type": "string", "enum": ["recorded", "archived"]},
                "questionResourceId": {"type": "string"},
                "questionVersionId": {"type": "string"},
                "goalResourceId": {"type": ["string", "null"]},
                "text": {"type": "string"},
                "textPreview": {"type": "string"},
                "textTruncated": {"type": "boolean"},
                "reason": {"type": "string"},
                "authority": {"type": "object"},
                "idempotency": {"type": "object"},
                "traceRefs": {"type": "array"},
                "replayRefs": {"type": "array"},
                "createdAt": {"type": "string"},
                "revision": {"type": "integer"}
            }
        }),
        lifecycle_states: ["recorded", "archived"]
            .into_iter()
            .map(str::to_owned)
            .collect(),
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        allowed_link_relations: ["answers", "evidence_for", "derived_from", "supersedes"]
            .into_iter()
            .map(str::to_owned)
            .collect(),
        default_retention: json!({"class": "project"}),
        redaction_rules: json!({"preview": "bounded_answer_summary"}),
        materialization_rules: json!({"durableOutputsRequireResourceVersion": true}),
        required_capabilities: json!({
            "read": ["goals.read", "resource.read"],
            "write": ["goals.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("resource").expect("valid static worker id"),
    }
}
