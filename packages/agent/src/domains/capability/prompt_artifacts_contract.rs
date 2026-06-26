use serde_json::{Map, Value, json};

pub(super) fn insert_prompt_artifacts_request_fields(properties: &mut Map<String, Value>) {
    insert_string(
        properties,
        "promptArtifactResourceId",
        "Durable prompt_artifact resource id for prompt_artifact_inspect.",
    );
    insert_string(
        properties,
        "artifactId",
        "Optional caller-visible prompt artifact id for idempotent resource identity.",
    );
    insert_string(
        properties,
        "artifactKind",
        "Required prompt artifact kind for prompt_artifact_record: history_entry, snippet, template, or prompt_reference.",
    );
    insert_string(
        properties,
        "title",
        "Required bounded prompt artifact title; must not include raw prompt or provider-message material.",
    );
    insert_string(
        properties,
        "summary",
        "Optional bounded prompt artifact summary; must not include raw prompt or provider-message material.",
    );
    insert_string(
        properties,
        "preview",
        "Optional bounded redacted prompt artifact preview; must not include raw prompt bodies or provider-message payloads.",
    );
    insert_string(
        properties,
        "contentFingerprint",
        "Required bounded content fingerprint for the prompt artifact body stored elsewhere; never raw prompt text.",
    );
    properties.insert(
        "contentRef".to_owned(),
        json!({"type": "object", "description": "Optional bounded content reference containing only kind plus id/resourceId and optional role/versionId; never raw prompt content."}),
    );
    insert_string(
        properties,
        "retentionState",
        "Optional prompt artifact retention state: active, archival_candidate, or retained.",
    );
}

fn insert_string(properties: &mut Map<String, Value>, name: &str, description: &str) {
    properties.insert(
        name.to_owned(),
        json!({"type": "string", "description": description}),
    );
}
