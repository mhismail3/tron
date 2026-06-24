//! Goal/question built-in resource definitions.

use serde_json::json;

use super::types::{
    EngineResourceVersioningMode, GOAL_ANSWER_KIND, GOAL_ANSWER_SCHEMA_ID, RegisterResourceType,
    USER_QUESTION_KIND, USER_QUESTION_SCHEMA_ID,
};
use crate::engine::kernel::ids::WorkerId;

pub(super) fn goal_question_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![
        RegisterResourceType {
            kind: "goal".to_owned(),
            schema_id: "tron.resource.goal.v1".to_owned(),
            schema: json!({
                "type": "object",
                "required": ["intent"],
                "additionalProperties": true,
                "properties": {
                    "intent": {"type": "string"},
                    "successCriteria": {"type": "array", "items": {"type": "string"}},
                    "inputResources": {"type": "array", "items": {"type": "string"}},
                    "expectedOutputKinds": {"type": "array", "items": {"type": "string"}},
                    "objective": {"type": "string"},
                    "owner": {"type": "object"},
                    "scope": {"type": "object"},
                    "constraints": {"type": "object"},
                    "queueRefs": {"type": "array"},
                    "planRefs": {"type": "array"},
                    "evidenceRefs": {"type": "array"},
                    "traceRefs": {"type": "array"},
                    "replayRefs": {"type": "array"},
                    "createdAt": {"type": "string"},
                    "updatedAt": {"type": "string"},
                    "cancellation": {"type": ["object", "null"]},
                    "revision": {"type": "integer"},
                    "riskBudget": {"type": "object"},
                    "authorityPolicy": {"type": "object"},
                    "retentionPolicy": {"type": "object"},
                    "completionCondition": {"type": "string"}
                }
            }),
            lifecycle_states: [
                "open",
                "in_progress",
                "completed",
                "failed",
                "cancelled",
                "archived",
            ]
            .into_iter()
            .map(str::to_owned)
            .collect(),
            versioning_mode: EngineResourceVersioningMode::AppendOnly,
            allowed_link_relations: [
                "input",
                "subgoal",
                "produced",
                "produces",
                "candidate_output",
                "promoted_output",
                "decided_by",
                "supported_by",
                "contradicted_by",
                "supersedes",
                "derived_from",
                "blocks",
                "answered_by",
            ]
            .into_iter()
            .map(str::to_owned)
            .collect(),
            default_retention: json!({"class": "project"}),
            redaction_rules: json!({"summary": true}),
            materialization_rules: json!({}),
            required_capabilities: json!({
                "read": ["resource.read"],
                "write": ["resource.write"],
                "complete": ["resource.write"]
            }),
            owner_worker_id: WorkerId::new("resource").expect("valid static worker id"),
        },
        RegisterResourceType {
            kind: USER_QUESTION_KIND.to_owned(),
            schema_id: USER_QUESTION_SCHEMA_ID.to_owned(),
            schema: json!({
                "type": "object",
                "required": [
                    "schemaVersion",
                    "state",
                    "prompt",
                    "requester",
                    "scope",
                    "createdAt",
                    "queueRefs",
                    "evidenceRefs",
                    "traceRefs",
                    "replayRefs",
                    "revision"
                ],
                "additionalProperties": true,
                "properties": {
                    "schemaVersion": {"type": "string"},
                    "state": {"type": "string", "enum": ["pending", "answered", "expired", "cancelled"]},
                    "prompt": {"type": "string"},
                    "requester": {"type": "object"},
                    "scope": {"type": "object"},
                    "goalRef": {"type": ["object", "null"]},
                    "options": {"type": "array"},
                    "allowFreeForm": {"type": "boolean"},
                    "expiresAt": {"type": ["string", "null"]},
                    "createdAt": {"type": "string"},
                    "answeredAt": {"type": ["string", "null"]},
                    "cancelledAt": {"type": ["string", "null"]},
                    "answer": {"type": ["object", "null"]},
                    "queueRefs": {"type": "array"},
                    "evidenceRefs": {"type": "array"},
                    "traceRefs": {"type": "array"},
                    "replayRefs": {"type": "array"},
                    "revision": {"type": "integer"}
                }
            }),
            lifecycle_states: ["pending", "answered", "expired", "cancelled", "archived"]
                .into_iter()
                .map(str::to_owned)
                .collect(),
            versioning_mode: EngineResourceVersioningMode::AppendOnly,
            allowed_link_relations: ["blocks", "answered_by", "evidence_for", "derived_from"]
                .into_iter()
                .map(str::to_owned)
                .collect(),
            default_retention: json!({"class": "project"}),
            redaction_rules: json!({"preview": "bounded_prompt_and_answer_refs"}),
            materialization_rules: json!({"durableOutputsRequireResourceVersion": true}),
            required_capabilities: json!({
                "read": ["goals.read", "resource.read"],
                "write": ["goals.write", "resource.write"],
                "answer": ["goals.write", "resource.write"]
            }),
            owner_worker_id: WorkerId::new("resource").expect("valid static worker id"),
        },
        RegisterResourceType {
            kind: GOAL_ANSWER_KIND.to_owned(),
            schema_id: GOAL_ANSWER_SCHEMA_ID.to_owned(),
            schema: json!({
                "type": "object",
                "required": [
                    "schemaVersion",
                    "questionResourceId",
                    "questionVersionId",
                    "answerText",
                    "actor",
                    "reason",
                    "authority",
                    "freshness",
                    "unblocksGoal",
                    "evidenceRefs",
                    "traceRefs",
                    "replayRefs",
                    "idempotency",
                    "answeredAt",
                    "revision"
                ],
                "additionalProperties": true,
                "properties": {
                    "schemaVersion": {"type": "string"},
                    "questionResourceId": {"type": "string"},
                    "questionVersionId": {"type": "string"},
                    "goalRef": {"type": ["object", "null"]},
                    "answerText": {"type": "string"},
                    "answerTextTruncated": {"type": "boolean"},
                    "actor": {"type": "object"},
                    "reason": {"type": "string"},
                    "authority": {"type": "object"},
                    "freshness": {"type": "object"},
                    "unblocksGoal": {"type": "boolean"},
                    "evidenceRefs": {"type": "array"},
                    "traceRefs": {"type": "array"},
                    "replayRefs": {"type": "array"},
                    "idempotency": {"type": "object"},
                    "answeredAt": {"type": "string"},
                    "revision": {"type": "integer"}
                }
            }),
            lifecycle_states: ["recorded", "archived"]
                .into_iter()
                .map(str::to_owned)
                .collect(),
            versioning_mode: EngineResourceVersioningMode::AppendOnly,
            allowed_link_relations: ["answer_for", "unblocks", "evidence_for", "derived_from"]
                .into_iter()
                .map(str::to_owned)
                .collect(),
            default_retention: json!({"class": "project"}),
            redaction_rules: json!({"preview": "bounded_answer_text"}),
            materialization_rules: json!({"durableOutputsRequireResourceVersion": true}),
            required_capabilities: json!({
                "read": ["goals.read", "resource.read"],
                "write": ["goals.write", "resource.write"]
            }),
            owner_worker_id: WorkerId::new("resource").expect("valid static worker id"),
        },
    ]
}
