//! Subagent/delegation task resource definitions.

use serde_json::json;

use super::types::{
    EngineResourceVersioningMode, RegisterResourceType, SUBAGENT_TASK_KIND, SUBAGENT_TASK_SCHEMA_ID,
};
use crate::engine::kernel::ids::WorkerId;

pub(super) fn subagent_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![RegisterResourceType {
        kind: SUBAGENT_TASK_KIND.to_owned(),
        schema_id: SUBAGENT_TASK_SCHEMA_ID.to_owned(),
        schema: json!({
            "type": "object",
            "required": [
                "schemaVersion",
                "state",
                "taskId",
                "parent",
                "scope",
                "objectiveSummary",
                "promptSummary",
                "createdAt",
                "updatedAt",
                "refs",
                "activation",
                "network",
                "revision"
            ],
            "additionalProperties": true,
            "properties": {
                "schemaVersion": {"type": "string"},
                "state": {"type": "string", "enum": ["requested", "queued", "running", "succeeded", "failed", "cancelled", "archived"]},
                "taskId": {"type": "string"},
                "parent": {"type": "object"},
                "scope": {"type": "object"},
                "objectiveSummary": {"type": "string"},
                "promptSummary": {"type": "string"},
                "createdAt": {"type": "string"},
                "updatedAt": {"type": "string"},
                "refs": {"type": "object"},
                "result": {"type": ["object", "null"]},
                "error": {"type": ["object", "null"]},
                "authority": {"type": "object"},
                "activation": {"type": "object"},
                "network": {"type": "object"},
                "redaction": {"type": "object"},
                "limits": {"type": "object"},
                "idempotency": {"type": "object"},
                "revision": {"type": "integer"}
            }
        }),
        lifecycle_states: [
            "requested",
            "queued",
            "running",
            "succeeded",
            "failed",
            "cancelled",
            "archived",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect(),
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        allowed_link_relations: [
            "parent_session",
            "parent_trace",
            "evidence_for",
            "derived_from",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect(),
        default_retention: json!({"class": "subagent_task_lifecycle"}),
        redaction_rules: json!({"preview": "summary_only", "rawPrompt": "not_persisted"}),
        materialization_rules: json!({"durableOutputsRequireResourceVersion": true}),
        required_capabilities: json!({
            "read": ["subagents.read", "resource.read"],
            "write": ["subagents.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("subagents").expect("valid static worker id"),
    }]
}
