use std::collections::BTreeMap;
use std::path::Path;

use chrono::{DateTime, Utc};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};

use super::{
    DEFAULT_STARTUP_TIMEOUT_MS, DEFAULT_STOP_TIMEOUT_MS, MAX_LOG_CAPTURE_BYTES,
    MAX_STARTUP_TIMEOUT_MS, MAX_STOP_TIMEOUT_MS, PREISSUED_BUNDLE_DELIVERY_MODE,
    STDIN_BUNDLE_DELIVERY_MODE,
};
use crate::engine::durability::resources::EngineResource;
use crate::engine::invocation::model::Invocation;
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::ids::{FunctionId, WorkerId};
use crate::engine::kernel::types::VisibilityScope;
use crate::engine::runtime::worker_protocol::WorkerRegistrationMode;

#[derive(Clone, Debug)]
pub(super) struct ActivationResource {
    pub(super) resource: EngineResource,
    pub(super) payload: Value,
    pub(super) function_id: FunctionId,
    pub(super) worker_id: WorkerId,
    pub(super) target_visibility: VisibilityScope,
    pub(super) namespace: String,
    pub(super) expires_at: DateTime<Utc>,
    pub(super) grant_id: String,
    pub(super) registration_mode: WorkerRegistrationMode,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct LaunchPlan {
    pub(super) resource_id: String,
    pub(super) expected_worker_id: WorkerId,
    pub(super) expected_function_id: FunctionId,
    pub(super) target_visibility: VisibilityScope,
    pub(super) namespace: String,
    pub(super) scope: PlanScope,
    pub(super) executable_path: String,
    pub(super) executable_digest_sha256: String,
    pub(super) executable_path_policy: String,
    pub(super) argv: Vec<String>,
    pub(super) argv_allowlist: Vec<String>,
    pub(super) env: BTreeMap<String, String>,
    pub(super) env_allowlist: Vec<String>,
    pub(super) cwd: Option<String>,
    pub(super) cwd_policy: String,
    pub(super) startup_timeout_ms: u64,
    pub(super) stop_timeout_ms: u64,
    pub(super) max_log_capture_bytes: u64,
    pub(super) activation_delivery_mode: String,
}

impl LaunchPlan {
    pub(super) fn from_payload(resource_id: &str, payload: &Value) -> Result<Self> {
        let expected_worker_id = WorkerId::new(payload_str(payload, "expectedWorkerId")?)?;
        let expected_function_id = FunctionId::new(payload_str(payload, "expectedFunctionId")?)?;
        let target_visibility = parse_target_visibility(payload_str(payload, "targetVisibility")?)?;
        let namespace = payload_str(payload, "namespace")?.to_owned();
        let scope = PlanScope::from_value(value_object(payload, "scope")?)?;
        let executable = value_object(payload, "executable")?;
        let executable_path = object_str(executable, "path")?.to_owned();
        let executable_digest_sha256 = object_str(executable, "sha256")?.to_owned();
        let executable_path_policy = object_str(executable, "pathPolicy")?.to_owned();
        let argv = string_array(payload, "argv")?;
        let argv_allowlist = string_array(payload, "argvAllowlist")?;
        let env = string_map(
            payload.get("env").unwrap_or(&Value::Object(Map::new())),
            "env",
        )?;
        let env_allowlist = string_array(payload, "envAllowlist")?;
        let cwd = optional_payload_string(payload, "cwd")?;
        let cwd_policy = payload_str(payload, "cwdPolicy")?.to_owned();
        let startup_timeout_ms = bounded_u64(
            payload,
            "startupTimeoutMs",
            DEFAULT_STARTUP_TIMEOUT_MS,
            1,
            MAX_STARTUP_TIMEOUT_MS,
        )?;
        let stop_timeout_ms = bounded_u64(
            payload,
            "stopTimeoutMs",
            DEFAULT_STOP_TIMEOUT_MS,
            1,
            MAX_STOP_TIMEOUT_MS,
        )?;
        let max_log_capture_bytes = bounded_u64(
            payload,
            "maxLogCaptureBytes",
            MAX_LOG_CAPTURE_BYTES,
            0,
            MAX_LOG_CAPTURE_BYTES,
        )?;
        let activation_delivery_mode = payload_str(payload, "activationDeliveryMode")?.to_owned();
        ensure_reviewed_governance(payload)?;
        let plan = Self {
            resource_id: resource_id.to_owned(),
            expected_worker_id,
            expected_function_id,
            target_visibility,
            namespace,
            scope,
            executable_path,
            executable_digest_sha256,
            executable_path_policy,
            argv,
            argv_allowlist,
            env,
            env_allowlist,
            cwd,
            cwd_policy,
            startup_timeout_ms,
            stop_timeout_ms,
            max_log_capture_bytes,
            activation_delivery_mode,
        };
        plan.validate_direct_exec_contract()?;
        Ok(plan)
    }

    fn validate_direct_exec_contract(&self) -> Result<()> {
        if self.activation_delivery_mode != PREISSUED_BUNDLE_DELIVERY_MODE
            && self.activation_delivery_mode != STDIN_BUNDLE_DELIVERY_MODE
        {
            return Err(EngineError::PolicyViolation(format!(
                "unsupported activation delivery mode {}",
                self.activation_delivery_mode
            )));
        }
        validate_direct_path("executable path", &self.executable_path)?;
        reject_secret_material("executable path", &self.executable_path)?;
        if self.executable_path_policy != "absolute_file" {
            return Err(EngineError::PolicyViolation(
                "worker launch plan executable path policy must be absolute_file".to_owned(),
            ));
        }
        reject_secret_material("executable path policy", &self.executable_path_policy)?;
        ensure_file_digest(&self.executable_path, &self.executable_digest_sha256)?;
        for arg in &self.argv {
            if looks_like_shell_arg(arg) {
                return Err(EngineError::PolicyViolation(format!(
                    "worker launch argv contains shell syntax: {arg}"
                )));
            }
            reject_secret_material("argv", arg)?;
            if !self.argv_allowlist.iter().any(|allowed| allowed == arg) {
                return Err(EngineError::PolicyViolation(format!(
                    "worker launch argv {arg:?} is not allowlisted"
                )));
            }
        }
        for allowed in &self.argv_allowlist {
            reject_secret_material("argv allowlist", allowed)?;
        }
        for (key, value) in &self.env {
            validate_env_key(key)?;
            if !self.env_allowlist.iter().any(|allowed| allowed == key) {
                return Err(EngineError::PolicyViolation(format!(
                    "worker launch env key {key} is not allowlisted"
                )));
            }
            if contains_secret_material(key) || contains_secret_material(value) {
                return Err(EngineError::PolicyViolation(format!(
                    "worker launch env key {key} appears secret-bearing"
                )));
            }
        }
        for key in &self.env_allowlist {
            reject_secret_material("env allowlist", key)?;
        }
        match (&self.cwd_policy[..], self.cwd.as_deref()) {
            ("none", None) => {}
            ("exact", Some(cwd)) => {
                validate_direct_path("cwd", cwd)?;
                reject_secret_material("cwd", cwd)?;
            }
            ("exact", None) => {
                return Err(EngineError::PolicyViolation(
                    "worker launch cwdPolicy exact requires cwd".to_owned(),
                ));
            }
            (other, _) => {
                return Err(EngineError::PolicyViolation(format!(
                    "unsupported worker launch cwdPolicy {other}"
                )));
            }
        }
        reject_secret_material("cwd policy", &self.cwd_policy)?;
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct PlanScope {
    pub(super) session_id: Option<String>,
    pub(super) workspace_id: Option<String>,
}

impl PlanScope {
    fn from_value(value: &Value) -> Result<Self> {
        Ok(Self {
            session_id: optional_payload_string(value, "sessionId")?,
            workspace_id: optional_payload_string(value, "workspaceId")?,
        })
    }
}

pub(super) struct LaunchActivationRequest {
    pub(super) activation_resource_id: String,
    pub(super) launch_plan_resource_id: String,
    pub(super) startup_timeout_ms: Option<u64>,
    pub(super) launch_reason: Option<String>,
    pub(super) idempotency_key: String,
}

impl LaunchActivationRequest {
    pub(super) fn from_invocation(invocation: &Invocation) -> Result<Self> {
        Ok(Self {
            activation_resource_id: non_empty_payload_string(
                &invocation.payload,
                "activationResourceId",
            )?,
            launch_plan_resource_id: non_empty_payload_string(
                &invocation.payload,
                "launchPlanResourceId",
            )?,
            startup_timeout_ms: optional_u64(&invocation.payload, "startupTimeoutMs")?,
            launch_reason: optional_payload_string(&invocation.payload, "launchReason")?,
            idempotency_key: non_empty_payload_string(&invocation.payload, "idempotencyKey")?,
        })
    }
}

pub(super) struct StopProcessRequest {
    pub(super) worker_process_resource_id: String,
    pub(super) reason: Option<String>,
}

impl StopProcessRequest {
    pub(super) fn from_invocation(invocation: &Invocation) -> Result<Self> {
        Ok(Self {
            worker_process_resource_id: non_empty_payload_string(
                &invocation.payload,
                "workerProcessResourceId",
            )?,
            reason: optional_payload_string(&invocation.payload, "reason")?,
        })
    }
}

pub(super) fn parse_target_visibility(value: &str) -> Result<VisibilityScope> {
    match value {
        "session" => Ok(VisibilityScope::Session),
        "workspace" => Ok(VisibilityScope::Workspace),
        other => Err(EngineError::PolicyViolation(format!(
            "worker launch visibility {other} is not supported"
        ))),
    }
}

pub(super) fn parse_time(value: &str, label: &str) -> Result<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|error| EngineError::PolicyViolation(format!("invalid {label}: {error}")))
}

pub(super) fn payload_str<'a>(payload: &'a Value, field: &str) -> Result<&'a str> {
    object_str(payload, field)
}

pub(super) fn non_empty_payload_string(payload: &Value, field: &str) -> Result<String> {
    let value = payload_str(payload, field)?;
    if value.trim().is_empty() {
        return Err(EngineError::PolicyViolation(format!(
            "{field} must be non-empty"
        )));
    }
    Ok(value.to_owned())
}

pub(super) fn validate_direct_path(label: &str, value: &str) -> Result<()> {
    if value.trim().is_empty()
        || value.contains('~')
        || value.contains('$')
        || value.contains('*')
        || value.contains('|')
        || value.contains(';')
        || value.contains("&&")
        || value.contains("..")
    {
        return Err(EngineError::PolicyViolation(format!(
            "worker launch {label} must be a direct absolute path without expansion"
        )));
    }
    if !Path::new(value).is_absolute() {
        return Err(EngineError::PolicyViolation(format!(
            "worker launch {label} must be absolute"
        )));
    }
    Ok(())
}

pub(super) fn contains_secret_material(value: &str) -> bool {
    let lower = value.to_ascii_lowercase();
    [
        "token",
        "secret",
        "password",
        "passwd",
        "bearer",
        "authorization",
        "api_key",
    ]
    .iter()
    .any(|needle| lower.contains(needle))
}

fn reject_secret_material(label: &str, value: &str) -> Result<()> {
    if contains_secret_material(value) {
        return Err(EngineError::PolicyViolation(format!(
            "worker launch {label} appears secret-bearing"
        )));
    }
    Ok(())
}

fn ensure_reviewed_governance(payload: &Value) -> Result<()> {
    let governance = value_object(payload, "governance")?;
    if governance.get("reviewed").and_then(Value::as_bool) != Some(true) {
        return Err(EngineError::PolicyViolation(
            "worker launch plan requires reviewed governance".to_owned(),
        ));
    }
    if object_str(governance, "decisionResourceId")?
        .trim()
        .is_empty()
    {
        return Err(EngineError::PolicyViolation(
            "worker launch plan requires decisionResourceId".to_owned(),
        ));
    }
    let evidence = governance
        .get("evidenceResourceIds")
        .and_then(Value::as_array)
        .ok_or_else(|| {
            EngineError::PolicyViolation(
                "worker launch plan governance requires evidenceResourceIds".to_owned(),
            )
        })?;
    if evidence.is_empty() {
        return Err(EngineError::PolicyViolation(
            "worker launch plan governance requires evidence".to_owned(),
        ));
    }
    Ok(())
}

fn value_object<'a>(payload: &'a Value, field: &str) -> Result<&'a Value> {
    payload
        .get(field)
        .filter(|value| value.is_object())
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!("required field {field} must be an object"))
        })
}

fn object_str<'a>(payload: &'a Value, field: &str) -> Result<&'a str> {
    payload.get(field).and_then(Value::as_str).ok_or_else(|| {
        EngineError::PolicyViolation(format!("required field {field} must be a string"))
    })
}

fn optional_payload_string(payload: &Value, field: &str) -> Result<Option<String>> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) if !value.trim().is_empty() => Ok(Some(value.clone())),
        Some(Value::String(_)) => Err(EngineError::PolicyViolation(format!(
            "{field} must be non-empty"
        ))),
        Some(other) => Err(EngineError::PolicyViolation(format!(
            "{field} must be a string, got {other}"
        ))),
    }
}

fn optional_u64(payload: &Value, field: &str) -> Result<Option<u64>> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(value)) => value
            .as_u64()
            .ok_or_else(|| {
                EngineError::PolicyViolation(format!("{field} must be an unsigned integer"))
            })
            .map(Some),
        Some(other) => Err(EngineError::PolicyViolation(format!(
            "{field} must be an unsigned integer, got {other}"
        ))),
    }
}

fn bounded_u64(payload: &Value, field: &str, default: u64, min: u64, max: u64) -> Result<u64> {
    let value = optional_u64(payload, field)?.unwrap_or(default);
    if value < min || value > max {
        return Err(EngineError::PolicyViolation(format!(
            "{field} must be between {min} and {max}"
        )));
    }
    Ok(value)
}

fn string_array(payload: &Value, field: &str) -> Result<Vec<String>> {
    let items = payload
        .get(field)
        .and_then(Value::as_array)
        .ok_or_else(|| EngineError::PolicyViolation(format!("{field} must be an array")))?;
    items
        .iter()
        .map(|item| {
            item.as_str().map(str::to_owned).ok_or_else(|| {
                EngineError::PolicyViolation(format!("{field} entries must be strings"))
            })
        })
        .collect()
}

fn string_map(payload: &Value, field: &str) -> Result<BTreeMap<String, String>> {
    let object = payload.as_object().ok_or_else(|| {
        EngineError::PolicyViolation(format!("{field} must be an object of strings"))
    })?;
    let mut values = BTreeMap::new();
    for (key, value) in object {
        let Some(value) = value.as_str() else {
            return Err(EngineError::PolicyViolation(format!(
                "{field}.{key} must be a string"
            )));
        };
        values.insert(key.clone(), value.to_owned());
    }
    Ok(values)
}

fn ensure_file_digest(path: &str, expected: &str) -> Result<()> {
    if expected.len() != 64 || !expected.chars().all(|ch| ch.is_ascii_hexdigit()) {
        return Err(EngineError::PolicyViolation(
            "worker launch executable digest must be sha256 hex".to_owned(),
        ));
    }
    let bytes = std::fs::read(path).map_err(|error| {
        EngineError::PolicyViolation(format!("worker launch executable cannot be read: {error}"))
    })?;
    let actual = hex::encode(Sha256::digest(bytes));
    if !actual.eq_ignore_ascii_case(expected) {
        return Err(EngineError::PolicyViolation(
            "worker launch executable digest mismatch".to_owned(),
        ));
    }
    Ok(())
}

fn looks_like_shell_arg(value: &str) -> bool {
    value.contains('|')
        || value.contains(';')
        || value.contains("&&")
        || value.contains('`')
        || value.contains("$(")
        || value.contains('>')
        || value.contains('<')
}

fn validate_env_key(value: &str) -> Result<()> {
    if value.trim().is_empty()
        || !value
            .chars()
            .all(|ch| ch.is_ascii_uppercase() || ch.is_ascii_digit() || ch == '_')
    {
        return Err(EngineError::PolicyViolation(format!(
            "worker launch env key {value:?} is invalid"
        )));
    }
    Ok(())
}
