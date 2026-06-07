//! Primitive execute operations for the bare engine loop.
//!
//! `capability::execute` is the only model-facing tool on this branch. It does
//! not search, inspect, route, bind, approve, or execute catalog targets. It
//! performs one direct host primitive operation and returns a model-visible
//! observation with engine details for audit.

use std::path::{Component, Path, PathBuf};
use std::process::Command as StdCommand;
use std::time::{Duration, Instant};

use chrono::Utc;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::process::Command;
use uuid::Uuid;

use super::Deps;
use crate::domains::session::event_store::trace::TRON_TRACE_METADATA_KEY;
use crate::domains::session::event_store::{
    AGENT_TRACE_VERSION, AgentTraceListOptions, AgentTraceRecord,
};
use crate::engine::invocation::{
    RUNTIME_METADATA_MODEL_PRIMITIVE_NAME, RUNTIME_METADATA_PROVIDER_INVOCATION_ID,
    RUNTIME_METADATA_RUN_ID, RUNTIME_METADATA_TURN,
};
use crate::engine::{
    CausalContext, FunctionId, Invocation, invocation::RUNTIME_METADATA_WORKING_DIRECTORY,
};
use crate::shared::content::CapabilityResultContent;
use crate::shared::model_capabilities::{CapabilityResult, CapabilityResultBody};
use crate::shared::server::context::run_blocking_task;
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
    let started_at = Utc::now().to_rfc3339();
    let start = Instant::now();
    let operation = required_str(&invocation.payload, "operation")?.to_owned();
    let mut trace_record = started_trace_record(invocation, deps, &operation, &started_at)?;
    deps.event_store
        .append_trace_record(&trace_record)
        .map_err(|error| internal(format!("record trace start: {error}")))?;

    let result = execute_operation(&operation, invocation, deps).await;
    match result {
        Ok(result) => {
            complete_trace_record(
                &mut trace_record,
                invocation,
                &result,
                None,
                start.elapsed(),
            );
            deps.event_store
                .update_trace_record(&trace_record)
                .map_err(|error| internal(format!("record trace completion: {error}")))?;
            result_value(result)
        }
        Err(error) => {
            complete_trace_record(
                &mut trace_record,
                invocation,
                &error_capability_result(error.to_string(), json!({"status": "failed"})),
                Some(&error),
                start.elapsed(),
            );
            deps.event_store
                .update_trace_record(&trace_record)
                .map_err(|store_error| internal(format!("record trace failure: {store_error}")))?;
            Err(error)
        }
    }
}

async fn execute_operation(
    operation: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    Ok(match operation {
        "observe" => observe(invocation)?,
        "state_get" => state_get(invocation, deps).await?,
        "state_set" => state_set(invocation, deps).await?,
        "state_list" => state_list(invocation, deps).await?,
        "file_read" => file_read(invocation).await?,
        "file_write" => file_write(invocation).await?,
        "process_run" => process_run(invocation).await?,
        "trace_list" => trace_list(invocation, deps)?,
        "trace_get" => trace_get(invocation, deps)?,
        "log_recent" => log_recent(invocation, deps).await?,
        other => {
            return Err(CapabilityError::InvalidParams {
                message: format!(
                    "Unsupported primitive execute operation '{other}'. Use observe, state_get, state_set, state_list, file_read, file_write, process_run, trace_list, trace_get, or log_recent."
                ),
            });
        }
    })
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

fn trace_list(invocation: &Invocation, deps: &Deps) -> Result<CapabilityResult, CapabilityError> {
    let limit = optional_u64(&invocation.payload, "limit")?
        .unwrap_or(50)
        .clamp(1, 500) as i64;
    let trace_id = optional_str(&invocation.payload, "traceId")?;
    let records = deps
        .event_store
        .list_trace_records(&AgentTraceListOptions {
            session_id: invocation.causal_context.session_id.as_deref(),
            trace_id,
            limit: Some(limit),
        })
        .map_err(|error| internal(format!("list trace records: {error}")))?;
    let records = records
        .into_iter()
        .map(|record| record.record_json)
        .collect::<Vec<_>>();
    Ok(ok_result(
        format!("Trace records: {}.", records.len()),
        json!({
            "primitiveOperation": "trace_list",
            "status": "ok",
            "records": records
        }),
    ))
}

fn trace_get(invocation: &Invocation, deps: &Deps) -> Result<CapabilityResult, CapabilityError> {
    let id = required_str(&invocation.payload, "traceRecordId")?;
    let Some(record) = deps
        .event_store
        .get_trace_record(id)
        .map_err(|error| internal(format!("get trace record: {error}")))?
    else {
        return Err(CapabilityError::InvalidParams {
            message: format!("trace record not found: {id}"),
        });
    };
    if let Some(session_id) = invocation.causal_context.session_id.as_deref()
        && record.session_id.as_deref() != Some(session_id)
    {
        return Err(CapabilityError::InvalidParams {
            message: format!("trace record not found for current session: {id}"),
        });
    }
    Ok(ok_result(
        format!("Trace record: {id}."),
        json!({
            "primitiveOperation": "trace_get",
            "status": "ok",
            "record": record.record_json
        }),
    ))
}

async fn log_recent(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let limit = optional_u64(&invocation.payload, "limit")?
        .map(|value| value as i64)
        .unwrap_or(50)
        .clamp(1, 500);
    let trace_id = optional_str(&invocation.payload, "traceId")?.map(str::to_owned);
    let session_id = invocation.causal_context.session_id.clone();
    let pool = deps.event_store.pool().clone();
    let entries = run_blocking_task("execute::log_recent", move || {
        let conn = pool.get().map_err(|error| internal(format!("open log query DB: {error}")))?;
        match (trace_id.as_deref(), session_id.as_deref()) {
            (Some(trace_id), Some(session_id)) => query_log_rows(
                &conn,
                "SELECT id, timestamp, level, component, message, session_id, trace_id, error_message \
                 FROM logs \
                 WHERE trace_id = ?1 AND (session_id IS NULL OR session_id = ?2) \
                 ORDER BY id DESC LIMIT ?3",
                rusqlite::params![trace_id, session_id, limit],
            ),
            (Some(trace_id), None) => query_log_rows(
                &conn,
                "SELECT id, timestamp, level, component, message, session_id, trace_id, error_message \
                 FROM logs \
                 WHERE trace_id = ?1 AND session_id IS NULL \
                 ORDER BY id DESC LIMIT ?2",
                rusqlite::params![trace_id, limit],
            ),
            (None, Some(session_id)) => query_log_rows(
                &conn,
                "SELECT id, timestamp, level, component, message, session_id, trace_id, error_message \
                 FROM logs \
                 WHERE session_id IS NULL OR session_id = ?1 \
                 ORDER BY id DESC LIMIT ?2",
                rusqlite::params![session_id, limit],
            ),
            (None, None) => query_log_rows(
                &conn,
                "SELECT id, timestamp, level, component, message, session_id, trace_id, error_message \
                 FROM logs \
                 WHERE session_id IS NULL \
                 ORDER BY id DESC LIMIT ?1",
                rusqlite::params![limit],
            ),
        }
    })
    .await?;

    Ok(ok_result(
        format!("Log entries: {}.", entries.len()),
        json!({
            "primitiveOperation": "log_recent",
            "status": "ok",
            "entries": entries
        }),
    ))
}

fn query_log_rows<P>(
    conn: &rusqlite::Connection,
    sql: &str,
    params: P,
) -> Result<Vec<Value>, CapabilityError>
where
    P: rusqlite::Params,
{
    let mut stmt = conn
        .prepare(sql)
        .map_err(|error| internal(format!("prepare log query: {error}")))?;
    let rows = stmt
        .query_map(params, log_row)
        .map_err(|error| internal(format!("read logs: {error}")))?;
    let mut entries = rows
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(|error| internal(format!("decode logs: {error}")))?;
    entries.reverse();
    Ok(entries)
}

fn log_row(row: &rusqlite::Row<'_>) -> rusqlite::Result<Value> {
    let id: i64 = row.get(0)?;
    let timestamp: String = row.get(1)?;
    let level: String = row.get(2)?;
    let component: String = row.get(3)?;
    let message: String = row.get(4)?;
    let session_id: Option<String> = row.get(5)?;
    let trace_id: Option<String> = row.get(6)?;
    let error_message: Option<String> = row.get(7)?;
    Ok(json!({
        "id": id,
        "timestamp": timestamp,
        "level": level,
        "component": component,
        "message": message,
        "sessionId": session_id,
        "traceId": trace_id,
        "errorMessage": error_message
    }))
}

fn started_trace_record(
    invocation: &Invocation,
    deps: &Deps,
    operation: &str,
    timestamp: &str,
) -> Result<AgentTraceRecord, CapabilityError> {
    let id = Uuid::now_v7().to_string();
    let session = match invocation.causal_context.session_id.as_deref() {
        Some(session_id) => deps
            .event_store
            .get_session(session_id)
            .map_err(|error| internal(format!("load trace session metadata: {error}")))?,
        None => None,
    };
    let model_id = session
        .as_ref()
        .map(|session| session.latest_model.clone())
        .unwrap_or_else(|| "unknown".to_owned());
    let provider = model_provider(&model_id);
    let working_directory = working_directory(invocation).ok();
    let vcs = working_directory.as_ref().and_then(|path| git_vcs(path));
    let record_json = agent_trace_json(
        invocation,
        &id,
        operation,
        "running",
        timestamp,
        None,
        None,
        vcs,
        Vec::new(),
        json!({
            "request": invocation.payload,
            "requestHash": hash_json(&invocation.payload),
            "modelId": model_id,
            "provider": provider,
            "workingDirectory": working_directory.as_ref().map(|path| path.display().to_string())
        }),
    );
    Ok(AgentTraceRecord {
        id,
        trace_id: invocation.causal_context.trace_id.as_str().to_owned(),
        invocation_id: invocation.id.as_str().to_owned(),
        parent_invocation_id: invocation
            .causal_context
            .parent_invocation_id
            .as_ref()
            .map(|id| id.as_str().to_owned()),
        provider_invocation_id: invocation
            .causal_context
            .runtime_metadata(RUNTIME_METADATA_PROVIDER_INVOCATION_ID)
            .map(ToOwned::to_owned),
        session_id: invocation.causal_context.session_id.clone(),
        workspace_id: invocation.causal_context.workspace_id.clone(),
        turn: runtime_i64(invocation, RUNTIME_METADATA_TURN),
        model_primitive_name: invocation
            .causal_context
            .runtime_metadata(RUNTIME_METADATA_MODEL_PRIMITIVE_NAME)
            .unwrap_or("execute")
            .to_owned(),
        operation: operation.to_owned(),
        status: "running".to_owned(),
        timestamp: timestamp.to_owned(),
        completed_at: None,
        duration_ms: None,
        record_json,
    })
}

fn complete_trace_record(
    record: &mut AgentTraceRecord,
    invocation: &Invocation,
    result: &CapabilityResult,
    error: Option<&CapabilityError>,
    duration: Duration,
) {
    let completed_at = Utc::now().to_rfc3339();
    let duration_ms = duration.as_millis().try_into().unwrap_or(i64::MAX);
    let result_value = serde_json::to_value(result).unwrap_or_else(|_| Value::Null);
    let status = result
        .details
        .as_ref()
        .and_then(|details| details.get("status"))
        .and_then(Value::as_str)
        .unwrap_or_else(|| {
            if result.is_error == Some(true) || error.is_some() {
                "failed"
            } else {
                "ok"
            }
        })
        .to_owned();
    let model_id = trace_model_id(&record.record_json);
    let files = if error.is_some() || result.is_error == Some(true) {
        Vec::new()
    } else {
        trace_files_for_operation(invocation, result, &model_id)
    };
    merge_tron_trace_metadata(
        &mut record.record_json,
        json!({
            "status": status,
            "completedAt": completed_at,
            "durationMs": duration_ms,
            "result": result_value,
            "resultHash": hash_json(result),
            "error": error.map(ToString::to_string)
        }),
    );
    record.record_json["files"] = json!(files);
    record.status = status;
    record.completed_at = Some(completed_at);
    record.duration_ms = Some(duration_ms);
}

#[allow(clippy::too_many_arguments)]
fn agent_trace_json(
    invocation: &Invocation,
    id: &str,
    operation: &str,
    status: &str,
    timestamp: &str,
    completed_at: Option<&str>,
    duration_ms: Option<i64>,
    vcs: Option<Value>,
    files: Vec<Value>,
    extra_metadata: Value,
) -> Value {
    let mut tron_metadata = json!({
        "traceId": invocation.causal_context.trace_id.as_str(),
        "invocationId": invocation.id.as_str(),
        "parentInvocationId": invocation.causal_context.parent_invocation_id.as_ref().map(|id| id.as_str()),
        "providerInvocationId": invocation.causal_context.runtime_metadata(RUNTIME_METADATA_PROVIDER_INVOCATION_ID),
        "sessionId": invocation.causal_context.session_id,
        "workspaceId": invocation.causal_context.workspace_id,
        "turn": runtime_i64(invocation, RUNTIME_METADATA_TURN),
        "runId": invocation.causal_context.runtime_metadata(RUNTIME_METADATA_RUN_ID),
        "modelPrimitiveName": invocation.causal_context.runtime_metadata(RUNTIME_METADATA_MODEL_PRIMITIVE_NAME).unwrap_or("execute"),
        "operation": operation,
        "status": status,
        "startedAt": timestamp,
        "completedAt": completed_at,
        "durationMs": duration_ms,
        "authority": {
            "actorId": invocation.causal_context.actor_id.as_str(),
            "actorKind": format!("{:?}", invocation.causal_context.actor_kind),
            "authorityGrantId": invocation.causal_context.authority_grant_id.as_str(),
            "scopes": invocation.causal_context.authority_scopes,
            "idempotencyKey": invocation.causal_context.idempotency_key
        }
    });
    merge_json_object(&mut tron_metadata, extra_metadata);
    json!({
        "version": AGENT_TRACE_VERSION,
        "id": id,
        "timestamp": timestamp,
        "vcs": vcs,
        "tool": {
            "name": "tron",
            "version": env!("CARGO_PKG_VERSION")
        },
        "files": files,
        "metadata": {
            TRON_TRACE_METADATA_KEY: tron_metadata
        }
    })
}

fn merge_tron_trace_metadata(record_json: &mut Value, extra: Value) {
    if let Some(metadata) = record_json
        .get_mut("metadata")
        .and_then(|metadata| metadata.get_mut(TRON_TRACE_METADATA_KEY))
    {
        merge_json_object(metadata, extra);
    }
}

fn merge_json_object(target: &mut Value, extra: Value) {
    let (Some(target), Value::Object(extra)) = (target.as_object_mut(), extra) else {
        return;
    };
    for (key, value) in extra {
        let _ = target.insert(key, value);
    }
}

fn trace_model_id(record_json: &Value) -> String {
    record_json
        .get("metadata")
        .and_then(|metadata| metadata.get(TRON_TRACE_METADATA_KEY))
        .and_then(|metadata| metadata.get("modelId"))
        .and_then(Value::as_str)
        .unwrap_or("unknown")
        .to_owned()
}

fn trace_files_for_operation(
    invocation: &Invocation,
    result: &CapabilityResult,
    model_id: &str,
) -> Vec<Value> {
    match invocation
        .payload
        .get("operation")
        .and_then(Value::as_str)
        .unwrap_or("")
    {
        "file_write" => {
            let path = required_str(&invocation.payload, "path").unwrap_or("<unknown>");
            let content = required_str(&invocation.payload, "content").unwrap_or("");
            vec![trace_file_record(path, content, "ai", model_id)]
        }
        "file_read" => {
            let path = required_str(&invocation.payload, "path").unwrap_or("<unknown>");
            let content = capability_result_text(result);
            vec![trace_file_record(path, &content, "unknown", model_id)]
        }
        _ => Vec::new(),
    }
}

fn trace_file_record(path: &str, content: &str, contributor_type: &str, model_id: &str) -> Value {
    let line_count = content.lines().count().max(1);
    json!({
        "path": path,
        "conversations": [{
            "contributor": {
                "type": contributor_type,
                "model_id": model_id
            },
            "ranges": [{
                "start_line": 1,
                "end_line": line_count,
                "content_hash": hash_bytes(content.as_bytes())
            }]
        }]
    })
}

fn capability_result_text(result: &CapabilityResult) -> String {
    match &result.content {
        CapabilityResultBody::Text(text) => text.clone(),
        CapabilityResultBody::Blocks(blocks) => blocks
            .iter()
            .filter_map(|block| match block {
                CapabilityResultContent::Text { text } => Some(text.as_str()),
                _ => None,
            })
            .collect::<Vec<_>>()
            .join("\n"),
    }
}

fn runtime_i64(invocation: &Invocation, key: &str) -> Option<i64> {
    invocation
        .causal_context
        .runtime_metadata(key)
        .and_then(|value| value.parse::<i64>().ok())
}

fn model_provider(model_id: &str) -> String {
    model_id
        .split_once('/')
        .map(|(provider, _)| provider.to_owned())
        .unwrap_or_else(|| "unknown".to_owned())
}

fn git_vcs(working_directory: &Path) -> Option<Value> {
    let output = StdCommand::new("git")
        .args(["rev-parse", "HEAD"])
        .current_dir(working_directory)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let revision = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    if revision.is_empty() {
        return None;
    }
    Some(json!({
        "type": "git",
        "revision": revision
    }))
}

fn hash_json(value: impl serde::Serialize) -> String {
    let bytes = serde_json::to_vec(&value).unwrap_or_default();
    hash_bytes(&bytes)
}

fn hash_bytes(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    format!("sha256:{:x}", hasher.finalize())
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
