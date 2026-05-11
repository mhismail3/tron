//! Observability primitive contracts.
//!
//! The observability worker reads the engine ledger and primitive stores as
//! local truth. `observability::trace_get` correlates invocation, catalog,
//! stream, approval, resource lease, and compensation records for one trace.

use serde_json::{Value, json};

use super::{
    OBSERVABILITY_WORKER_ID, PrimitiveFunctionRegistration, host_dispatched_registration,
    primitive_function,
};
use crate::engine::{EffectClass, Result, VisibilityScope};

pub(crate) const TRACE_GET_FUNCTION: &str = "observability::trace_get";
pub(crate) const TRACE_LIST_FUNCTION: &str = "observability::trace_list";
pub(crate) const SPAN_LIST_FUNCTION: &str = "observability::span_list";
pub(crate) const LOG_QUERY_FUNCTION: &str = "observability::log_query";
pub(crate) const METRICS_SNAPSHOT_FUNCTION: &str = "observability::metrics_snapshot";

pub(super) fn registrations() -> Result<Vec<PrimitiveFunctionRegistration>> {
    Ok(vec![
        system_read(
            TRACE_GET_FUNCTION,
            "get one engine trace with correlated invocation and catalog records",
            trace_get_schema(),
            json!({
                "type": "object",
                "required": ["traceId", "summary", "invocations", "catalogChanges", "streams", "approvals", "leases", "compensation"],
                "additionalProperties": false,
                "properties": {
                    "traceId": {"type": "string"},
                    "summary": {"type": "object"},
                    "invocations": {"type": "array"},
                    "catalogChanges": {"type": "array"},
                    "streams": {"type": "array"},
                    "approvals": {"type": "array"},
                    "leases": {"type": "array"},
                    "compensation": {"type": "array"}
                }
            }),
        ),
        system_read(
            TRACE_LIST_FUNCTION,
            "list recent engine traces",
            trace_list_schema(),
            json!({
                "type": "object",
                "required": ["traces"],
                "additionalProperties": false,
                "properties": {"traces": {"type": "array"}}
            }),
        ),
        system_read(
            SPAN_LIST_FUNCTION,
            "list invocation spans for one trace",
            trace_get_schema(),
            json!({
                "type": "object",
                "required": ["traceId", "spans"],
                "additionalProperties": false,
                "properties": {
                    "traceId": {"type": "string"},
                    "spans": {"type": "array"}
                }
            }),
        ),
        system_read(
            LOG_QUERY_FUNCTION,
            "query engine-owned structured log projections",
            log_query_schema(),
            json!({
                "type": "object",
                "required": ["logs"],
                "additionalProperties": false,
                "properties": {"logs": {"type": "array"}}
            }),
        ),
        system_read(
            METRICS_SNAPSHOT_FUNCTION,
            "return a local metrics snapshot for engine primitives",
            metrics_schema(),
            json!({
                "type": "object",
                "required": ["metrics"],
                "additionalProperties": false,
                "properties": {"metrics": {"type": "object"}}
            }),
        ),
    ])
}

fn system_read(
    id: &str,
    description: &str,
    request_schema: Value,
    response_schema: Value,
) -> PrimitiveFunctionRegistration {
    let mut definition = primitive_function(
        id,
        OBSERVABILITY_WORKER_ID,
        description,
        EffectClass::PureRead,
        "observability.read",
    )
    .with_request_schema(request_schema)
    .with_response_schema(response_schema);
    definition.visibility = VisibilityScope::System;
    host_dispatched_registration(definition)
}

fn trace_get_schema() -> Value {
    json!({
        "type": "object",
        "required": ["traceId"],
        "additionalProperties": false,
        "properties": {
            "traceId": {"type": "string"},
            "includeFullPayloads": {"type": "boolean"}
        }
    })
}

fn trace_list_schema() -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "limit": {"type": "integer"},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"}
        }
    })
}

fn log_query_schema() -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "traceId": {"type": "string"},
            "sessionId": {"type": "string"},
            "workspaceId": {"type": "string"},
            "component": {"type": "string"},
            "origin": {"type": "string"},
            "minLevel": {"type": "string", "enum": ["trace", "debug", "info", "warn", "warning", "error", "fatal"]},
            "limit": {"type": "integer"},
            "text": {"type": "string"},
            "includeFullPayloads": {"type": "boolean"}
        }
    })
}

fn metrics_schema() -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {}
    })
}
