use serde_json::Value;

use crate::shared::server::errors::CapabilityError;

use super::SCHEMA_VERSION;

pub(crate) const LIST_LIMIT_DEFAULT: usize = 25;
pub(crate) const LIST_LIMIT_MAX: usize = 100;
pub(crate) const INSPECT_ITEMS_DEFAULT: usize = 25;
pub(crate) const INSPECT_ITEMS_MAX: usize = 100;
pub(crate) const MAX_ARRAY_ITEMS: usize = 16;
pub(crate) const MAX_OBJECT_FIELDS: usize = 32;
pub(crate) const MAX_STRING_BYTES: usize = 256;
pub(crate) const MAX_NESTING_DEPTH: usize = 6;

const REQUIRED_TOP_LEVEL_FIELDS: &[&str] = &[
    "schemaVersion",
    "identity",
    "capabilityDeclarations",
    "resourceDeclarations",
    "authorityNeeds",
    "settingsDeclarations",
    "dependencyIntents",
    "validation",
    "provenance",
    "lifecycle",
    "redactionProof",
];

const ARRAY_FIELDS: &[&str] = &[
    "capabilityDeclarations",
    "resourceDeclarations",
    "authorityNeeds",
    "settingsDeclarations",
    "dependencyIntents",
];

pub(crate) fn validate_manifest_payload(
    payload: &Value,
    operation: &str,
) -> Result<(), CapabilityError> {
    let object = payload.as_object().ok_or_else(|| {
        invalid(format!(
            "{operation} module manifest payload must be an object"
        ))
    })?;
    for field in REQUIRED_TOP_LEVEL_FIELDS {
        if !object.contains_key(*field) {
            return Err(invalid(format!(
                "{operation} malformed module manifest missing {field}"
            )));
        }
    }
    if payload.get("schemaVersion").and_then(Value::as_str) != Some(SCHEMA_VERSION) {
        return Err(invalid(format!(
            "{operation} expected module manifest schemaVersion {SCHEMA_VERSION}"
        )));
    }
    ensure_object(payload.get("identity"), "identity", operation)?;
    ensure_object(payload.get("validation"), "validation", operation)?;
    ensure_object(payload.get("provenance"), "provenance", operation)?;
    ensure_object(payload.get("lifecycle"), "lifecycle", operation)?;
    ensure_object(payload.get("redactionProof"), "redactionProof", operation)?;
    for field in ARRAY_FIELDS {
        ensure_bounded_array(payload.get(*field), field, operation)?;
    }
    ensure_bounded_array(
        payload.pointer("/validation/checks"),
        "validation.checks",
        operation,
    )?;
    ensure_bounded_array(
        payload.pointer("/validation/evidenceRefs"),
        "validation.evidenceRefs",
        operation,
    )?;
    ensure_bounded_array(
        payload.pointer("/provenance/sourceRefs"),
        "provenance.sourceRefs",
        operation,
    )?;
    ensure_lifecycle(payload, operation)?;
    ensure_redaction_proof(payload, operation)?;
    validate_safe_value(payload, operation, 0, false)?;
    Ok(())
}

fn ensure_object(
    value: Option<&Value>,
    field: &str,
    operation: &str,
) -> Result<(), CapabilityError> {
    if matches!(value, Some(Value::Object(_))) {
        Ok(())
    } else {
        Err(invalid(format!(
            "{operation} module manifest {field} must be an object"
        )))
    }
}

fn ensure_bounded_array(
    value: Option<&Value>,
    field: &str,
    operation: &str,
) -> Result<(), CapabilityError> {
    let Some(Value::Array(items)) = value else {
        return Err(invalid(format!(
            "{operation} module manifest {field} must be an array"
        )));
    };
    if items.len() > MAX_ARRAY_ITEMS {
        return Err(invalid(format!(
            "{operation} module manifest {field} exceeds {MAX_ARRAY_ITEMS} items"
        )));
    }
    Ok(())
}

fn ensure_lifecycle(payload: &Value, operation: &str) -> Result<(), CapabilityError> {
    let lifecycle = payload
        .get("lifecycle")
        .and_then(Value::as_object)
        .ok_or_else(|| invalid(format!("{operation} module lifecycle must be an object")))?;
    for required in [
        "state",
        "activation",
        "installable",
        "executable",
        "networkPolicy",
    ] {
        if !lifecycle.contains_key(required) {
            return Err(invalid(format!(
                "{operation} module lifecycle missing {required}"
            )));
        }
    }
    if lifecycle.get("networkPolicy").and_then(Value::as_str) != Some("none") {
        return Err(invalid(format!(
            "{operation} module manifest must declare networkPolicy none"
        )));
    }
    Ok(())
}

fn ensure_redaction_proof(payload: &Value, operation: &str) -> Result<(), CapabilityError> {
    let proof = payload
        .get("redactionProof")
        .and_then(Value::as_object)
        .ok_or_else(|| invalid(format!("{operation} redactionProof must be an object")))?;
    for required in [
        "localPaths",
        "environmentValues",
        "commands",
        "sensitiveValues",
        "grantIdentifiers",
        "authorityIdentifiers",
        "tokenLikeMaterial",
        "personalInfoLiterals",
    ] {
        if proof.get(required).and_then(Value::as_str) != Some("absent") {
            return Err(invalid(format!(
                "{operation} redactionProof.{required} must be absent"
            )));
        }
    }
    Ok(())
}

fn validate_safe_value(
    value: &Value,
    operation: &str,
    depth: usize,
    in_redaction_proof: bool,
) -> Result<(), CapabilityError> {
    if depth > MAX_NESTING_DEPTH {
        return Err(invalid(format!(
            "{operation} module manifest exceeds max nesting depth {MAX_NESTING_DEPTH}"
        )));
    }
    match value {
        Value::Null | Value::Bool(_) | Value::Number(_) => Ok(()),
        Value::String(text) => validate_safe_string(text, operation),
        Value::Array(items) => {
            if items.len() > MAX_ARRAY_ITEMS {
                return Err(invalid(format!(
                    "{operation} module manifest array exceeds {MAX_ARRAY_ITEMS} items"
                )));
            }
            for item in items {
                validate_safe_value(item, operation, depth + 1, in_redaction_proof)?;
            }
            Ok(())
        }
        Value::Object(object) => {
            if object.len() > MAX_OBJECT_FIELDS {
                return Err(invalid(format!(
                    "{operation} module manifest object exceeds {MAX_OBJECT_FIELDS} fields"
                )));
            }
            for (key, value) in object {
                let nested_redaction_proof = in_redaction_proof || key == "redactionProof";
                if !nested_redaction_proof && sensitive_key(key) {
                    return Err(invalid(format!(
                        "{operation} module manifest contains forbidden key {key}"
                    )));
                }
                validate_safe_string(key, operation)?;
                validate_safe_value(value, operation, depth + 1, nested_redaction_proof)?;
            }
            Ok(())
        }
    }
}

fn validate_safe_string(text: &str, operation: &str) -> Result<(), CapabilityError> {
    if text.len() > MAX_STRING_BYTES {
        return Err(invalid(format!(
            "{operation} module manifest string exceeds {MAX_STRING_BYTES} bytes"
        )));
    }
    if unsafe_text(text) {
        return Err(invalid(format!(
            "{operation} module manifest contains provider-unsafe text"
        )));
    }
    Ok(())
}

fn sensitive_key(key: &str) -> bool {
    let lower = key.to_ascii_lowercase();
    matches!(
        lower.as_str(),
        "secret"
            | "secrets"
            | "token"
            | "password"
            | "credential"
            | "credentials"
            | "apikey"
            | "api_key"
            | "env"
            | "environment"
            | "path"
            | "paths"
            | "command"
            | "cmd"
            | "argv"
            | "grantid"
            | "authorityid"
    ) || lower.contains("grant_id")
        || lower.contains("authority_id")
        || lower.contains("api_key")
}

pub(crate) fn unsafe_text(text: &str) -> bool {
    let trimmed = text.trim();
    let lower = trimmed.to_ascii_lowercase();
    trimmed.starts_with('/')
        || trimmed.starts_with("~/")
        || trimmed.contains("\\")
        || lower.contains("/users/")
        || lower.contains("packages/agent/")
        || lower.contains("bearer ")
        || lower.starts_with("sk-")
        || lower.starts_with("ghp_")
        || lower.starts_with("xox")
        || lower.contains("api_key")
        || lower.contains("apikey")
        || lower.contains("grant-")
        || lower.contains("grant_")
        || lower.contains("grant:")
        || looks_like_email(trimmed)
}

fn looks_like_email(text: &str) -> bool {
    let Some((local, domain)) = text.split_once('@') else {
        return false;
    };
    !local.is_empty() && domain.contains('.') && !domain.ends_with('.')
}

fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}
