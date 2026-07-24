//! Stateless execution support for the durable worker runtime.
//!
//! This module owns bounded process/HTTP I/O, artifact copying and hashing,
//! typed event projection (including transient model-tool progress), output
//! normalization, and secret redaction. It owns no mutable runtime state;
//! [`WorkerRuntime`] remains the single coordinator.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::process::Command;

use crate::engine::{InProcessFunctionHandler, Invocation};
use crate::shared::protocol::events::{BaseEvent, ToolEventIdentity, TronEvent};

use super::super::process::{
    MAX_PROCESS_CAPTURE_BYTES, ProcessTree, trusted_local_command_path, wait_with_bounded_output,
};
use super::super::types::{ActiveWorker, InvocationRecord, InvokeRequest, WorkerCommand};
use super::ModelToolInvocationOutcome;
use super::{ModelToolProgressTarget, WorkerRuntime};

fn readable_activity_label(value: &str) -> String {
    let words = value
        .split(['_', '-', '.'])
        .filter(|part| !part.is_empty())
        .collect::<Vec<_>>();
    let joined = words.join(" ");
    let mut characters = joined.chars();
    let Some(first) = characters.next() else {
        return "worker step".to_owned();
    };
    format!("{}{}", first.to_uppercase(), characters.as_str())
}

impl WorkerRuntime {
    pub(super) fn emit_model_tool_progress(
        &self,
        worker_invocation_id: &str,
        message: impl Into<String>,
        percent: Option<f64>,
    ) {
        let Some(target) = self.model_tool_progress.get(worker_invocation_id) else {
            return;
        };
        let base = BaseEvent::now(&target.session_id).with_trace_context(
            Some(target.trace_id.clone()),
            target.root_invocation_id.clone(),
        );
        let event = TronEvent::ToolInvocationProgress {
            base,
            invocation_id: target.invocation_id.clone(),
            tool_name: Some(target.tool_name.clone()),
            message: Some(
                crate::shared::foundation::redaction::redact_sensitive_content(&message.into()),
            ),
            percent,
            tool_identity: ToolEventIdentity {
                trace_id: Some(target.trace_id.clone()),
                root_invocation_id: target.root_invocation_id.clone(),
                ..ToolEventIdentity::default()
            },
        };
        let _ = self.orchestrator.emit_transient_session_event(event);
    }

    pub(super) fn emit_model_tool_output(
        &self,
        worker_invocation_id: &str,
        update: impl Into<String>,
    ) {
        let Some(target) = self.model_tool_progress.get(worker_invocation_id) else {
            return;
        };
        let update = crate::shared::foundation::redaction::redact_sensitive_content(&update.into());
        let event = TronEvent::ToolInvocationOutput {
            base: BaseEvent::now(&target.session_id).with_trace_context(
                Some(target.trace_id.clone()),
                target.root_invocation_id.clone(),
            ),
            invocation_id: target.invocation_id.clone(),
            update,
        };
        let _ = self.orchestrator.emit_transient_session_event(event);
    }

    pub(super) fn observe_agent_model_tool_progress(
        &self,
        worker_invocation_id: &str,
        event: &TronEvent,
    ) {
        match event {
            TronEvent::AgentStart { .. } => {
                let worker_name = self
                    .model_tool_progress
                    .get(worker_invocation_id)
                    .map(|target| target.worker_name.clone())
                    .unwrap_or_else(|| "Agent worker".to_owned());
                self.emit_model_tool_progress(
                    worker_invocation_id,
                    format!("{worker_name} agent started"),
                    Some(0.1),
                );
                self.emit_model_tool_output(worker_invocation_id, format!("Started {worker_name}"));
            }
            TronEvent::TurnStart { .. } => {
                self.emit_model_tool_progress(
                    worker_invocation_id,
                    "Planning and executing the delegated work",
                    Some(0.18),
                );
            }
            TronEvent::ToolInvocationStarted { tool_name, .. } => {
                let label = readable_activity_label(tool_name);
                self.emit_model_tool_progress(worker_invocation_id, format!("Using {label}"), None);
                self.emit_model_tool_output(worker_invocation_id, format!("Started {label}"));
            }
            TronEvent::ToolInvocationCompleted {
                tool_name,
                is_error,
                ..
            } => {
                let label = readable_activity_label(tool_name);
                let outcome = if is_error.unwrap_or(false) {
                    format!("{label} reported an issue")
                } else {
                    format!("Finished {label}")
                };
                self.emit_model_tool_progress(worker_invocation_id, outcome.clone(), None);
                self.emit_model_tool_output(worker_invocation_id, outcome);
            }
            TronEvent::ResponseComplete {
                has_tool_invocations,
                ..
            } if !has_tool_invocations => {
                self.emit_model_tool_progress(
                    worker_invocation_id,
                    "Preparing the typed worker result",
                    Some(0.84),
                );
            }
            TronEvent::AgentEnd { .. } => {
                self.emit_model_tool_progress(
                    worker_invocation_id,
                    "Validating the typed worker result",
                    Some(0.92),
                );
            }
            _ => {}
        }
    }
}

pub(super) async fn wait_for_agent_terminal(
    runtime: &WorkerRuntime,
    events: &mut tokio::sync::broadcast::Receiver<TronEvent>,
    session_id: &str,
    worker_invocation_id: &str,
) -> Result<Option<String>, String> {
    loop {
        match events.recv().await {
            Ok(event) if event.session_id() == session_id => {
                runtime.observe_agent_model_tool_progress(worker_invocation_id, &event);
                if let TronEvent::AgentEnd { error, .. } = event {
                    return Ok(error);
                }
            }
            Ok(_) => {}
            Err(tokio::sync::broadcast::error::RecvError::Lagged(skipped)) => {
                // A still-active run will publish another terminal event. Once
                // the registry is empty, however, AgentEnd has already been
                // emitted and cannot be recovered from this lossy channel.
                // Fail explicitly instead of waiting until the two-hour worker
                // ceiling with no producer left to wake this receiver.
                if runtime.orchestrator.get_run_id(session_id).is_none() {
                    return Err(format!(
                        "agent event stream missed terminal status after lagging by {skipped} events"
                    ));
                }
            }
            Err(tokio::sync::broadcast::error::RecvError::Closed) => {
                return Err("agent event stream closed before the worker run terminated".to_owned());
            }
        }
    }
}

pub(super) struct DynamicWorkerHandler {
    pub(super) runtime: Arc<WorkerRuntime>,
    pub(super) worker_id: String,
}

#[async_trait::async_trait]
impl InProcessFunctionHandler for DynamicWorkerHandler {
    async fn invoke(&self, invocation: Invocation) -> crate::engine::Result<Value> {
        let trace_id = invocation.causal_context.trace_id.as_str().to_owned();
        let depth = invocation.causal_context.trigger_depth();
        let idempotency_key = invocation
            .causal_context
            .idempotency_key
            .clone()
            .unwrap_or_else(|| format!("manual:{}", invocation.id));
        let request = InvokeRequest {
            worker_id: self.worker_id.clone(),
            input: invocation.payload,
            idempotency_key,
            trace_id: trace_id.clone(),
            causal_depth: depth,
            trigger_kind: "manual".to_owned(),
            origin_session_id: invocation.causal_context.session_id.clone(),
        };
        let progress_target = invocation
            .causal_context
            .model_tool_invocation_id()
            .zip(invocation.causal_context.session_id.as_deref())
            .map(|(provider_invocation_id, session_id)| {
                let summary = self.runtime.store.summary(&self.worker_id).ok().flatten();
                ModelToolProgressTarget {
                    session_id: session_id.to_owned(),
                    invocation_id: provider_invocation_id.to_owned(),
                    tool_name: summary.as_ref().map_or_else(
                        || self.worker_id.clone(),
                        |summary| summary.tool_name.clone(),
                    ),
                    worker_name: summary
                        .as_ref()
                        .map_or_else(|| self.worker_id.clone(), |summary| summary.name.clone()),
                    trace_id,
                    root_invocation_id: invocation
                        .causal_context
                        .parent_invocation_id
                        .as_ref()
                        .map(|id| id.as_str().to_owned()),
                }
            });
        let top_level_model_call = invocation.causal_context.origin_worker_id().is_none();
        let outcome = match (progress_target, top_level_model_call) {
            (Some(target), true) => self
                .runtime
                .invoke_from_model_tool_adaptive(request, target)
                .await
                .map_err(crate::engine::EngineError::HandlerFailed)?,
            (Some(target), false) => ModelToolInvocationOutcome::Terminal(
                self.runtime
                    .invoke_from_model_tool(
                        request,
                        target,
                        invocation.causal_context.origin_worker_invocation_id(),
                    )
                    .await
                    .map_err(crate::engine::EngineError::HandlerFailed)?,
            ),
            (None, _) => ModelToolInvocationOutcome::Terminal(
                self.runtime
                    .invoke(request)
                    .await
                    .map_err(crate::engine::EngineError::HandlerFailed)?,
            ),
        };
        let record = match outcome {
            ModelToolInvocationOutcome::Terminal(record) => record,
            ModelToolInvocationOutcome::Background(record) => {
                return Ok(json!({
                    "kind":"worker_invocation_receipt",
                    "status":record.status,
                    "mode":"background",
                    "invocationId":record.invocation_id,
                    "workerId":record.worker_id,
                    "workerName":self.runtime.store.summary(&self.worker_id)
                        .ok()
                        .flatten()
                        .map_or_else(|| self.worker_id.clone(), |worker| worker.name),
                    "originSessionId":record.origin_session_id,
                    "message":"The durable worker run is continuing in the background. Do not poll or wait; report that it is running. Its result will appear in Session Context and the worker inbox.",
                }));
            }
        };
        if record.status != "completed" {
            return Err(crate::engine::EngineError::HandlerFailed(
                record
                    .error
                    .unwrap_or_else(|| format!("worker '{}' failed", self.worker_id)),
            ));
        }
        self.runtime
            .provider_worker_output(&record)
            .map_err(crate::engine::EngineError::HandlerFailed)
    }
}

pub(super) async fn read_http_body_limited(
    response: &mut reqwest::Response,
    max_bytes: usize,
    label: &str,
) -> Result<Vec<u8>, String> {
    if response
        .content_length()
        .is_some_and(|length| length > max_bytes as u64)
    {
        return Err(format!("{label} exceeds the {max_bytes}-byte ceiling"));
    }
    let mut body = Vec::with_capacity(
        response
            .content_length()
            .unwrap_or_default()
            .min(max_bytes as u64) as usize,
    );
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|error| format!("read {label}: {error}"))?
    {
        if body.len().saturating_add(chunk.len()) > max_bytes {
            return Err(format!("{label} exceeds the {max_bytes}-byte ceiling"));
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

pub(super) async fn run_worker_command(
    spec: &WorkerCommand,
    workdir: &Path,
    state_dir: Option<&Path>,
    input: Option<&Value>,
    secrets: &HashMap<String, String>,
    invocation: Option<&InvocationRecord>,
) -> Result<Value, String> {
    let child = spawn_process(
        &spec.command,
        workdir,
        state_dir,
        secrets,
        Stdio::piped(),
        Stdio::piped(),
        invocation,
    )?;
    let input = input
        .map(serde_json::to_vec)
        .transpose()
        .map_err(|error| format!("encode worker input: {error}"))?;
    let output = wait_with_bounded_output(
        child,
        input,
        Duration::from_secs(spec.timeout_seconds),
        format!(
            "worker command timed out after {} seconds",
            spec.timeout_seconds
        ),
        MAX_PROCESS_CAPTURE_BYTES,
    )
    .await
    .map_err(|error| format!("wait for worker command: {error}"))?;
    if !output.status.success() {
        let truncation = if output.stderr_truncated {
            "\n[stderr truncated at 4194304 bytes]"
        } else {
            ""
        };
        return Err(redact_known_secrets(
            &format!(
                "worker command exited {}: {}{}",
                output.status,
                String::from_utf8_lossy(&output.stderr),
                truncation,
            ),
            secrets,
        ));
    }
    if let Some((kind, error)) = output.input_error
        && kind != std::io::ErrorKind::BrokenPipe
    {
        return Err(format!("write worker input: {error}"));
    }
    if output.stdout_truncated {
        return Err(format!(
            "worker command stdout exceeded the {}-byte capture ceiling",
            MAX_PROCESS_CAPTURE_BYTES
        ));
    }
    if output.stdout.is_empty() {
        return Ok(json!({}));
    }
    Ok(serde_json::from_slice(&output.stdout).unwrap_or_else(|_| {
        json!({
            "stdout": String::from_utf8_lossy(&output.stdout).trim_end()
        })
    }))
}

pub(super) fn spawn_process(
    command: &[String],
    workdir: &Path,
    state_dir: Option<&Path>,
    secrets: &HashMap<String, String>,
    stdout: Stdio,
    stderr: Stdio,
    invocation: Option<&InvocationRecord>,
) -> Result<ProcessTree, String> {
    let (program, arguments) = command
        .split_first()
        .ok_or_else(|| "worker command has no program".to_owned())?;
    let program_path = if program.starts_with("./") {
        workdir.join(program.trim_start_matches("./"))
    } else {
        PathBuf::from(program)
    };
    let mut process = Command::new(program_path);
    process
        .args(arguments)
        .current_dir(workdir)
        .stdin(Stdio::piped())
        .stdout(stdout)
        .stderr(stderr)
        .kill_on_drop(true);
    if let Some(root) = worker_artifact_root(workdir) {
        let dependency_runtime = root.join("dependency-runtime");
        let bin = dependency_runtime.join("bin");
        let path = trusted_local_command_path(Some(&bin))?;
        process
            .env("TRON_WORKER_DEPENDENCY_ROOT", &dependency_runtime)
            .env("PIP_TARGET", dependency_runtime.join("python"))
            .env("PYTHONPATH", dependency_runtime.join("python"))
            .env("PYTHONUSERBASE", dependency_runtime.join("python-user"))
            .env("NPM_CONFIG_PREFIX", &dependency_runtime)
            .env("CARGO_HOME", dependency_runtime.join("cargo"))
            .env("GEM_HOME", dependency_runtime.join("gems"))
            .env("BUNDLE_PATH", dependency_runtime.join("gems"))
            .env("PATH", path);
    }
    if let Some(state_dir) = state_dir {
        process.env("TRON_WORKER_STATE_DIR", state_dir);
    }
    for (name, value) in secrets {
        let env_name = format!(
            "TRON_SECRET_{}",
            name.chars()
                .map(|character| if character.is_ascii_alphanumeric() {
                    character.to_ascii_uppercase()
                } else {
                    '_'
                })
                .collect::<String>()
        );
        process.env(env_name, value);
    }
    if let Some(invocation) = invocation {
        process
            .env("TRON_WORKER_INVOCATION_ID", &invocation.invocation_id)
            .env("TRON_WORKER_IDEMPOTENCY_KEY", &invocation.idempotency_key)
            .env("TRON_WORKER_TRACE_ID", &invocation.trace_id)
            .env(
                "TRON_WORKER_CAUSAL_DEPTH",
                invocation.causal_depth.to_string(),
            )
            .env("TRON_WORKER_TRIGGER_KIND", &invocation.trigger_kind);
    }
    ProcessTree::spawn(&mut process)
        .map_err(|error| format!("start worker command '{program}': {error}"))
}

fn worker_artifact_root(workdir: &Path) -> Option<PathBuf> {
    workdir
        .ancestors()
        .find(|candidate| candidate.join("dependency-runtime").is_dir())
        .map(Path::to_path_buf)
}

pub(super) fn digest_tree(root: &Path) -> Result<String, String> {
    let mut entries = walkdir::WalkDir::new(root)
        .follow_links(false)
        .into_iter()
        .collect::<Result<Vec<_>, _>>()
        .map_err(|error| error.to_string())?;
    entries.retain(|entry| entry.file_type().is_file() || entry.file_type().is_symlink());
    entries.sort_by(|left, right| left.path().cmp(right.path()));
    let mut digest = Sha256::new();
    for entry in entries {
        let relative = entry
            .path()
            .strip_prefix(root)
            .map_err(|error| error.to_string())?;
        digest.update(relative.to_string_lossy().as_bytes());
        digest.update([0]);
        if entry.file_type().is_symlink() {
            digest.update(
                std::fs::read_link(entry.path())
                    .map_err(|error| error.to_string())?
                    .to_string_lossy()
                    .as_bytes(),
            );
            digest.update([0xfe]);
        } else {
            digest.update(std::fs::read(entry.path()).map_err(|error| error.to_string())?);
            digest.update([0xff]);
        }
    }
    Ok(hex::encode(digest.finalize()))
}

pub(super) fn resident_key(worker: &ActiveWorker) -> String {
    format!(
        "{}@{}",
        worker.summary.worker_id, worker.summary.active_version
    )
}

pub(super) fn redact_known_secrets(value: &str, secrets: &HashMap<String, String>) -> String {
    let mut redacted = crate::shared::foundation::redaction::redact_sensitive_content(value);
    for secret in secrets.values().filter(|secret| !secret.is_empty()) {
        redacted = redacted.replace(secret, "[REDACTED]");
    }
    redacted
}

pub(super) fn redact_json_known_secrets(value: Value, secrets: &HashMap<String, String>) -> Value {
    match value {
        Value::String(value) => Value::String(redact_known_secrets(&value, secrets)),
        Value::Array(values) => Value::Array(
            values
                .into_iter()
                .map(|value| redact_json_known_secrets(value, secrets))
                .collect(),
        ),
        Value::Object(values) => Value::Object(
            values
                .into_iter()
                .map(|(key, value)| (key, redact_json_known_secrets(value, secrets)))
                .collect(),
        ),
        value => value,
    }
}

pub(super) fn normalize_agent_output(value: Value) -> Value {
    let text = match value {
        Value::String(text) => text,
        Value::Array(blocks) => {
            let text = blocks
                .iter()
                .filter_map(|block| block.get("text").and_then(Value::as_str))
                .collect::<Vec<_>>()
                .join("\n");
            if text.is_empty() {
                return Value::Array(blocks);
            }
            text
        }
        value => return value,
    };
    let trimmed = text.trim();
    if let Ok(value) = serde_json::from_str(trimmed) {
        return value;
    }
    let unfenced = trimmed
        .strip_prefix("```json")
        .or_else(|| trimmed.strip_prefix("```"))
        .and_then(|body| body.strip_suffix("```"))
        .map(str::trim);
    if let Some(unfenced) = unfenced
        && let Ok(value) = serde_json::from_str(unfenced)
    {
        return value;
    }
    json!({"text": text})
}

pub(super) fn json_subset_matches(filter: &Value, candidate: &Value) -> bool {
    match filter {
        Value::Object(expected) => {
            let Some(actual) = candidate.as_object() else {
                return false;
            };
            expected.iter().all(|(key, expected)| {
                actual
                    .get(key)
                    .is_some_and(|actual| json_subset_matches(expected, actual))
            })
        }
        Value::Array(expected) => candidate.as_array().is_some_and(|actual| {
            expected.len() == actual.len()
                && expected
                    .iter()
                    .zip(actual)
                    .all(|(expected, actual)| json_subset_matches(expected, actual))
        }),
        _ => filter == candidate,
    }
}

/// Project an engine event into the worker's ordinary typed input without a
/// framework envelope. Configured input provides defaults; only event payload
/// keys explicitly declared by the top-level input schema may override them.
pub(super) fn materialize_engine_event_input(
    configured: &Value,
    payload: &Value,
    schema: &Value,
) -> Value {
    let mut materialized = configured.clone();
    let (Some(materialized), Some(payload), Some(properties)) = (
        materialized.as_object_mut(),
        payload.as_object(),
        schema.get("properties").and_then(Value::as_object),
    ) else {
        return materialized;
    };
    for key in properties.keys() {
        if let Some(value) = payload.get(key) {
            let _ = materialized.insert(key.clone(), value.clone());
        }
    }
    Value::Object(materialized.clone())
}

pub(super) fn copy_tree(source: &Path, destination: &Path) -> Result<(), String> {
    if !source.exists() {
        return Ok(());
    }
    for entry in walkdir::WalkDir::new(source).follow_links(false) {
        let entry = entry.map_err(|error| error.to_string())?;
        let relative = entry
            .path()
            .strip_prefix(source)
            .map_err(|error| error.to_string())?;
        let target = destination.join(relative);
        if entry.file_type().is_dir() {
            std::fs::create_dir_all(&target).map_err(|error| error.to_string())?;
        } else if entry.file_type().is_file() {
            if let Some(parent) = target.parent() {
                std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
            }
            std::fs::copy(entry.path(), target).map_err(|error| error.to_string())?;
        } else if entry.file_type().is_symlink() {
            if let Some(parent) = target.parent() {
                std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
            }
            copy_symlink(entry.path(), &target)?;
        } else {
            return Err(format!(
                "worker artifact contains unsupported special file {}",
                entry.path().display()
            ));
        }
    }
    Ok(())
}

#[cfg(unix)]
fn copy_symlink(source: &Path, destination: &Path) -> Result<(), String> {
    let target = std::fs::read_link(source)
        .map_err(|error| format!("read worker symlink {}: {error}", source.display()))?;
    std::os::unix::fs::symlink(&target, destination).map_err(|error| {
        format!(
            "copy worker symlink {} -> {}: {error}",
            destination.display(),
            target.display()
        )
    })
}

#[cfg(not(unix))]
fn copy_symlink(source: &Path, _destination: &Path) -> Result<(), String> {
    Err(format!(
        "worker symlink copies are not supported on this platform: {}",
        source.display()
    ))
}

#[cfg(unix)]
pub(super) fn set_owner_only(path: &Path) -> Result<(), String> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
        .map_err(|error| error.to_string())
}

#[cfg(not(unix))]
pub(super) fn set_owner_only(_path: &Path) -> Result<(), String> {
    Ok(())
}
