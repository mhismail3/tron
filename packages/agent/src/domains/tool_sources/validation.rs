use serde_json::{Map, Value};

use crate::engine::{EngineResourceScope, Invocation};
use crate::shared::server::errors::CapabilityError;

pub(super) const LIST_LIMIT_DEFAULT: usize = 25;
pub(super) const LIST_LIMIT_MAX: usize = 100;
pub(super) const MAX_STRING_BYTES: usize = 2_048;
pub(super) const MAX_SCHEMA_BYTES: usize = 32_000;
pub(super) const MAX_TOTAL_PAYLOAD_BYTES: usize = 96_000;
pub(super) const MAX_DECLARED_TOOLS: usize = 50;
pub(super) const MAX_DECLARED_SCHEMAS: usize = 50;
pub(super) const MAX_REFS: usize = 25;
pub(super) const INSPECT_SCHEMA_PREVIEW_DEFAULT: usize = 8_192;
pub(super) const INSPECT_SCHEMA_PREVIEW_MAX: usize = 32_000;

pub(super) fn validate_proposal_payload(value: &Value) -> Result<(), CapabilityError> {
    validate_no_forbidden_material(value)?;
    validate_no_execution_intent(value)?;
    validate_no_activation_intent(value)?;
    validate_sandbox_policy(value.get("sandboxPolicy").unwrap_or(&Value::Null))?;
    validate_declared_schema_bounds(value.get("declaredSchemas").unwrap_or(&Value::Null))?;
    validate_total_size(value)
}

pub(super) fn validate_no_forbidden_material(value: &Value) -> Result<(), CapabilityError> {
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
            if text.len() > MAX_STRING_BYTES {
                return Err(invalid(format!(
                    "{} exceeds {MAX_STRING_BYTES} bytes",
                    path.join(".")
                )));
            }
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

pub(super) fn validate_no_execution_intent(value: &Value) -> Result<(), CapabilityError> {
    walk_json(value, &mut Vec::new(), &mut |path, value| {
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
                | "spawn"
        ) {
            return Err(invalid(format!(
                "execution field {} is not allowed in a tool source proposal",
                path.join(".")
            )));
        }
        if key_lower.ends_with("path") {
            if let Value::String(path_value) = value {
                validate_safe_relative_path(path_value)?;
            }
        }
        Ok(())
    })
}

pub(super) fn validate_total_size(value: &Value) -> Result<(), CapabilityError> {
    let bytes = serde_json::to_vec(value)
        .map_err(|error| invalid(format!("serialize tool source payload: {error}")))?
        .len();
    if bytes > MAX_TOTAL_PAYLOAD_BYTES {
        return Err(invalid(format!(
            "tool source payload exceeds {MAX_TOTAL_PAYLOAD_BYTES} bytes"
        )));
    }
    Ok(())
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

pub(super) fn required_object(
    payload: &Value,
    field: &str,
) -> Result<Map<String, Value>, CapabilityError> {
    optional_object(payload, field)?.ok_or_else(|| invalid(format!("missing {field}")))
}

pub(super) fn optional_object(
    payload: &Value,
    field: &str,
) -> Result<Option<Map<String, Value>>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Object(value)) if !value.is_empty() => Ok(Some(value.clone())),
        Some(Value::Object(_)) => Err(invalid(format!("{field} must not be empty"))),
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
        .ok_or_else(|| invalid("tool source proposal writes require an idempotencyKey"))
}

pub(super) fn validate_source_kind(value: &str) -> Result<(), CapabilityError> {
    if matches!(
        value,
        "mcp_server" | "local_worker_package" | "openapi" | "external_process" | "other"
    ) {
        Ok(())
    } else {
        Err(invalid(format!("unsupported sourceKind {value}")))
    }
}

pub(super) fn validate_report_status(value: &str) -> Result<(), CapabilityError> {
    if matches!(value, "passed" | "failed" | "quarantined") {
        Ok(())
    } else {
        Err(invalid("status must be passed, failed, or quarantined"))
    }
}

pub(super) fn validate_bounded_array(
    label: &str,
    values: &[Value],
    max: usize,
) -> Result<(), CapabilityError> {
    if values.len() > max {
        return Err(invalid(format!("{label} may contain at most {max} items")));
    }
    Ok(())
}

pub(super) fn validate_resource_id_prefix(value: &str, kind: &str) -> Result<(), CapabilityError> {
    if value.starts_with(&format!("{kind}:")) {
        Ok(())
    } else {
        Err(invalid(format!("resource id must start with {kind}:")))
    }
}

pub(super) fn resource_scope(invocation: &Invocation) -> EngineResourceScope {
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
        .unwrap_or(EngineResourceScope::System)
}

fn validate_no_activation_intent(value: &Value) -> Result<(), CapabilityError> {
    walk_json(value, &mut Vec::new(), &mut |path, value| {
        if let Some(key) = path.last() {
            let key_lower = key.to_ascii_lowercase();
            let key_compact = key_lower.replace(['_', '-'], "");
            if matches!(
                key_compact.as_str(),
                "activate"
                    | "activation"
                    | "register"
                    | "registration"
                    | "enable"
                    | "enabled"
                    | "install"
                    | "installed"
                    | "execute"
                    | "execution"
                    | "start"
                    | "restart"
                    | "launch"
                    | "catalogregistration"
            ) && !is_inert_activation_proof(path, value)
            {
                return Err(invalid(format!(
                    "activation field {} is not allowed",
                    path.join(".")
                )));
            }
        }
        if let Value::String(text) = value {
            if contains_activation_intent(text) {
                return Err(invalid(format!(
                    "activation intent string {} is not allowed",
                    path.join(".")
                )));
            }
        }
        Ok(())
    })
}

fn is_inert_activation_proof(path: &[String], value: &Value) -> bool {
    if path == ["authority", "activation"] {
        return value.as_str() == Some("forbidden");
    }
    path.first().is_some_and(|key| key == "activation")
        && matches!(value, Value::Bool(false) | Value::Object(_))
}

fn contains_activation_intent(text: &str) -> bool {
    let tokens = activation_tokens(text);
    let check_len = tokens.len().min(80);
    for index in 0..check_len {
        let token = tokens[index].as_str();
        if token == "catalog"
            && tokens
                .get(index + 1)
                .is_some_and(|next| next == "registration" || next == "register")
            && !has_negated_context(&tokens, index)
        {
            return true;
        }
        if is_activation_verb(token)
            && !has_negated_context(&tokens, index)
            && has_activation_target(&tokens, index, check_len)
        {
            return true;
        }
    }
    false
}

fn activation_tokens(text: &str) -> Vec<String> {
    text.to_ascii_lowercase()
        .split(|character: char| !character.is_ascii_alphanumeric())
        .filter(|token| !token.is_empty())
        .take(96)
        .map(str::to_owned)
        .collect()
}

fn is_activation_verb(token: &str) -> bool {
    matches!(
        token,
        "activate"
            | "activating"
            | "register"
            | "registering"
            | "install"
            | "installing"
            | "enable"
            | "enabling"
            | "execute"
            | "executing"
            | "start"
            | "starting"
            | "restart"
            | "restarting"
            | "launch"
            | "launching"
    )
}

fn has_activation_target(tokens: &[String], index: usize, check_len: usize) -> bool {
    let end = (index + 7).min(check_len);
    tokens[index + 1..end]
        .iter()
        .filter(|token| !matches!(token.as_str(), "a" | "an" | "the" | "this" | "that" | "new"))
        .any(|token| {
            matches!(
                token.as_str(),
                "mcp"
                    | "server"
                    | "servers"
                    | "package"
                    | "packages"
                    | "plugin"
                    | "plugins"
                    | "tool"
                    | "tools"
                    | "worker"
                    | "workers"
                    | "process"
                    | "processes"
                    | "command"
                    | "commands"
                    | "catalog"
                    | "source"
                    | "sources"
                    | "extension"
                    | "extensions"
            )
        })
}

fn has_negated_context(tokens: &[String], index: usize) -> bool {
    let start = index.saturating_sub(4);
    tokens[start..index].iter().any(|token| {
        matches!(
            token.as_str(),
            "no" | "not" | "never" | "without" | "forbid" | "forbidden" | "deny" | "denied"
        )
    })
}

fn validate_sandbox_policy(value: &Value) -> Result<(), CapabilityError> {
    let Some(policy) = value.as_object() else {
        return Err(invalid("sandboxPolicy must be an object"));
    };
    if policy.is_empty() {
        return Err(invalid("sandboxPolicy must not be empty"));
    }
    if let Some(authority_scopes) = policy.get("authorityScopes").and_then(Value::as_array) {
        reject_wildcards(authority_scopes, "sandboxPolicy.authorityScopes")?;
    }
    if let Some(resource_kinds) = policy.get("resourceKinds").and_then(Value::as_array) {
        reject_wildcards(resource_kinds, "sandboxPolicy.resourceKinds")?;
    }
    if let Some(selectors) = policy.get("resourceSelectors").and_then(Value::as_array) {
        reject_wildcards(selectors, "sandboxPolicy.resourceSelectors")?;
    }
    Ok(())
}

fn validate_declared_schema_bounds(value: &Value) -> Result<(), CapabilityError> {
    if let Some(schemas) = value.as_array() {
        for schema in schemas {
            let bytes = serde_json::to_vec(schema)
                .map_err(|error| invalid(format!("serialize declared schema: {error}")))?
                .len();
            if bytes > MAX_SCHEMA_BYTES {
                return Err(invalid(format!(
                    "declared schema exceeds {MAX_SCHEMA_BYTES} bytes"
                )));
            }
        }
    }
    Ok(())
}

fn validate_safe_relative_path(value: &str) -> Result<(), CapabilityError> {
    if value.starts_with('/')
        || value.starts_with('~')
        || value.contains("..")
        || value.contains('\\')
        || value.contains('\0')
    {
        return Err(invalid("unsafe path value is not allowed"));
    }
    Ok(())
}

fn reject_wildcards(values: &[Value], label: &str) -> Result<(), CapabilityError> {
    for value in values {
        if value.as_str() == Some("*") {
            return Err(invalid(format!(
                "{label} may not contain wildcard authority"
            )));
        }
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

pub(super) fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}

pub(super) fn policy(message: impl Into<String>) -> CapabilityError {
    CapabilityError::Custom {
        code: "TOOL_SOURCE_POLICY_DENIED".to_owned(),
        message: message.into(),
        details: None,
    }
}
