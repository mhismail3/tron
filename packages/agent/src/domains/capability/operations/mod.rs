//! Primitive execute operations for the bare engine loop.
//!
//! `capability::execute` is the only model-facing tool on this branch. It does
//! not search, inspect, route, bind, approve, or execute catalog targets. It
//! performs one direct host primitive operation and returns a model-visible
//! observation with engine details for audit.

use std::path::{Component, Path, PathBuf};
use std::time::Duration;

use serde_json::{Value, json};
use tokio::process::Command;

use super::Deps;
use crate::engine::{
    CausalContext, FunctionId, Invocation, invocation::RUNTIME_METADATA_WORKING_DIRECTORY,
};
use crate::shared::content::CapabilityResultContent;
use crate::shared::model_capabilities::{CapabilityResult, CapabilityResultBody};
use crate::shared::server::errors::CapabilityError;

const DEFAULT_COMMAND_TIMEOUT_MS: u64 = 30_000;
const MAX_COMMAND_TIMEOUT_MS: u64 = 120_000;
const DEFAULT_OUTPUT_BYTES: usize = 20_000;
const MAX_OUTPUT_BYTES: usize = 200_000;
const MAX_FILE_READ_BYTES: u64 = 256 * 1024;

pub(crate) async fn execute_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let operation = required_str(&invocation.payload, "operation")?;
    let result = match operation {
        "observe" => observe(invocation)?,
        "state_get" => state_get(invocation, deps).await?,
        "state_set" => state_set(invocation, deps).await?,
        "state_list" => state_list(invocation, deps).await?,
        "file_read" => file_read(invocation).await?,
        "file_write" => file_write(invocation).await?,
        "process_run" => process_run(invocation).await?,
        other => {
            return Err(CapabilityError::InvalidParams {
                message: format!(
                    "Unsupported primitive execute operation '{other}'. Use observe, state_get, state_set, state_list, file_read, file_write, or process_run."
                ),
            });
        }
    };
    result_value(result)
}

fn observe(invocation: &Invocation) -> Result<CapabilityResult, CapabilityError> {
    let input = optional_str(&invocation.payload, "input")?.unwrap_or("");
    Ok(ok_result(
        if input.is_empty() {
            "Observation recorded.".to_owned()
        } else {
            input.to_owned()
        },
        json!({
            "primitiveOperation": "observe",
            "status": "ok"
        }),
    ))
}

async fn state_get(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let payload = state_payload(invocation, false)?;
    let value = invoke_engine_value(
        deps,
        "state::get",
        payload,
        invocation.causal_context.clone(),
    )
    .await?;
    Ok(ok_result(
        format!("State read: {}", compact_json(&value)),
        json!({
            "primitiveOperation": "state_get",
            "status": "ok",
            "state": value
        }),
    ))
}

async fn state_set(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let payload = state_payload(invocation, true)?;
    let value = invoke_engine_value(
        deps,
        "state::set",
        payload,
        invocation.causal_context.clone(),
    )
    .await?;
    Ok(ok_result(
        format!("State updated: {}", compact_json(&value)),
        json!({
            "primitiveOperation": "state_set",
            "status": "ok",
            "state": value
        }),
    ))
}

async fn state_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let mut payload = json!({
        "scope": optional_str(&invocation.payload, "scope")?.unwrap_or("session"),
        "namespace": required_str(&invocation.payload, "namespace")?,
    });
    if let Some(prefix) = optional_str(&invocation.payload, "keyPrefix")? {
        payload["keyPrefix"] = json!(prefix);
    }
    let value = invoke_engine_value(
        deps,
        "state::list",
        payload,
        invocation.causal_context.clone(),
    )
    .await?;
    Ok(ok_result(
        format!("State entries: {}", compact_json(&value)),
        json!({
            "primitiveOperation": "state_list",
            "status": "ok",
            "state": value
        }),
    ))
}

async fn file_read(invocation: &Invocation) -> Result<CapabilityResult, CapabilityError> {
    let path = resolve_relative_path(invocation, required_str(&invocation.payload, "path")?)?;
    let metadata = tokio::fs::metadata(&path)
        .await
        .map_err(|error| internal(format!("read metadata {}: {error}", path.display())))?;
    if metadata.len() > MAX_FILE_READ_BYTES {
        return Err(CapabilityError::InvalidParams {
            message: format!(
                "file_read refuses files larger than {MAX_FILE_READ_BYTES} bytes in the primitive loop"
            ),
        });
    }
    let content = tokio::fs::read_to_string(&path)
        .await
        .map_err(|error| internal(format!("read {}: {error}", path.display())))?;
    Ok(ok_result(
        content.clone(),
        json!({
            "primitiveOperation": "file_read",
            "status": "ok",
            "path": path,
            "bytes": content.len()
        }),
    ))
}

async fn file_write(invocation: &Invocation) -> Result<CapabilityResult, CapabilityError> {
    let path = resolve_relative_path(invocation, required_str(&invocation.payload, "path")?)?;
    let content = required_str(&invocation.payload, "content")?;
    if let Some(parent) = path.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|error| internal(format!("create {}: {error}", parent.display())))?;
    }
    tokio::fs::write(&path, content)
        .await
        .map_err(|error| internal(format!("write {}: {error}", path.display())))?;
    Ok(ok_result(
        format!("Wrote {} bytes to {}.", content.len(), path.display()),
        json!({
            "primitiveOperation": "file_write",
            "status": "ok",
            "path": path,
            "bytes": content.len()
        }),
    ))
}

async fn process_run(invocation: &Invocation) -> Result<CapabilityResult, CapabilityError> {
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

fn state_payload(invocation: &Invocation, include_value: bool) -> Result<Value, CapabilityError> {
    let mut payload = json!({
        "scope": optional_str(&invocation.payload, "scope")?.unwrap_or("session"),
        "namespace": required_str(&invocation.payload, "namespace")?,
        "key": required_str(&invocation.payload, "key")?,
    });
    if include_value {
        payload["value"] = invocation.payload.get("value").cloned().ok_or_else(|| {
            CapabilityError::InvalidParams {
                message: "missing required field value".to_owned(),
            }
        })?;
    }
    Ok(payload)
}

async fn invoke_engine_value(
    deps: &Deps,
    function_id: &str,
    payload: Value,
    causal_context: CausalContext,
) -> Result<Value, CapabilityError> {
    let result = deps
        .engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new(function_id).map_err(|error| internal(error.to_string()))?,
            payload,
            causal_context,
        ))
        .await;
    if let Some(error) = result.error {
        return Err(internal(format!("{function_id} failed: {error}")));
    }
    result
        .value
        .ok_or_else(|| internal(format!("{function_id} returned no value")))
}

fn resolve_relative_path(invocation: &Invocation, raw: &str) -> Result<PathBuf, CapabilityError> {
    if raw.trim().is_empty() {
        return Err(CapabilityError::InvalidParams {
            message: "path must not be empty".to_owned(),
        });
    }
    let candidate = Path::new(raw);
    if candidate.is_absolute() {
        return Err(CapabilityError::InvalidParams {
            message: "primitive file paths must be relative to the working directory".to_owned(),
        });
    }
    for component in candidate.components() {
        if matches!(
            component,
            Component::ParentDir | Component::RootDir | Component::Prefix(_)
        ) {
            return Err(CapabilityError::InvalidParams {
                message: "primitive file paths must not escape the working directory".to_owned(),
            });
        }
    }
    Ok(working_directory(invocation)?.join(candidate))
}

fn working_directory(invocation: &Invocation) -> Result<PathBuf, CapabilityError> {
    invocation
        .causal_context
        .runtime_metadata(RUNTIME_METADATA_WORKING_DIRECTORY)
        .map(PathBuf::from)
        .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")))
        .canonicalize()
        .map_err(|error| internal(format!("resolve working directory: {error}")))
}

fn required_str<'a>(payload: &'a Value, field: &str) -> Result<&'a str, CapabilityError> {
    optional_str(payload, field)?.ok_or_else(|| CapabilityError::InvalidParams {
        message: format!("missing required field {field}"),
    })
}

fn optional_str<'a>(payload: &'a Value, field: &str) -> Result<Option<&'a str>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value)),
        Some(_) => Err(CapabilityError::InvalidParams {
            message: format!("{field} must be a string"),
        }),
    }
}

fn optional_u64(payload: &Value, field: &str) -> Result<Option<u64>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Number(value)) => {
            value
                .as_u64()
                .map(Some)
                .ok_or_else(|| CapabilityError::InvalidParams {
                    message: format!("{field} must be a positive integer"),
                })
        }
        Some(_) => Err(CapabilityError::InvalidParams {
            message: format!("{field} must be a positive integer"),
        }),
    }
}

fn ok_result(text: String, details: Value) -> CapabilityResult {
    CapabilityResult {
        content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(text)]),
        details: Some(details),
        is_error: Some(false),
        stop_turn: None,
    }
}

fn error_capability_result(text: String, details: Value) -> CapabilityResult {
    CapabilityResult {
        content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(text)]),
        details: Some(details),
        is_error: Some(true),
        stop_turn: None,
    }
}

fn result_value(result: CapabilityResult) -> Result<Value, CapabilityError> {
    serde_json::to_value(result).map_err(|error| internal(format!("serialize result: {error}")))
}

fn compact_json(value: &Value) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "<unserializable>".to_owned())
}

fn truncate_utf8(bytes: &[u8], max: usize) -> String {
    let end = bytes.len().min(max);
    String::from_utf8_lossy(&bytes[..end]).into_owned()
}

fn internal(message: impl Into<String>) -> CapabilityError {
    CapabilityError::Internal {
        message: message.into(),
    }
}
