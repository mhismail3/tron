use serde_json::{Map, Value, json};

use crate::engine::{EngineResourceInspection, EngineResourceScope, Invocation};
use crate::shared::server::errors::CapabilityError;

pub(super) const LIST_LIMIT_DEFAULT: usize = 25;
pub(super) const LIST_LIMIT_MAX: usize = 100;
pub(super) const REQUEST_ID_MAX_BYTES: usize = 160;
pub(super) const DECISION_ID_MAX_BYTES: usize = 160;
pub(super) const TOKEN_MAX_BYTES: usize = 256;
pub(super) const TITLE_MAX_BYTES: usize = 160;
pub(super) const SUMMARY_MAX_BYTES: usize = 2_000;
pub(super) const IDEMPOTENCY_KEY_MAX_BYTES: usize = 256;
pub(super) const MAX_REFS: usize = 25;
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
        .ok_or_else(|| invalid("module_install write operations require an idempotencyKey"))
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
        .ok_or_else(|| invalid("module install requires trusted session or workspace scope"))
}

pub(super) fn request_lifecycle_state(payload: &Value) -> Result<String, CapabilityError> {
    let state =
        optional_string(payload, "lifecycleState")?.unwrap_or_else(|| "pending_review".to_owned());
    if matches!(state.as_str(), "pending_review" | "superseded" | "archived") {
        Ok(state)
    } else {
        Err(invalid(format!(
            "unsupported module install request lifecycle {state}"
        )))
    }
}

pub(super) fn decision_lifecycle_state(payload: &Value) -> Result<String, CapabilityError> {
    let state = required_string(payload, "decision")?;
    if matches!(state.as_str(), "approved" | "rejected" | "denied") {
        Ok(if state == "approved" {
            "install_candidate".to_owned()
        } else {
            "rejected".to_owned()
        })
    } else {
        Err(invalid(format!(
            "unsupported module install decision {state}"
        )))
    }
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

pub(super) fn validate_dependency_policy_status(payload: &Value) -> Result<Value, CapabilityError> {
    let status = optional_string(payload, "dependencyPolicyStatus")?
        .unwrap_or_else(|| "not_required".to_owned());
    if !matches!(
        status.as_str(),
        "not_required" | "linked" | "satisfied" | "blocked"
    ) {
        return Err(invalid(format!(
            "unsupported dependencyPolicyStatus {status}"
        )));
    }
    Ok(json!({
        "status": bounded_provider_visible_token("dependencyPolicyStatus", &status, TOKEN_MAX_BYTES)?,
        "metadataOnly": true,
        "restored": false,
        "packageManagerUsed": false
    }))
}

pub(super) fn validate_rollback_readiness(payload: &Value) -> Result<Value, CapabilityError> {
    let readiness =
        optional_string(payload, "rollbackReadiness")?.unwrap_or_else(|| "not_proven".to_owned());
    if !matches!(readiness.as_str(), "not_proven" | "ready" | "blocked") {
        return Err(invalid(format!(
            "unsupported rollbackReadiness {readiness}"
        )));
    }
    Ok(json!({
        "status": bounded_provider_visible_token("rollbackReadiness", &readiness, TOKEN_MAX_BYTES)?,
        "metadataOnly": true,
        "rollbackExecuted": false
    }))
}

pub(super) fn validate_approval_refs(
    payload: &Value,
) -> Result<(String, Option<String>), CapabilityError> {
    let request_resource_id = required_string(payload, "approvalRequestResourceId")?;
    validate_approval_request_resource_id(&request_resource_id)?;
    let decision_resource_id = optional_string(payload, "approvalDecisionResourceId")?
        .map(|id| {
            validate_approval_decision_resource_id(&id)?;
            Ok::<_, CapabilityError>(id)
        })
        .transpose()?;
    Ok((request_resource_id, decision_resource_id))
}

pub(super) fn validate_module_validation_report_resource_id(
    value: &str,
) -> Result<(), CapabilityError> {
    if !value.starts_with("module_validation_report:") {
        return Err(invalid(
            "moduleValidationReportResourceId has unsupported resource kind",
        ));
    }
    bounded_provider_visible_token("moduleValidationReportResourceId", value, TOKEN_MAX_BYTES)
        .map(|_| ())
}

pub(super) fn validate_module_install_request_resource_id(
    value: &str,
) -> Result<(), CapabilityError> {
    if !value.starts_with("module_install_request:") {
        return Err(invalid(
            "moduleInstallRequestResourceId has unsupported resource kind",
        ));
    }
    bounded_provider_visible_token("moduleInstallRequestResourceId", value, TOKEN_MAX_BYTES)
        .map(|_| ())
}

pub(super) fn validate_module_install_decision_resource_id(
    value: &str,
) -> Result<(), CapabilityError> {
    if !value.starts_with("module_install_decision:") {
        return Err(invalid(
            "moduleInstallDecisionResourceId has unsupported resource kind",
        ));
    }
    bounded_provider_visible_token("moduleInstallDecisionResourceId", value, TOKEN_MAX_BYTES)
        .map(|_| ())
}

pub(super) fn validate_approval_request_resource_id(value: &str) -> Result<(), CapabilityError> {
    if !value.starts_with("approval_request:") {
        return Err(invalid(
            "approvalRequestResourceId has unsupported resource kind",
        ));
    }
    bounded_provider_visible_token("approvalRequestResourceId", value, TOKEN_MAX_BYTES).map(|_| ())
}

pub(super) fn validate_approval_decision_resource_id(value: &str) -> Result<(), CapabilityError> {
    if !value.starts_with("approval_decision:") {
        return Err(invalid(
            "approvalDecisionResourceId has unsupported resource kind",
        ));
    }
    bounded_provider_visible_token("approvalDecisionResourceId", value, TOKEN_MAX_BYTES).map(|_| ())
}

pub(super) fn ensure_validation_report_prerequisite(
    inspection: &EngineResourceInspection,
    expected_scope: &EngineResourceScope,
) -> Result<Value, CapabilityError> {
    if inspection.resource.kind != "module_validation_report" {
        return Err(invalid(
            "module install requires a module_validation_report prerequisite",
        ));
    }
    if inspection.resource.schema_id != "tron.resource.module_validation_report.v1" {
        return Err(invalid(
            "module install requires the current module_validation_report schema",
        ));
    }
    if &inspection.resource.scope != expected_scope {
        return Err(invalid(
            "module install validation report must be in the current scope",
        ));
    }
    if !matches!(inspection.resource.lifecycle.as_str(), "passed") {
        return Err(invalid("module install requires passed validation report"));
    }
    let current = inspection
        .resource
        .current_version_id
        .as_deref()
        .ok_or_else(|| invalid("module validation report has no current version"))?;
    let version = inspection
        .versions
        .iter()
        .find(|version| version.version_id == current)
        .ok_or_else(|| invalid("module validation report current version is missing"))?;
    if !version.state.may_be_current() {
        return Err(invalid(
            "module validation report current version is unavailable",
        ));
    }
    let payload = &version.payload;
    if payload.get("schemaVersion").and_then(Value::as_str)
        != Some("tron.module_validation_report.v1")
    {
        return Err(invalid(
            "module install requires current module validation payload version",
        ));
    }
    if payload
        .pointer("/validation/status")
        .and_then(Value::as_str)
        != Some("passed")
    {
        return Err(invalid("module install requires validation status passed"));
    }
    if ref_count(payload.pointer("/subjectRefs/modules")) == 0 {
        return Err(invalid("module install requires bounded module refs"));
    }
    if ref_count(payload.pointer("/evidence/docs")) == 0 {
        return Err(invalid("module install requires docs evidence"));
    }
    if ref_count(payload.pointer("/evidence/tests")) == 0 {
        return Err(invalid("module install requires tests evidence"));
    }
    let proof = payload
        .get("noInstallNoExecutionProof")
        .and_then(Value::as_object)
        .ok_or_else(|| invalid("module install requires no-install/no-execution proof"))?;
    for (field, expected) in [
        ("noInstall", true),
        ("noExecution", true),
        ("networkAccessPerformed", false),
        ("dependencyRestorePerformed", false),
        ("packageManagerUsed", false),
        ("repoManagedSkillsTouched", false),
        ("rawCommandsStored", false),
        ("rawLogsStored", false),
        ("fileContentsStored", false),
        ("absolutePathsStored", false),
    ] {
        if proof.get(field).and_then(Value::as_bool) != Some(expected) {
            return Err(invalid(format!(
                "module install requires validation proof {field}={expected}"
            )));
        }
    }
    if proof.get("networkPolicy").and_then(Value::as_str) != Some("none") {
        return Err(invalid(
            "module install requires validation proof networkPolicy none",
        ));
    }
    Ok(json!({
        "kind": inspection.resource.kind,
        "resourceId": inspection.resource.resource_id,
        "versionId": version.version_id,
        "schemaId": inspection.resource.schema_id,
        "status": "passed",
        "currentVersionRevalidated": true,
        "moduleRefCount": ref_count(payload.pointer("/subjectRefs/modules")),
        "proposalRefCount": ref_count(payload.pointer("/subjectRefs/proposals")),
        "docEvidenceCount": ref_count(payload.pointer("/evidence/docs")),
        "testEvidenceCount": ref_count(payload.pointer("/evidence/tests")),
        "noInstallNoExecutionProof": {
            "noInstall": true,
            "noExecution": true,
            "networkPolicy": "none",
            "dependencyRestorePerformed": false,
            "packageManagerUsed": false,
            "networkAccessPerformed": false
        }
    }))
}

fn ref_count(value: Option<&Value>) -> usize {
    value.and_then(Value::as_array).map_or(0, Vec::len)
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
                        "{key} is not accepted; module install records store bounded metadata and refs only"
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

fn reject_shell_command_like(field: &str, value: &str) -> Result<(), CapabilityError> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Ok(());
    }
    let lowered = trimmed.to_ascii_lowercase();
    let tokens = lowered
        .split(|ch: char| ch.is_ascii_whitespace() || matches!(ch, ';' | '|' | '&'))
        .filter(|token| !token.is_empty())
        .collect::<Vec<_>>();
    if tokens.iter().any(|token| {
        matches!(
            *token,
            "cargo"
                | "npm"
                | "pnpm"
                | "yarn"
                | "bun"
                | "pip"
                | "python"
                | "python3"
                | "node"
                | "bash"
                | "sh"
                | "zsh"
                | "xcodebuild"
                | "swift"
                | "git"
                | "curl"
                | "wget"
                | "make"
        )
    }) || lowered.contains(" && ")
        || lowered.contains(" | ")
        || lowered.starts_with("./")
    {
        return Err(invalid(format!(
            "{field} must not contain raw shell-command-like material"
        )));
    }
    Ok(())
}

fn looks_like_email(value: &str) -> bool {
    let Some((local, domain)) = value.split_once('@') else {
        return false;
    };
    !local.is_empty()
        && domain.contains('.')
        && domain
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-'))
}

pub(super) fn invalid(message: impl Into<String>) -> CapabilityError {
    CapabilityError::InvalidParams {
        message: message.into(),
    }
}
