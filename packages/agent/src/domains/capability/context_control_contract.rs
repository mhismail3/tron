use serde_json::{Map, json};

#[cfg(test)]
pub(super) const CONTEXT_CONTROL_SCHEMA_FIELDS: &[&str] = &[
    "contextControlActionResourceId",
    "contextControlSnapshotResourceId",
    "expectedContextControlActionVersionId",
    "contextActionReason",
];

pub(super) fn insert_context_control_fields(properties: &mut Map<String, serde_json::Value>) {
    properties.insert(
        "contextControlActionResourceId".to_owned(),
        json!({"type": "string", "description": "Exact context_control_action resource id for context_control_action_inspect."}),
    );
    properties.insert(
        "contextControlSnapshotResourceId".to_owned(),
        json!({"type": "string", "description": "Returned context_control_snapshot resource id from context_control_snapshot or a compact/clear preflight; inspect raw snapshot payloads only through provider-safe projections."}),
    );
    properties.insert(
        "expectedContextControlActionVersionId".to_owned(),
        json!({"type": "string", "description": "Optional current context_control_action version id for UI freshness checks."}),
    );
    properties.insert(
        "contextActionReason".to_owned(),
        json!({"type": "string", "maxLength": 500, "description": "Bounded reason text for context_control_compact or context_control_clear; raw prompts, paths, commands, logs, secrets, and system prompt bodies are forbidden."}),
    );
}
