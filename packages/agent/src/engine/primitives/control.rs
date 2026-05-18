//! Control-plane primitive contracts.
//!
//! The control worker is a projection surface over existing substrate truth.
//! It owns no durable state and exposes no mutation multiplexer.

use serde_json::{Value, json};

use super::{
    CONTROL_WORKER_ID, PrimitiveFunctionRegistration, host_dispatched_registration,
    primitive_function,
};
use crate::engine::{EffectClass, Result, VisibilityScope};

pub(crate) const SNAPSHOT_FUNCTION: &str = "control::snapshot";
pub(crate) const INSPECT_FUNCTION: &str = "control::inspect";

pub(super) fn registrations() -> Result<Vec<PrimitiveFunctionRegistration>> {
    Ok(vec![
        control_read(
            SNAPSHOT_FUNCTION,
            "project the current worker/capability/resource/grant/invocation substrate",
            snapshot_schema(),
            json!({
                "type": "object",
                "required": ["catalogRevision", "workers", "capabilities", "resourceTypes", "activeGoals", "invocations", "grants", "queues", "leases", "approvals", "storage", "integrityWarnings", "availableActions", "uiSurfaceRefs"],
                "additionalProperties": false,
                "properties": {
                    "catalogRevision": {"type": "integer"},
                    "workers": {"type": "array"},
                    "capabilities": {"type": "array"},
                    "resourceTypes": {"type": "array"},
                    "activeGoals": {"type": "array"},
                    "invocations": {"type": "array"},
                    "grants": {"type": "array"},
                    "queues": {"type": "array"},
                    "leases": {"type": "array"},
                    "approvals": {"type": "array"},
                    "storage": {"type": ["object", "null"]},
                    "integrityWarnings": {"type": "array"},
                    "availableActions": {"type": "array"},
                    "uiSurfaceRefs": {"type": "array"}
                }
            }),
        ),
        control_read(
            INSPECT_FUNCTION,
            "inspect one substrate target graph",
            inspect_schema(),
            json!({
                "type": "object",
                "required": ["targetType", "targetId", "graph", "availableActions", "uiSurfaceRefs"],
                "additionalProperties": false,
                "properties": {
                    "targetType": {"type": "string"},
                    "targetId": {"type": "string"},
                    "graph": {"type": "object"},
                    "availableActions": {"type": "array"},
                    "uiSurfaceRefs": {"type": "array"}
                }
            }),
        ),
    ])
}

fn control_read(
    id: &str,
    description: &str,
    request_schema: Value,
    response_schema: Value,
) -> PrimitiveFunctionRegistration {
    let mut definition = primitive_function(
        id,
        CONTROL_WORKER_ID,
        description,
        EffectClass::PureRead,
        "control.read",
    )
    .with_request_schema(request_schema)
    .with_response_schema(response_schema);
    definition.visibility = VisibilityScope::System;
    host_dispatched_registration(definition)
}

fn snapshot_schema() -> Value {
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

fn inspect_schema() -> Value {
    json!({
        "type": "object",
        "required": ["targetType", "targetId"],
        "additionalProperties": false,
        "properties": {
            "targetType": {
                "type": "string",
                "enum": ["worker", "capability", "grant", "goal", "resource", "invocation", "trace"]
            },
            "targetId": {"type": "string"},
            "includeFullPayloads": {"type": "boolean"}
        }
    })
}
