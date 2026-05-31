//! process domain worker.
//!
//! This worker owns host process execution as a capability. The model never
//! receives a shell-specific capability; it discovers and invokes `process::run`
//! through the capability primitives.
//!
//! The broad `process::run` contract has conditional approval instead of a
//! blanket approval bit. Payload-sensitive approval classification lives in
//! [`approval`], including the pre-approval check that rejects write-like
//! commands submitted as `executionMode = "read_only"`. Schema validation,
//! including rejection of empty commands, idempotency, lease, audit, and actual
//! execution remain on the normal
//! engine/capability path. The same classifier also lets low-risk first-party
//! read/check commands such as `date`, `pwd`, `git status`, and test/build
//! checks skip an extra inspect turn. It also permits composed read-only file
//! checks such as `test -f README.md` and bounded `sed -n` printing while still
//! rejecting `sed -i`, sed write scripts, redirection, and unknown snippets.
//! Commands outside the low-risk set must use
//! `executionMode = "sandbox_materialized"` with declared expected outputs, then
//! materialize those outputs through resource capabilities. Each
//! `expectedOutputs[].path` is a relative path inside the isolated process
//! sandbox; absolute, home-relative, and parent-escaping paths are rejected
//! before approval so an impossible host path cannot pause for approval and
//! fail only after execution. Shell redirection and `tee` targets in the command
//! must match declared expected outputs; parent directories for declared outputs
//! are prepared inside the sandbox before execution. Duplicate sandbox output
//! paths and duplicate resolved materialization targets are rejected before
//! approval/spawn so one command cannot race two files into the same resource
//! destination. Relative materialization targets resolve to the active session
//! worktree so approved sandbox output never leaks into the server process cwd.
//! Every `process::run` invocation requires active session worktree truth.
//! Read-only command cwd/path operands and materialized output targets are
//! bounded to that worktree, and child processes receive an allowlisted
//! environment instead of inheriting
//! server secrets. If a request omits `cwd`, direct read-only execution uses the
//! active session worktree, so common shell checks stay fast without leaving the
//! capability architecture.

pub(crate) mod approval;
mod bounds;
pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;

use std::collections::BTreeSet;
use std::path::{Component, Path, PathBuf};
use std::process::Stdio;
use std::time::Instant;

use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

use crate::domains::worker::{DomainRegistrationContext, DomainWorkerModule};
use crate::engine::{
    ActorId, ActorKind, AuthorityGrantId, CausalContext, FunctionId, Invocation, TraceId,
};
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::{opt_string, opt_u64, require_string_param};

use bounds::{
    active_session_root, bounded_process_path, opt_env, require_active_session_root,
    safe_process_environment, validate_process_env, validate_read_only_process_boundaries,
};

const DEFAULT_TIMEOUT_MS: u64 = 120_000;
const MAX_OUTPUT_BYTES: usize = 400 * 1024;

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    let domain_deps = Deps::from_engine(deps);
    crate::domains::worker::domain_worker_module(
        "process",
        contract::STREAM_TOPICS,
        handlers::function_registrations(contract::capabilities()?, domain_deps)?,
    )
}

async fn process_run_value(invocation: &Invocation, deps: &Deps) -> Result<Value, CapabilityError> {
    let params = Some(&invocation.payload);
    let command = require_string_param(params, "command")?;
    if command.trim().is_empty() {
        return Err(CapabilityError::InvalidParams {
            message: "process::run requires non-empty command".to_owned(),
        });
    }
    let execution_mode =
        opt_string(params, "executionMode").ok_or_else(|| CapabilityError::InvalidParams {
            message: "process::run requires executionMode".to_owned(),
        })?;
    if let Err(message) = approval::validate_run_payload_before_approval(&invocation.payload) {
        return Err(CapabilityError::InvalidParams {
            message: message.to_owned(),
        });
    }
    if execution_mode != "read_only" && execution_mode != "sandbox_materialized" {
        return Err(CapabilityError::InvalidParams {
            message: format!("unsupported executionMode: {execution_mode}"),
        });
    }
    let active_root = require_active_session_root(invocation, deps)?;
    if execution_mode == "sandbox_materialized" {
        validate_expected_output_collisions(invocation, deps)?;
    }
    let sandbox = if execution_mode == "sandbox_materialized" {
        Some(
            tempfile::tempdir().map_err(|error| CapabilityError::Internal {
                message: format!("create process sandbox: {error}"),
            })?,
        )
    } else {
        None
    };
    if let Some(sandbox) = sandbox.as_ref() {
        prepare_sandbox_expected_output_dirs(&invocation.payload, sandbox.path())?;
    }
    let cwd = sandbox
        .as_ref()
        .map(|dir| dir.path().to_string_lossy().into_owned())
        .unwrap_or_else(|| {
            opt_string(params, "cwd").unwrap_or_else(|| default_cwd(invocation, deps))
        });
    if execution_mode == "read_only" {
        validate_read_only_process_boundaries(&active_root, &command, &cwd)?;
    }
    let shell = opt_string(params, "shell").unwrap_or_else(|| "bash".to_owned());
    let timeout_ms = command_timeout_ms(params).clamp(1, 600_000);
    let stdin = opt_string(params, "stdin");
    let env = opt_env(params);
    validate_process_env(&env)?;
    let mut sandbox_env = Vec::new();
    if let Some(sandbox) = sandbox.as_ref() {
        let sandbox_home = sandbox.path().join("home");
        let sandbox_tmp = sandbox.path().join("tmp");
        std::fs::create_dir_all(&sandbox_home).map_err(|error| CapabilityError::Internal {
            message: format!("create sandbox HOME: {error}"),
        })?;
        std::fs::create_dir_all(&sandbox_tmp).map_err(|error| CapabilityError::Internal {
            message: format!("create sandbox TMPDIR: {error}"),
        })?;
        sandbox_env.push((
            "HOME".to_owned(),
            sandbox_home.to_string_lossy().into_owned(),
        ));
        sandbox_env.push((
            "TMPDIR".to_owned(),
            sandbox_tmp.to_string_lossy().into_owned(),
        ));
    }

    let shell_bin = match shell.as_str() {
        "bash" | "zsh" | "sh" => shell,
        other => {
            return Err(CapabilityError::InvalidParams {
                message: format!("unsupported shell: {other}"),
            });
        }
    };
    let start = Instant::now();
    let mut child = Command::new(shell_bin)
        .arg("-lc")
        .arg(command)
        .current_dir(cwd)
        .env_clear()
        .envs(safe_process_environment())
        .envs(env)
        .envs(sandbox_env)
        .stdin(if stdin.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| CapabilityError::Custom {
            code: "PROCESS_SPAWN_FAILED".to_owned(),
            message: error.to_string(),
            details: None,
        })?;

    if let Some(stdin) = stdin
        && let Some(mut pipe) = child.stdin.take()
    {
        let _ = pipe.write_all(stdin.as_bytes()).await;
    }

    let output = match tokio::time::timeout(
        std::time::Duration::from_millis(timeout_ms),
        child.wait_with_output(),
    )
    .await
    {
        Ok(result) => result.map_err(|error| CapabilityError::Custom {
            code: "PROCESS_WAIT_FAILED".to_owned(),
            message: error.to_string(),
            details: None,
        })?,
        Err(_) => {
            let mut result = json!({
                "stdout": "",
                "stderr": format!("process timed out after {timeout_ms}ms"),
                "exitCode": -1,
                "durationMs": u64::try_from(start.elapsed().as_millis()).unwrap_or(u64::MAX),
                "timedOut": true,
                "outputTruncated": false,
            });
            if execution_mode == "sandbox_materialized"
                || invocation
                    .payload
                    .get("retainOutput")
                    .and_then(Value::as_bool)
                    .unwrap_or(false)
            {
                result["resourceRefs"] = Value::Array(
                    create_execution_output_resource(deps, invocation, &result).await?,
                );
            }
            return Ok(result);
        }
    };

    let (stdout, stdout_truncated) = decode_capped(&output.stdout);
    let (stderr, stderr_truncated) = decode_capped(&output.stderr);
    let mut result = json!({
        "stdout": stdout,
        "stderr": stderr,
        "exitCode": output.status.code().unwrap_or(-1),
        "durationMs": u64::try_from(start.elapsed().as_millis()).unwrap_or(u64::MAX),
        "timedOut": false,
        "outputTruncated": stdout_truncated || stderr_truncated,
    });
    let mut refs = Vec::new();
    let mut materialized_outputs = Vec::new();
    if execution_mode == "sandbox_materialized" {
        let materialized =
            materialize_expected_outputs(deps, invocation, sandbox.as_ref().unwrap().path())
                .await?;
        refs.extend(materialized.resource_refs);
        materialized_outputs.extend(materialized.outputs);
    }
    if invocation
        .payload
        .get("retainOutput")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        || execution_mode == "sandbox_materialized"
    {
        refs.extend(create_execution_output_resource(deps, invocation, &result).await?);
    }
    if !refs.is_empty() {
        result["resourceRefs"] = Value::Array(refs);
    }
    if !materialized_outputs.is_empty() {
        result["materializedOutputs"] = Value::Array(materialized_outputs);
    }
    Ok(result)
}

struct MaterializedProcessOutputs {
    resource_refs: Vec<Value>,
    outputs: Vec<Value>,
}

async fn materialize_expected_outputs(
    deps: &Deps,
    invocation: &Invocation,
    sandbox_root: &Path,
) -> Result<MaterializedProcessOutputs, CapabilityError> {
    let expected = invocation
        .payload
        .get("expectedOutputs")
        .and_then(Value::as_array)
        .ok_or_else(|| CapabilityError::InvalidParams {
            message: "sandbox_materialized process::run requires expectedOutputs".to_owned(),
        })?;
    let mut refs = Vec::new();
    let mut outputs = Vec::new();
    for item in expected {
        let relative = item.get("path").and_then(Value::as_str).ok_or_else(|| {
            CapabilityError::InvalidParams {
                message: "expectedOutputs entries require path".to_owned(),
            }
        })?;
        let sandbox_path = safe_sandbox_output_path(sandbox_root, relative)?;
        let content =
            std::fs::read_to_string(&sandbox_path).map_err(|error| CapabilityError::Custom {
                code: "PROCESS_EXPECTED_OUTPUT_MISSING".to_owned(),
                message: format!("expected output {relative} was not materialized: {error}"),
                details: None,
            })?;
        let target_path = item
            .get("targetPath")
            .and_then(Value::as_str)
            .unwrap_or(relative);
        let target_path = materialized_target_path(invocation, deps, target_path)?;
        let content_hash = sha256_hex(content.as_bytes());
        let result = invoke_resource_capability(
            deps,
            invocation,
            "materialized_file::update",
            json!({
                "path": target_path.to_string_lossy(),
                "content": content,
            }),
        )
        .await?;
        let mut resource_refs = result
            .get("resourceRefs")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        for resource_ref in &mut resource_refs {
            if resource_ref.get("kind").and_then(Value::as_str) == Some("materialized_file") {
                resource_ref["fileContentHash"] = json!(content_hash);
                resource_ref["materializedPath"] = json!(target_path.to_string_lossy());
            }
        }
        let preview = bounded_preview(
            result
                .get("version")
                .and_then(|version| version.get("payload"))
                .and_then(|payload| payload.get("content"))
                .and_then(Value::as_str)
                .unwrap_or_default(),
        );
        outputs.push(json!({
            "path": relative,
            "targetPath": target_path.to_string_lossy(),
            "resourceId": resource_refs
                .first()
                .and_then(|resource_ref| resource_ref.get("resourceId"))
                .and_then(Value::as_str)
                .unwrap_or_default(),
            "versionId": resource_refs
                .first()
                .and_then(|resource_ref| resource_ref.get("versionId"))
                .and_then(Value::as_str)
                .unwrap_or_default(),
            "contentHash": content_hash,
            "sizeBytes": preview.size_bytes,
            "contentPreview": preview.text,
            "previewTruncated": preview.truncated,
        }));
        refs.extend(resource_refs);
    }
    Ok(MaterializedProcessOutputs {
        resource_refs: refs,
        outputs,
    })
}

fn prepare_sandbox_expected_output_dirs(
    payload: &Value,
    sandbox_root: &Path,
) -> Result<(), CapabilityError> {
    let Some(expected) = payload.get("expectedOutputs").and_then(Value::as_array) else {
        return Ok(());
    };
    for item in expected {
        let Some(relative) = item.get("path").and_then(Value::as_str) else {
            continue;
        };
        let output_path = safe_sandbox_declared_output_path(sandbox_root, relative)?;
        if let Some(parent) = output_path.parent()
            && parent != sandbox_root
        {
            std::fs::create_dir_all(parent).map_err(|error| CapabilityError::Internal {
                message: format!("create declared process output directory: {error}"),
            })?;
        }
    }
    Ok(())
}

fn validate_expected_output_collisions(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<(), CapabilityError> {
    let Some(expected) = invocation
        .payload
        .get("expectedOutputs")
        .and_then(Value::as_array)
    else {
        return Ok(());
    };
    let mut sandbox_paths = BTreeSet::new();
    let mut target_paths = BTreeSet::new();
    for item in expected {
        let relative = item.get("path").and_then(Value::as_str).ok_or_else(|| {
            CapabilityError::InvalidParams {
                message: "expectedOutputs entries require path".to_owned(),
            }
        })?;
        let sandbox_path = safe_sandbox_declared_output_path(Path::new("/"), relative)?;
        if !sandbox_paths.insert(sandbox_path) {
            return Err(CapabilityError::InvalidParams {
                message: "expectedOutputs must not declare duplicate output paths".to_owned(),
            });
        }
        let target_path = item
            .get("targetPath")
            .and_then(Value::as_str)
            .unwrap_or(relative);
        let target_path = materialized_target_path(invocation, deps, target_path)?;
        if !target_paths.insert(target_path) {
            return Err(CapabilityError::InvalidParams {
                message: "expectedOutputs must not declare duplicate targetPath destinations"
                    .to_owned(),
            });
        }
    }
    Ok(())
}

fn safe_sandbox_declared_output_path(
    root: &Path,
    relative: &str,
) -> Result<PathBuf, CapabilityError> {
    if relative.trim().is_empty() || relative.starts_with('~') {
        return Err(CapabilityError::InvalidParams {
            message: "expected output path must be relative inside the process sandbox".to_owned(),
        });
    }
    let path = Path::new(relative);
    if path.is_absolute() {
        return Err(CapabilityError::InvalidParams {
            message: "expected output path must be relative inside the process sandbox".to_owned(),
        });
    }
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Normal(part) => normalized.push(part),
            Component::CurDir => {}
            Component::ParentDir | Component::RootDir | Component::Prefix(_) => {
                return Err(CapabilityError::InvalidParams {
                    message: "expected output path must stay inside the process sandbox".to_owned(),
                });
            }
        }
    }
    if normalized.as_os_str().is_empty() {
        return Err(CapabilityError::InvalidParams {
            message: "expected output path cannot be empty".to_owned(),
        });
    }
    Ok(root.join(normalized))
}

struct BoundedPreview {
    text: String,
    size_bytes: usize,
    truncated: bool,
}

fn bounded_preview(content: &str) -> BoundedPreview {
    const MAX_PREVIEW_BYTES: usize = 4096;
    let bytes = content.as_bytes();
    if bytes.len() <= MAX_PREVIEW_BYTES {
        return BoundedPreview {
            text: content.to_owned(),
            size_bytes: bytes.len(),
            truncated: false,
        };
    }
    let mut boundary = MAX_PREVIEW_BYTES;
    while !content.is_char_boundary(boundary) {
        boundary -= 1;
    }
    BoundedPreview {
        text: format!("{}…", &content[..boundary]),
        size_bytes: bytes.len(),
        truncated: true,
    }
}

fn materialized_target_path(
    invocation: &Invocation,
    deps: &Deps,
    target_path: &str,
) -> Result<PathBuf, CapabilityError> {
    if let Some(root) = active_session_root(invocation, deps)? {
        return bounded_process_path(&root, target_path, "expected output targetPath");
    }
    let path = Path::new(target_path);
    if path.is_absolute() {
        return Ok(path.to_path_buf());
    }
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Normal(part) => normalized.push(part),
            Component::CurDir => {}
            Component::ParentDir => {
                return Err(CapabilityError::InvalidParams {
                    message: format!(
                        "expected output targetPath {target_path} must stay inside the active session worktree"
                    ),
                });
            }
            Component::RootDir | Component::Prefix(_) => {
                return Err(CapabilityError::InvalidParams {
                    message: format!("invalid expected output targetPath: {target_path}"),
                });
            }
        }
    }
    if normalized.as_os_str().is_empty() {
        return Err(CapabilityError::InvalidParams {
            message: "expected output targetPath cannot be empty".to_owned(),
        });
    }
    Ok(PathBuf::from(default_cwd(invocation, deps)).join(normalized))
}

async fn create_execution_output_resource(
    deps: &Deps,
    invocation: &Invocation,
    result: &Value,
) -> Result<Vec<Value>, CapabilityError> {
    let created = invoke_resource_capability(
        deps,
        invocation,
        "resource::create",
        json!({
            "kind": "execution_output",
            "payload": {
                "stdoutPreview": result.get("stdout").and_then(Value::as_str).unwrap_or_default(),
                "stderrPreview": result.get("stderr").and_then(Value::as_str).unwrap_or_default(),
                "exitCode": result.get("exitCode").and_then(Value::as_i64).unwrap_or(-1),
                "durationMs": result.get("durationMs").and_then(Value::as_u64).unwrap_or(0),
                "timedOut": result.get("timedOut").and_then(Value::as_bool).unwrap_or(false),
                "outputTruncated": result.get("outputTruncated").and_then(Value::as_bool).unwrap_or(false),
                "redactionPolicy": {"preview": "bounded"}
            }
        }),
    )
    .await?;
    Ok(created
        .get("resourceRefs")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default())
}

async fn invoke_resource_capability(
    deps: &Deps,
    parent: &Invocation,
    function_id: &str,
    payload: Value,
) -> Result<Value, CapabilityError> {
    let payload_hash = {
        let mut hasher = Sha256::new();
        hasher.update(serde_json::to_vec(&payload).unwrap_or_default());
        hex::encode(hasher.finalize())
    };
    let mut causal = CausalContext::new(
        ActorId::new("system:process").map_err(engine_capability_error)?,
        ActorKind::System,
        AuthorityGrantId::new("engine-system").map_err(engine_capability_error)?,
        TraceId::new(parent.causal_context.trace_id.as_str()).map_err(engine_capability_error)?,
    )
    .with_parent_invocation(parent.id.clone())
    .with_scope("resource.write")
    .with_idempotency_key(format!(
        "{}:{}:{payload_hash}",
        parent.id.as_str(),
        function_id
    ));
    if let Some(session_id) = &parent.causal_context.session_id {
        causal = causal.with_session_id(session_id.clone());
    }
    if let Some(workspace_id) = &parent.causal_context.workspace_id {
        causal = causal.with_workspace_id(workspace_id.clone());
    }
    for (key, value) in &parent.causal_context.runtime_metadata {
        causal = causal.with_runtime_metadata(key.clone(), value.clone());
    }
    let result = deps
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new(function_id).map_err(engine_capability_error)?,
            payload,
            causal,
        ))
        .await;
    if let Some(error) = result.error {
        return Err(engine_capability_error(error));
    }
    result.value.ok_or_else(|| CapabilityError::Internal {
        message: format!("{function_id} returned no value"),
    })
}

fn safe_sandbox_output_path(root: &Path, relative: &str) -> Result<PathBuf, CapabilityError> {
    let candidate = root.join(relative);
    let canonical_root = root
        .canonicalize()
        .map_err(|error| CapabilityError::Internal {
            message: format!("canonicalize process sandbox: {error}"),
        })?;
    let canonical = candidate
        .canonicalize()
        .map_err(|error| CapabilityError::Custom {
            code: "PROCESS_EXPECTED_OUTPUT_MISSING".to_owned(),
            message: format!("expected output {relative} is not readable: {error}"),
            details: None,
        })?;
    if !canonical.starts_with(&canonical_root) {
        return Err(CapabilityError::InvalidParams {
            message: format!("expected output {relative} escapes process sandbox"),
        });
    }
    Ok(canonical)
}

fn engine_capability_error(error: impl std::fmt::Display) -> CapabilityError {
    CapabilityError::Custom {
        code: "ENGINE_RESOURCE_MATERIALIZATION_FAILED".to_owned(),
        message: error.to_string(),
        details: None,
    }
}

fn decode_capped(bytes: &[u8]) -> (String, bool) {
    let truncated = bytes.len() > MAX_OUTPUT_BYTES;
    let slice = if truncated {
        &bytes[..MAX_OUTPUT_BYTES]
    } else {
        bytes
    };
    let mut text = String::from_utf8_lossy(slice).into_owned();
    if truncated {
        text.push_str("\n[output truncated]");
    }
    (text, truncated)
}

fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hex::encode(hasher.finalize())
}

fn command_timeout_ms(params: Option<&Value>) -> u64 {
    let timeout_ms = opt_u64(params, "timeoutMs", DEFAULT_TIMEOUT_MS);
    if timeout_ms != DEFAULT_TIMEOUT_MS || params.and_then(|value| value.get("timeout")).is_none() {
        return timeout_ms;
    }
    opt_u64(params, "timeout", DEFAULT_TIMEOUT_MS)
}

fn default_cwd(invocation: &Invocation, deps: &Deps) -> String {
    let Some(session_id) = invocation.causal_context.session_id.as_deref() else {
        return crate::shared::paths::home_dir();
    };
    if let Some(worktree) = deps
        .worktree_coordinator
        .as_ref()
        .and_then(|coordinator| coordinator.effective_working_dir(session_id))
    {
        return worktree;
    }
    match deps.event_store.get_session(session_id) {
        Ok(Some(session)) => session.working_directory,
        Ok(None) | Err(_) => crate::shared::paths::home_dir(),
    }
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;
