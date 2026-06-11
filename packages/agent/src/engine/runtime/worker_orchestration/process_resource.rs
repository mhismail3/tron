use std::collections::BTreeMap;

use chrono::Utc;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::contracts::{
    ActivationResource, LaunchActivationRequest, LaunchPlan, contains_secret_material,
    non_empty_payload_string,
};
use super::supervisor::{WorkerProcessHandle, WorkerProcessStartResult, WorkerProcessStopResult};
use crate::engine::durability::resources::{EngineResourceInspection, EngineResourceScope};
use crate::engine::invocation::model::Invocation;
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::runtime::worker_protocol::WorkerRegistrationMode;

#[derive(Clone, Debug)]
pub(super) struct RedactedOutput {
    stdout_snippet: String,
    stderr_snippet: String,
    output_truncated: bool,
    redacted: bool,
    max_bytes: u64,
}

impl RedactedOutput {
    pub(super) fn empty(max_bytes: u64) -> Self {
        Self {
            stdout_snippet: String::new(),
            stderr_snippet: String::new(),
            output_truncated: false,
            redacted: true,
            max_bytes,
        }
    }

    pub(super) fn from_start_result(result: &WorkerProcessStartResult, max_bytes: u64) -> Self {
        Self {
            stdout_snippet: redact_text(&result.stdout_snippet, max_bytes as usize),
            stderr_snippet: redact_text(&result.stderr_snippet, max_bytes as usize),
            output_truncated: result.output_truncated,
            redacted: true,
            max_bytes,
        }
    }

    pub(super) fn from_stop_result(result: &WorkerProcessStopResult, max_bytes: u64) -> Self {
        Self {
            stdout_snippet: redact_text(&result.stdout_snippet, max_bytes as usize),
            stderr_snippet: redact_text(&result.stderr_snippet, max_bytes as usize),
            output_truncated: result.output_truncated,
            redacted: true,
            max_bytes,
        }
    }

    pub(super) fn json(&self) -> Value {
        json!({
            "stdoutSnippet": self.stdout_snippet,
            "stderrSnippet": self.stderr_snippet,
            "outputTruncated": self.output_truncated,
            "redacted": self.redacted,
            "maxBytes": self.max_bytes,
        })
    }
}

pub(super) fn process_payload(
    status: &str,
    process_resource_id: &str,
    activation: &ActivationResource,
    plan: &LaunchPlan,
    request: &LaunchActivationRequest,
    handle: Option<WorkerProcessHandle>,
    logs: RedactedOutput,
    failure_reason: Option<String>,
) -> Value {
    let handle_value = handle
        .map(|handle| serde_json::to_value(handle).expect("process handle serializes"))
        .unwrap_or(Value::Null);
    json!({
        "status": status,
        "activationResourceId": activation.resource.resource_id,
        "launchPlanResourceId": plan.resource_id,
        "workerProcessResourceId": process_resource_id,
        "workerId": activation.worker_id.as_str(),
        "functionId": activation.function_id.as_str(),
        "targetVisibility": activation.target_visibility.as_str(),
        "namespace": activation.namespace,
        "scope": activation.payload["scope"].clone(),
        "launch": {
            "source": "worker::launch_activation",
            "reason": request.launch_reason,
            "startupTimeoutMs": request.startup_timeout_ms.unwrap_or(plan.startup_timeout_ms),
            "stopTimeoutMs": plan.stop_timeout_ms,
            "maxLogCaptureBytes": plan.max_log_capture_bytes,
            "activationDeliveryMode": plan.activation_delivery_mode,
            "requestedAt": Utc::now().to_rfc3339(),
            "idempotencyKeyFingerprint": short_hash(&request.idempotency_key),
        },
        "process": {
            "directExec": true,
            "executablePath": plan.executable_path,
            "executableDigestSha256": plan.executable_digest_sha256,
            "executablePathPolicy": plan.executable_path_policy,
            "argv": plan.argv,
            "envKeys": plan.env.keys().cloned().collect::<Vec<_>>(),
            "cwd": plan.cwd,
            "cwdPolicy": plan.cwd_policy,
            "handle": handle_value,
        },
        "readiness": {
            "helloSeen": status == "hello_seen" || status == "ready",
            "functionRegistered": status == "ready",
            "expectedMarkers": expected_readiness_markers(activation),
            "failureReason": failure_reason,
        },
        "logs": logs.json(),
        "exit": {
            "reason": Value::Null,
            "exitCode": Value::Null,
            "stoppedAt": Value::Null,
        },
        "metadata": {
            "tokenStorage": "not_persisted",
            "redactionPolicy": "token-env-log-elision",
        }
    })
}

pub(super) fn launch_response_from_process(
    inspection: &EngineResourceInspection,
    activation: &ActivationResource,
    plan: &LaunchPlan,
) -> Result<Value> {
    let payload = current_payload(inspection)?;
    Ok(json!({
        "workerProcessResourceId": inspection.resource.resource_id,
        "activationResourceId": activation.resource.resource_id,
        "workerId": activation.worker_id.as_str(),
        "functionId": activation.function_id.as_str(),
        "launchStatus": payload["status"].clone(),
        "processHandle": payload["process"]["handle"].clone(),
        "expectedReadinessMarkers": expected_readiness_markers(activation),
        "launchPlanResourceId": plan.resource_id,
    }))
}

pub(super) fn expected_readiness_markers(activation: &ActivationResource) -> Vec<String> {
    vec![
        format!(
            "hello workerId={} activationResourceId={}",
            activation.worker_id.as_str(),
            activation.resource.resource_id
        ),
        format!(
            "register functionId={} workerId={}",
            activation.function_id.as_str(),
            activation.worker_id.as_str()
        ),
    ]
}

pub(super) fn validate_activation_for_launch(activation: &ActivationResource) -> Result<()> {
    if !matches!(
        activation.resource.lifecycle.as_str(),
        "issued" | "connected" | "registered"
    ) {
        return Err(EngineError::PolicyViolation(format!(
            "worker activation {} is not active for launch",
            activation.resource.resource_id
        )));
    }
    if activation.expires_at <= Utc::now() {
        return Err(EngineError::PolicyViolation(format!(
            "worker activation {} is expired",
            activation.resource.resource_id
        )));
    }
    if !matches!(
        activation.resource.scope,
        EngineResourceScope::Session(_) | EngineResourceScope::Workspace(_)
    ) {
        return Err(EngineError::PolicyViolation(
            "worker activation launch requires session or workspace scope".to_owned(),
        ));
    }
    if activation.registration_mode != WorkerRegistrationMode::Volatile {
        return Err(EngineError::PolicyViolation(
            "worker activation launch requires volatile registration".to_owned(),
        ));
    }
    if activation
        .payload
        .get("expectedFunctionDefinition")
        .is_none()
    {
        return Err(EngineError::PolicyViolation(
            "worker activation launch requires a function-only expected definition".to_owned(),
        ));
    }
    Ok(())
}

pub(super) fn validate_launch_plan_matches_activation(
    plan: &LaunchPlan,
    activation: &ActivationResource,
) -> Result<()> {
    if plan.expected_worker_id != activation.worker_id {
        return Err(EngineError::PolicyViolation(
            "worker launch plan workerId does not match activation".to_owned(),
        ));
    }
    if plan.expected_function_id != activation.function_id {
        return Err(EngineError::PolicyViolation(
            "worker launch plan functionId does not match activation".to_owned(),
        ));
    }
    if plan.target_visibility != activation.target_visibility {
        return Err(EngineError::PolicyViolation(
            "worker launch plan visibility does not match activation".to_owned(),
        ));
    }
    if plan.namespace != activation.namespace {
        return Err(EngineError::PolicyViolation(
            "worker launch plan namespace does not match activation".to_owned(),
        ));
    }
    let (session_id, workspace_id) = scope_ids(&activation.resource.scope);
    if plan.scope.session_id != session_id || plan.scope.workspace_id != workspace_id {
        return Err(EngineError::PolicyViolation(
            "worker launch plan scope does not match activation".to_owned(),
        ));
    }
    Ok(())
}

pub(super) fn launch_env(
    plan: &LaunchPlan,
    activation: &ActivationResource,
) -> BTreeMap<String, String> {
    let mut env = plan.env.clone();
    if plan
        .env_allowlist
        .iter()
        .any(|key| key == "TRON_WORKER_ACTIVATION_RESOURCE_ID")
    {
        env.insert(
            "TRON_WORKER_ACTIVATION_RESOURCE_ID".to_owned(),
            activation.resource.resource_id.clone(),
        );
    }
    env
}

pub(super) fn ensure_idempotency(invocation: &Invocation, function_name: &str) -> Result<()> {
    let payload_key = non_empty_payload_string(&invocation.payload, "idempotencyKey")?;
    match invocation.causal_context.idempotency_key.as_deref() {
        Some(context_key) if context_key == payload_key => Ok(()),
        _ => Err(EngineError::PolicyViolation(format!(
            "{function_name} idempotencyKey must match causal context"
        ))),
    }
}

pub(super) fn ensure_resource_kind(
    inspection: &EngineResourceInspection,
    kind: &str,
) -> Result<()> {
    if inspection.resource.kind == kind {
        Ok(())
    } else {
        Err(EngineError::PolicyViolation(format!(
            "resource {} is kind {}, expected {kind}",
            inspection.resource.resource_id, inspection.resource.kind
        )))
    }
}

pub(super) fn current_payload(inspection: &EngineResourceInspection) -> Result<&Value> {
    let current = inspection
        .resource
        .current_version_id
        .as_deref()
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "resource {} has no current version",
                inspection.resource.resource_id
            ))
        })?;
    inspection
        .versions
        .iter()
        .find(|version| version.version_id == current)
        .map(|version| &version.payload)
        .ok_or_else(|| {
            EngineError::PolicyViolation(format!(
                "resource {} current version is missing",
                inspection.resource.resource_id
            ))
        })
}

pub(super) fn process_handle_from_payload(payload: &Value) -> Result<WorkerProcessHandle> {
    serde_json::from_value(payload["process"]["handle"].clone()).map_err(|error| {
        EngineError::PolicyViolation(format!("worker process handle is invalid: {error}"))
    })
}

pub(super) fn is_terminal_process_status(status: &str) -> bool {
    matches!(
        status,
        "stopped" | "failed" | "killed" | "expired" | "revoked" | "archived"
    )
}

pub(super) fn process_resource_id(
    activation_resource_id: &str,
    launch_plan_resource_id: &str,
    idempotency_key: &str,
) -> String {
    format!(
        "worker_process:{}",
        short_hash(&format!(
            "{activation_resource_id}:{launch_plan_resource_id}:{idempotency_key}"
        ))
    )
}

pub(super) fn scope_ids(scope: &EngineResourceScope) -> (Option<String>, Option<String>) {
    match scope {
        EngineResourceScope::Session(value) => (Some(value.clone()), None),
        EngineResourceScope::Workspace(value) => (None, Some(value.clone())),
        EngineResourceScope::System => (None, None),
    }
}

pub(super) fn redact_text(value: &str, max: usize) -> String {
    let mut output = String::new();
    for line in value.lines() {
        let redacted_line = if contains_secret_material(line) {
            "[redacted]"
        } else {
            line
        };
        if output
            .len()
            .saturating_add(redacted_line.len())
            .saturating_add(1)
            > max
        {
            break;
        }
        if !output.is_empty() {
            output.push('\n');
        }
        output.push_str(redacted_line);
    }
    if value.is_empty() {
        String::new()
    } else {
        output
    }
}

fn short_hash(value: &str) -> String {
    let hash = hex::encode(Sha256::digest(value.as_bytes()));
    hash.chars().take(16).collect()
}
