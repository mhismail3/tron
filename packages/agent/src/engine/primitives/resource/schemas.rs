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

pub(super) fn wrapper_create_schema() -> Value {
    json!({
        "type": "object",
        "required": ["payload"],
        "additionalProperties": false,
        "properties": {
            "resourceId": {"type": "string"},
            "scope": {"type": "string", "enum": ["system", "workspace", "session"]},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"},
            "lifecycle": {"type": "string"},
            "policy": {"type": "object"},
            "payload": {},
            "locations": locations_schema()
        }
    })
}

pub(super) fn wrapper_update_schema() -> Value {
    json!({
        "type": "object",
        "required": ["resourceId", "payload"],
        "additionalProperties": false,
        "properties": {
            "resourceId": {"type": "string"},
            "expectedCurrentVersionId": expected_current_version_id_property(),
            "payload": {},
            "locations": locations_schema()
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

pub(super) fn artifact_split_schema() -> Value {
    json!({
        "type": "object",
        "required": ["resourceId", "parts"],
        "additionalProperties": false,
        "properties": {
            "resourceId": {"type": "string"},
            "scope": {"type": "string", "enum": ["system", "workspace", "session"]},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"},
            "lifecycle": {"type": "string"},
            "policy": {"type": "object"},
            "parts": {"type": "array", "items": {"type": "object"}, "minItems": 1}
        }
    })
}

pub(super) fn artifact_compose_schema() -> Value {
    json!({
        "type": "object",
        "required": ["inputResourceIds", "payload"],
        "additionalProperties": false,
        "properties": {
            "inputResourceIds": {"type": "array", "items": {"type": "string"}, "minItems": 1},
            "resourceId": {"type": "string"},
            "scope": {"type": "string", "enum": ["system", "workspace", "session"]},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"},
            "lifecycle": {"type": "string"},
            "policy": {"type": "object"},
            "payload": {},
            "locations": locations_schema()
        }
    })
}

pub(super) fn artifact_merge_schema() -> Value {
    json!({
        "type": "object",
        "required": ["targetResourceId", "sourceResourceIds", "payload"],
        "additionalProperties": false,
        "properties": {
            "targetResourceId": {"type": "string"},
            "sourceResourceIds": {"type": "array", "items": {"type": "string"}},
            "expectedCurrentVersionId": expected_current_version_id_property(),
            "lifecycle": {"type": "string"},
            "payload": {},
            "locations": locations_schema()
        }
    })
}

pub(super) fn artifact_search_schema() -> Value {
    json!({
        "type": "object",
        "required": ["query"],
        "additionalProperties": false,
        "properties": {
            "query": {"type": "string"},
            "scope": {"type": "string", "enum": ["system", "workspace", "session"]},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"},
            "limit": {"type": "integer"}
        }
    })
}

pub(super) fn goal_complete_schema() -> Value {
    json!({
        "type": "object",
        "required": ["goalResourceId", "agentResultResourceId", "promotedResourceIds", "decision"],
        "additionalProperties": false,
        "properties": {
            "goalResourceId": {"type": "string"},
            "agentResultResourceId": {"type": "string"},
            "promotedResourceIds": {"type": "array", "items": {"type": "string"}, "minItems": 1},
            "decision": {"type": "object"},
            "metadata": {"type": "object"}
        }
    })
}

pub(super) fn attach_schema() -> Value {
    json!({
        "type": "object",
        "required": ["targetResourceId", "payload"],
        "additionalProperties": false,
        "properties": {
            "resourceId": {"type": "string"},
            "targetResourceId": {"type": "string"},
            "relation": {"type": "string"},
            "scope": {"type": "string", "enum": ["system", "workspace", "session"]},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"},
            "lifecycle": {"type": "string"},
            "policy": {"type": "object"},
            "payload": {},
            "locations": locations_schema(),
            "metadata": {"type": "object"}
        }
    })
}

pub(super) fn attach_response_schema() -> Value {
    json!({
        "type": "object",
        "required": ["resource", "link", "resourceRefs"],
        "additionalProperties": false,
        "properties": {
            "resource": {"type": "object"},
            "link": {"type": "object"},
            "resourceRefs": resource_refs_schema()
        }
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

pub(super) fn artifact_materialize_schema() -> Value {
    json!({
        "type": "object",
        "required": ["artifactResourceId", "path"],
        "additionalProperties": false,
        "properties": {
            "artifactResourceId": {"type": "string"},
            "resourceId": {"type": "string"},
            "path": {"type": "string"},
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
