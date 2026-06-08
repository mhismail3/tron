//! Process primitive execute operations.

use std::time::Duration;

use serde_json::json;
use tokio::process::Command;

use super::filesystem::working_directory;
use super::{error_capability_result, internal, optional_u64, required_str};
use crate::engine::Invocation;
use crate::shared::protocol::content::CapabilityResultContent;
use crate::shared::protocol::model_capabilities::{CapabilityResult, CapabilityResultBody};
use crate::shared::server::errors::CapabilityError;

const DEFAULT_COMMAND_TIMEOUT_MS: u64 = 30_000;
const MAX_COMMAND_TIMEOUT_MS: u64 = 120_000;
const DEFAULT_OUTPUT_BYTES: usize = 20_000;
const MAX_OUTPUT_BYTES: usize = 200_000;

pub(super) async fn process_run(
    invocation: &Invocation,
) -> Result<CapabilityResult, CapabilityError> {
    let command = required_str(&invocation.payload, "command")?;
    let root = working_directory(invocation)?;
    let timeout_ms = optional_u64(&invocation.payload, "timeoutMs")?
        .unwrap_or(DEFAULT_COMMAND_TIMEOUT_MS)
        .clamp(1, MAX_COMMAND_TIMEOUT_MS);
    let max_output_bytes = optional_u64(&invocation.payload, "maxOutputBytes")?
        .map(|value| value as usize)
        .unwrap_or(DEFAULT_OUTPUT_BYTES)
        .clamp(1, MAX_OUTPUT_BYTES);
    let child = Command::new("/bin/sh")
        .arg("-lc")
        .arg(command)
        .current_dir(root)
        .kill_on_drop(true)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|error| internal(format!("spawn process: {error}")))?;
    let output =
        match tokio::time::timeout(Duration::from_millis(timeout_ms), child.wait_with_output())
            .await
        {
            Ok(result) => result.map_err(|error| internal(format!("wait for process: {error}")))?,
            Err(_) => {
                return Ok(error_capability_result(
                    format!("process_run timed out after {timeout_ms}ms"),
                    json!({
                        "primitiveOperation": "process_run",
                        "status": "timeout",
                        "timeoutMs": timeout_ms
                    }),
                ));
            }
        };
    let stdout = truncate_utf8(&output.stdout, max_output_bytes);
    let stderr = truncate_utf8(&output.stderr, max_output_bytes);
    let exit_code = output.status.code();
    let is_error = !output.status.success();
    Ok(CapabilityResult {
        content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(format!(
            "exitCode: {}\nstdout:\n{}\nstderr:\n{}",
            exit_code
                .map(|code| code.to_string())
                .unwrap_or_else(|| "signal".to_owned()),
            stdout,
            stderr
        ))]),
        details: Some(json!({
            "primitiveOperation": "process_run",
            "status": if is_error { "failed" } else { "ok" },
            "exitCode": exit_code,
            "stdout": stdout,
            "stderr": stderr
        })),
        is_error: Some(is_error),
        stop_turn: None,
    })
}

fn truncate_utf8(bytes: &[u8], max: usize) -> String {
    let end = bytes.len().min(max);
    String::from_utf8_lossy(&bytes[..end]).into_owned()
}
