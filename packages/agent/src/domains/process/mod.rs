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
//! outside the low-risk set require the normal fresh-inspection and approval
//! flow before dispatch. If a request omits `cwd`, the worker uses the active
//! session worktree when available, then the session workspace, so common shell
//! checks stay fast without leaving the capability architecture.

pub(crate) mod approval;
pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
pub(crate) use deps::Deps;

use std::collections::HashMap;
use std::process::Stdio;
use std::time::Instant;

use serde_json::{Value, json};
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

use crate::domains::worker::{DomainRegistrationContext, DomainWorkerModule};
use crate::engine::Invocation;
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
    let cwd = opt_string(params, "cwd").unwrap_or_else(|| default_cwd(invocation, deps));
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
            return Ok(json!({
                "stdout": "",
                "stderr": format!("process timed out after {timeout_ms}ms"),
                "exitCode": -1,
                "durationMs": u64::try_from(start.elapsed().as_millis()).unwrap_or(u64::MAX),
                "timedOut": true,
                "outputTruncated": false,
            }));
        }
    };

    let (stdout, stdout_truncated) = decode_capped(&output.stdout);
    let (stderr, stderr_truncated) = decode_capped(&output.stderr);
    Ok(json!({
        "stdout": stdout,
        "stderr": stderr,
        "exitCode": output.status.code().unwrap_or(-1),
        "durationMs": u64::try_from(start.elapsed().as_millis()).unwrap_or(u64::MAX),
        "timedOut": false,
        "outputTruncated": stdout_truncated || stderr_truncated,
    }))
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
        let invocation = invocation(json!({"command": "pwd"}), Some(&created.session.id));

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
}
