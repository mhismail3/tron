//! Import/session-resource graph lineage resource definitions.

use serde_json::json;

use super::types::{
    EngineResourceVersioningMode, IMPORT_HISTORY_RECORD_KIND, IMPORT_HISTORY_RECORD_SCHEMA_ID,
    RegisterResourceType,
};
use crate::engine::kernel::ids::WorkerId;

/// Built-in resource definitions for import/session-resource graph lineage.
#[must_use]
pub(crate) fn import_history_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![RegisterResourceType {
        kind: IMPORT_HISTORY_RECORD_KIND.to_owned(),
        schema_id: IMPORT_HISTORY_RECORD_SCHEMA_ID.to_owned(),
        schema: json!({
            "type": "object",
            "required": [
                "schemaVersion",
                "state",
                "recordId",
                "graphKind",
                "scope",
                "subjectRef",
                "parentRefs",
                "childRefs",
                "createdAt",
                "updatedAt",
                "retention",
                "metadata",
                "refs",
                "traceRefs",
                "replayRefs",
                "authority",
                "idempotency",
                "revision"
            ],
            "additionalProperties": true,
            "properties": {
                "schemaVersion": {"type": "string"},
                "state": {"type": "string", "enum": ["active", "archived"]},
                "recordId": {"type": "string"},
                "graphKind": {"type": "string", "enum": ["session_resource"]},
                "scope": {"type": "object"},
                "subjectRef": {"type": "object"},
                "parentRefs": {"type": "array"},
                "childRefs": {"type": "array"},
                "createdAt": {"type": "string"},
                "updatedAt": {"type": "string"},
                "retention": {"type": "object"},
                "metadata": {"type": "object"},
                "refs": {"type": "object"},
                "traceRefs": {"type": "array"},
                "replayRefs": {"type": "array"},
                "authority": {"type": "object"},
                "idempotency": {"type": "object"},
                "revision": {"type": "integer"}
            }
        }),
        lifecycle_states: ["active", "archived"]
            .into_iter()
            .map(str::to_owned)
            .collect(),
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        allowed_link_relations: [
            "source",
            "evidence_for",
            "derived_from",
            "parent_of",
            "child_of",
            "session_subject",
            "resource_subject",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect(),
        default_retention: json!({
            "class": "import_lineage_metadata",
            "maxAgeDays": 90,
            "archiveKeepsEvidence": true
        }),
        redaction_rules: json!({
            "preview": "metadata_only",
            "neverReturn": ["rawImportPayload", "repositoryTree", "repositoryContents", "paths", "diffText"],
            "lineage": "bounded_refs_only"
        }),
        materialization_rules: json!({
            "durableOutputsRequireResourceVersion": true,
            "payloadStoresGraphRefsOnly": true,
            "rawImportPayloadStored": false,
            "genericGraphOnly": true
        }),
        required_capabilities: json!({
            "read": ["import_history.read", "resource.read"],
            "write": ["import_history.write", "resource.write"],
            "delete": ["import_history.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("import_history").expect("valid static worker id"),
    }]
}
