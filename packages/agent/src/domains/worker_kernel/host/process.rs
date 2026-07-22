//! Bounded trusted-local command execution.

use std::process::Stdio;
use std::time::Duration;

use serde_json::{Value, json};

use crate::engine::Invocation;

use super::super::process::{
    MAX_PROCESS_CAPTURE_BYTES, ProcessTree, trusted_local_command_path, wait_with_bounded_output,
};
use super::super::runtime::WorkerRuntime;
use super::support::resolve_path;

const MAX_PROCESS_ARGUMENTS: usize = 256;
const MAX_PROCESS_INPUT_BYTES: usize = 4 * 1_048_576;

pub(in crate::domains::worker_kernel) async fn process_run(
    invocation: &Invocation,
    _runtime: &WorkerRuntime,
) -> Result<Value, String> {
    let command = invocation
        .payload
        .get("command")
        .and_then(Value::as_array)
        .ok_or_else(|| "command must be an array".to_owned())?
        .iter()
        .map(|value| {
            value
                .as_str()
                .map(ToOwned::to_owned)
                .ok_or_else(|| "command entries must be strings".to_owned())
        })
        .collect::<Result<Vec<_>, _>>()?;
    if command.is_empty() || command.len() > MAX_PROCESS_ARGUMENTS {
        return Err(format!(
            "command must contain 1 to {MAX_PROCESS_ARGUMENTS} entries"
        ));
    }
    let (program, arguments) = command.split_first().expect("non-empty command");
    let cwd = invocation
        .payload
        .get("cwd")
        .and_then(Value::as_str)
        .map_or_else(
            || resolve_path(invocation, "."),
            |path| resolve_path(invocation, path),
        )?;
    let timeout = invocation
        .payload
        .get("timeoutSeconds")
        .and_then(Value::as_u64)
        .unwrap_or(300)
        .clamp(1, 7_200);
    let input = invocation.payload.get("stdin").map(|input| {
        input.as_str().map_or_else(
            || serde_json::to_vec(input).unwrap_or_default(),
            |text| text.as_bytes().to_vec(),
        )
    });
    if input
        .as_ref()
        .is_some_and(|input| input.len() > MAX_PROCESS_INPUT_BYTES)
    {
        return Err(format!(
            "process stdin exceeds the {MAX_PROCESS_INPUT_BYTES}-byte reliability ceiling"
        ));
    }
    let mut process = tokio::process::Command::new(program);
    process
        .args(arguments)
        .current_dir(&cwd)
        .env("PATH", trusted_local_command_path(None)?)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let child =
        ProcessTree::spawn(&mut process).map_err(|error| format!("start process: {error}"))?;
    let output = wait_with_bounded_output(
        child,
        input,
        Duration::from_secs(timeout),
        format!("process timed out after {timeout} seconds"),
        MAX_PROCESS_CAPTURE_BYTES,
    )
    .await
    .map_err(|error| format!("wait for process: {error}"))?;
    if let Some((kind, error)) = output.input_error
        && kind != std::io::ErrorKind::BrokenPipe
    {
        return Err(format!("write process input: {error}"));
    }
    Ok(json!({
        "command": command,
        "cwd": cwd,
        "status": output.status.code(),
        "success": output.status.success(),
        "stdout": String::from_utf8_lossy(&output.stdout),
        "stderr": String::from_utf8_lossy(&output.stderr),
        "stdoutTruncated": output.stdout_truncated,
        "stderrTruncated": output.stderr_truncated,
    }))
}
