//! Shared module payload parsing and sanitization helpers.
//!
//! Module lifecycle, source-trust, health, and audit code all consume the same
//! resource payload grammar. This file owns scalar extraction, hash/preview
//! helpers, and secret-handle enforcement so those invariants do not live in
//! the lifecycle root.

use super::*;

pub(super) fn required_object<'a>(
    value: Option<&'a Value>,
    field: &str,
) -> Result<&'a serde_json::Map<String, Value>> {
    value.and_then(Value::as_object).ok_or_else(|| {
        EngineError::PolicyViolation(format!("required field {field} must be an object"))
    })
}

pub(super) fn required_value_str<'a>(value: &'a Value, field: &str) -> Result<&'a str> {
    value.get(field).and_then(Value::as_str).ok_or_else(|| {
        EngineError::PolicyViolation(format!("required field {field} must be a string"))
    })
}

pub(super) fn required_map_str<'a>(
    value: &'a serde_json::Map<String, Value>,
    field: &str,
) -> Result<&'a str> {
    value.get(field).and_then(Value::as_str).ok_or_else(|| {
        EngineError::PolicyViolation(format!("required field {field} must be a string"))
    })
}

pub(super) fn string_array_from(value: Option<&Value>, field: &str) -> Result<Vec<String>> {
    let items = value.and_then(Value::as_array).ok_or_else(|| {
        EngineError::PolicyViolation(format!("required field {field} must be an array"))
    })?;
    items
        .iter()
        .map(|item| {
            item.as_str().map(ToOwned::to_owned).ok_or_else(|| {
                EngineError::PolicyViolation(format!("{field} entries must be strings"))
            })
        })
        .collect()
}

pub(super) fn parse_risk(value: &str) -> Result<RiskLevel> {
    match value.to_ascii_lowercase().as_str() {
        "low" => Ok(RiskLevel::Low),
        "medium" => Ok(RiskLevel::Medium),
        "high" => Ok(RiskLevel::High),
        "critical" => Ok(RiskLevel::Critical),
        other => Err(EngineError::PolicyViolation(format!(
            "unsupported risk {other}"
        ))),
    }
}

pub(super) fn parse_datetime(value: &str) -> Result<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| EngineError::PolicyViolation(format!("invalid grant expiresAt: {error}")))
}

pub(super) fn hash_json(value: &Value) -> Result<String> {
    let bytes = serde_json::to_vec(value).map_err(|error| EngineError::LedgerFailure {
        operation: "module.hash_json",
        message: error.to_string(),
    })?;
    Ok(format!("sha256:{:x}", Sha256::digest(bytes)))
}

pub(super) fn append_string_array(existing: Option<&Value>, additions: Vec<String>) -> Value {
    let mut values = existing
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(ToOwned::to_owned)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    for addition in additions {
        if !values.iter().any(|value| value == &addition) {
            values.push(addition);
        }
    }
    json!(values)
}

pub(super) fn append_value_array(existing: Option<&Value>, addition: Value) -> Value {
    let mut values = existing
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if !values.iter().any(|value| value == &addition) {
        values.push(addition);
    }
    Value::Array(values)
}

pub(super) fn bounded_json(value: &Value, max_bytes: usize) -> Value {
    let text = value.to_string();
    if text.len() <= max_bytes {
        return value.clone();
    }
    json!({
        "truncated": true,
        "preview": truncate_utf8_bytes(text, max_bytes),
    })
}

pub(super) fn truncate_utf8_bytes(mut text: String, max_bytes: usize) -> String {
    if text.len() <= max_bytes {
        return text;
    }
    let mut end = max_bytes;
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    text.truncate(end);
    text
}

pub(super) fn reject_raw_secrets(value: &Value) -> Result<()> {
    reject_raw_secrets_at(value, "$", None)
}

fn reject_raw_secrets_at(value: &Value, path: &str, key_hint: Option<&str>) -> Result<()> {
    match value {
        Value::Object(object) => {
            for (key, child) in object {
                reject_raw_secrets_at(child, &format!("{path}.{key}"), Some(key))?;
            }
        }
        Value::Array(items) => {
            for (index, child) in items.iter().enumerate() {
                reject_raw_secrets_at(child, &format!("{path}[{index}]"), key_hint)?;
            }
        }
        Value::String(text) => {
            let key = key_hint.unwrap_or_default().to_ascii_lowercase();
            let normalized_key = key.replace(['-', '_'], "");
            let public_key_identifier = matches!(
                normalized_key.as_str(),
                "publickey" | "signaturekeyref" | "keyid"
            );
            let secret_key = !public_key_identifier
                && [
                    "secret",
                    "token",
                    "password",
                    "apikey",
                    "privatekey",
                    "credential",
                ]
                .iter()
                .any(|marker| normalized_key.contains(marker));
            let secret_value = text.starts_with("sk-")
                || text.starts_with("pk-")
                || text.to_ascii_lowercase().contains("secret=");
            let allowed_ref = text.starts_with("secret_ref:")
                || text.starts_with("vault:")
                || text.starts_with(TRUST_ROOT_PREFIX);
            if (secret_key || secret_value) && !allowed_ref {
                return Err(EngineError::PolicyViolation(format!(
                    "{path} contains secret-like value; store only secret_ref or vault handles"
                )));
            }
        }
        _ => {}
    }
    Ok(())
}

pub(super) fn collect_secret_refs(value: &Value) -> Vec<String> {
    let mut refs = Vec::new();
    collect_secret_refs_inner(value, &mut refs);
    refs
}

fn collect_secret_refs_inner(value: &Value, refs: &mut Vec<String>) {
    match value {
        Value::String(text) if text.starts_with("secret_ref:") || text.starts_with("vault:") => {
            refs.push(text.clone());
        }
        Value::Array(items) => {
            for item in items {
                collect_secret_refs_inner(item, refs);
            }
        }
        Value::Object(object) => {
            for child in object.values() {
                collect_secret_refs_inner(child, refs);
            }
        }
        _ => {}
    }
}
