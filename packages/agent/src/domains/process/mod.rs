//! process domain worker.
//!
//! This worker owns host process execution as a capability. The model never
//! receives a shell-specific capability; it discovers and invokes `process::run`
//! through the capability primitives.

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

async fn process_run_value(params: Option<&Value>, _deps: &Deps) -> Result<Value, CapabilityError> {
    let command = require_string_param(params, "command")?;
    let cwd = opt_string(params, "cwd").unwrap_or_else(crate::shared::paths::home_dir);
    let shell = opt_string(params, "shell").unwrap_or_else(|| "bash".to_owned());
    let timeout_ms = opt_u64(params, "timeoutMs", DEFAULT_TIMEOUT_MS).clamp(1, 600_000);
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
