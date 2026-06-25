//! Content-free repository tree snapshot resource definitions.

use serde_json::json;

use super::types::{
    EngineResourceVersioningMode, REPOSITORY_TREE_SNAPSHOT_KIND,
    REPOSITORY_TREE_SNAPSHOT_SCHEMA_ID, RegisterResourceType,
};
use crate::engine::kernel::ids::WorkerId;

/// Built-in resource definitions for content-free repository tree snapshots.
#[must_use]
pub(crate) fn repository_tree_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![RegisterResourceType {
        kind: REPOSITORY_TREE_SNAPSHOT_KIND.to_owned(),
        schema_id: REPOSITORY_TREE_SNAPSHOT_SCHEMA_ID.to_owned(),
        schema: json!({
            "type": "object",
            "required": [
                "schemaVersion",
                "state",
                "snapshotId",
                "scope",
                "repositoryRef",
                "rootRef",
                "treeObjectRef",
                "counts",
                "pathEntries",
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
                "snapshotId": {"type": "string"},
                "scope": {"type": "object"},
                "repositoryRef": {"type": "object"},
                "rootRef": {"type": "object"},
                "headRef": {"type": "object"},
                "treeObjectRef": {"type": "string"},
                "counts": {"type": "object"},
                "pathEntries": {"type": "array"},
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
            "repository_subject",
            "root_subject",
            "head_subject",
            "tree_object",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect(),
        default_retention: json!({
            "class": "repository_tree_metadata",
            "maxAgeDays": 90,
            "archiveKeepsEvidence": true
        }),
        redaction_rules: json!({
            "preview": "metadata_only",
            "neverReturn": ["rawImportPayload", "repositoryTree", "repositoryContents", "rawRepositoryContents", "absolutePath", "rootPath", "blobBytes", "fileContents", "diffText"],
            "paths": "bounded_normalized_relative_metadata_only"
        }),
        materialization_rules: json!({
            "durableOutputsRequireResourceVersion": true,
            "payloadStoresRepositoryTreeMetadataOnly": true,
            "rawImportPayloadStored": false,
            "rawRepositoryContentsStored": false,
            "absolutePathsStored": false,
            "contentFreeSnapshot": true
        }),
        required_capabilities: json!({
            "read": ["repository_tree.read", "resource.read"],
            "write": ["repository_tree.write", "resource.write"],
            "delete": ["repository_tree.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("repository_tree").expect("valid static worker id"),
    }]
}
