//! Module package lifecycle request and response schemas.
//!
//! The module primitive root registers functions and dispatches lifecycle
//! operations; this file owns the stable package/config/activation JSON schema
//! builders those registrations expose.

use super::*;

pub(super) fn register_package_schema() -> Value {
    json!({
        "type": "object",
        "required": ["manifest"],
        "additionalProperties": false,
        "properties": {
            "manifest": {"type": "object"},
            "expectedCurrentVersionId": {"type": "string"}
        }
    })
}

pub(super) fn inspect_package_schema() -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "packageId": {"type": "string"},
            "packageResourceId": {"type": "string"}
        }
    })
}

pub(super) fn configure_schema() -> Value {
    json!({
        "type": "object",
        "required": ["packageResourceId", "packageVersionId", "scope", "config"],
        "additionalProperties": false,
        "properties": {
            "packageResourceId": {"type": "string"},
            "packageVersionId": {"type": "string"},
            "scope": {"type": "string"},
            "workspaceId": {"type": "string"},
            "sessionId": {"type": "string"},
            "config": {"type": "object"},
            "expectedCurrentVersionId": {"type": "string"}
        }
    })
}

pub(super) fn activate_schema() -> Value {
    json!({
        "type": "object",
        "required": [
            "packageResourceId",
            "packageVersionId",
            "moduleConfigResourceId",
            "configVersionId",
            "scope",
            "childGrantRequest"
        ],
        "additionalProperties": false,
        "properties": {
            "packageResourceId": {"type": "string"},
            "packageVersionId": {"type": "string"},
            "moduleConfigResourceId": {"type": "string"},
            "configVersionId": {"type": "string"},
            "scope": {"type": "string"},
            "workspaceId": {"type": "string"},
            "sessionId": {"type": "string"},
            "workerId": {"type": "string"},
            "childGrantRequest": {"type": "object"},
            "lifecyclePolicy": {"type": "object"},
            "healthPolicy": {"type": "object"},
            "rollbackPolicy": {"type": "object"},
            "rollbackTarget": {},
            "expectedCurrentVersionId": {"type": "string"}
        }
    })
}

pub(super) fn disable_schema() -> Value {
    json!({
        "type": "object",
        "required": ["activationResourceId"],
        "additionalProperties": false,
        "properties": {
            "activationResourceId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"}
        }
    })
}

pub(super) fn upgrade_schema() -> Value {
    let mut schema = activate_schema();
    if let Some(required) = schema.get_mut("required").and_then(Value::as_array_mut) {
        required.push(json!("activationResourceId"));
        required.push(json!("expectedCurrentVersionId"));
    }
    schema["properties"]["activationResourceId"] = json!({"type": "string"});
    schema
}

pub(super) fn rollback_schema() -> Value {
    json!({
        "type": "object",
        "required": [
            "activationResourceId",
            "targetVersionId",
            "childGrantRequest",
            "expectedCurrentVersionId"
        ],
        "additionalProperties": false,
        "properties": {
            "activationResourceId": {"type": "string"},
            "targetVersionId": {"type": "string"},
            "scope": {"type": "string"},
            "workspaceId": {"type": "string"},
            "sessionId": {"type": "string"},
            "childGrantRequest": {"type": "object"},
            "expectedCurrentVersionId": {"type": "string"}
        }
    })
}

pub(super) fn quarantine_schema() -> Value {
    json!({
        "type": "object",
        "required": ["resourceId"],
        "additionalProperties": false,
        "properties": {
            "resourceId": {"type": "string"},
            "evidenceResourceIds": {"type": "array", "items": {"type": "string"}},
            "expectedCurrentVersionId": {"type": "string"}
        }
    })
}

pub(super) fn remove_package_schema() -> Value {
    json!({
        "type": "object",
        "required": ["packageResourceId"],
        "additionalProperties": false,
        "properties": {
            "packageResourceId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"},
            "reason": {"type": "string"}
        }
    })
}

pub(super) fn module_resource_response_schema(kind: &str) -> Value {
    json!({
        "type": "object",
        "required": ["resourceRefs"],
        "additionalProperties": true,
        "properties": {
            "resource": {"type": "object"},
            "version": {"type": "object"},
            "activation": {"type": "object"},
            "resourceRefs": {
                "type": "array",
                "items": {
                    "type": "object",
                    "required": ["resourceId", "kind", "versionId", "role", "contentHash"],
                    "additionalProperties": false,
                    "properties": {
                        "resourceId": {"type": "string"},
                        "kind": {"type": "string"},
                        "versionId": {"type": ["string", "null"]},
                        "role": {"type": "string"},
                        "contentHash": {"type": ["string", "null"]}
                    }
                }
            },
            "expectedKind": {"type": "string", "enum": [kind]}
        }
    })
}
