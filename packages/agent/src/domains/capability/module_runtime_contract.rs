use serde_json::{Map, json};

#[cfg(test)]
pub(super) const MODULE_RUNTIME_SCHEMA_FIELDS: &[&str] = &[
    "moduleRuntimeResourceId",
    "moduleLifecycleResourceId",
    "expectedModuleRuntimeVersionId",
    "runtimeRequestId",
    "runtimeKind",
    "runtimeLabel",
    "runtimeState",
    "inputRefs",
    "outputArtifactRefs",
    "timeoutMs",
];

pub(super) fn insert_module_runtime_request_fields(
    properties: &mut Map<String, serde_json::Value>,
) {
    properties.insert(
        "moduleRuntimeResourceId".to_owned(),
        json!({"type": "string", "description": "Exact module_runtime_state resource id for runtime inspect or cancel."}),
    );
    properties.insert(
        "moduleLifecycleResourceId".to_owned(),
        json!({"type": "string", "description": "Exact enabled module_lifecycle_state resource id required before module_runtime_request proceeds."}),
    );
    properties.insert(
        "expectedModuleRuntimeVersionId".to_owned(),
        json!({"type": "string", "description": "Expected current module_runtime_state version id for runtime cancel freshness."}),
    );
    properties.insert(
        "runtimeRequestId".to_owned(),
        json!({"type": "string", "description": "Required bounded provider-visible runtime request id used to derive the runtime resource id."}),
    );
    properties.insert(
        "runtimeKind".to_owned(),
        json!({"type": "string", "description": "Bounded runtime envelope kind label; not a command, interpreter, or package-manager directive."}),
    );
    properties.insert(
        "runtimeLabel".to_owned(),
        json!({"type": "string", "description": "Bounded human-readable runtime envelope label without raw commands, paths, secrets, or logs."}),
    );
    properties.insert(
        "runtimeState".to_owned(),
        json!({"type": "string", "description": "Initial supervised runtime metadata state for module_runtime_request: requested, running, completed, or failed."}),
    );
    properties.insert(
        "inputRefs".to_owned(),
        json!({"type": "array", "description": "Bounded resource-backed input refs; raw input, code, stdin, prompts, paths, and file contents are forbidden."}),
    );
    properties.insert(
        "outputArtifactRefs".to_owned(),
        json!({"type": "array", "description": "Bounded output artifact refs only; raw stdout, stderr, logs, commands, and file contents are forbidden."}),
    );
    properties.insert(
        "timeoutMs".to_owned(),
        json!({"type": "integer", "minimum": 1, "maximum": 120000, "description": "Bounded supervision timeout metadata for module_runtime_request."}),
    );
}
