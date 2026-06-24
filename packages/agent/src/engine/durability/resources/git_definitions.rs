//! Git-owned built-in resource definitions.

use serde_json::json;

use super::types::{
    EngineResourceVersioningMode, GIT_INDEX_CHANGE_KIND, GIT_INDEX_CHANGE_SCHEMA_ID,
    RegisterResourceType,
};
use crate::engine::kernel::ids::WorkerId;

pub(super) fn git_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![RegisterResourceType {
        kind: GIT_INDEX_CHANGE_KIND.to_owned(),
        schema_id: GIT_INDEX_CHANGE_SCHEMA_ID.to_owned(),
        schema: json!({
            "type": "object",
            "required": [
                "schemaVersion",
                "operation",
                "state",
                "repository",
                "path",
                "expectedHead",
                "headOid",
                "reason",
                "authority",
                "before",
                "after",
                "evidence",
                "traceRefs",
                "replayRefs",
                "idempotency",
                "revision",
                "createdAt"
            ],
            "additionalProperties": true,
            "properties": {
                "schemaVersion": {"type": "string"},
                "operation": {"type": "string", "enum": ["stage", "unstage"]},
                "state": {"type": "string", "enum": ["committed", "archived"]},
                "repository": {"type": "object"},
                "path": {"type": "object"},
                "expectedHead": {"type": "string"},
                "headOid": {"type": "string"},
                "reason": {"type": "string"},
                "authority": {"type": "object"},
                "before": {"type": "object"},
                "after": {"type": "object"},
                "evidence": {"type": "object"},
                "traceRefs": {"type": "array"},
                "replayRefs": {"type": "array"},
                "idempotency": {"type": "object"},
                "revision": {"type": "integer"},
                "createdAt": {"type": "string"}
            }
        }),
        lifecycle_states: ["committed", "archived"]
            .into_iter()
            .map(str::to_owned)
            .collect(),
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        allowed_link_relations: ["evidence_for", "derived_from", "supersedes"]
            .into_iter()
            .map(str::to_owned)
            .collect(),
        default_retention: json!({"class": "project"}),
        redaction_rules: json!({"preview": "metadata_only"}),
        materialization_rules: json!({"durableOutputsRequireResourceVersion": true}),
        required_capabilities: json!({
            "read": ["git.read", "resource.read"],
            "write": ["git.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("resource").expect("valid static worker id"),
    }]
}
