//! Catalog primitive worker contracts.

use serde_json::{Value, json};

use super::{
    CATALOG_WORKER_ID, PrimitiveFunctionRegistration, host_dispatched_registration,
    primitive_function,
};
use crate::engine::{EffectClass, Result};

pub(crate) const LIST_FUNCTION: &str = "catalog::list";
pub(crate) const INSPECT_FUNCTION: &str = "catalog::inspect";
pub(crate) const WATCH_SNAPSHOT_FUNCTION: &str = "catalog::watch_snapshot";

pub(super) fn registrations() -> Result<Vec<PrimitiveFunctionRegistration>> {
    Ok(vec![
        host_dispatched_registration(
            primitive_function(
                LIST_FUNCTION,
                CATALOG_WORKER_ID,
                "list live catalog functions, workers, triggers, and trigger types",
                EffectClass::PureRead,
                "catalog.read",
            )
            .with_request_schema(list_schema())
            .with_response_schema(json!({
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
            })),
        ),
        host_dispatched_registration(
            primitive_function(
                INSPECT_FUNCTION,
                CATALOG_WORKER_ID,
                "inspect one live catalog item",
                EffectClass::PureRead,
                "catalog.read",
            )
            .with_request_schema(inspect_schema())
            .with_response_schema(json!({
                "type": "object",
                "required": ["catalogRevision", "kind", "definition"],
                "additionalProperties": false,
                "properties": {
                    "catalogRevision": {"type": "integer"},
                    "kind": {"type": "string"},
                    "definition": {}
                }
            })),
        ),
        host_dispatched_registration(
            primitive_function(
                WATCH_SNAPSHOT_FUNCTION,
                CATALOG_WORKER_ID,
                "return catalog changes and current catalog snapshot",
                EffectClass::PureRead,
                "catalog.read",
            )
            .with_request_schema(watch_snapshot_schema())
            .with_response_schema(json!({
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
            })),
        ),
    ])
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
