use chrono::{DateTime, Utc};
use serde_json::Value;

use crate::shared::server::errors::CapabilityError;

use super::errors::invalid_params;
use super::support::{optional_array, optional_object, parse_datetime, required_string};

const MAX_METADATA_BYTES: usize = 8_192;
const MAX_ARRAY_ITEMS: usize = 50;
const MAX_STRING_BYTES: usize = 512;
const MAX_KEY_BYTES: usize = 64;

pub(super) fn reason_codes(payload: &Value) -> Result<Vec<String>, CapabilityError> {
    let values = optional_array(payload, "reasonCodes")?;
    if values.is_empty() {
        return Err(invalid_params("reasonCodes must contain at least one code"));
    }
    values
        .into_iter()
        .map(|value| {
            value
                .as_str()
                .ok_or_else(|| invalid_params("reasonCodes entries must be strings"))
                .and_then(|value| bounded_string(value, "reasonCodes"))
        })
        .collect()
}

pub(super) fn bounded_object(
    payload: &Value,
    field: &str,
) -> Result<Option<Value>, CapabilityError> {
    let Some(value) = optional_object(payload, field)? else {
        return Ok(None);
    };
    validate_bounded_metadata(&value, field, 0)?;
    Ok(Some(value))
}

pub(super) fn bounded_array(payload: &Value, field: &str) -> Result<Vec<Value>, CapabilityError> {
    let values = optional_array(payload, field)?;
    if values.len() > MAX_ARRAY_ITEMS {
        return Err(invalid_params(format!("{field} has too many entries")));
    }
    for value in &values {
        validate_bounded_metadata(value, field, 0)?;
    }
    Ok(values)
}

pub(super) fn required_datetime(
    payload: &Value,
    field: &str,
) -> Result<DateTime<Utc>, CapabilityError> {
    let value = required_string(payload, field)?;
    parse_datetime(&value)
}

pub(super) fn validate_bounded_metadata(
    value: &Value,
    path: &str,
    depth: usize,
) -> Result<(), CapabilityError> {
    if depth > 8 {
        return Err(invalid_params(format!("{path} is nested too deeply")));
    }
    if value.to_string().len() > MAX_METADATA_BYTES {
        return Err(invalid_params(format!("{path} exceeds metadata budget")));
    }
    match value {
        Value::Object(object) => validate_object(object, path, depth)?,
        Value::Array(items) => validate_array(items, path, depth)?,
        Value::String(text) => validate_string(text, path)?,
        _ => {}
    }
    Ok(())
}

pub(super) fn bounded_string(value: &str, field: &str) -> Result<String, CapabilityError> {
    if value.trim().is_empty() {
        return Err(invalid_params(format!("{field} must be non-empty")));
    }
    if value.len() > MAX_STRING_BYTES {
        return Err(invalid_params(format!("{field} is too long")));
    }
    validate_bounded_metadata(&Value::String(value.to_owned()), field, 0)?;
    Ok(value.to_owned())
}

fn validate_object(
    object: &serde_json::Map<String, Value>,
    path: &str,
    depth: usize,
) -> Result<(), CapabilityError> {
    for (key, nested) in object {
        if key.len() > MAX_KEY_BYTES {
            return Err(invalid_params(format!("{path}.{key} key is too long")));
        }
        let lower = key.to_ascii_lowercase();
        if raw_or_private_key(&lower) {
            return Err(invalid_params(format!(
                "{path}.{key} cannot store raw/private memory evidence material"
            )));
        }
        validate_bounded_metadata(nested, &format!("{path}.{key}"), depth + 1)?;
    }
    Ok(())
}

fn validate_array(items: &[Value], path: &str, depth: usize) -> Result<(), CapabilityError> {
    if items.len() > MAX_ARRAY_ITEMS {
        return Err(invalid_params(format!("{path} has too many entries")));
    }
    for (index, nested) in items.iter().enumerate() {
        validate_bounded_metadata(nested, &format!("{path}[{index}]"), depth + 1)?;
    }
    Ok(())
}

fn validate_string(text: &str, path: &str) -> Result<(), CapabilityError> {
    let lower = text.to_ascii_lowercase();
    if text.len() > MAX_STRING_BYTES {
        return Err(invalid_params(format!("{path} string is too long")));
    }
    if secret_like_or_unsafe(&lower, text) {
        return Err(invalid_params(format!(
            "{path} cannot store secret-like material or unsafe paths"
        )));
    }
    Ok(())
}

fn raw_or_private_key(lower: &str) -> bool {
    matches!(
        lower,
        "content"
            | "text"
            | "body"
            | "raw"
            | "prompt"
            | "summary"
            | "providerpayload"
            | "rawpayload"
            | "idempotencykey"
            | "secret"
            | "token"
            | "path"
            | "url"
            | "uri"
    ) || lower.contains("secret")
        || lower.contains("token")
        || lower.contains("credential")
}

fn secret_like_or_unsafe(lower: &str, text: &str) -> bool {
    lower.contains("bearer ")
        || lower.contains("secret=")
        || lower.contains("secret:")
        || lower.contains("token=")
        || lower.contains("token:")
        || lower.contains("authorization:")
        || lower.starts_with("sk-")
        || text.starts_with('/')
        || text.starts_with("~/")
        || text.contains("://")
}
