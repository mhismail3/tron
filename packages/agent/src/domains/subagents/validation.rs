use serde_json::{Map, Value};

use crate::engine::{EngineResourceScope, Invocation};
use crate::shared::server::errors::CapabilityError;

pub(super) const LIST_LIMIT_DEFAULT: usize = 25;
pub(super) const LIST_LIMIT_MAX: usize = 100;
pub(super) const MAX_SUMMARY_BYTES: usize = 2_048;
pub(super) const MAX_REF_ITEMS: usize = 25;
pub(super) const MAX_PLACEHOLDER_BYTES: usize = 8_192;
pub(super) const MAX_TOTAL_PAYLOAD_BYTES: usize = 64_000;

pub(super) fn validate_task_payload(value: &Value) -> Result<(), CapabilityError> {
    validate_no_forbidden_material(value)?;
    validate_no_execution_fields(value)?;
    validate_total_size(value)
}

pub(super) fn validate_update_payload(value: &Value) -> Result<(), CapabilityError> {
    validate_no_forbidden_material(value)?;
    validate_no_execution_fields(value)?;
    validate_placeholder_bounds(value.get("result").unwrap_or(&Value::Null), "result")?;
    validate_placeholder_bounds(value.get("error").unwrap_or(&Value::Null), "error")?;
    validate_total_size(value)
}

pub(super) fn required_string(payload: &Value, field: &str) -> Result<String, CapabilityError> {
    optional_string(payload, field)?.ok_or_else(|| invalid(format!("missing {field}")))
}

pub(super) fn optional_string(
    payload: &Value,
    field: &str,
) -> Result<Option<String>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) if !value.trim().is_empty() => Ok(Some(value.clone())),
        Some(Value::String(_)) => Err(invalid(format!("{field} must not be empty"))),
        Some(_) => Err(invalid(format!("{field} must be a string"))),
    }
}

pub(super) fn optional_object(
    payload: &Value,
    field: &str,
) -> Result<Option<Map<String, Value>>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Object(value)) => Ok(Some(value.clone())),
        Some(_) => Err(invalid(format!("{field} must be an object"))),
    }
}

pub(super) fn optional_array(
    payload: &Value,
    field: &str,
) -> Result<Option<Vec<Value>>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Array(value)) => Ok(Some(value.clone())),
        Some(_) => Err(invalid(format!("{field} must be an array"))),
    }
}

pub(super) fn optional_bool(payload: &Value, field: &str) -> Result<Option<bool>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(value)) => Ok(Some(*value)),
        Some(_) => Err(invalid(format!("{field} must be a boolean"))),
    }
}

pub(super) fn optional_u64(payload: &Value, field: &str) -> Result<Option<u64>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(value)) => value
            .as_u64()
            .map(Some)
            .ok_or_else(|| invalid(format!("{field} must be a positive integer"))),
        Some(_) => Err(invalid(format!("{field} must be a positive integer"))),
    }
}

pub(super) fn idempotency_key(
    invocation: &Invocation,
    payload: &Value,
) -> Result<String, CapabilityError> {
    invocation
        .causal_context
        .idempotency_key
        .clone()
        .or_else(|| optional_string(payload, "idempotencyKey").ok().flatten())
        .ok_or_else(|| invalid("subagent task writes require an idempotencyKey"))
}

pub(super) fn bounded_text(
    field: &str,
    value: &str,
    max_bytes: usize,
) -> Result<String, CapabilityError> {
    if value.trim().is_empty() {
        return Err(invalid(format!("{field} must not be empty")));
    }
    if value.len() > max_bytes {
        return Err(invalid(format!("{field} exceeds {max_bytes} bytes")));
    }
    Ok(value.to_owned())
}

pub(super) fn validate_state(value: &str) -> Result<(), CapabilityError> {
    if matches!(
        value,
        "requested" | "queued" | "running" | "succeeded" | "failed" | "cancelled" | "archived"
    ) {
        Ok(())
    } else {
        Err(invalid(
            "state is not a supported subagent task lifecycle state",
        ))
    }
}

pub(super) fn validate_refs(label: &str, values: &[Value]) -> Result<(), CapabilityError> {
    if values.len() > MAX_REF_ITEMS {
        return Err(invalid(format!(
            "{label} may contain at most {MAX_REF_ITEMS} items"
        )));
    }
    validate_placeholder_bounds(&Value::Array(values.to_owned()), label)
}

pub(super) fn validate_context_handoff_refs(values: &[Value]) -> Result<(), CapabilityError> {
    if values.len() > MAX_REF_ITEMS {
        return Err(invalid(format!(
            "handoffRefs may contain at most {MAX_REF_ITEMS} items"
        )));
    }
    walk_json(
        &Value::Array(values.to_owned()),
        &mut Vec::new(),
        &mut |path, value| {
            if let Some(key) = path.last() {
                let lowered = key.to_ascii_lowercase();
                if lowered.contains("prompt")
                    || lowered.contains("result")
                    || lowered.contains("command")
                    || lowered.contains("log")
                    || lowered.contains("stdout")
                    || lowered.contains("stderr")
                    || lowered == "path"
                    || lowered.ends_with("path")
                    || lowered == "url"
                    || lowered == "uri"
                {
                    return Err(invalid(format!(
                        "handoffRefs must contain refs/fingerprints only, not raw {key}"
                    )));
                }
            }
            if let Value::String(text) = value {
                validate_summary_is_not_raw_payload("handoffRefs", text)?;
            }
            Ok(())
        },
    )?;
    validate_placeholder_bounds(&Value::Array(values.to_owned()), "handoffRefs")
}

pub(super) fn validate_summary_is_not_raw_payload(
    field: &str,
    value: &str,
) -> Result<(), CapabilityError> {
    let lowered = value.to_ascii_lowercase();
    if lowered.contains("bearer ")
        || lowered.contains("api_key=")
        || lowered.contains("password=")
        || lowered.contains("secret=")
        || lowered.contains("authorization:")
        || lowered.contains("stdout:")
        || lowered.contains("stderr:")
        || lowered.contains("raw prompt")
        || lowered.contains("raw result")
        || lowered.contains("tool log")
        || lowered.contains("file://")
        || lowered.contains("/users/")
        || lowered.contains("/private/")
    {
        return Err(invalid(format!(
            "{field} must be summary-only and cannot include raw prompts, results, logs, paths, or secrets"
        )));
    }
    Ok(())
}

pub(super) fn resource_scope(
    invocation: &Invocation,
) -> Result<EngineResourceScope, CapabilityError> {
    invocation
        .causal_context
        .session_id
        .as_ref()
        .map(|session| EngineResourceScope::Session(session.clone()))
        .or_else(|| {
            invocation
                .causal_context
                .workspace_id
                .as_ref()
                .map(|workspace| EngineResourceScope::Workspace(workspace.clone()))
        })
        .ok_or_else(|| {
            invalid("subagent task operations require trusted session or workspace scope")
        })
}

pub(super) fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}

fn validate_no_forbidden_material(value: &Value) -> Result<(), CapabilityError> {
    walk_json(value, &mut Vec::new(), &mut |path, value| {
        if let Some(key) = path.last() {
            let key_lower = key.to_ascii_lowercase();
            if key_lower.contains("secret")
                || key_lower.contains("password")
                || key_lower.contains("credential")
                || key_lower == "token"
                || key_lower.ends_with("token")
                || key_lower.contains("api_key")
                || key_lower.contains("apikey")
                || key_lower == "authorization"
            {
                return Err(invalid(format!("inline secret field {key} is not allowed")));
            }
        }
        if let Value::String(text) = value {
            let lowered = text.to_ascii_lowercase();
            if lowered.contains("bearer ")
                || lowered.contains("api_key=")
                || lowered.contains("password=")
                || lowered.contains("secret=")
            {
                return Err(invalid("inline credential material is not allowed"));
            }
        }
        Ok(())
    })
}

fn validate_no_execution_fields(value: &Value) -> Result<(), CapabilityError> {
    walk_json(value, &mut Vec::new(), &mut |path, _value| {
        let Some(key) = path.last() else {
            return Ok(());
        };
        let key_lower = key.to_ascii_lowercase();
        if matches!(
            key_lower.as_str(),
            "command"
                | "commands"
                | "argv"
                | "args"
                | "executable"
                | "launchcommand"
                | "workingdirectory"
                | "env"
                | "environment"
                | "process"
                | "pid"
                | "endpoint"
                | "url"
                | "cookie"
                | "login"
        ) {
            return Err(invalid(format!(
                "execution field {} is not allowed in a subagent task record",
                path.join(".")
            )));
        }
        Ok(())
    })
}

fn validate_placeholder_bounds(value: &Value, label: &str) -> Result<(), CapabilityError> {
    let bytes = serde_json::to_vec(value)
        .map_err(|error| invalid(format!("serialize {label}: {error}")))?
        .len();
    if bytes > MAX_PLACEHOLDER_BYTES {
        return Err(invalid(format!(
            "{label} exceeds {MAX_PLACEHOLDER_BYTES} bytes"
        )));
    }
    Ok(())
}

fn validate_total_size(value: &Value) -> Result<(), CapabilityError> {
    let bytes = serde_json::to_vec(value)
        .map_err(|error| invalid(format!("serialize subagent task payload: {error}")))?
        .len();
    if bytes > MAX_TOTAL_PAYLOAD_BYTES {
        return Err(invalid(format!(
            "subagent task payload exceeds {MAX_TOTAL_PAYLOAD_BYTES} bytes"
        )));
    }
    Ok(())
}

fn walk_json<F>(
    value: &Value,
    path: &mut Vec<String>,
    visitor: &mut F,
) -> Result<(), CapabilityError>
where
    F: FnMut(&[String], &Value) -> Result<(), CapabilityError>,
{
    visitor(path, value)?;
    match value {
        Value::Object(map) => {
            for (key, child) in map {
                path.push(key.clone());
                walk_json(child, path, visitor)?;
                let _ = path.pop();
            }
        }
        Value::Array(values) => {
            for (index, child) in values.iter().enumerate() {
                path.push(index.to_string());
                walk_json(child, path, visitor)?;
                let _ = path.pop();
            }
        }
        _ => {}
    }
    Ok(())
}
