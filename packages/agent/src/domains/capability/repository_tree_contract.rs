use serde_json::{Map, Value, json};

pub(super) fn insert_repository_tree_request_fields(properties: &mut Map<String, Value>) {
    insert_string(
        properties,
        "repositoryTreeResourceId",
        "Durable repository_tree_snapshot resource id for repository_tree_inspect.",
    );
    insert_string(
        properties,
        "snapshotId",
        "Optional caller-visible snapshot id for repository_tree_snapshot idempotent resource identity.",
    );
    properties.insert(
        "repositoryRef".to_owned(),
        json!({"type": "object", "description": "Bounded repository reference for repository_tree_snapshot; contains only kind plus id/resourceId and optional role/versionId."}),
    );
    properties.insert(
        "rootRef".to_owned(),
        json!({"type": "object", "description": "Bounded workspace/repository-root reference for repository_tree_snapshot; contains only kind plus id/resourceId and optional role/versionId."}),
    );
    properties.insert(
        "headRef".to_owned(),
        json!({"type": "object", "description": "Optional bounded commit/head reference for repository_tree_snapshot metadata only."}),
    );
    insert_string(
        properties,
        "treeObjectRef",
        "Bounded tree object or snapshot fingerprint token for repository_tree_snapshot; never raw tree contents.",
    );
    properties.insert(
        "pathEntries".to_owned(),
        json!({"type": "array", "description": "Optional bounded normalized relative path metadata for repository_tree_snapshot; entries may contain path, kind, mode, objectRef, contentHash, and sizeBytes only."}),
    );
    for field in [
        "totalEntries",
        "fileCount",
        "directoryCount",
        "symlinkCount",
        "submoduleCount",
        "maxDepth",
    ] {
        properties.insert(
            field.to_owned(),
            json!({"type": "integer", "description": "Optional bounded aggregate repository tree count metadata."}),
        );
    }
    insert_string(
        properties,
        "repositoryRefId",
        "Optional bounded repository ref id filter for repository_tree_list.",
    );
    insert_string(
        properties,
        "snapshotLabel",
        "Optional bounded short label for repository_tree_snapshot metadata.",
    );
    insert_string(
        properties,
        "snapshotSummary",
        "Optional bounded summary for repository_tree_snapshot metadata.",
    );
}

fn insert_string(properties: &mut Map<String, Value>, name: &str, description: &str) {
    properties.insert(
        name.to_owned(),
        json!({"type": "string", "description": description}),
    );
}
