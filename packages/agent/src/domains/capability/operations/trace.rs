//! Agent trace primitive execute operations.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command as StdCommand;
use std::sync::LazyLock;
use std::time::Duration;

use chrono::Utc;
use regex::Regex;
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
const TRACE_PROJECTION_BOUNDARY_CONTENT: &str = "Provider-visible trace projection exposes safe engine trace/invocation refs only; it excludes raw provider invocation ids and other raw internals. Provider transcript tool-call ids may exist for protocol threading, but they are not trace projection providerInvocationId fields. Internal audit storage may retain raw fields for replay and policy, and engine-internal durability may create bookkeeping resources without being provider-visible mutating capability work.";
static TRACE_ABSOLUTE_PATHS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"(^|[\s"'(:=])(?:/Users|/var|/tmp|/private|/Volumes|/Applications)/[^\s"')]+"#)
        .expect("valid trace absolute path regex")
});
static TRACE_UNSAFE_RELATIVE_PATHS: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r#"(^|[\s"'(:=])(?:\.{1,2}/|~/?)[^\s"')]+"#)
        .expect("valid trace relative path regex")
});

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
        .map(|record| provider_safe_trace_record(&record.record_json))
        .collect::<Vec<_>>();
    let status_summary = trace_status_summary(&records);
    Ok(ok_result(
        trace_list_content(records.len(), &status_summary),
        json!({
            "primitiveOperation": "trace_list",
            "status": "ok",
            "projectionBoundary": trace_projection_boundary(),
            "statusSummary": status_summary,
            "records": records
        }),
    ))
}

fn trace_list_content(record_count: usize, status_summary: &Value) -> String {
    let in_progress = status_summary
        .get("inProgressCount")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let ok_count = status_summary
        .pointer("/completedStatusCounts/ok")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    let failed_count = status_summary
        .pointer("/completedStatusCounts/failed")
        .and_then(Value::as_u64)
        .unwrap_or(0);
    format!(
        "Trace records: {record_count}. Completed trace statuses: ok {ok_count}, failed {failed_count}. In-progress records: {in_progress}; the current trace_list call may appear as running until this call completes. {TRACE_PROJECTION_BOUNDARY_CONTENT}"
    )
}

fn trace_status_summary(records: &[Value]) -> Value {
    let mut completed_status_counts = BTreeMap::<String, u64>::new();
    let mut in_progress_count = 0_u64;
    for record in records {
        let status = record
            .get("status")
            .and_then(Value::as_str)
            .unwrap_or("unknown");
        let completed = record
            .get("completedAt")
            .is_some_and(|value| !value.is_null());
        if completed {
            *completed_status_counts
                .entry(status.to_owned())
                .or_insert(0) += 1;
        } else {
            in_progress_count += 1;
        }
    }
    let completed_status_values_only_ok_failed = completed_status_counts
        .keys()
        .all(|status| status == "ok" || status == "failed");
    json!({
        "totalRecords": records.len(),
        "completedStatusCounts": completed_status_counts,
        "completedStatusValuesOnlyOkFailed": completed_status_values_only_ok_failed,
        "inProgressCount": in_progress_count,
        "currentTraceListMayAppearRunning": true,
        "answerGuidance": "When asked whether trace status values are only ok/failed, answer about completed trace records separately from in-progress records. The current trace_list invocation can appear running until this call is complete."
    })
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
        format!("Trace record: {id}. {TRACE_PROJECTION_BOUNDARY_CONTENT}"),
        json!({
            "primitiveOperation": "trace_get",
            "status": "ok",
            "projectionBoundary": trace_projection_boundary(),
            "record": provider_safe_trace_record(&record.record_json)
        }),
    ))
}

fn trace_projection_boundary() -> Value {
    json!({
        "providerVisibleProjection": "provider_safe_trace_projection",
        "providerVisibleMeaning": "Fields in this result are safe bounded projections for the model. Visible traceId/invocationId fields are engine refs, not raw provider invocation ids.",
        "internalAuditStorage": "Engine trace storage may retain raw audit fields for replay, policy, and debugging.",
        "safeRefSemantics": "traceId, invocationId, parentInvocationId, runId, sessionRef, and workspaceRef are provider-safe engine refs, not raw provider invocation ids.",
        "transcriptToolCallBoundary": "Provider transcript tool-call ids may exist in model/provider message history for protocol threading. Trace projection safety claims are about trace_list/trace_get projection fields, where providerInvocationId is not exposed.",
        "operationBoundary": "Safety claims are about provider-visible capability operations and provider-visible projections. Internal engine durability may record prompt traces, resources, and audit bookkeeping for replay/policy without counting as a provider-visible mutating capability operation.",
        "rawCommandEvidenceGuidance": "Trace projection proves raw requests/results and local material are excluded. Operation-specific schemas or results may provide additional no-raw-command proof.",
        "answerGuidance": "When reporting safety, say provider-visible trace projections expose safe engine trace/invocation refs only, exclude raw provider invocation ids and raw internals, and do not claim internal audit storage lacks those fields. Say no provider-visible mutating capability operation was used instead of saying no mutation occurred at all.",
        "traceGetUse": "Use trace_list for normal current-session proof. Call trace_get only when a specific trace record needs focused inspection."
    })
}

fn provider_safe_trace_record(record: &Value) -> Value {
    let metadata = record
        .get("metadata")
        .and_then(|metadata| metadata.get(TRON_TRACE_METADATA_KEY))
        .unwrap_or(&Value::Null);
    let authority = metadata.get("authority").unwrap_or(&Value::Null);
    json!({
        "schemaVersion": "tron.trace.provider_safe.v1",
        "id": record.get("id").cloned().unwrap_or(Value::Null),
        "version": record.get("version").cloned().unwrap_or(Value::Null),
        "timestamp": record.get("timestamp").cloned().unwrap_or(Value::Null),
        "traceId": metadata.get("traceId").cloned().unwrap_or(Value::Null),
        "invocationId": metadata.get("invocationId").cloned().unwrap_or(Value::Null),
        "parentInvocationId": metadata.get("parentInvocationId").cloned().unwrap_or(Value::Null),
        "runId": metadata.get("runId").cloned().unwrap_or(Value::Null),
        "sessionRef": metadata.get("sessionId").cloned().unwrap_or(Value::Null),
        "workspaceRef": metadata.get("workspaceId").cloned().unwrap_or(Value::Null),
        "turn": metadata.get("turn").cloned().unwrap_or(Value::Null),
        "modelPrimitiveName": metadata.get("modelPrimitiveName").cloned().unwrap_or(Value::Null),
        "operation": metadata.get("operation").cloned().unwrap_or(Value::Null),
        "status": metadata.get("status").cloned().unwrap_or(Value::Null),
        "startedAt": metadata.get("startedAt").cloned().unwrap_or(Value::Null),
        "completedAt": metadata.get("completedAt").cloned().unwrap_or(Value::Null),
        "durationMs": metadata.get("durationMs").cloned().unwrap_or(Value::Null),
        "request": {
            "hash": metadata.get("requestHash").cloned().unwrap_or(Value::Null),
            "rawStoredInProjection": false
        },
        "result": {
            "hash": metadata.get("resultHash").cloned().unwrap_or(Value::Null),
            "rawStoredInProjection": false
        },
        "projectionBoundary": {
            "providerVisibleProjection": true,
            "safeEngineRefsOnly": true,
            "rawAuditFieldsProjected": false,
            "internalAuditStorageMayRetainRawAuditFields": true
        },
        "authority": {
            "actorKind": authority.get("actorKind").cloned().unwrap_or(Value::Null),
            "scopeCount": authority
                .get("scopes")
                .and_then(Value::as_array)
                .map(|scopes| scopes.len())
                .unwrap_or(0),
            "rawActorIdStored": false,
            "rawAuthorityGrantIdStored": false,
            "rawIdempotencyKeyStored": false
        },
        "error": trace_safe_error(metadata.get("error")),
        "redaction": {
            "rawAuthorityIdsExcluded": true,
            "rawGrantIdsExcluded": true,
            "rawIdempotencyKeysExcluded": true,
            "rawProviderInvocationIdsExcluded": true,
            "rawWorkingDirectoryExcluded": true,
            "rawRequestExcluded": true,
            "rawResultExcluded": true,
            "rawFilesExcluded": true,
            "rawVcsExcluded": true
        }
    })
}

fn trace_safe_error(error: Option<&Value>) -> Value {
    let Some(error) = error else {
        return Value::Null;
    };
    let message = error
        .get("message")
        .and_then(Value::as_str)
        .map(redact_trace_text);
    json!({
        "code": error.get("code").cloned().unwrap_or(Value::Null),
        "category": error.get("category").cloned().unwrap_or(Value::Null),
        "recoverable": error.get("recoverable").cloned().unwrap_or(Value::Null),
        "message": message,
        "detailsStoredInProjection": false
    })
}

fn redact_trace_text(message: &str) -> String {
    let redacted = crate::shared::foundation::redaction::redact_sensitive_content(message);
    let redacted = TRACE_ABSOLUTE_PATHS
        .replace_all(&redacted, "${1}[redacted-path]")
        .to_string();
    TRACE_UNSAFE_RELATIVE_PATHS
        .replace_all(&redacted, "${1}[redacted-path]")
        .to_string()
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
    let status = if result.is_error == Some(true) || error.is_some() {
        "failed"
    } else {
        "ok"
    }
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
            | "context_survivor_record"
            | "context_survivor_list"
            | "context_survivor_disable"
            | "context_exclusion_record"
            | "context_exclusion_list"
            | "context_exclusion_disable"
            | "context_policy_snapshot"
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trace_completion_status_ignores_resource_lifecycle_status_details() {
        use crate::engine::{
            ActorId, ActorKind, AuthorityGrantId, CausalContext, DeliveryMode, FunctionId,
            InvocationId, TraceId,
        };

        let grant_id = AuthorityGrantId::new("grant-trace-status-test").expect("grant id");
        let context = CausalContext::new(
            ActorId::new("agent:trace-status-test").expect("actor id"),
            ActorKind::Agent,
            grant_id,
            TraceId::new("trace-status-test").expect("trace id"),
        )
        .with_session_id("sess-trace-status-test");
        let invocation = Invocation {
            id: InvocationId::new("invocation-trace-status-test").expect("invocation id"),
            function_id: FunctionId::new("capability::execute").expect("function id"),
            delivery_mode: DeliveryMode::Sync,
            payload: json!({"operation": "repository_tree_snapshot"}),
            causal_context: context,
        };
        let mut record = AgentTraceRecord {
            id: "trace-record-status-test".to_owned(),
            trace_id: "trace-status-test".to_owned(),
            invocation_id: "invocation-trace-status-test".to_owned(),
            parent_invocation_id: None,
            provider_invocation_id: None,
            session_id: Some("sess-trace-status-test".to_owned()),
            workspace_id: None,
            turn: None,
            model_primitive_name: "execute".to_owned(),
            operation: "repository_tree_snapshot".to_owned(),
            status: "running".to_owned(),
            timestamp: "2026-07-08T00:00:00Z".to_owned(),
            completed_at: None,
            duration_ms: None,
            record_json: json!({
                "metadata": {
                    TRON_TRACE_METADATA_KEY: {
                        "operation": "repository_tree_snapshot",
                        "status": "running",
                        "modelId": "gpt-test"
                    }
                },
                "files": []
            }),
        };
        let result = ok_result(
            "Repository tree snapshot recorded.".to_owned(),
            json!({
                "primitiveOperation": "repository_tree_snapshot",
                "status": "active"
            }),
        );

        complete_trace_record(
            &mut record,
            &invocation,
            &result,
            None,
            Duration::from_millis(12),
        );

        assert_eq!(record.status, "ok");
        assert_eq!(
            record.record_json["metadata"][TRON_TRACE_METADATA_KEY]["status"],
            "ok"
        );
    }

    #[test]
    fn provider_safe_trace_record_excludes_internal_authority_and_raw_payloads() {
        let record = json!({
            "id": "trace_record_1",
            "version": "0.1",
            "timestamp": "2026-07-08T03:27:04Z",
            "files": [{"path": "secret.txt"}],
            "vcs": {"revision": "abc123"},
            "metadata": {
                TRON_TRACE_METADATA_KEY: {
                    "traceId": "trace_1",
                    "invocationId": "inv_1",
                    "parentInvocationId": "root_1",
                    "providerInvocationId": "call_1",
                    "runId": "run_1",
                    "sessionId": "sess_1",
                    "workspaceId": "ws_1",
                    "turn": 3,
                    "modelPrimitiveName": "execute",
                    "operation": "git_status",
                    "status": "ok",
                    "startedAt": "2026-07-08T03:27:04Z",
                    "completedAt": "2026-07-08T03:27:05Z",
                    "durationMs": 91,
                    "workingDirectory": "/Users/example/private/repo",
                    "request": {
                        "operation": "process_run",
                        "command": "cat /Users/example/.secret"
                    },
                    "requestHash": "sha256:request",
                    "result": {
                        "content": [{"type": "text", "text": "raw command output"}]
                    },
                    "resultHash": "sha256:result",
                    "authority": {
                        "actorId": "agent:sess_1",
                        "actorKind": "Agent",
                        "authorityGrantId": "grant_must_not_project",
                        "idempotencyKey": "idempotency_must_not_project",
                        "scopes": ["capability.execute", "git.read"]
                    }
                }
            }
        });

        let safe = provider_safe_trace_record(&record);
        let rendered = serde_json::to_string_pretty(&safe).expect("render safe trace record");

        assert_eq!(safe["schemaVersion"], "tron.trace.provider_safe.v1");
        assert_eq!(safe["id"], "trace_record_1");
        assert_eq!(safe["traceId"], "trace_1");
        assert_eq!(safe["invocationId"], "inv_1");
        assert!(safe.get("providerInvocationId").is_none());
        assert_eq!(safe["operation"], "git_status");
        assert_eq!(safe["request"]["hash"], "sha256:request");
        assert_eq!(safe["result"]["hash"], "sha256:result");
        assert_eq!(
            safe["projectionBoundary"]["providerVisibleProjection"],
            true
        );
        assert_eq!(safe["projectionBoundary"]["safeEngineRefsOnly"], true);
        assert_eq!(safe["projectionBoundary"]["rawAuditFieldsProjected"], false);
        assert_eq!(
            safe["projectionBoundary"]["internalAuditStorageMayRetainRawAuditFields"],
            true
        );
        assert_eq!(safe["authority"]["scopeCount"], 2);
        assert_eq!(safe["redaction"]["rawAuthorityIdsExcluded"], true);
        assert_eq!(safe["redaction"]["rawProviderInvocationIdsExcluded"], true);
        assert!(!rendered.contains("providerInvocationId"), "{rendered}");
        assert!(!rendered.contains("call_1"), "{rendered}");
        assert!(!rendered.contains("authorityGrantId"), "{rendered}");
        assert!(!rendered.contains("grant_must_not_project"), "{rendered}");
        assert!(
            !rendered.contains("idempotency_must_not_project"),
            "{rendered}"
        );
        assert!(!rendered.contains("agent:sess_1"), "{rendered}");
        assert!(!rendered.contains("/Users/example"), "{rendered}");
        assert!(
            !rendered.contains("cat /Users/example/.secret"),
            "{rendered}"
        );
        assert!(!rendered.contains("raw command output"), "{rendered}");
        assert!(!rendered.contains("secret.txt"), "{rendered}");
        assert!(!rendered.contains("abc123"), "{rendered}");
    }

    #[test]
    fn trace_projection_boundary_instructs_provider_safe_answering() {
        let boundary = trace_projection_boundary();

        assert_eq!(
            boundary["providerVisibleProjection"],
            "provider_safe_trace_projection"
        );
        assert!(
            boundary["answerGuidance"]
                .as_str()
                .expect("answer guidance")
                .contains("exclude raw provider invocation ids")
        );
        assert!(
            boundary["safeRefSemantics"]
                .as_str()
                .expect("safe ref semantics")
                .contains("not raw provider invocation ids")
        );
        assert!(
            boundary["transcriptToolCallBoundary"]
                .as_str()
                .expect("transcript tool call boundary")
                .contains("protocol threading")
        );
        assert!(
            boundary["operationBoundary"]
                .as_str()
                .expect("operation boundary")
                .contains("provider-visible mutating capability operation")
        );
        assert!(
            boundary["rawCommandEvidenceGuidance"]
                .as_str()
                .expect("raw command evidence guidance")
                .contains("Operation-specific schemas")
        );
        assert!(
            boundary["internalAuditStorage"]
                .as_str()
                .expect("internal audit storage")
                .contains("may retain raw audit fields")
        );
        assert!(
            boundary["traceGetUse"]
                .as_str()
                .expect("trace get use")
                .contains("trace_list")
        );
    }

    #[test]
    fn trace_status_summary_separates_completed_from_current_running_trace() {
        let records = vec![
            json!({
                "status": "ok",
                "completedAt": "2026-07-08T03:27:05Z"
            }),
            json!({
                "status": "failed",
                "completedAt": "2026-07-08T03:27:06Z"
            }),
            json!({
                "status": "running",
                "completedAt": null
            }),
        ];

        let summary = trace_status_summary(&records);
        let content = trace_list_content(records.len(), &summary);

        assert_eq!(summary["completedStatusCounts"]["ok"], 1);
        assert_eq!(summary["completedStatusCounts"]["failed"], 1);
        assert_eq!(summary["completedStatusValuesOnlyOkFailed"], true);
        assert_eq!(summary["inProgressCount"], 1);
        assert!(
            summary["answerGuidance"]
                .as_str()
                .expect("answer guidance")
                .contains("completed trace records separately")
        );
        assert!(content.contains("Completed trace statuses: ok 1, failed 1"));
        assert!(content.contains("current trace_list call may appear as running"));
    }

    #[test]
    fn trace_projection_boundary_content_is_model_facing() {
        assert!(TRACE_PROJECTION_BOUNDARY_CONTENT.contains("Provider-visible"));
        assert!(TRACE_PROJECTION_BOUNDARY_CONTENT.contains("safe engine trace/invocation refs"));
        assert!(TRACE_PROJECTION_BOUNDARY_CONTENT.contains("excludes raw provider invocation ids"));
        assert!(TRACE_PROJECTION_BOUNDARY_CONTENT.contains("protocol threading"));
        assert!(
            TRACE_PROJECTION_BOUNDARY_CONTENT
                .contains("Internal audit storage may retain raw fields")
        );
        assert!(
            TRACE_PROJECTION_BOUNDARY_CONTENT
                .contains("engine-internal durability may create bookkeeping resources")
        );
    }

    #[test]
    fn provider_safe_trace_record_redacts_error_message_paths() {
        let record = json!({
            "id": "trace_record_2",
            "metadata": {
                TRON_TRACE_METADATA_KEY: {
                    "operation": "filesystem_read",
                    "status": "error",
                    "error": {
                        "code": "ENGINE_POLICY_VIOLATION",
                        "category": "invalid_request",
                        "recoverable": true,
                        "message": "failed to read /Users/example/private.txt",
                        "details": {
                            "rawCommand": "cat /Users/example/private.txt"
                        }
                    }
                }
            }
        });

        let safe = provider_safe_trace_record(&record);
        let rendered = serde_json::to_string_pretty(&safe).expect("render safe trace record");

        assert_eq!(safe["error"]["code"], "ENGINE_POLICY_VIOLATION");
        assert_eq!(safe["error"]["category"], "invalid_request");
        assert_eq!(safe["error"]["recoverable"], true);
        assert_eq!(safe["error"]["detailsStoredInProjection"], false);
        assert!(rendered.contains("[redacted-path]"), "{rendered}");
        assert!(!rendered.contains("/Users/example"), "{rendered}");
        assert!(!rendered.contains("rawCommand"), "{rendered}");
    }
}
