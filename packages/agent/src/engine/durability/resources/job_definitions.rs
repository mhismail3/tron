//! Job-owned built-in resource definitions.

use serde_json::json;

use super::types::{
    EngineResourceVersioningMode, JOB_PROCESS_KIND, JOB_PROCESS_SCHEMA_ID, RegisterResourceType,
};
use crate::engine::kernel::ids::WorkerId;

pub(super) fn job_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![RegisterResourceType {
        kind: JOB_PROCESS_KIND.to_owned(),
        schema_id: JOB_PROCESS_SCHEMA_ID.to_owned(),
        schema: json!({
            "type": "object",
            "required": [
                "schemaVersion",
                "state",
                "command",
                "authority",
                "limits",
                "retention",
                "createdAt",
                "startedAt",
                "traceRefs",
                "replayRefs",
                "revision"
            ],
            "additionalProperties": true,
            "properties": {
                "schemaVersion": {"type": "string"},
                "state": {"type": "string", "enum": ["running", "completed", "failed", "timed_out", "cancelled", "archived"]},
                "command": {"type": "object"},
                "authority": {"type": "object"},
                "limits": {"type": "object"},
                "retention": {"type": "object"},
                "createdAt": {"type": "string"},
                "startedAt": {"type": "string"},
                "completedAt": {"type": ["string", "null"]},
                "cancellation": {"type": "object"},
                "terminal": {"type": ["object", "null"]},
                "output": {"type": ["object", "null"]},
                "traceRefs": {"type": "array"},
                "replayRefs": {"type": "array"},
                "revision": {"type": "integer"}
            }
        }),
        lifecycle_states: [
            "running",
            "completed",
            "failed",
            "timed_out",
            "cancelled",
            "archived",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect(),
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        allowed_link_relations: [
            "produced",
            "produced_output",
            "derived_from",
            "evidence_for",
            "supersedes",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect(),
        default_retention: json!({"class": "project"}),
        redaction_rules: json!({"preview": "metadata_only"}),
        materialization_rules: json!({"durableOutputsRequireResourceVersion": true}),
        required_capabilities: json!({
            "read": ["jobs.read", "resource.read"],
            "write": ["jobs.write", "resource.write"],
            "cancel": ["jobs.write", "resource.write"],
            "cleanup": ["jobs.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("resource").expect("valid static worker id"),
    }]
}
