use super::*;

pub(super) fn register_type_schema() -> Value {
    json!({
        "type": "object",
        "required": ["kind", "schemaId", "lifecycleStates"],
        "additionalProperties": false,
        "properties": {
            "kind": {"type": "string"},
            "schemaId": {"type": "string"},
            "schema": {"type": "object"},
            "lifecycleStates": {"type": "array", "items": {"type": "string"}, "minItems": 1},
            "versioningMode": {"type": "string", "enum": ["append_only", "current_pointer"]},
            "allowedLinkRelations": {"type": "array", "items": {"type": "string"}},
            "defaultRetention": {"type": "object"},
            "redactionRules": {"type": "object"},
            "materializationRules": {"type": "object"},
            "requiredCapabilities": {"type": "object"},
            "ownerWorkerId": {"type": "string"}
        }
    })
}

pub(super) fn create_schema() -> Value {
    json!({
        "type": "object",
        "required": ["kind"],
        "additionalProperties": false,
        "properties": resource_properties(true)
    })
}

pub(super) fn update_schema() -> Value {
    json!({
        "type": "object",
        "required": ["resourceId", "payload"],
        "additionalProperties": false,
        "properties": {
            "resourceId": {"type": "string"},
            "expectedCurrentVersionId": expected_current_version_id_property(),
            "lifecycle": {"type": "string"},
            "payload": {},
            "locations": locations_schema()
        }
    })
}

pub(super) fn link_schema() -> Value {
    json!({
        "type": "object",
        "required": ["sourceResourceId", "targetResourceId", "relation"],
        "additionalProperties": false,
        "properties": {
            "sourceResourceId": {"type": "string"},
            "targetResourceId": {"type": "string"},
            "relation": {"type": "string"},
            "metadata": {"type": "object"}
        }
    })
}

pub(super) fn list_schema() -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "kind": {"type": "string"},
            "scope": {"type": "string", "enum": ["system", "workspace", "session"]},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"},
            "lifecycle": {"type": "string"},
            "limit": {"type": "integer"}
        }
    })
}

pub(super) fn wrapper_lifecycle_schema() -> Value {
    json!({
        "type": "object",
        "required": ["resourceId"],
        "additionalProperties": false,
        "properties": {
            "resourceId": {"type": "string"},
            "expectedCurrentVersionId": expected_current_version_id_property()
        }
    })
}

pub(super) fn expected_current_version_id_property() -> Value {
    json!({
        "type": "string",
        "description": "Optional CAS guard; use expectedCurrentVersionId, not versionId, with a prior result's version.versionId, resourceRefs[].versionId, or inspect.resource.currentVersionId."
    })
}

pub(super) fn resource_refs_schema() -> Value {
    json!({
        "type": "array",
        "items": {
            "type": "object",
            "required": ["resourceId", "kind", "role"],
            "additionalProperties": false,
            "properties": {
                "resourceId": {"type": "string"},
                "kind": {"type": "string"},
                "versionId": {"type": "string"},
                "role": {"type": "string"},
                "contentHash": {"type": "string"},
                "relation": {"type": "string"}
            }
        }
    })
}

pub(super) fn materialized_file_create_schema() -> Value {
    json!({
        "type": "object",
        "required": ["path", "content"],
        "additionalProperties": false,
        "properties": {
            "resourceId": {"type": "string"},
            "path": {"type": "string"},
            "content": {"type": "string"},
            "contentHash": {"type": "string"},
            "scope": {"type": "string", "enum": ["system", "workspace", "session"]},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"},
            "policy": {"type": "object"}
        }
    })
}

pub(super) fn materialized_file_update_schema() -> Value {
    json!({
        "type": "object",
        "required": ["path", "content"],
        "additionalProperties": false,
        "properties": {
            "resourceId": {"type": "string"},
            "expectedCurrentVersionId": expected_current_version_id_property(),
            "path": {"type": "string"},
            "content": {"type": "string"},
            "contentHash": {"type": "string"},
            "scope": {"type": "string", "enum": ["system", "workspace", "session"]},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"},
            "policy": {"type": "object"}
        }
    })
}

pub(super) fn patch_propose_schema() -> Value {
    json!({
        "type": "object",
        "required": ["targetPath", "diff"],
        "additionalProperties": false,
        "properties": {
            "resourceId": {"type": "string"},
            "targetPath": {"type": "string"},
            "targetResourceId": {"type": "string"},
            "baseVersionId": {"type": "string"},
            "baseContentHash": {"type": "string"},
            "diff": {"type": "string"},
            "result": {"type": "object"},
            "scope": {"type": "string", "enum": ["system", "workspace", "session"]},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"},
            "policy": {"type": "object"}
        }
    })
}

pub(super) fn patch_apply_schema() -> Value {
    json!({
        "type": "object",
        "required": ["patchResourceId", "content"],
        "additionalProperties": false,
        "properties": {
            "patchResourceId": {"type": "string"},
            "targetResourceId": {"type": "string"},
            "content": {"type": "string"}
        }
    })
}

pub(super) fn resource_properties(include_creation: bool) -> Value {
    let mut properties = serde_json::Map::new();
    if include_creation {
        properties.insert("resourceId".to_owned(), json!({"type": "string"}));
        properties.insert("kind".to_owned(), json!({"type": "string"}));
        properties.insert("schemaId".to_owned(), json!({"type": "string"}));
        properties.insert("ownerWorkerId".to_owned(), json!({"type": "string"}));
    }
    properties.insert(
        "scope".to_owned(),
        json!({"type": "string", "enum": ["system", "workspace", "session"]}),
    );
    properties.insert("sessionId".to_owned(), json!({"type": "string"}));
    properties.insert("workspaceId".to_owned(), json!({"type": "string"}));
    properties.insert("lifecycle".to_owned(), json!({"type": "string"}));
    properties.insert("policy".to_owned(), json!({"type": "object"}));
    properties.insert("payload".to_owned(), json!({}));
    properties.insert("locations".to_owned(), locations_schema());
    Value::Object(properties)
}

pub(super) fn locations_schema() -> Value {
    json!({
        "type": "array",
        "items": {
            "type": "object",
            "required": ["kind", "uri"],
            "additionalProperties": false,
            "properties": {
                "kind": {"type": "string"},
                "uri": {"type": "string"},
                "mimeType": {"type": "string"},
                "sizeBytes": {"type": "integer"}
            }
        }
    })
}
