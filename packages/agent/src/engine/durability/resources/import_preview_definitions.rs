//! Content-free import preview resource definitions.

use serde_json::json;

use super::types::{
    EngineResourceVersioningMode, IMPORT_PREVIEW_KIND, IMPORT_PREVIEW_SCHEMA_ID,
    RegisterResourceType,
};
use crate::engine::kernel::ids::WorkerId;

/// Built-in resource definitions for content-free import previews.
#[must_use]
pub(crate) fn import_preview_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![RegisterResourceType {
        kind: IMPORT_PREVIEW_KIND.to_owned(),
        schema_id: IMPORT_PREVIEW_SCHEMA_ID.to_owned(),
        schema: json!({
            "type": "object",
            "required": [
                "schemaVersion",
                "state",
                "previewId",
                "scope",
                "importHistoryRef",
                "repositoryTreeRef",
                "previewFingerprint",
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
                "previewId": {"type": "string"},
                "scope": {"type": "object"},
                "importHistoryRef": {"type": "object"},
                "repositoryTreeRef": {"type": "object"},
                "repositoryRef": {"type": "object"},
                "rootRef": {"type": "object"},
                "headRef": {"type": "object"},
                "previewFingerprint": {"type": "string"},
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
            "import_history_subject",
            "repository_tree_subject",
            "repository_subject",
            "root_subject",
            "head_subject",
            "preview_fingerprint",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect(),
        default_retention: json!({
            "class": "import_preview_metadata",
            "maxAgeDays": 90,
            "archiveKeepsEvidence": true
        }),
        redaction_rules: json!({
            "preview": "metadata_only",
            "neverReturn": ["rawImportPayload", "rawPreviewPayload", "previewPayload", "importPreview", "repositoryContents", "rawRepositoryContents", "absolutePath", "rootPath", "blobBytes", "fileContents", "diffText", "gitCommand", "commitMessage"],
            "paths": "bounded_normalized_relative_metadata_only"
        }),
        materialization_rules: json!({
            "durableOutputsRequireResourceVersion": true,
            "payloadStoresImportPreviewMetadataOnly": true,
            "rawImportPayloadStored": false,
            "rawPreviewPayloadStored": false,
            "rawRepositoryContentsStored": false,
            "absolutePathsStored": false,
            "contentFreePreview": true,
            "importExecutionPerformed": false,
            "gitMutationPerformed": false
        }),
        required_capabilities: json!({
            "read": ["import_preview.read", "resource.read"],
            "write": ["import_preview.write", "resource.write"],
            "delete": ["import_preview.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("import_preview").expect("valid static worker id"),
    }]
}
