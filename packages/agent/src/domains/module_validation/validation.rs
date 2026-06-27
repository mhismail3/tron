use serde_json::{Map, Value, json};

use crate::engine::{EngineResourceScope, Invocation};
use crate::shared::server::errors::CapabilityError;

pub(super) const LIST_LIMIT_DEFAULT: usize = 25;
pub(super) const LIST_LIMIT_MAX: usize = 100;
pub(super) const REPORT_ID_MAX_BYTES: usize = 160;
pub(super) const TOKEN_MAX_BYTES: usize = 256;
pub(super) const TITLE_MAX_BYTES: usize = 160;
pub(super) const SUMMARY_MAX_BYTES: usize = 2_000;
pub(super) const IDEMPOTENCY_KEY_MAX_BYTES: usize = 256;
pub(super) const MAX_REFS: usize = 25;
pub(super) const MAX_CHECKS: usize = 25;
pub(super) const PREVIEW_MAX_BYTES: usize = 280;

const FORBIDDEN_FIELDS: &[&str] = &[
    "code",
    "sourceCode",
    "prompt",
    "messages",
    "command",
    "rawCommand",
    "commandLine",
    "shell",
    "argv",
    "env",
    "environment",
    "environmentValues",
    "dependencyInstall",
    "packageManager",
    "fileContents",
    "fileContent",
    "rawFileContents",
    "absolutePath",
    "localPath",
    "unsafePath",
    "rawLogs",
    "rawLog",
    "logs",
    "stdout",
    "stderr",
    "stdin",
    "rawValidationReportBody",
    "validationReportBody",
    "body",
    "rootPath",
    "workingDirectory",
    "cwd",
    "path",
    "paths",
    "grantId",
    "authorityId",
    "rawGrantId",
    "rawAuthorityId",
    "debugPayload",
    "chainOfThought",
];

pub(super) fn reject_unsafe_payload(payload: &Value) -> Result<(), CapabilityError> {
    reject_forbidden_fields(payload)?;
    reject_unsafe_strings(payload)
}

pub(super) fn required_string(payload: &Value, field: &str) -> Result<String, CapabilityError> {
    optional_string(payload, field)?.ok_or_else(|| invalid(format!("{field} is required")))
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

pub(super) fn optional_bool(payload: &Value, field: &str) -> Result<Option<bool>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(value)) => Ok(Some(*value)),
        Some(_) => Err(invalid(format!("{field} must be a boolean"))),
    }
}

pub(super) fn optional_array(
    payload: &Value,
    field: &str,
) -> Result<Option<Vec<Value>>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Array(items)) => Ok(Some(items.clone())),
        Some(_) => Err(invalid(format!("{field} must be an array"))),
    }
}

pub(super) fn bounded_text(
    field: &str,
    value: &str,
    max_bytes: usize,
) -> Result<String, CapabilityError> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Err(invalid(format!("{field} must not be empty")));
    }
    if trimmed.len() > max_bytes {
        return Err(invalid(format!("{field} exceeds {max_bytes} bytes")));
    }
    reject_secret_like(field, trimmed)?;
    reject_provider_visible_token_like(field, trimmed)?;
    reject_prompt_like(field, trimmed)?;
    reject_shell_command_like(field, trimmed)?;
    Ok(trimmed.to_owned())
}

pub(super) fn bounded_token(
    field: &str,
    value: &str,
    max_bytes: usize,
) -> Result<String, CapabilityError> {
    let trimmed = value.trim();
    if trimmed.is_empty()
        || trimmed == "*"
        || trimmed.eq_ignore_ascii_case("all")
        || trimmed.eq_ignore_ascii_case("any")
        || trimmed.len() > max_bytes
        || !trimmed
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b':' | b'-' | b'_' | b'.'))
    {
        return Err(invalid(format!(
            "{field} must be a bounded non-wildcard token"
        )));
    }
    reject_secret_like(field, trimmed)?;
    reject_path_like(field, trimmed)?;
    Ok(trimmed.to_owned())
}

pub(super) fn bounded_provider_visible_token(
    field: &str,
    value: &str,
    max_bytes: usize,
) -> Result<String, CapabilityError> {
    let trimmed = bounded_token(field, value, max_bytes)?;
    reject_provider_visible_token_like(field, &trimmed)?;
    Ok(trimmed)
}

pub(super) fn idempotency_key(
    invocation: &Invocation,
    payload: &Value,
) -> Result<String, CapabilityError> {
    if let Some(key) = invocation.causal_context.idempotency_key.as_deref() {
        return bounded_token("idempotencyKey", key, IDEMPOTENCY_KEY_MAX_BYTES);
    }
    optional_string(payload, "idempotencyKey")?
        .map(|key| bounded_token("idempotencyKey", &key, IDEMPOTENCY_KEY_MAX_BYTES))
        .transpose()?
        .ok_or_else(|| invalid("module_validation_record requires an idempotencyKey"))
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
        .ok_or_else(|| invalid("module validation requires trusted session or workspace scope"))
}

pub(super) fn lifecycle_state(payload: &Value) -> Result<String, CapabilityError> {
    let state = optional_string(payload, "lifecycleState")?.unwrap_or_else(|| "pending".to_owned());
    if matches!(
        state.as_str(),
        "pending" | "passed" | "failed" | "superseded" | "archived"
    ) {
        Ok(state)
    } else {
        Err(invalid(format!(
            "unsupported module validation report lifecycle {state}"
        )))
    }
}

pub(super) fn required_ref_array(
    payload: &Value,
    field: &str,
) -> Result<Vec<Value>, CapabilityError> {
    let refs =
        optional_array(payload, field)?.ok_or_else(|| invalid(format!("{field} is required")))?;
    if refs.is_empty() {
        return Err(invalid(format!("{field} must not be empty")));
    }
    validate_ref_array(field, &refs, MAX_REFS)
}

pub(super) fn validate_ref_array(
    label: &str,
    refs: &[Value],
    max_items: usize,
) -> Result<Vec<Value>, CapabilityError> {
    if refs.len() > max_items {
        return Err(invalid(format!(
            "{label} may contain at most {max_items} items"
        )));
    }
    refs.iter()
        .map(|value| sanitize_ref_item(label, value))
        .collect()
}

pub(super) fn validate_command_result_ref_array(
    label: &str,
    refs: &[Value],
    max_items: usize,
) -> Result<Vec<Value>, CapabilityError> {
    let refs = validate_ref_array(label, refs, max_items)?;
    for item in &refs {
        for key in ["preview", "summary"] {
            if let Some(value) = item.get(key).and_then(Value::as_str) {
                reject_shell_command_like(&format!("{label}.{key}"), value)?;
            }
        }
    }
    Ok(refs)
}

pub(super) fn validation_result(payload: &Value) -> Result<Value, CapabilityError> {
    let status = optional_string(payload, "validationStatus")?
        .map(|value| bounded_provider_visible_token("validationStatus", &value, TOKEN_MAX_BYTES))
        .transpose()?
        .unwrap_or_else(|| "pending_review".to_owned());
    if !matches!(
        status.as_str(),
        "pending_review" | "passed" | "failed" | "blocked" | "superseded"
    ) {
        return Err(invalid(format!("unsupported validationStatus {status}")));
    }
    let checks = validate_check_array(
        "validationChecks",
        &optional_array(payload, "validationChecks")?.unwrap_or_default(),
    )?;
    Ok(json!({
        "status": status,
        "checks": checks
    }))
}

pub(super) fn validate_check_array(
    label: &str,
    checks: &[Value],
) -> Result<Vec<Value>, CapabilityError> {
    if checks.len() > MAX_CHECKS {
        return Err(invalid(format!(
            "{label} may contain at most {MAX_CHECKS} items"
        )));
    }
    checks
        .iter()
        .map(|value| sanitize_check_item(label, value))
        .collect()
}

fn sanitize_check_item(label: &str, value: &Value) -> Result<Value, CapabilityError> {
    let Value::Object(item) = value else {
        return Err(invalid(format!("{label} must be an object")));
    };
    let name = item
        .get("name")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(format!("{label} requires name")))?;
    let status = item
        .get("status")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(format!("{label} requires status")))?;
    let mut sanitized = Map::new();
    sanitized.insert(
        "name".to_owned(),
        json!(bounded_provider_visible_token(
            "check.name",
            name,
            TOKEN_MAX_BYTES
        )?),
    );
    sanitized.insert(
        "status".to_owned(),
        json!(bounded_provider_visible_token(
            "check.status",
            status,
            TOKEN_MAX_BYTES
        )?),
    );
    if let Some(summary) = item.get("summary").and_then(Value::as_str) {
        sanitized.insert(
            "summary".to_owned(),
            json!(bounded_text("check.summary", summary, PREVIEW_MAX_BYTES)?),
        );
    }
    if let Some(fingerprint) = item.get("fingerprint").and_then(Value::as_str) {
        sanitized.insert(
            "fingerprint".to_owned(),
            json!(bounded_provider_visible_token(
                "check.fingerprint",
                fingerprint,
                TOKEN_MAX_BYTES
            )?),
        );
    }
    if item
        .keys()
        .any(|key| !matches!(key.as_str(), "name" | "status" | "summary" | "fingerprint"))
    {
        return Err(invalid(format!(
            "{label} may contain only name, status, summary, and fingerprint"
        )));
    }
    Ok(Value::Object(sanitized))
}

fn sanitize_ref_item(label: &str, value: &Value) -> Result<Value, CapabilityError> {
    let Value::Object(item) = value else {
        return Err(invalid(format!("{label} must be an object")));
    };
    let kind = item
        .get("kind")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(format!("{label} requires kind")))?;
    let id = item
        .get("id")
        .or_else(|| item.get("resourceId"))
        .and_then(Value::as_str)
        .ok_or_else(|| invalid(format!("{label} requires id or resourceId")))?;
    let mut sanitized = Map::new();
    sanitized.insert(
        "kind".to_owned(),
        json!(bounded_provider_visible_token(
            "ref.kind",
            kind,
            TOKEN_MAX_BYTES
        )?),
    );
    if item.get("resourceId").is_some() {
        sanitized.insert(
            "resourceId".to_owned(),
            json!(bounded_provider_visible_token(
                "ref.resourceId",
                id,
                TOKEN_MAX_BYTES
            )?),
        );
    } else {
        sanitized.insert(
            "id".to_owned(),
            json!(bounded_provider_visible_token(
                "ref.id",
                id,
                TOKEN_MAX_BYTES
            )?),
        );
    }
    if let Some(role) = item.get("role").and_then(Value::as_str) {
        sanitized.insert(
            "role".to_owned(),
            json!(bounded_provider_visible_token(
                "ref.role",
                role,
                TOKEN_MAX_BYTES
            )?),
        );
    }
    if let Some(version_id) = item.get("versionId").and_then(Value::as_str) {
        sanitized.insert(
            "versionId".to_owned(),
            json!(bounded_provider_visible_token(
                "ref.versionId",
                version_id,
                TOKEN_MAX_BYTES
            )?),
        );
    }
    for key in ["status", "fingerprint", "preview", "summary"] {
        if let Some(value) = item.get(key).and_then(Value::as_str) {
            let sanitized_value = if matches!(key, "preview" | "summary") {
                bounded_text(&format!("ref.{key}"), value, PREVIEW_MAX_BYTES)?
            } else {
                bounded_provider_visible_token(&format!("ref.{key}"), value, TOKEN_MAX_BYTES)?
            };
            sanitized.insert(key.to_owned(), json!(sanitized_value));
        }
    }
    if item.keys().any(|key| {
        !matches!(
            key.as_str(),
            "kind"
                | "id"
                | "resourceId"
                | "role"
                | "versionId"
                | "status"
                | "fingerprint"
                | "preview"
                | "summary"
        )
    }) {
        return Err(invalid(format!(
            "{label} may contain only kind, id/resourceId, role, versionId, status, fingerprint, preview, and summary"
        )));
    }
    Ok(Value::Object(sanitized))
}

fn reject_forbidden_fields(value: &Value) -> Result<(), CapabilityError> {
    match value {
        Value::Object(object) => {
            for (key, child) in object {
                if FORBIDDEN_FIELDS
                    .iter()
                    .any(|forbidden| forbidden.eq_ignore_ascii_case(key))
                {
                    return Err(invalid(format!(
                        "{key} is not accepted; module validation reports store bounded metadata and refs only"
                    )));
                }
                reject_forbidden_fields(child)?;
            }
        }
        Value::Array(items) => {
            for child in items {
                reject_forbidden_fields(child)?;
            }
        }
        _ => {}
    }
    Ok(())
}

fn reject_unsafe_strings(value: &Value) -> Result<(), CapabilityError> {
    match value {
        Value::String(text) => {
            reject_secret_like("payload", text)?;
            reject_prompt_like("payload", text)?;
            reject_path_like("payload", text)
        }
        Value::Array(items) => {
            for child in items {
                reject_unsafe_strings(child)?;
            }
            Ok(())
        }
        Value::Object(object) => {
            for child in object.values() {
                reject_unsafe_strings(child)?;
            }
            Ok(())
        }
        _ => Ok(()),
    }
}

fn reject_path_like(field: &str, value: &str) -> Result<(), CapabilityError> {
    let trimmed = value.trim();
    let lower = trimmed.to_ascii_lowercase();
    if trimmed == "/"
        || trimmed.starts_with('/')
        || trimmed.starts_with('~')
        || trimmed.starts_with("./")
        || trimmed.contains("..")
        || trimmed.contains('\\')
        || trimmed.contains("//")
        || lower.contains("packages/agent/skills")
        || lower.contains("/users/")
    {
        return Err(invalid(format!(
            "{field} must not contain unsafe path-like material"
        )));
    }
    Ok(())
}

fn reject_secret_like(field: &str, value: &str) -> Result<(), CapabilityError> {
    let lowered = value.to_ascii_lowercase();
    if lowered.contains("bearer ")
        || lowered.starts_with("sk-")
        || lowered.starts_with("ghp_")
        || lowered.starts_with("xox")
        || lowered.contains("api_key")
        || lowered.contains("apikey")
        || lowered.contains("password=")
        || lowered.contains("secret=")
        || lowered.contains("authorization:")
        || lowered.contains("token:")
        || lowered.contains("\"token\"")
        || lowered.contains("grant-")
        || lowered.contains("grant_")
        || lowered.contains("grant:")
        || looks_like_email(value.trim())
    {
        return Err(invalid(format!(
            "{field} must not contain credential-like material"
        )));
    }
    Ok(())
}

fn reject_provider_visible_token_like(field: &str, value: &str) -> Result<(), CapabilityError> {
    if contains_github_token_like(value)
        || contains_jwt_like(value)
        || contains_aws_access_key_like(value)
    {
        return Err(invalid(format!(
            "{field} must not contain token-like material"
        )));
    }
    Ok(())
}

fn contains_github_token_like(value: &str) -> bool {
    let lowered = value.to_ascii_lowercase();
    let pat_prefix = "github_pat_";
    let short_prefixes = ["ghp_", "gho_", "ghu_", "ghs_", "ghr_"];
    token_like_run_after_prefix(&lowered, pat_prefix, 20)
        || short_prefixes
            .iter()
            .any(|prefix| token_like_run_after_prefix(&lowered, prefix, 20))
}

fn token_like_run_after_prefix(value: &str, prefix: &str, min_suffix_len: usize) -> bool {
    value.match_indices(prefix).any(|(index, _)| {
        let after_prefix = &value[index + prefix.len()..];
        after_prefix
            .bytes()
            .take_while(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
            .count()
            >= min_suffix_len
    })
}

fn contains_jwt_like(value: &str) -> bool {
    value.match_indices("eyJ").any(|(index, _)| {
        let candidate = &value[index..];
        let mut parts = candidate.splitn(3, '.');
        let (Some(header), Some(payload), Some(signature_and_suffix)) =
            (parts.next(), parts.next(), parts.next())
        else {
            return false;
        };
        if !is_base64url_part(header) || !is_base64url_part(payload) {
            return false;
        }
        let signature_len = signature_and_suffix
            .bytes()
            .take_while(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
            .count();
        signature_len >= 8
    })
}

fn is_base64url_part(part: &str) -> bool {
    part.len() >= 8
        && part
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

fn contains_aws_access_key_like(value: &str) -> bool {
    let bytes = value.as_bytes();
    bytes.windows(20).any(|window| {
        matches!(&window[..4], b"AKIA" | b"ASIA")
            && window
                .iter()
                .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit())
    })
}

fn reject_prompt_like(field: &str, value: &str) -> Result<(), CapabilityError> {
    let lowered = value.to_ascii_lowercase();
    if lowered.contains("ignore previous")
        || lowered.contains("system prompt")
        || lowered.contains("hidden chain")
        || lowered.contains("chain-of-thought")
        || lowered.contains("developer message")
    {
        return Err(invalid(format!(
            "{field} must not contain prompt-injection-like material"
        )));
    }
    Ok(())
}

pub(super) fn contains_shell_command_like(value: &str) -> bool {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return false;
    }
    let lowered = trimmed.to_ascii_lowercase();
    let tokens = lowered
        .split_whitespace()
        .map(|token| token.trim_matches(|character: char| matches!(character, '`' | '"' | '\'')))
        .collect::<Vec<_>>();
    let first_token = tokens.first().copied().unwrap_or_default();
    let second_token = tokens.get(1).copied().unwrap_or_default();
    if first_token.starts_with("scripts/tron") || first_token.starts_with("./") {
        return true;
    }
    if command_token_pair_is_shell_like(first_token, second_token) {
        return true;
    }
    [
        " cargo test",
        " cargo check",
        " cargo clippy",
        " cargo fmt",
        " xcodebuild test",
        " xcodegen generate",
        " scripts/tron ",
        " tron ci",
        " tron dev",
        " git status",
        " git diff",
        " git ls-files",
    ]
    .iter()
    .any(|needle| lowered.contains(needle))
        || lowered.contains(" && ")
        || lowered.contains(" || ")
        || lowered.contains("$(")
        || lowered.contains('`')
}

fn command_token_pair_is_shell_like(first_token: &str, second_token: &str) -> bool {
    if first_token.is_empty() || second_token.is_empty() {
        return false;
    }
    if second_token.starts_with('-')
        || second_token.starts_with("./")
        || second_token.starts_with('/')
        || second_token.contains('=')
    {
        return matches!(
            first_token,
            "cargo"
                | "git"
                | "xcodebuild"
                | "xcodegen"
                | "tron"
                | "bash"
                | "sh"
                | "zsh"
                | "python"
                | "python3"
                | "node"
                | "npm"
                | "pnpm"
                | "yarn"
                | "make"
                | "swift"
                | "swiftc"
                | "rustc"
                | "rustup"
                | "docker"
                | "brew"
                | "curl"
                | "wget"
        );
    }
    matches!(
        (first_token, second_token),
        (
            "cargo",
            "test" | "check" | "clippy" | "fmt" | "build" | "run" | "doc" | "metadata"
        ) | (
            "git",
            "status" | "diff" | "show" | "log" | "ls-files" | "grep" | "add" | "commit"
        ) | ("xcodebuild", "test" | "build" | "clean")
            | ("xcodegen", "generate")
            | ("tron", "ci" | "dev" | "test" | "build")
            | ("bash" | "sh" | "zsh", _)
            | (
                "python" | "python3" | "node" | "npm" | "pnpm" | "yarn" | "make",
                _
            )
            | ("swift" | "swiftc" | "rustc" | "rustup", _)
            | ("docker" | "brew" | "curl" | "wget", _)
    )
}

fn reject_shell_command_like(field: &str, value: &str) -> Result<(), CapabilityError> {
    if contains_shell_command_like(value) {
        return Err(invalid(format!(
            "{field} must not contain shell-command-like material"
        )));
    }
    Ok(())
}

fn looks_like_email(text: &str) -> bool {
    let Some((local, domain)) = text.split_once('@') else {
        return false;
    };
    !local.is_empty() && domain.contains('.') && !domain.ends_with('.')
}

pub(super) fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}
