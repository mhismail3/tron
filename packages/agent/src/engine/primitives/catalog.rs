//! Catalog primitive worker contracts.
//!
//! Read-only catalog surfaces are system-visible and gated by `catalog.read`
//! so operator clients can project live worker/function/trigger state without
//! owning catalog mutations.

use serde_json::{Value, json};

use super::{
    CATALOG_WORKER_ID, PrimitiveFunctionRegistration, host_dispatched_registration,
    primitive_function,
};
use crate::engine::{EffectClass, Result, VisibilityScope};

pub(crate) const LIST_FUNCTION: &str = "catalog::list";
pub(crate) const INSPECT_FUNCTION: &str = "catalog::inspect";
pub(crate) const WATCH_SNAPSHOT_FUNCTION: &str = "catalog::watch_snapshot";

pub(super) fn registrations() -> Result<Vec<PrimitiveFunctionRegistration>> {
    Ok(vec![
        catalog_read(
            LIST_FUNCTION,
            "list live catalog functions, workers, triggers, and trigger types",
            list_schema(),
            json!({
                "type": "object",
                "required": ["catalogRevision", "functions", "workers", "triggers", "triggerTypes"],
                "additionalProperties": false,
                "properties": {
                    "catalogRevision": {"type": "integer"},
                    "functions": {"type": "array"},
                    "workers": {"type": "array"},
                    "triggers": {"type": "array"},
                    "triggerTypes": {"type": "array"}
                }
            }),
        ),
        catalog_read(
            INSPECT_FUNCTION,
            "inspect one live catalog item",
            inspect_schema(),
            json!({
                "type": "object",
                "required": ["catalogRevision", "kind", "definition"],
                "additionalProperties": false,
                "properties": {
                    "catalogRevision": {"type": "integer"},
                    "kind": {"type": "string"},
                    "definition": {}
                }
            }),
        ),
        catalog_read(
            WATCH_SNAPSHOT_FUNCTION,
            "return catalog changes and current catalog snapshot",
            watch_snapshot_schema(),
            json!({
                "type": "object",
                "required": ["changes", "snapshot", "currentRevision", "nextRevision", "hasMore"],
                "additionalProperties": false,
                "properties": {
                    "changes": {"type": "array"},
                    "snapshot": {"type": "object"},
                    "currentRevision": {"type": "integer"},
                    "nextRevision": {"type": "integer"},
                    "hasMore": {"type": "boolean"}
                }
            }),
        ),
    ])
}

fn catalog_read(
    id: &str,
    description: &str,
    request_schema: Value,
    response_schema: Value,
) -> PrimitiveFunctionRegistration {
    let mut definition = primitive_function(
        id,
        CATALOG_WORKER_ID,
        description,
        EffectClass::PureRead,
        "catalog.read",
    )
    .with_request_schema(request_schema)
    .with_response_schema(response_schema);
    definition.visibility = VisibilityScope::System;
    host_dispatched_registration(definition)
}

fn list_schema() -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "includeInternal": {"type": "boolean"},
            "namespacePrefix": {"type": "string"},
            "visibility": {"type": "string"}
        }
    })
}

fn inspect_schema() -> Value {
    json!({
        "type": "object",
        "required": ["kind", "id"],
        "additionalProperties": false,
        "properties": {
            "kind": {"type": "string", "enum": ["function", "worker", "trigger_type", "trigger"]},
            "id": {"type": "string"}
        }
    })
}

fn watch_snapshot_schema() -> Value {
    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": {
            "afterRevision": {"type": "integer"},
            "limit": {"type": "integer"},
            "classes": {"type": "array", "items": {"type": "string"}},
            "kinds": {"type": "array", "items": {"type": "string"}},
            "subjectPrefix": {"type": "string"},
            "ownerWorker": {"type": "string"}
        }
    })
}
