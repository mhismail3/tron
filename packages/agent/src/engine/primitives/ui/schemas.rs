use serde_json::{Value, json};

pub(super) fn create_surface_schema() -> Value {
    json!({
        "type": "object",
        "required": ["surface"],
        "additionalProperties": false,
        "properties": {
            "resourceId": {"type": "string"},
            "surface": {"type": "object"},
            "scope": {"type": "string"},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"},
            "lifecycle": {"type": "string"},
            "policy": {"type": "object"}
        }
    })
}

pub(super) fn update_surface_schema() -> Value {
    json!({
        "type": "object",
        "required": ["resourceId", "expectedCurrentVersionId", "surface"],
        "additionalProperties": false,
        "properties": {
            "resourceId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"},
            "surface": {"type": "object"},
            "lifecycle": {"type": "string"}
        }
    })
}

pub(super) fn expire_surface_schema() -> Value {
    json!({
        "type": "object",
        "required": ["surfaceResourceId"],
        "additionalProperties": false,
        "properties": {
            "surfaceResourceId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"}
        }
    })
}

pub(super) fn discard_surface_schema() -> Value {
    json!({
        "type": "object",
        "required": ["surfaceResourceId"],
        "additionalProperties": false,
        "properties": {
            "surfaceResourceId": {"type": "string"},
            "expectedCurrentVersionId": {"type": "string"}
        }
    })
}

pub(super) fn submit_action_schema() -> Value {
    json!({
        "type": "object",
        "required": ["surfaceResourceId", "surfaceVersionId", "actionId", "userInput", "idempotencyKey"],
        "additionalProperties": false,
        "properties": {
            "surfaceResourceId": {"type": "string"},
            "surfaceVersionId": {"type": "string"},
            "actionId": {"type": "string"},
            "userInput": {"type": "object"},
            "idempotencyKey": {"type": "string"}
        }
    })
}

pub(super) fn submit_action_response_schema() -> Value {
    json!({
        "type": "object",
        "required": ["surfaceResourceId", "surfaceVersionId", "actionId", "accepted", "userInput"],
        "additionalProperties": false,
        "properties": {
            "surfaceResourceId": {"type": "string"},
            "surfaceVersionId": {"type": "string"},
            "actionId": {"type": "string"},
            "accepted": {"type": "boolean"},
            "userInput": {"type": "object"}
        }
    })
}

pub(super) fn surface_resource_response_schema() -> Value {
    json!({
        "type": "object",
        "required": ["resourceRefs"],
        "additionalProperties": false,
        "properties": {
            "surface": {"type": "object"},
            "resource": {"type": "object"},
            "version": {"type": "object"},
            "resourceRefs": {"type": "array"}
        }
    })
}

pub(super) fn surface_version_response_schema() -> Value {
    json!({
        "type": "object",
        "required": ["version", "resourceRefs"],
        "additionalProperties": false,
        "properties": {
            "surface": {"type": "object"},
            "version": {"type": "object"},
            "resourceRefs": {"type": "array"}
        }
    })
}
