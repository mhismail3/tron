//! Validation for runtime UI surface resources.

use chrono::DateTime;
use serde_json::{Value, json};

use super::types::UI_SURFACE_SCHEMA_VERSION;
use crate::engine::errors::{EngineError, Result};
use crate::engine::ids::FunctionId;
use crate::engine::schema;

const UI_MAX_DEPTH: usize = 8;
const UI_MAX_COMPONENTS: usize = 200;
const UI_MAX_TABLE_ROWS: usize = 200;
const UI_MAX_TEXT_BYTES: usize = 16 * 1024;
const UI_MAX_ACTIONS: usize = 50;
const UI_MAX_PAYLOAD_BYTES: usize = 64 * 1024;

pub(crate) fn ui_surface_schema() -> Value {
    json!({
        "type": "object",
        "required": [
            "surfaceId",
            "title",
            "purpose",
            "schemaVersion",
            "layout",
            "actions",
            "expiresAt"
        ],
        "additionalProperties": false,
        "properties": {
            "surfaceId": {"type": "string"},
            "title": {"type": "string"},
            "purpose": {"type": "string"},
            "schemaVersion": {"type": "integer"},
            "layout": {"type": "object"},
            "actions": {"type": "array", "items": {"type": "object"}, "maxItems": UI_MAX_ACTIONS},
            "expiresAt": {"type": "string"}
        }
    })
}

/// Validate the bounded runtime `ui_surface` payload contract.
pub(crate) fn validate_ui_surface_payload(payload: &Value) -> Result<()> {
    let bytes = serde_json::to_vec(payload).map_err(|error| EngineError::LedgerFailure {
        operation: "ui_surface.payload_size",
        message: error.to_string(),
    })?;
    if bytes.len() > UI_MAX_PAYLOAD_BYTES {
        return Err(EngineError::PolicyViolation(format!(
            "ui_surface payload exceeds {UI_MAX_PAYLOAD_BYTES} bytes"
        )));
    }
    ensure_non_empty_string(payload, "surfaceId")?;
    ensure_non_empty_string(payload, "title")?;
    ensure_non_empty_string(payload, "purpose")?;
    ensure_datetime_string(payload, "expiresAt")?;
    ensure_schema_version(payload)?;

    let mut stats = UiSurfaceStats::default();
    validate_ui_component(
        payload
            .get("layout")
            .ok_or_else(|| EngineError::PolicyViolation("ui_surface requires layout".to_owned()))?,
        1,
        &mut stats,
    )?;
    if stats.components > UI_MAX_COMPONENTS {
        return Err(EngineError::PolicyViolation(format!(
            "ui_surface has more than {UI_MAX_COMPONENTS} components"
        )));
    }
    if stats.text_bytes > UI_MAX_TEXT_BYTES {
        return Err(EngineError::PolicyViolation(format!(
            "ui_surface text exceeds {UI_MAX_TEXT_BYTES} bytes"
        )));
    }
    validate_ui_actions(payload.get("actions"))?;
    scan_ui_value_for_forbidden_content(payload, "$")
}

#[derive(Default)]
struct UiSurfaceStats {
    components: usize,
    text_bytes: usize,
}

fn ensure_schema_version(payload: &Value) -> Result<()> {
    let Some(version) = payload.get("schemaVersion").and_then(Value::as_u64) else {
        return Err(EngineError::PolicyViolation(
            "ui_surface requires schemaVersion".to_owned(),
        ));
    };
    if version == UI_SURFACE_SCHEMA_VERSION {
        Ok(())
    } else {
        Err(EngineError::PolicyViolation(format!(
            "ui_surface schemaVersion {version} is not supported"
        )))
    }
}

fn validate_ui_component(
    component: &Value,
    depth: usize,
    stats: &mut UiSurfaceStats,
) -> Result<()> {
    if depth > UI_MAX_DEPTH {
        return Err(EngineError::PolicyViolation(format!(
            "ui_surface component tree exceeds depth {UI_MAX_DEPTH}"
        )));
    }
    let object = component.as_object().ok_or_else(|| {
        EngineError::PolicyViolation("ui_surface component must be an object".to_owned())
    })?;
    let component_type = object
        .get("type")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| {
            EngineError::PolicyViolation("ui_surface component requires type".to_owned())
        })?;
    if !ui_component_types().contains(&component_type) {
        return Err(EngineError::PolicyViolation(format!(
            "unsupported ui component {component_type}"
        )));
    }
    stats.components += 1;
    let props = object.get("props").unwrap_or(&Value::Null);
    validate_ui_component_props(component_type, props, stats)?;
    if let Some(children) = object.get("children") {
        let children = children.as_array().ok_or_else(|| {
            EngineError::PolicyViolation("ui_surface children must be an array".to_owned())
        })?;
        for child in children {
            validate_ui_component(child, depth + 1, stats)?;
        }
    }
    Ok(())
}

fn validate_ui_component_props(
    component_type: &str,
    props: &Value,
    stats: &mut UiSurfaceStats,
) -> Result<()> {
    if props.is_null() {
        return Ok(());
    }
    let object = props.as_object().ok_or_else(|| {
        EngineError::PolicyViolation(format!("{component_type} props must be an object"))
    })?;
    let allowed = allowed_component_props(component_type);
    for (key, value) in object {
        if !allowed.iter().any(|allowed| allowed == key) {
            return Err(EngineError::PolicyViolation(format!(
                "{component_type} does not allow prop {key}"
            )));
        }
        if key == "rows" {
            if value
                .as_array()
                .is_some_and(|rows| rows.len() > UI_MAX_TABLE_ROWS)
            {
                return Err(EngineError::PolicyViolation(format!(
                    "Table rows exceed {UI_MAX_TABLE_ROWS}"
                )));
            }
        }
        stats.text_bytes = stats.text_bytes.saturating_add(utf8_string_bytes(value));
    }
    Ok(())
}

fn validate_ui_actions(value: Option<&Value>) -> Result<()> {
    let Some(actions) = value.and_then(Value::as_array) else {
        return Err(EngineError::PolicyViolation(
            "ui_surface actions must be an array".to_owned(),
        ));
    };
    if actions.len() > UI_MAX_ACTIONS {
        return Err(EngineError::PolicyViolation(format!(
            "ui_surface has more than {UI_MAX_ACTIONS} actions"
        )));
    }
    let mut ids = std::collections::BTreeSet::new();
    for action in actions {
        let object = action.as_object().ok_or_else(|| {
            EngineError::PolicyViolation("ui_surface action must be an object".to_owned())
        })?;
        for field in ["actionId", "label", "expiresAt"] {
            ensure_non_empty_object_string(object, field)?;
        }
        let action_id = object.get("actionId").and_then(Value::as_str).unwrap();
        if !ids.insert(action_id.to_owned()) {
            return Err(EngineError::PolicyViolation(format!(
                "duplicate ui action {action_id}"
            )));
        }
        ensure_datetime_value(object.get("expiresAt"), "expiresAt")?;
        let input_schema = object.get("inputSchema").ok_or_else(|| {
            EngineError::PolicyViolation("ui action requires inputSchema".to_owned())
        })?;
        schema::validate_schema_definition(
            &resource_function_id(),
            "ui_action_input",
            input_schema,
        )?;
    }
    Ok(())
}

fn ensure_non_empty_string(payload: &Value, field: &str) -> Result<()> {
    let object = payload.as_object().ok_or_else(|| {
        EngineError::PolicyViolation("ui_surface payload must be an object".to_owned())
    })?;
    ensure_non_empty_object_string(object, field)
}

fn ensure_non_empty_object_string(
    object: &serde_json::Map<String, Value>,
    field: &str,
) -> Result<()> {
    object
        .get(field)
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .map(|_| ())
        .ok_or_else(|| EngineError::PolicyViolation(format!("ui_surface requires {field}")))
}

fn ensure_datetime_string(payload: &Value, field: &str) -> Result<()> {
    let object = payload.as_object().ok_or_else(|| {
        EngineError::PolicyViolation("ui_surface payload must be an object".to_owned())
    })?;
    ensure_datetime_value(object.get(field), field)
}

fn ensure_datetime_value(value: Option<&Value>, field: &str) -> Result<()> {
    let Some(text) = value
        .and_then(Value::as_str)
        .filter(|value| !value.is_empty())
    else {
        return Err(EngineError::PolicyViolation(format!(
            "ui_surface requires datetime {field}"
        )));
    };
    DateTime::parse_from_rfc3339(text)
        .map(|_| ())
        .map_err(|error| {
            EngineError::PolicyViolation(format!("ui_surface invalid datetime {field}: {error}"))
        })
}

fn ui_component_types() -> &'static [&'static str] {
    &[
        "Text",
        "Heading",
        "Monospace",
        "Badge",
        "Section",
        "List",
        "Table",
        "Tabs",
        "Disclosure",
        "ResourceRef",
        "InvocationRef",
        "GrantRef",
        "Metric",
        "TextField",
        "TextArea",
        "Select",
        "Toggle",
        "Stepper",
        "DateTime",
        "Button",
        "ButtonGroup",
        "Confirmation",
        "Progress",
        "Health",
        "Warning",
        "Error",
        "EmptyState",
    ]
}

fn allowed_component_props(component_type: &str) -> Vec<&'static str> {
    let mut props = match component_type {
        "Text" | "Heading" | "Warning" | "Error" => vec!["text", "level", "tone"],
        "Monospace" => vec!["text", "language", "truncate"],
        "Badge" => vec!["text", "tone"],
        "Section" | "Disclosure" => vec!["title", "subtitle", "open"],
        "List" => vec!["items", "style"],
        "Table" => vec!["columns", "rows", "caption"],
        "Tabs" => vec!["tabs", "selected"],
        "ResourceRef" => vec!["resourceId", "versionId", "kind", "label"],
        "InvocationRef" => vec!["invocationId", "label"],
        "GrantRef" => vec!["grantId", "label"],
        "Metric" => vec!["label", "value", "unit", "tone"],
        "TextField" | "TextArea" | "DateTime" => {
            vec!["name", "label", "placeholder", "value", "required"]
        }
        "Select" => vec!["name", "label", "options", "value", "required"],
        "Toggle" => vec!["name", "label", "value"],
        "Stepper" => vec!["name", "label", "value", "min", "max", "step"],
        "Button" => vec!["actionId", "label", "variant", "disabled"],
        "ButtonGroup" => vec!["actions", "alignment"],
        "Confirmation" => vec!["title", "message", "confirmActionId", "cancelLabel"],
        "Progress" => vec!["label", "value", "total"],
        "Health" => vec!["status", "label", "detail"],
        "EmptyState" => vec!["title", "message", "actionId"],
        _ => Vec::new(),
    };
    props.extend(["id", "binding", "visibleWhen", "disabledWhen"]);
    props
}

fn scan_ui_value_for_forbidden_content(value: &Value, path: &str) -> Result<()> {
    match value {
        Value::Object(object) => {
            for (key, child) in object {
                if secret_like_key(key) && child.as_str().is_some_and(raw_secret_like_value) {
                    return Err(EngineError::PolicyViolation(format!(
                        "ui_surface stores secret-like value at {path}.{key}; use secret_ref"
                    )));
                }
                if ui_structural_identifier_key(key) && child.is_string() {
                    continue;
                }
                scan_ui_value_for_forbidden_content(child, &format!("{path}.{key}"))?;
            }
        }
        Value::Array(items) => {
            for (index, child) in items.iter().enumerate() {
                scan_ui_value_for_forbidden_content(child, &format!("{path}[{index}]"))?;
            }
        }
        Value::String(text) => {
            let lower = text.to_ascii_lowercase();
            if lower.contains("<script")
                || lower.contains("javascript:")
                || lower.contains("file://")
            {
                return Err(EngineError::PolicyViolation(format!(
                    "ui_surface contains executable or local-file content at {path}"
                )));
            }
            if raw_secret_like_value(text) {
                return Err(EngineError::PolicyViolation(format!(
                    "ui_surface contains raw secret-like value at {path}; use secret_ref"
                )));
            }
        }
        _ => {}
    }
    Ok(())
}

fn secret_like_key(key: &str) -> bool {
    let key = key.to_ascii_lowercase().replace(['-', '_'], "");
    ["secret", "apikey", "password", "credential", "accesstoken"]
        .iter()
        .any(|needle| key.contains(needle))
}

fn ui_structural_identifier_key(key: &str) -> bool {
    matches!(
        key,
        "id" | "surfaceId"
            | "resourceId"
            | "versionId"
            | "resourceVersionId"
            | "packageVersionId"
            | "configVersionId"
            | "activationVersionId"
            | "expectedCurrentVersionId"
            | "contentHash"
            | "sessionId"
            | "workspaceId"
            | "targetResourceId"
            | "targetVersionId"
            | "functionId"
            | "grantId"
            | "invocationId"
            | "createdByInvocationId"
            | "actionId"
            | "confirmActionId"
    )
}

fn raw_secret_like_value(value: &str) -> bool {
    let trimmed = value.trim();
    if trimmed.starts_with("secret_ref:") || trimmed.starts_with("redacted:") {
        return false;
    }
    trimmed.starts_with("sk-")
        || trimmed.starts_with("xox")
        || (trimmed.len() >= 32
            && trimmed
                .chars()
                .all(|ch| ch.is_ascii_alphanumeric() || ch == '_' || ch == '-'))
}

fn utf8_string_bytes(value: &Value) -> usize {
    match value {
        Value::String(text) => text.len(),
        Value::Array(items) => items.iter().map(utf8_string_bytes).sum(),
        Value::Object(object) => object.values().map(utf8_string_bytes).sum(),
        _ => 0,
    }
}

fn resource_function_id() -> FunctionId {
    FunctionId::new("resource::payload").expect("valid static resource function id")
}
