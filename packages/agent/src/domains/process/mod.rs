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
//! materialize those outputs through resource capabilities. Relative
//! materialization targets resolve to the active session worktree so approved
//! sandbox output never leaks into the server process cwd. Every `process::run`
//! invocation requires active session worktree truth. Read-only command cwd/path
//! operands and materialized output targets are bounded to that worktree, and
//! child processes receive an allowlisted environment instead of inheriting
//! server secrets. If a request omits `cwd`, direct read-only execution uses the
//! active session worktree, so common shell checks stay fast without leaving the
//! capability architecture.

pub(crate) mod approval;
mod bounds;
pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;

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
    let sandbox = if execution_mode == "sandbox_materialized" {
        Some(
            tempfile::tempdir().map_err(|error| CapabilityError::Internal {
                message: format!("create process sandbox: {error}"),
            })?,
        )
    } else {
        None
    };
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
mod tests {
    use std::sync::Arc;

    use serde_json::json;

    use super::*;
    use crate::domains::session::event_store::EventStore;
    use crate::domains::session::event_store::sqlite::connection::{self, ConnectionConfig};
    use crate::domains::session::event_store::sqlite::migrations::run_migrations;
    use crate::engine::{ActorId, ActorKind, AuthorityGrantId, CausalContext, FunctionId, TraceId};

    fn event_store() -> Arc<EventStore> {
        let pool = connection::new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            run_migrations(&conn).unwrap();
        }
        Arc::new(EventStore::new(pool))
    }

    fn invocation(payload: Value, session_id: Option<&str>) -> Invocation {
        let mut causal = CausalContext::new(
            ActorId::new("agent:test").unwrap(),
            ActorKind::Agent,
            AuthorityGrantId::new("grant:test").unwrap(),
            TraceId::generate(),
        );
        if let Some(session_id) = session_id {
            causal = causal.with_session_id(session_id.to_owned());
        }
        Invocation::new_sync(FunctionId::new("process::run").unwrap(), payload, causal)
    }

    #[test]
    fn process_run_defaults_to_session_working_directory() {
        let store = event_store();
        let created = store
            .create_session(
                "gpt-5.5",
                "/tmp/tron-process-default-cwd",
                None,
                None,
                None,
                None,
            )
            .unwrap();
        let deps = Deps::for_test(Arc::clone(&store));
        let invocation = invocation(
            json!({"command": "pwd", "executionMode": "read_only"}),
            Some(&created.session.id),
        );

        assert_eq!(
            default_cwd(&invocation, &deps),
            "/tmp/tron-process-default-cwd"
        );
    }

    #[test]
    fn process_timeout_accepts_timeout_ms_and_timeout() {
        assert_eq!(
            command_timeout_ms(Some(&json!({"timeoutMs": 42, "timeout": 1000}))),
            42
        );
        assert_eq!(command_timeout_ms(Some(&json!({"timeout": 1000}))), 1000);
        assert_eq!(command_timeout_ms(Some(&json!({}))), DEFAULT_TIMEOUT_MS);
    }

    #[test]
    fn process_response_schema_accepts_materialized_output_summaries() {
        let spec = contract::capabilities()
            .unwrap()
            .into_iter()
            .find(|spec| spec.function_id.as_str() == "process::run")
            .unwrap();
        crate::engine::schema::validate_payload(
            &spec.function_id,
            "response",
            spec.response_schema.as_ref().unwrap(),
            &json!({
                "stdout": "wrote result.txt\n",
                "stderr": "",
                "exitCode": 0,
                "durationMs": 12,
                "timedOut": false,
                "outputTruncated": false,
                "resourceRefs": [{
                    "resourceId": "materialized_file:test",
                    "kind": "materialized_file",
                    "role": "updated",
                    "versionId": "ver_test",
                    "contentHash": "version-hash",
                    "fileContentHash": "file-hash",
                    "materializedPath": "/tmp/result.txt"
                }],
                "materializedOutputs": [{
                    "path": "result.txt",
                    "targetPath": "/tmp/result.txt",
                    "resourceId": "materialized_file:test",
                    "versionId": "ver_test",
                    "contentHash": "file-hash",
                    "sizeBytes": 7,
                    "contentPreview": "result\n",
                    "previewTruncated": false
                }]
            }),
        )
        .unwrap();
    }

    #[test]
    fn process_request_schema_rejects_empty_command() {
        let spec = contract::capabilities()
            .unwrap()
            .into_iter()
            .find(|spec| spec.function_id.as_str() == "process::run")
            .unwrap();
        let err = crate::engine::schema::validate_payload(
            &spec.function_id,
            "request",
            spec.request_schema.as_ref().unwrap(),
            &json!({"command": "", "executionMode": "read_only"}),
        )
        .unwrap_err();

        assert!(err.to_string().contains("minLength 1"));
    }

    #[tokio::test]
    async fn blank_process_command_is_rejected_before_execution() {
        let store = event_store();
        let deps = Deps::for_test(store);
        let invocation = invocation(
            json!({"command": "   ", "executionMode": "read_only"}),
            None,
        );
        let err = process_run_value(&invocation, &deps).await.unwrap_err();

        assert!(
            matches!(err, CapabilityError::InvalidParams { message } if message.contains("non-empty command"))
        );
    }

    #[tokio::test]
    async fn write_like_read_only_process_is_rejected_before_execution() {
        let store = event_store();
        let deps = Deps::for_test(store);
        let invocation = invocation(
            json!({"command": "touch should-not-exist", "executionMode": "read_only"}),
            None,
        );
        let err = process_run_value(&invocation, &deps).await.unwrap_err();
        assert!(
            matches!(err, CapabilityError::InvalidParams { message } if message.contains("sandbox_materialized"))
        );
    }

    #[tokio::test]
    async fn composed_read_only_file_checks_execute_in_session_worktree() {
        let store = event_store();
        let tmp = tempfile::tempdir().unwrap();
        std::fs::write(tmp.path().join("README.md"), "alpha\nbeta\ngamma\n").unwrap();
        let created = store
            .create_session(
                "gpt-5.5",
                &tmp.path().to_string_lossy(),
                None,
                None,
                None,
                None,
            )
            .unwrap();
        let deps = Deps::for_test(store);
        let invocation = invocation(
            json!({
                "command": "pwd && printf 'hi\n' && test ! -e should_not_exist.txt && test -f README.md && sed -n '1,3p' README.md",
                "executionMode": "read_only"
            }),
            Some(&created.session.id),
        );

        let value = process_run_value(&invocation, &deps).await.unwrap();
        assert_eq!(value.get("exitCode").and_then(Value::as_i64), Some(0));
        let stdout = value.get("stdout").and_then(Value::as_str).unwrap();
        assert!(stdout.contains(&tmp.path().to_string_lossy().to_string()));
        assert!(stdout.contains("hi\nalpha\nbeta\ngamma"));
        assert!(!tmp.path().join("should_not_exist.txt").exists());
    }

    #[tokio::test]
    async fn read_only_process_rejects_paths_outside_session_worktree() {
        let store = event_store();
        let tmp = tempfile::tempdir().unwrap();
        let created = store
            .create_session(
                "gpt-5.5",
                &tmp.path().to_string_lossy(),
                None,
                None,
                None,
                None,
            )
            .unwrap();
        let deps = Deps::for_test(store);
        let cases = [
            "cat /etc/passwd",
            "git -C /tmp status --short",
            "cd /tmp && pwd",
            "cat ../secret.txt",
            "cat $HOME/.ssh/id_rsa",
        ];

        for command in cases {
            let invocation = invocation(
                json!({"command": command, "executionMode": "read_only"}),
                Some(&created.session.id),
            );
            let err = process_run_value(&invocation, &deps).await.unwrap_err();
            assert!(
                matches!(err, CapabilityError::InvalidParams { ref message } if message.contains("active session worktree")),
                "{command} should be rejected, got {err:?}"
            );
        }
    }

    #[tokio::test]
    async fn read_only_process_allows_search_patterns_but_bounds_search_paths() {
        let store = event_store();
        let tmp = tempfile::tempdir().unwrap();
        std::fs::write(tmp.path().join("README.md"), "alpha\nneedle\n").unwrap();
        let created = store
            .create_session(
                "gpt-5.5",
                &tmp.path().to_string_lossy(),
                None,
                None,
                None,
                None,
            )
            .unwrap();
        let deps = Deps::for_test(store);
        let allowed = invocation(
            json!({"command": "grep 'needle$' README.md", "executionMode": "read_only"}),
            Some(&created.session.id),
        );

        let value = process_run_value(&allowed, &deps).await.unwrap();
        assert_eq!(value.get("exitCode").and_then(Value::as_i64), Some(0));
        assert_eq!(
            value.get("stdout").and_then(Value::as_str),
            Some("needle\n")
        );

        let denied = invocation(
            json!({"command": "grep needle /etc/passwd", "executionMode": "read_only"}),
            Some(&created.session.id),
        );
        let err = process_run_value(&denied, &deps).await.unwrap_err();
        assert!(
            matches!(err, CapabilityError::InvalidParams { message } if message.contains("active session worktree"))
        );
    }

    #[tokio::test]
    async fn read_only_process_rejects_shell_glob_path_operands() {
        let store = event_store();
        let tmp = tempfile::tempdir().unwrap();
        std::fs::write(tmp.path().join("README.md"), "safe\n").unwrap();
        let created = store
            .create_session(
                "gpt-5.5",
                &tmp.path().to_string_lossy(),
                None,
                None,
                None,
                None,
            )
            .unwrap();
        let deps = Deps::for_test(store);
        let denied = invocation(
            json!({"command": "cat *.md", "executionMode": "read_only"}),
            Some(&created.session.id),
        );

        let err = process_run_value(&denied, &deps).await.unwrap_err();
        assert!(
            matches!(err, CapabilityError::InvalidParams { message } if message.contains("glob or brace expansion"))
        );
    }

    #[tokio::test]
    async fn read_only_find_allows_name_globs_but_bounds_search_roots() {
        let store = event_store();
        let tmp = tempfile::tempdir().unwrap();
        std::fs::write(tmp.path().join("README.md"), "safe\n").unwrap();
        let created = store
            .create_session(
                "gpt-5.5",
                &tmp.path().to_string_lossy(),
                None,
                None,
                None,
                None,
            )
            .unwrap();
        let deps = Deps::for_test(store);
        let allowed = invocation(
            json!({"command": "find . -maxdepth 1 -name '*.md'", "executionMode": "read_only"}),
            Some(&created.session.id),
        );

        let value = process_run_value(&allowed, &deps).await.unwrap();
        assert_eq!(value.get("exitCode").and_then(Value::as_i64), Some(0));
        assert!(
            value
                .get("stdout")
                .and_then(Value::as_str)
                .is_some_and(|stdout| stdout.contains("README.md"))
        );

        let denied = invocation(
            json!({"command": "find /tmp -maxdepth 1 -name '*.md'", "executionMode": "read_only"}),
            Some(&created.session.id),
        );
        let err = process_run_value(&denied, &deps).await.unwrap_err();
        assert!(
            matches!(err, CapabilityError::InvalidParams { message } if message.contains("active session worktree"))
        );
    }

    #[tokio::test]
    async fn read_only_process_rejects_symlink_operands_that_escape_worktree() {
        let store = event_store();
        let tmp = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        std::fs::write(outside.path().join("secret.txt"), "secret").unwrap();
        std::os::unix::fs::symlink(
            outside.path().join("secret.txt"),
            tmp.path().join("linked-secret.txt"),
        )
        .unwrap();
        let created = store
            .create_session(
                "gpt-5.5",
                &tmp.path().to_string_lossy(),
                None,
                None,
                None,
                None,
            )
            .unwrap();
        let deps = Deps::for_test(store);
        let invocation = invocation(
            json!({"command": "cat linked-secret.txt", "executionMode": "read_only"}),
            Some(&created.session.id),
        );

        let err = process_run_value(&invocation, &deps).await.unwrap_err();
        assert!(
            matches!(err, CapabilityError::InvalidParams { message } if message.contains("active session worktree"))
        );
    }

    #[test]
    fn safe_process_environment_is_explicitly_allowlisted() {
        let env = safe_process_environment();

        assert!(!env.contains_key("OPENAI_API_KEY"));
        assert!(!env.contains_key("TRON_ENGINE_BEARER_TOKEN"));
        assert!(env.keys().all(|key| !bounds::secret_like_env_key(key)));
    }

    #[tokio::test]
    async fn process_run_rejects_secret_like_env_payloads() {
        let store = event_store();
        let tmp = tempfile::tempdir().unwrap();
        let created = store
            .create_session(
                "gpt-5.5",
                &tmp.path().to_string_lossy(),
                None,
                None,
                None,
                None,
            )
            .unwrap();
        let deps = Deps::for_test(store);
        let invocation = invocation(
            json!({
                "command": "printf ok",
                "executionMode": "read_only",
                "env": {"API_TOKEN": "secret_ref:test"}
            }),
            Some(&created.session.id),
        );

        let err = process_run_value(&invocation, &deps).await.unwrap_err();
        assert!(
            matches!(err, CapabilityError::InvalidParams { message } if message.contains("secret-like"))
        );
    }

    #[tokio::test]
    async fn unknown_read_only_process_is_rejected_before_execution() {
        let store = event_store();
        let deps = Deps::for_test(store);
        let target = std::env::temp_dir().join(format!(
            "tron-process-read-only-{}.txt",
            uuid::Uuid::now_v7()
        ));
        let invocation = invocation(
            json!({
                "command": format!("python3 -c 'open({:?}, \"w\").write(\"nope\")'", target),
                "executionMode": "read_only"
            }),
            None,
        );

        let err = process_run_value(&invocation, &deps).await.unwrap_err();
        assert!(
            matches!(err, CapabilityError::InvalidParams { message } if message.contains("proven low-risk"))
        );
        assert!(
            !target.exists(),
            "read_only rejection must happen before process spawn"
        );
    }

    #[tokio::test]
    async fn process_run_requires_active_session_worktree() {
        let store = event_store();
        let deps = Deps::for_test(store);
        let invocation = invocation(
            json!({"command": "date", "executionMode": "read_only"}),
            None,
        );

        let err = process_run_value(&invocation, &deps).await.unwrap_err();
        assert!(
            matches!(err, CapabilityError::InvalidParams { message } if message.contains("active session worktree"))
        );
    }

    #[tokio::test]
    async fn sandbox_materialized_process_declared_outputs_become_resources() {
        let store = event_store();
        let tmp = tempfile::tempdir().unwrap();
        let target = tmp.path().join("materialized").join("result.txt");
        let created = store
            .create_session(
                "gpt-5.5",
                &tmp.path().to_string_lossy(),
                None,
                None,
                None,
                None,
            )
            .unwrap();
        let deps = Deps::for_test(store);
        let invocation = invocation(
            json!({
                "command": "mkdir -p out && printf 'hello from sandbox' > out/result.txt",
                "executionMode": "sandbox_materialized",
                "expectedOutputs": [{
                    "path": "out/result.txt",
                    "targetPath": target.to_string_lossy()
                }],
                "retainOutput": true
            }),
            Some(&created.session.id),
        );

        let value = process_run_value(&invocation, &deps).await.unwrap();
        assert_eq!(value["exitCode"], 0);
        assert_eq!(
            std::fs::read_to_string(&target).unwrap(),
            "hello from sandbox"
        );
        let refs = value["resourceRefs"].as_array().unwrap();
        assert!(
            refs.iter()
                .any(|resource_ref| resource_ref["kind"] == "materialized_file")
        );
        assert!(
            refs.iter()
                .any(|resource_ref| resource_ref["kind"] == "execution_output")
        );
    }

    #[tokio::test]
    async fn sandbox_materialized_relative_outputs_materialize_in_session_worktree() {
        let store = event_store();
        let tmp = tempfile::tempdir().unwrap();
        let created = store
            .create_session(
                "gpt-5.5",
                &tmp.path().to_string_lossy(),
                None,
                None,
                None,
                None,
            )
            .unwrap();
        let deps = Deps::for_test(store);
        let invocation = invocation(
            json!({
                "command": "printf 'session materialized\n' > result.txt",
                "executionMode": "sandbox_materialized",
                "expectedOutputs": [{"path": "result.txt"}],
                "retainOutput": true
            }),
            Some(&created.session.id),
        );

        let value = process_run_value(&invocation, &deps).await.unwrap();
        assert_eq!(value["exitCode"], 0);
        assert_eq!(
            std::fs::read_to_string(tmp.path().join("result.txt")).unwrap(),
            "session materialized\n"
        );
        let materialized = value["materializedOutputs"].as_array().unwrap();
        assert_eq!(materialized[0]["path"], "result.txt");
        let expected_target = tmp.path().join("result.txt").canonicalize().unwrap();
        assert_eq!(
            materialized[0]["targetPath"].as_str(),
            Some(expected_target.to_string_lossy().as_ref())
        );
        assert_eq!(materialized[0]["contentPreview"], "session materialized\n");
        let refs = value["resourceRefs"].as_array().unwrap();
        let file_ref = refs
            .iter()
            .find(|resource_ref| resource_ref["kind"] == "materialized_file")
            .unwrap();
        assert_eq!(
            file_ref["materializedPath"].as_str(),
            Some(expected_target.to_string_lossy().as_ref())
        );
        assert_eq!(file_ref["fileContentHash"], materialized[0]["contentHash"]);
    }

    #[tokio::test]
    async fn sandbox_materialized_relative_target_path_cannot_escape_session_worktree() {
        let store = event_store();
        let tmp = tempfile::tempdir().unwrap();
        let created = store
            .create_session(
                "gpt-5.5",
                &tmp.path().to_string_lossy(),
                None,
                None,
                None,
                None,
            )
            .unwrap();
        let deps = Deps::for_test(store);
        let invocation = invocation(
            json!({
                "command": "printf 'escape\n' > result.txt",
                "executionMode": "sandbox_materialized",
                "expectedOutputs": [{"path": "result.txt", "targetPath": "../escape.txt"}]
            }),
            Some(&created.session.id),
        );

        let err = process_run_value(&invocation, &deps).await.unwrap_err();
        assert!(
            matches!(err, CapabilityError::InvalidParams { message } if message.contains("must stay inside"))
        );
        assert!(!tmp.path().parent().unwrap().join("escape.txt").exists());
    }

    #[tokio::test]
    async fn sandbox_materialized_absolute_target_path_cannot_escape_session_worktree() {
        let store = event_store();
        let tmp = tempfile::tempdir().unwrap();
        let outside = tempfile::tempdir().unwrap();
        let created = store
            .create_session(
                "gpt-5.5",
                &tmp.path().to_string_lossy(),
                None,
                None,
                None,
                None,
            )
            .unwrap();
        let deps = Deps::for_test(store);
        let target = outside.path().join("escape.txt");
        let invocation = invocation(
            json!({
                "command": "printf 'escape\n' > result.txt",
                "executionMode": "sandbox_materialized",
                "expectedOutputs": [{"path": "result.txt", "targetPath": target.to_string_lossy()}]
            }),
            Some(&created.session.id),
        );

        let err = process_run_value(&invocation, &deps).await.unwrap_err();
        assert!(
            matches!(err, CapabilityError::InvalidParams { message } if message.contains("active session worktree"))
        );
        assert!(!target.exists());
    }
}
