//! process domain worker.
//!
//! This worker owns host process execution as a capability. The model never
//! receives a shell-specific capability; it discovers and invokes `process::run`
//! through the capability primitives.
//!
//! The broad `process::run` contract has conditional approval instead of a
//! blanket approval bit. Payload-sensitive approval classification lives in
//! [`approval`], while schema validation, idempotency, lease, audit, and actual
//! execution remain on the normal engine/capability path. The same classifier
//! also lets low-risk first-party read/check commands such as `date`, `pwd`,
//! `git status`, and test/build checks skip an extra inspect turn; commands
//! outside the low-risk set must use `executionMode = "sandbox_materialized"`
//! with declared expected outputs, then materialize those outputs through
//! resource capabilities. If a request omits `cwd`, direct read-only execution
//! uses the active session worktree when available, then the session workspace,
//! so common shell checks stay fast without leaving the capability architecture.

pub(crate) mod approval;
pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
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
    let execution_mode =
        opt_string(params, "executionMode").ok_or_else(|| CapabilityError::InvalidParams {
            message: "process::run requires executionMode".to_owned(),
        })?;
    if execution_mode == "read_only" && approval::run_requires_approval(&invocation.payload) {
        return Err(CapabilityError::InvalidParams {
            message:
                "process::run read_only commands must be proven low-risk by the classifier; use executionMode=sandbox_materialized with expectedOutputs for mutating or unknown commands"
                    .to_owned(),
        });
    }
    if execution_mode != "read_only" && execution_mode != "sandbox_materialized" {
        return Err(CapabilityError::InvalidParams {
            message: format!("unsupported executionMode: {execution_mode}"),
        });
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
    let cwd = sandbox
        .as_ref()
        .map(|dir| dir.path().to_string_lossy().into_owned())
        .unwrap_or_else(|| {
            opt_string(params, "cwd").unwrap_or_else(|| default_cwd(invocation, deps))
        });
    let shell = opt_string(params, "shell").unwrap_or_else(|| "bash".to_owned());
    let timeout_ms = command_timeout_ms(params).clamp(1, 600_000);
    let stdin = opt_string(params, "stdin");
    let env = params
        .and_then(|value| value.get("env"))
        .and_then(Value::as_object)
        .map(|map| {
            map.iter()
                .filter_map(|(key, value)| {
                    value.as_str().map(|value| (key.clone(), value.to_owned()))
                })
                .collect::<HashMap<_, _>>()
        })
        .unwrap_or_default();

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
    if execution_mode == "sandbox_materialized" {
        refs.extend(
            materialize_expected_outputs(deps, invocation, sandbox.as_ref().unwrap().path())
                .await?,
        );
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
    Ok(result)
}

async fn materialize_expected_outputs(
    deps: &Deps,
    invocation: &Invocation,
    sandbox_root: &Path,
) -> Result<Vec<Value>, CapabilityError> {
    let expected = invocation
        .payload
        .get("expectedOutputs")
        .and_then(Value::as_array)
        .ok_or_else(|| CapabilityError::InvalidParams {
            message: "sandbox_materialized process::run requires expectedOutputs".to_owned(),
        })?;
    let mut refs = Vec::new();
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
        let result = invoke_resource_capability(
            deps,
            invocation,
            "materialized_file::update",
            json!({
                "path": target_path,
                "content": content,
            }),
        )
        .await?;
        refs.extend(
            result
                .get("resourceRefs")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default(),
        );
    }
    Ok(refs)
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
    async fn sandbox_materialized_process_declared_outputs_become_resources() {
        let store = event_store();
        let deps = Deps::for_test(store);
        let tmp = tempfile::tempdir().unwrap();
        let target = tmp.path().join("materialized").join("result.txt");
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
            Some("session-a"),
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
}
