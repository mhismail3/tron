//! Built-in memory resource type definitions.
//!
//! These schemas define the engine-owned memory contract surface: engine
//! identity, policy, records, prompt traces, eval runs, and migration
//! envelopes. They do not define a retrieval/indexing algorithm.

use serde_json::{Value, json};

use super::types::{
    EngineResourceVersioningMode, MEMORY_ENGINE_KIND, MEMORY_ENGINE_SCHEMA_ID,
    MEMORY_EVAL_RUN_KIND, MEMORY_EVAL_RUN_SCHEMA_ID, MEMORY_MIGRATION_ENVELOPE_KIND,
    MEMORY_MIGRATION_ENVELOPE_SCHEMA_ID, MEMORY_POLICY_KIND, MEMORY_POLICY_SCHEMA_ID,
    MEMORY_PROMPT_TRACE_KIND, MEMORY_PROMPT_TRACE_SCHEMA_ID, MEMORY_RECORD_KIND,
    MEMORY_RECORD_SCHEMA_ID, RegisterResourceType,
};
use crate::engine::kernel::ids::WorkerId;

pub(super) fn memory_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![
        memory_builtin_type(
            MEMORY_ENGINE_KIND,
            MEMORY_ENGINE_SCHEMA_ID,
            json!({
                "type": "object",
                "required": [
                    "schemaVersion",
                    "engineId",
                    "label",
                    "version",
                    "packageProvenance",
                    "supportedModes",
                    "supportedStores",
                    "privacyFeatures",
                    "migrationSupport",
                    "evalProfile",
                    "status"
                ],
                "additionalProperties": true,
                "properties": {
                    "schemaVersion": {"type": "string"},
                    "engineId": {"type": "string"},
                    "label": {"type": "string"},
                    "version": {"type": "string"},
                    "packageProvenance": {"type": "object"},
                    "supportedModes": {"type": "array"},
                    "supportedStores": {"type": "array"},
                    "privacyFeatures": {"type": "object"},
                    "migrationSupport": {"type": "object"},
                    "evalProfile": {"type": "object"},
                    "status": {"type": "string"}
                }
            }),
            vec![
                "available",
                "active",
                "shadow",
                "disabled",
                "retired",
                "archived",
            ],
            vec![
                "selected_by",
                "compares_with",
                "exported_by",
                "imported_by",
                "evaluated_by",
                "supersedes",
                "derived_from",
                "evidence_for",
            ],
        ),
        memory_builtin_type(
            MEMORY_POLICY_KIND,
            MEMORY_POLICY_SCHEMA_ID,
            json!({
                "type": "object",
                "required": [
                    "schemaVersion",
                    "mode",
                    "inclusion",
                    "retention",
                    "privacy",
                    "migration",
                    "provenance",
                    "revision"
                ],
                "additionalProperties": true,
                "properties": {
                    "schemaVersion": {"type": "string"},
                    "mode": {"type": "string", "enum": ["disabled", "active", "shadow", "compare"]},
                    "activeEngineId": {"type": "string"},
                    "compareEngineIds": {"type": "array"},
                    "inclusion": {"type": "object"},
                    "retention": {"type": "object"},
                    "privacy": {"type": "object"},
                    "migration": {"type": "object"},
                    "provenance": {"type": "object"},
                    "revision": {"type": "integer"}
                }
            }),
            vec!["disabled", "active", "shadow", "compare", "archived"],
            vec![
                "selects_engine",
                "compares_engine",
                "governs_record",
                "governs_prompt_trace",
                "supersedes",
                "derived_from",
                "evidence_for",
            ],
        ),
        memory_builtin_type(
            MEMORY_RECORD_KIND,
            MEMORY_RECORD_SCHEMA_ID,
            json!({
                "type": "object",
                "required": [
                    "schemaVersion",
                    "subject",
                    "scope",
                    "preview",
                    "bodyRef",
                    "provenance",
                    "confidence",
                    "sensitivity",
                    "retention",
                    "sourceRefs",
                    "traceRefs",
                    "replayRefs",
                    "lifecycle",
                    "migration",
                    "revision"
                ],
                "additionalProperties": true,
                "properties": {
                    "schemaVersion": {"type": "string"},
                    "subject": {"type": "string"},
                    "scope": {"type": "object"},
                    "preview": {"type": "string"},
                    "bodyRef": {"type": "object"},
                    "provenance": {"type": "object"},
                    "confidence": {"type": "object"},
                    "sensitivity": {"type": "string"},
                    "retention": {"type": "object"},
                    "expiresAt": {"type": "string"},
                    "sourceRefs": {"type": "array"},
                    "traceRefs": {"type": "array"},
                    "replayRefs": {"type": "array"},
                    "lifecycle": {"type": "object"},
                    "migration": {"type": "object"},
                    "revision": {"type": "integer"}
                }
            }),
            vec![
                "retained",
                "edited",
                "tombstoned",
                "expired",
                "exported",
                "archived",
            ],
            vec![
                "governed_by",
                "source_event",
                "source_resource",
                "source_trace",
                "source_replay",
                "included_by",
                "excluded_by",
                "exported_by",
                "imported_by",
                "supersedes",
                "derived_from",
                "evidence_for",
            ],
        ),
        memory_builtin_type(
            MEMORY_PROMPT_TRACE_KIND,
            MEMORY_PROMPT_TRACE_SCHEMA_ID,
            json!({
                "type": "object",
                "required": [
                    "schemaVersion",
                    "mode",
                    "considered",
                    "included",
                    "excluded",
                    "promptBudget",
                    "redaction",
                    "traceRefs",
                    "replayRefs",
                    "createdAt"
                ],
                "additionalProperties": true,
                "properties": {
                    "schemaVersion": {"type": "string"},
                    "mode": {"type": "string", "enum": ["disabled", "active", "shadow", "compare"]},
                    "engineId": {"type": "string"},
                    "considered": {"type": "array"},
                    "included": {"type": "array"},
                    "excluded": {"type": "array"},
                    "promptBudget": {"type": "object"},
                    "redaction": {"type": "object"},
                    "traceRefs": {"type": "array"},
                    "replayRefs": {"type": "array"},
                    "createdAt": {"type": "string"}
                }
            }),
            vec!["recorded", "discarded", "archived"],
            vec![
                "governed_by",
                "considered_record",
                "included_record",
                "excluded_record",
                "derived_from",
                "evidence_for",
            ],
        ),
        memory_builtin_type(
            MEMORY_EVAL_RUN_KIND,
            MEMORY_EVAL_RUN_SCHEMA_ID,
            json!({
                "type": "object",
                "required": [
                    "schemaVersion",
                    "engineId",
                    "datasetProvenance",
                    "scores",
                    "outcome",
                    "findings",
                    "createdAt"
                ],
                "additionalProperties": true,
                "properties": {
                    "schemaVersion": {"type": "string"},
                    "engineId": {"type": "string"},
                    "datasetProvenance": {"type": "object"},
                    "scores": {"type": "object"},
                    "outcome": {"type": "string"},
                    "findings": {"type": "array"},
                    "createdAt": {"type": "string"}
                }
            }),
            vec!["passed", "failed", "inconclusive", "archived"],
            vec![
                "evaluates_engine",
                "evaluates_record",
                "uses_dataset",
                "supersedes",
                "derived_from",
                "evidence_for",
            ],
        ),
        memory_builtin_type(
            MEMORY_MIGRATION_ENVELOPE_KIND,
            MEMORY_MIGRATION_ENVELOPE_SCHEMA_ID,
            json!({
                "type": "object",
                "required": [
                    "schemaVersion",
                    "operation",
                    "sourceEngineId",
                    "records",
                    "indexMetadata",
                    "lineage",
                    "validation",
                    "createdAt"
                ],
                "additionalProperties": true,
                "properties": {
                    "schemaVersion": {"type": "string"},
                    "operation": {"type": "string", "enum": ["export", "import"]},
                    "sourceEngineId": {"type": "string"},
                    "targetEngineId": {"type": "string"},
                    "records": {"type": "array"},
                    "indexMetadata": {"type": "object"},
                    "lineage": {"type": "object"},
                    "validation": {"type": "object"},
                    "createdAt": {"type": "string"}
                }
            }),
            vec!["exported", "imported", "invalid", "archived"],
            vec![
                "exports_record",
                "imports_record",
                "exports_index",
                "imports_index",
                "source_engine",
                "target_engine",
                "supersedes",
                "derived_from",
                "evidence_for",
            ],
        ),
    ]
}

fn memory_builtin_type(
    kind: &str,
    schema_id: &str,
    schema: Value,
    lifecycle_states: Vec<&str>,
    allowed_link_relations: Vec<&str>,
) -> RegisterResourceType {
    RegisterResourceType {
        kind: kind.to_owned(),
        schema_id: schema_id.to_owned(),
        schema,
        lifecycle_states: lifecycle_states.into_iter().map(str::to_owned).collect(),
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        allowed_link_relations: allowed_link_relations
            .into_iter()
            .map(str::to_owned)
            .collect(),
        default_retention: json!({"class": "project"}),
        redaction_rules: json!({"preview": "metadata_only"}),
        materialization_rules: json!({"durableOutputsRequireResourceVersion": true}),
        required_capabilities: json!({
            "read": ["memory.read", "resource.read"],
            "write": ["memory.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("resource").expect("valid static worker id"),
    }
}
