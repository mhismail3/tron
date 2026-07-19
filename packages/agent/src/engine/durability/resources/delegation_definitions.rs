//! Real child-agent delegation resource definition.

use serde_json::json;

use super::types::{
    DELEGATION_KIND, DELEGATION_SCHEMA_ID, EngineResourceVersioningMode, RegisterResourceType,
};
use crate::engine::kernel::ids::WorkerId;

pub(super) fn delegation_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![RegisterResourceType {
        kind: DELEGATION_KIND.to_owned(),
        schema_id: DELEGATION_SCHEMA_ID.to_owned(),
        schema: json!({
            "type": "object",
            "required": ["schemaVersion", "state", "parentSessionId", "objectiveSummary", "createdAt", "updatedAt", "revision"],
            "additionalProperties": false,
            "properties": {
                "schemaVersion": {"const": "tron.delegation.v1"},
                "state": {"enum": ["preparing", "running", "result_ready", "accepted", "failed", "cancelled"]},
                "parentSessionId": {"type": "string"},
                "childSessionId": {"type": ["string", "null"]},
                "childRunId": {"type": ["string", "null"]},
                "objectiveSummary": {"type": "string"},
                "successCriteria": {"type": "array", "items": {"type": "string"}},
                "handoffRefs": {"type": "array", "maxItems": 32, "items": {"type": "object", "additionalProperties": false, "required": ["kind", "id"], "properties": {
                    "kind": {"type": "string", "minLength": 1, "maxLength": 256, "pattern": "^[^*]+$"},
                    "id": {"type": "string", "minLength": 1, "maxLength": 256, "pattern": "^[^*]+$"},
                    "versionId": {"type": "string", "minLength": 1, "maxLength": 256, "pattern": "^[^*]+$"}
                }}},
                "resultSummary": {"type": ["string", "null"]},
                "resultRefs": {"type": "array", "items": {"type": "object"}},
                "failure": {"type": ["object", "null"]},
                "authority": {"type": "object"},
                "limits": {"type": "object"},
                "idempotencyKey": {"type": "string"},
                "cancelIdempotencyKey": {"type": ["string", "null"]},
                "acceptIdempotencyKey": {"type": ["string", "null"]},
                "createdAt": {"type": "string"},
                "updatedAt": {"type": "string"},
                "revision": {"type": "integer", "minimum": 1}
            }
        }),
        lifecycle_states: [
            "preparing",
            "running",
            "result_ready",
            "accepted",
            "failed",
            "cancelled",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect(),
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        allowed_link_relations: [
            "parent_session",
            "child_session",
            "produced",
            "derived_from",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect(),
        default_retention: json!({"class": "delegation_lifecycle"}),
        redaction_rules: json!({"preview": "summary_only", "rawPrompt": "not_persisted"}),
        materialization_rules: json!({"resultAcceptanceRequired": true}),
        required_capabilities: json!({
            "read": ["delegation.read", "resource.read"],
            "write": ["delegation.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("delegation").expect("valid static worker id"),
    }]
}
