//! Agent trace primitive execute operations.

use std::path::{Path, PathBuf};
use std::process::Command as StdCommand;
use std::time::Duration;

use chrono::Utc;
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use uuid::Uuid;

use super::filesystem::working_directory;
use super::{Deps, internal, invalid, ok_result, optional_str, optional_u64, required_str};
use crate::domains::session::event_store::trace::TRON_TRACE_METADATA_KEY;
use crate::domains::session::event_store::{
    AGENT_TRACE_VERSION, AgentTraceListOptions, AgentTraceRecord,
};
use crate::engine::{
    Invocation, RUNTIME_METADATA_MODEL_PRIMITIVE_NAME, RUNTIME_METADATA_PROVIDER_INVOCATION_ID,
    RUNTIME_METADATA_PROVIDER_TYPE, RUNTIME_METADATA_RUN_ID, RUNTIME_METADATA_TURN,
    RUNTIME_METADATA_WORKING_DIRECTORY,
};
use crate::shared::protocol::model_capabilities::CapabilityResult;
use crate::shared::server::errors::CapabilityError;

const TRACE_REDACTION_FINGERPRINT_ALGORITHM: &str = "sha256:tron.trace.redacted.v1";
const AUTHORITY_GRANT_FINGERPRINT_DOMAIN: &[u8] = b"tron.trace.authority_grant_id.v1\0";
const IDEMPOTENCY_KEY_FINGERPRINT_DOMAIN: &[u8] = b"tron.trace.idempotency_key.v1\0";

pub(super) fn trace_list(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let limit = optional_u64(&invocation.payload, "limit")?
        .unwrap_or(50)
        .clamp(1, 500) as i64;
    let trace_id = optional_str(&invocation.payload, "traceId")?;
    let session_id = invocation
        .causal_context
        .session_id
        .as_deref()
        .ok_or_else(|| invalid("trace_list requires trusted current session context"))?;
    let records = deps
        .event_store
        .list_trace_records(&AgentTraceListOptions {
            session_id: Some(session_id),
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

pub(super) fn trace_get(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<CapabilityResult, CapabilityError> {
    let id = required_str(&invocation.payload, "traceRecordId")?;
    let session_id = invocation
        .causal_context
        .session_id
        .as_deref()
        .ok_or_else(|| invalid("trace_get requires trusted current session context"))?;
    let Some(record) = deps
        .event_store
        .get_trace_record(id)
        .map_err(|error| internal(format!("get trace record: {error}")))?
    else {
        return Err(CapabilityError::InvalidParams {
            message: format!("trace record not found: {id}"),
        });
    };
    if record.session_id.as_deref() != Some(session_id) {
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

pub(super) fn started_trace_record(
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
    let provider = invocation
        .causal_context
        .runtime_metadata(RUNTIME_METADATA_PROVIDER_TYPE);
    let module_safe_trace = is_module_safe_operation(operation);
    let (working_directory, working_directory_metadata) = if module_safe_trace {
        module_proposal_working_directory_metadata()
    } else {
        trace_working_directory_metadata(invocation)
    };
    let vcs = working_directory.as_ref().and_then(|path| git_vcs(path));
    let mut trace_metadata = if module_safe_trace {
        let request = module_safe_trace_request(operation);
        json!({
            "request": request.clone(),
            "requestHash": hash_json(&request),
            "rawRequestStored": false,
            "modelId": model_id,
            "provider": provider,
        })
    } else {
        json!({
            "request": invocation.payload,
            "requestHash": hash_json(&invocation.payload),
            "modelId": model_id,
            "provider": provider,
        })
    };
    merge_json_object(&mut trace_metadata, working_directory_metadata);
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
        trace_metadata,
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

fn trace_working_directory_metadata(invocation: &Invocation) -> (Option<PathBuf>, Value) {
    match working_directory(invocation) {
        Ok(path) => {
            let metadata = json!({
                "workingDirectory": path.display().to_string()
            });
            (Some(path), metadata)
        }
        Err(error) => {
            let mut metadata = json!({
                "workingDirectory": Value::Null,
                "workingDirectoryError": error.to_string()
            });
            if let (Some(object), Some(raw)) = (
                metadata.as_object_mut(),
                invocation
                    .causal_context
                    .runtime_metadata(RUNTIME_METADATA_WORKING_DIRECTORY),
            ) {
                object.insert("workingDirectoryRaw".to_owned(), json!(raw));
            }
            (None, metadata)
        }
    }
}

fn module_proposal_working_directory_metadata() -> (Option<PathBuf>, Value) {
    (
        None,
        json!({
            "workingDirectory": Value::Null,
            "workingDirectoryRedacted": true,
            "workingDirectoryRawStored": false
        }),
    )
}

fn module_safe_trace_request(operation: &str) -> Value {
    json!({
        "operation": operation,
        "projection": "module_trace_safe_request.v1",
        "rawPayloadStored": false,
        "metadataOnly": true
    })
}

pub(super) fn complete_trace_record(
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
    let authority = trace_authority_metadata(invocation, operation);
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
        "authority": authority
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

fn trace_authority_metadata(invocation: &Invocation, operation: &str) -> Value {
    if is_module_safe_operation(operation) {
        return json!({
            "actorId": invocation.causal_context.actor_id.as_str(),
            "actorKind": format!("{:?}", invocation.causal_context.actor_kind),
            "authorityGrantId": redacted_trace_scalar(
                AUTHORITY_GRANT_FINGERPRINT_DOMAIN,
                invocation.causal_context.authority_grant_id.as_str(),
            ),
            "scopes": invocation.causal_context.authority_scopes,
            "idempotencyKey": invocation
                .causal_context
                .idempotency_key
                .as_deref()
                .map(|key| redacted_trace_scalar(IDEMPOTENCY_KEY_FINGERPRINT_DOMAIN, key))
        });
    }

    json!({
        "actorId": invocation.causal_context.actor_id.as_str(),
        "actorKind": format!("{:?}", invocation.causal_context.actor_kind),
        "authorityGrantId": invocation.causal_context.authority_grant_id.as_str(),
        "scopes": invocation.causal_context.authority_scopes,
        "idempotencyKey": invocation.causal_context.idempotency_key
    })
}

fn redacted_trace_scalar(domain: &[u8], value: &str) -> Value {
    json!({
        "redacted": true,
        "rawStored": false,
        "fingerprintAlgorithm": TRACE_REDACTION_FINGERPRINT_ALGORITHM,
        "fingerprint": hash_bytes_with_domain(domain, value.as_bytes())
    })
}

fn is_module_proposal_operation(operation: &str) -> bool {
    matches!(
        operation,
        "module_proposal_record" | "module_proposal_list" | "module_proposal_inspect"
    )
}

fn is_module_runtime_operation(operation: &str) -> bool {
    matches!(
        operation,
        "module_runtime_request"
            | "module_runtime_list"
            | "module_runtime_inspect"
            | "module_runtime_cancel"
    )
}

fn is_context_control_operation(operation: &str) -> bool {
    matches!(
        operation,
        "context_control_snapshot"
            | "context_control_compact"
            | "context_control_clear"
            | "context_control_action_list"
            | "context_control_action_inspect"
    )
}

fn is_module_program_execution_operation(operation: &str) -> bool {
    matches!(
        operation,
        "module_program_execution_start"
            | "module_program_execution_status"
            | "module_program_execution_cancel"
            | "module_program_execution_cleanup"
    )
}

fn is_module_safe_operation(operation: &str) -> bool {
    is_module_proposal_operation(operation)
        || is_module_runtime_operation(operation)
        || is_context_control_operation(operation)
        || is_module_program_execution_operation(operation)
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
        "filesystem_write" | "filesystem_edit" | "filesystem_apply_patch" => {
            trace_files_for_filesystem_result(result, model_id)
        }
        _ => Vec::new(),
    }
}

fn trace_files_for_filesystem_result(result: &CapabilityResult, model_id: &str) -> Vec<Value> {
    let Some(details) = result.details.as_ref() else {
        return Vec::new();
    };
    let filesystem = &details["filesystem"];
    if filesystem["status"] != "committed" {
        return Vec::new();
    }
    let Some(path) = filesystem
        .pointer("/path/relativePath")
        .and_then(Value::as_str)
    else {
        return Vec::new();
    };
    let Some(hash) = filesystem
        .pointer("/materialized/contentHash")
        .or_else(|| filesystem.pointer("/after/contentHash"))
        .and_then(Value::as_str)
    else {
        return Vec::new();
    };
    vec![trace_file_hash_record(path, hash, model_id)]
}

fn trace_file_hash_record(path: &str, content_hash: &str, model_id: &str) -> Value {
    json!({
        "path": path,
        "conversations": [{
            "contributor": {
                "type": "ai",
                "model_id": model_id
            },
            "ranges": [{
                "start_line": 1,
                "end_line": 1,
                "content_hash": format!("sha256:{content_hash}")
            }]
        }]
    })
}

fn runtime_i64(invocation: &Invocation, key: &str) -> Option<i64> {
    invocation
        .causal_context
        .runtime_metadata(key)
        .and_then(|value| value.parse::<i64>().ok())
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

fn hash_bytes_with_domain(domain: &[u8], bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(domain);
    hasher.update(bytes);
    format!("sha256:{:x}", hasher.finalize())
}
