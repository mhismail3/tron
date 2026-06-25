//! Built-in procedural state resource definitions.
//!
//! The procedural record contract is intentionally inert: it stores
//! provenance/eval/status metadata for skills, rules, hooks, and procedures,
//! but does not define triggers, prompt injection, learned behavior, or any
//! activation path.

use serde_json::json;

use super::types::{
    EngineResourceVersioningMode, PROCEDURAL_RECORD_KIND, PROCEDURAL_RECORD_SCHEMA_ID,
    RegisterResourceType,
};
use crate::engine::kernel::ids::WorkerId;

pub(super) fn procedural_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![RegisterResourceType {
        kind: PROCEDURAL_RECORD_KIND.to_owned(),
        schema_id: PROCEDURAL_RECORD_SCHEMA_ID.to_owned(),
        schema: json!({
            "type": "object",
            "required": [
                "schemaVersion",
                "proceduralKind",
                "identity",
                "summary",
                "status",
                "provenance",
                "eval",
                "activation",
                "sourceRefs",
                "traceRefs",
                "replayRefs",
                "revision"
            ],
            "additionalProperties": true,
            "properties": {
                "schemaVersion": {"type": "string"},
                "proceduralKind": {"type": "string", "enum": ["skill", "rule", "hook", "procedure"]},
                "identity": {"type": "object"},
                "summary": {"type": "string"},
                "status": {"type": "string", "enum": ["draft", "candidate", "validated", "disabled", "stale", "archived"]},
                "provenance": {"type": "object"},
                "eval": {"type": "object"},
                "activation": {"type": "object"},
                "sourceRefs": {"type": "array"},
                "traceRefs": {"type": "array"},
                "replayRefs": {"type": "array"},
                "revision": {"type": "integer"}
            }
        }),
        lifecycle_states: vec![
            "draft".to_owned(),
            "candidate".to_owned(),
            "validated".to_owned(),
            "disabled".to_owned(),
            "stale".to_owned(),
            "archived".to_owned(),
        ],
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        allowed_link_relations: vec![
            "source_resource".to_owned(),
            "evaluated_by".to_owned(),
            "supersedes".to_owned(),
            "derived_from".to_owned(),
            "evidence_for".to_owned(),
        ],
        default_retention: json!({"class": "project"}),
        redaction_rules: json!({
            "projection": "metadata_only",
            "body": "not_provider_visible",
            "activation": "proof_only"
        }),
        materialization_rules: json!({"durableOutputsRequireResourceVersion": true}),
        required_capabilities: json!({
            "read": ["procedural.read", "resource.read"],
            "write": ["procedural.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("procedural").expect("valid static worker id"),
    }]
}
