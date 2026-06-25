use serde_json::{Map, Value, json};

pub(super) fn insert_import_preview_request_fields(properties: &mut Map<String, Value>) {
    insert_string(
        properties,
        "importPreviewResourceId",
        "Durable import_preview resource id for import_preview_inspect.",
    );
    insert_string(
        properties,
        "previewId",
        "Optional caller-visible preview id for import_preview_record idempotent resource identity.",
    );
    properties.insert(
        "importHistoryRef".to_owned(),
        json!({"type": "object", "description": "Required bounded import_history_record/resource-graph reference for import_preview_record; contains only kind plus id/resourceId and optional role/versionId."}),
    );
    properties.insert(
        "repositoryTreeRef".to_owned(),
        json!({"type": "object", "description": "Required bounded repository_tree_snapshot reference for import_preview_record; contains only kind plus id/resourceId and optional role/versionId."}),
    );
    properties.insert(
        "repositoryRef".to_owned(),
        json!({"type": "object", "description": "Optional bounded repository reference for import_preview_record; contains only kind plus id/resourceId and optional role/versionId."}),
    );
    properties.insert(
        "rootRef".to_owned(),
        json!({"type": "object", "description": "Optional bounded workspace/repository-root reference for import_preview_record; contains only kind plus id/resourceId and optional role/versionId."}),
    );
    properties.insert(
        "headRef".to_owned(),
        json!({"type": "object", "description": "Optional bounded commit/head reference for import_preview_record metadata only."}),
    );
    insert_string(
        properties,
        "previewFingerprint",
        "Bounded import preview fingerprint token for import_preview_record; never raw preview payload or repository contents.",
    );
    properties.insert(
        "pathEntries".to_owned(),
        json!({"type": "array", "description": "Optional bounded normalized relative path metadata for import_preview_record; entries may contain path, kind, mode, objectRef, contentHash, changeKind, and sizeBytes only."}),
    );
    for field in [
        "totalEntries",
        "addedEntries",
        "modifiedEntries",
        "removedEntries",
        "renamedEntries",
        "maxDepth",
    ] {
        properties.insert(
            field.to_owned(),
            json!({"type": "integer", "description": "Optional bounded aggregate import preview count metadata."}),
        );
    }
    insert_string(
        properties,
        "repositoryRefId",
        "Optional bounded repository ref id filter for import_preview_list.",
    );
    insert_string(
        properties,
        "importHistoryRefId",
        "Optional bounded import_history_record ref id filter for import_preview_list.",
    );
    insert_string(
        properties,
        "repositoryTreeRefId",
        "Optional bounded repository_tree_snapshot ref id filter for import_preview_list.",
    );
    insert_string(
        properties,
        "previewLabel",
        "Optional bounded short label for import_preview_record metadata.",
    );
    insert_string(
        properties,
        "previewSummary",
        "Optional bounded summary for import_preview_record metadata.",
    );
    insert_string(
        properties,
        "changeSummary",
        "Optional bounded change summary for import_preview_record metadata.",
    );
}

fn insert_string(properties: &mut Map<String, Value>, name: &str, description: &str) {
    properties.insert(
        name.to_owned(),
        json!({"type": "string", "description": description}),
    );
}
