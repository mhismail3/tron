//! Stateless execution support for the durable worker runtime.
//!
//! This module owns bounded process/HTTP I/O, artifact copying and hashing,
//! typed event projection, output normalization, and secret redaction. It owns
//! no mutable runtime state; [`WorkerRuntime`] remains the single coordinator.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;

use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::process::Command;

use crate::domains::agent::r#loop::orchestrator::core::Orchestrator;
use crate::engine::{InProcessFunctionHandler, Invocation, RUNTIME_METADATA_TRIGGER_DEPTH};
use crate::shared::protocol::events::TronEvent;

use super::super::process::{
    MAX_PROCESS_CAPTURE_BYTES, ProcessTree, trusted_local_command_path, wait_with_bounded_output,
};
use super::super::types::{ActiveWorker, InvocationRecord, InvokeRequest, WorkerCommand};
use super::WorkerRuntime;

pub(super) async fn wait_for_agent_terminal(
    orchestrator: &Orchestrator,
    events: &mut tokio::sync::broadcast::Receiver<TronEvent>,
    session_id: &str,
) -> Result<Option<String>, String> {
    loop {
        match events.recv().await {
            Ok(event) if event.session_id() == session_id => {
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
                if orchestrator.get_run_id(session_id).is_none() {
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
        if !self.runtime.autonomous_enabled() {
            return Err(crate::engine::EngineError::HandlerFailed(
                "autonomous workers are disabled for this profile; set autonomousWorkers=true"
                    .to_owned(),
            ));
        }
        let trace_id = invocation.causal_context.trace_id.as_str().to_owned();
        let depth = invocation
            .causal_context
            .runtime_metadata
            .get(RUNTIME_METADATA_TRIGGER_DEPTH)
            .and_then(|value| value.parse::<u32>().ok())
            .unwrap_or(0);
        let idempotency_key = invocation
            .causal_context
            .idempotency_key
            .clone()
            .unwrap_or_else(|| format!("manual:{}", invocation.id));
        let record = self
            .runtime
            .invoke(InvokeRequest {
                worker_id: self.worker_id.clone(),
                input: invocation.payload,
                idempotency_key,
                trace_id,
                causal_depth: depth,
                trigger_kind: "manual".to_owned(),
            })
            .await
            .map_err(crate::engine::EngineError::HandlerFailed)?;
        if record.status != "completed" {
            return Err(crate::engine::EngineError::HandlerFailed(
                record
                    .error
                    .unwrap_or_else(|| format!("worker '{}' failed", self.worker_id)),
            ));
        }
        Ok(record.output.unwrap_or_else(|| json!({})))
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
    input: Option<&Value>,
    secrets: &HashMap<String, String>,
    invocation: Option<&InvocationRecord>,
) -> Result<Value, String> {
    let child = spawn_process(
        &spec.command,
        workdir,
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
