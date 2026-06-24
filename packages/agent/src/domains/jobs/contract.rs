use serde_json::json;

use crate::domains::registration::catalog::{CapabilitySpec, TransportIdempotencyMode};
use crate::domains::registration::contract::CapabilityContract;
use crate::engine::{DurableOutputContract, EffectClass, IdempotencyContract, RiskLevel};

use super::{
    CANCEL_FUNCTION, CLEANUP_FUNCTION, JOB_PROCESS_KIND, JOBS_LIFECYCLE_TOPIC, LIST_FUNCTION,
    LOG_FUNCTION, READ_SCOPE, START_FUNCTION, STATUS_FUNCTION, WORKER, WRITE_SCOPE,
};

/// Canonical durable job capability contracts.
pub(crate) fn capabilities() -> crate::engine::Result<Vec<CapabilitySpec>> {
    Ok(vec![
        write_contract(
            START_FUNCTION,
            "Start a non-interactive local command as a durable job_process resource with bounded output and fail-closed network policy.",
        )
        .request_schema(start_schema())
        .response_schema(start_response_schema())
        .output_contract(DurableOutputContract::resource_backed([JOB_PROCESS_KIND]))
        .build()?,
        read_contract(
            STATUS_FUNCTION,
            "Inspect one durable job_process resource and its current lifecycle state.",
        )
        .request_schema(job_resource_schema())
        .response_schema(job_response_schema())
        .build()?,
        read_contract(
            LIST_FUNCTION,
            "List durable job_process resources in the current invocation scope.",
        )
        .request_schema(list_schema())
        .response_schema(list_response_schema())
        .build()?,
        read_contract(
            LOG_FUNCTION,
            "Read bounded stdout/stderr previews from one durable job_process resource.",
        )
        .request_schema(job_resource_schema())
        .response_schema(log_response_schema())
        .build()?,
        write_contract(
            CANCEL_FUNCTION,
            "Record terminal cancellation for a running durable job_process resource and request runtime process termination.",
        )
        .request_schema(cancel_schema())
        .response_schema(cancel_response_schema())
        .output_contract(DurableOutputContract::resource_backed([JOB_PROCESS_KIND]))
        .build()?,
        write_contract(
            CLEANUP_FUNCTION,
            "Archive terminal durable job_process resources that satisfy retention cleanup criteria.",
        )
        .request_schema(cleanup_schema())
        .response_schema(cleanup_response_schema())
        .output_contract(DurableOutputContract::resource_backed([JOB_PROCESS_KIND]))
        .build()?,
    ])
}

fn read_contract(function_id: &'static str, description: &'static str) -> CapabilityContract {
    CapabilityContract::new(
        function_id,
        WORKER,
        EffectClass::PureRead,
        RiskLevel::Low,
        Some(READ_SCOPE),
    )
    .description(description)
    .tags(vec!["jobs", "process", "resource", "replay"])
    .domain_module("jobs")
    .presentation_hints(json!({"systemImage": "terminal"}))
}

fn write_contract(function_id: &'static str, description: &'static str) -> CapabilityContract {
    CapabilityContract::new(
        function_id,
        WORKER,
        EffectClass::AppendOnlyEvent,
        RiskLevel::Medium,
        Some(WRITE_SCOPE),
    )
    .description(description)
    .tags(vec!["jobs", "process", "resource", "lifecycle"])
    .domain_module("jobs")
    .idempotency(IdempotencyContract::caller_session_engine_ledger())
    .idempotency_mode(TransportIdempotencyMode::ExplicitRequired)
    .stream_topics(vec![JOBS_LIFECYCLE_TOPIC])
    .presentation_hints(json!({"systemImage": "terminal"}))
}

fn start_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["command"],
        "additionalProperties": false,
        "properties": {
            "command": {"type": "string"},
            "timeoutMs": {"type": "integer", "minimum": 1},
            "maxOutputBytes": {"type": "integer", "minimum": 1},
            "cleanupAfterSeconds": {"type": "integer", "minimum": 0}
        }
    })
}

fn job_resource_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["jobResourceId"],
        "additionalProperties": false,
        "properties": {
            "jobResourceId": {"type": "string"}
        }
    })
}

fn list_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "state": {
                "type": "string",
                "enum": ["running", "completed", "failed", "timed_out", "cancelled", "archived"]
            },
            "limit": {"type": "integer", "minimum": 1}
        }
    })
}

fn cancel_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["jobResourceId"],
        "additionalProperties": false,
        "properties": {
            "jobResourceId": {"type": "string"},
            "reason": {"type": "string"}
        }
    })
}

fn cleanup_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "olderThanSeconds": {"type": "integer", "minimum": 0},
            "limit": {"type": "integer", "minimum": 1}
        }
    })
}

fn start_response_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["schemaVersion", "status", "jobResourceId", "jobVersionId", "streamCursor", "resourceRefs"],
        "additionalProperties": true,
        "properties": {
            "schemaVersion": {"type": "string"},
            "status": {"type": "string"},
            "jobResourceId": {"type": "string"},
            "jobVersionId": {"type": "string"},
            "streamCursor": {"type": "integer"},
            "processId": {"type": "integer"},
            "resourceRefs": {"type": "array"}
        }
    })
}

fn job_response_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["schemaVersion", "status", "job", "resourceRefs"],
        "additionalProperties": true,
        "properties": {
            "schemaVersion": {"type": "string"},
            "status": {"type": "string"},
            "job": {"type": "object"},
            "resourceRefs": {"type": "array"}
        }
    })
}

fn list_response_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["schemaVersion", "status", "jobs"],
        "additionalProperties": false,
        "properties": {
            "schemaVersion": {"type": "string"},
            "status": {"type": "string"},
            "jobs": {"type": "array"}
        }
    })
}

fn log_response_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["schemaVersion", "status", "jobResourceId", "jobVersionId", "stdoutPreview", "stderrPreview", "outputTruncated", "resourceRefs"],
        "additionalProperties": true,
        "properties": {
            "schemaVersion": {"type": "string"},
            "status": {"type": "string"},
            "jobResourceId": {"type": "string"},
            "jobVersionId": {"type": "string"},
            "stdoutPreview": {"type": "string"},
            "stderrPreview": {"type": "string"},
            "outputResourceId": {"type": "string"},
            "outputVersionId": {"type": "string"},
            "outputTruncated": {"type": "boolean"},
            "resourceRefs": {"type": "array"}
        }
    })
}

fn cancel_response_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["schemaVersion", "status", "jobResourceId", "jobVersionId", "idempotent", "resourceRefs"],
        "additionalProperties": true,
        "properties": {
            "schemaVersion": {"type": "string"},
            "status": {"type": "string"},
            "jobResourceId": {"type": "string"},
            "jobVersionId": {"type": "string"},
            "streamCursor": {"type": "integer"},
            "idempotent": {"type": "boolean"},
            "runtimeHadJob": {"type": "boolean"},
            "resourceRefs": {"type": "array"}
        }
    })
}

fn cleanup_response_schema() -> serde_json::Value {
    json!({
        "type": "object",
        "required": ["schemaVersion", "status", "archivedCount", "archived"],
        "additionalProperties": false,
        "properties": {
            "schemaVersion": {"type": "string"},
            "status": {"type": "string"},
            "archivedCount": {"type": "integer"},
            "archived": {"type": "array"}
        }
    })
}
