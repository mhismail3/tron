//! Built-in resource type definitions for the collapsed substrate.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::types::{
    EngineResourceTypeDefinition, EngineResourceVersioningMode, RegisterResourceType,
    UI_SURFACE_KIND, UI_SURFACE_SCHEMA_ID,
};
use super::ui_surface::ui_surface_schema;
use crate::engine::ids::WorkerId;

/// Built-in resource kinds for the collapsed modular substrate.
#[must_use]
pub fn builtin_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![
        builtin_type(
            "artifact",
            "tron.resource.artifact.v1",
            json!({
                "type": "object",
                "required": ["title", "body"],
                "additionalProperties": true,
                "properties": {
                    "title": {"type": "string"},
                    "body": {},
                    "format": {"type": "string"},
                    "summary": {"type": "string"},
                    "metadata": {"type": "object"}
                }
            }),
            vec!["draft", "promoted", "discarded", "archived"],
            vec![
                "input",
                "produced",
                "candidate_output",
                "promoted_output",
                "supported_by",
                "contradicted_by",
                "supports",
                "supersedes",
                "evidence_for",
                "derived_from",
                "part_of",
            ],
            json!({"read": ["resource.read"], "write": ["resource.write"], "promote": ["resource.write"], "delete": ["resource.write"]}),
        ),
        builtin_type(
            "goal",
            "tron.resource.goal.v1",
            json!({
                "type": "object",
                "required": ["intent"],
                "additionalProperties": true,
                "properties": {
                    "intent": {"type": "string"},
                    "successCriteria": {"type": "array", "items": {"type": "string"}},
                    "inputResources": {"type": "array", "items": {"type": "string"}},
                    "expectedOutputKinds": {"type": "array", "items": {"type": "string"}},
                    "constraints": {"type": "object"},
                    "riskBudget": {"type": "object"},
                    "authorityPolicy": {"type": "object"},
                    "retentionPolicy": {"type": "object"},
                    "completionCondition": {"type": "string"}
                }
            }),
            vec!["open", "in_progress", "completed", "failed", "archived"],
            vec![
                "input",
                "subgoal",
                "produced",
                "produces",
                "candidate_output",
                "promoted_output",
                "decided_by",
                "supported_by",
                "contradicted_by",
                "supersedes",
                "derived_from",
            ],
            json!({"read": ["resource.read"], "write": ["resource.write"], "complete": ["resource.write"]}),
        ),
        builtin_type(
            "decision",
            "tron.resource.decision.v1",
            json!({
                "type": "object",
                "required": ["status", "summary"],
                "additionalProperties": true,
                "properties": {
                    "status": {"type": "string"},
                    "summary": {"type": "string"},
                    "promotedResources": {"type": "array", "items": {"type": "string"}},
                    "discardedResources": {"type": "array", "items": {"type": "string"}},
                    "metadata": {"type": "object"}
                }
            }),
            vec!["draft", "final", "archived"],
            vec![
                "decides",
                "promotes",
                "discards",
                "supports",
                "supported_by",
                "contradicted_by",
                "derived_from",
                "revokes",
                "supersedes",
                "renewed_by",
                "rotates_from",
                "rotates_to",
                "enforces_revocation",
                "evidence_for",
            ],
            json!({"read": ["resource.read"], "write": ["resource.write"]}),
        ),
        builtin_type(
            "claim",
            "tron.resource.claim.v1",
            json!({
                "type": "object",
                "required": ["statement"],
                "additionalProperties": true,
                "properties": {
                    "statement": {"type": "string"},
                    "confidence": {"type": "number"},
                    "metadata": {"type": "object"}
                }
            }),
            vec!["draft", "accepted", "rejected", "archived"],
            vec![
                "claims_about",
                "supported_by",
                "contradicted_by",
                "contradicts",
                "derived_from",
            ],
            json!({"read": ["resource.read"], "write": ["resource.write"]}),
        ),
        builtin_type(
            "evidence",
            "tron.resource.evidence.v1",
            json!({
                "type": "object",
                "required": ["summary"],
                "additionalProperties": true,
                "properties": {
                    "summary": {"type": "string"},
                    "source": {"type": "string"},
                    "resourceRef": {"type": "string"},
                    "metadata": {"type": "object"}
                }
            }),
            vec!["draft", "accepted", "rejected", "archived"],
            vec![
                "evidence_for",
                "supported_by",
                "contradicted_by",
                "derived_from",
                "supports",
                "revokes",
                "supersedes",
                "renewed_by",
                "rotates_from",
                "rotates_to",
                "enforces_revocation",
            ],
            json!({"read": ["resource.read"], "write": ["resource.write"]}),
        ),
        builtin_type(
            UI_SURFACE_KIND,
            UI_SURFACE_SCHEMA_ID,
            ui_surface_schema(),
            vec![
                "draft",
                "active",
                "superseded",
                "expired",
                "discarded",
                "damaged",
            ],
            vec![
                "input",
                "produced",
                "candidate_output",
                "promoted_output",
                "decided_by",
                "supported_by",
                "contradicted_by",
                "supersedes",
                "derived_from",
                "renders",
                "acts_on",
            ],
            json!({
                "read": ["ui.read", "resource.read"],
                "write": ["ui.write", "resource.write"],
                "delete": ["ui.write", "resource.write"]
            }),
        ),
        builtin_type(
            "materialized_file",
            "tron.resource.materialized_file.v1",
            json!({
                "type": "object",
                "required": ["canonicalPath", "relativePath", "entryType", "contentHash", "sizeBytes"],
                "additionalProperties": true,
                "properties": {
                    "canonicalPath": {"type": "string"},
                    "relativePath": {"type": "string"},
                    "entryType": {"type": "string", "enum": ["file", "directory"]},
                    "content": {"type": "string"},
                    "contentHash": {"type": "string"},
                    "sizeBytes": {"type": "integer"},
                    "mimeType": {"type": "string"},
                    "metadata": {"type": "object"}
                }
            }),
            vec![
                "draft",
                "materialized",
                "promoted",
                "discarded",
                "damaged",
                "quarantined",
                "archived",
            ],
            vec![
                "applies_patch",
                "derived_from",
                "materializes",
                "produced",
                "promoted_output",
            ],
            json!({"read": ["resource.read"], "write": ["resource.write"], "promote": ["resource.write"], "delete": ["resource.write"]}),
        ),
        builtin_type(
            "patch_proposal",
            "tron.resource.patch_proposal.v1",
            json!({
                "type": "object",
                "required": ["targetPath", "diff", "status"],
                "additionalProperties": true,
                "properties": {
                    "targetPath": {"type": "string"},
                    "targetResourceId": {"type": "string"},
                    "baseVersionId": {"type": "string"},
                    "baseContentHash": {"type": "string"},
                    "diff": {"type": "string"},
                    "status": {"type": "string"},
                    "result": {"type": "object"}
                }
            }),
            vec![
                "proposed",
                "applied",
                "merged",
                "rejected",
                "discarded",
                "archived",
            ],
            vec![
                "applies_to",
                "produces",
                "produced",
                "derived_from",
                "promoted_output",
            ],
            json!({"read": ["resource.read"], "write": ["resource.write"], "apply": ["resource.write"]}),
        ),
        builtin_type(
            "execution_output",
            "tron.resource.execution_output.v1",
            json!({
                "type": "object",
                "required": ["exitCode", "durationMs", "timedOut", "outputTruncated"],
                "additionalProperties": true,
                "properties": {
                    "stdoutPreview": {"type": "string"},
                    "stderrPreview": {"type": "string"},
                    "logPreview": {"type": "string"},
                    "exitCode": {"type": "integer"},
                    "durationMs": {"type": "integer"},
                    "timedOut": {"type": "boolean"},
                    "outputTruncated": {"type": "boolean"},
                    "redactionPolicy": {"type": "object"},
                    "metadata": {"type": "object"}
                }
            }),
            vec!["retained", "discarded", "archived"],
            vec!["produced_by", "produced", "derived_from"],
            json!({"read": ["resource.read"], "write": ["resource.write"]}),
        ),
        builtin_type(
            "agent_result",
            "tron.resource.agent_result.v1",
            json!({
                "type": "object",
                "required": ["message", "stopReason"],
                "additionalProperties": true,
                "properties": {
                    "message": {"type": "string"},
                    "promotedRefs": {"type": "array"},
                    "decisionRefs": {"type": "array"},
                    "subgoalRefs": {"type": "array"},
                    "stopReason": {"type": "string"},
                    "tokenUsage": {"type": "object"},
                    "metadata": {"type": "object"}
                }
            }),
            vec!["final", "interrupted", "discarded", "archived"],
            vec![
                "answers",
                "decides",
                "promotes",
                "supports",
                "produced",
                "derived_from",
            ],
            json!({"read": ["resource.read"], "write": ["resource.write"]}),
        ),
    ]
}

pub(crate) fn type_definition_from_request(
    request: RegisterResourceType,
    revision: u64,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
) -> EngineResourceTypeDefinition {
    EngineResourceTypeDefinition {
        kind: request.kind,
        schema_id: request.schema_id,
        schema: request.schema,
        lifecycle_states: request.lifecycle_states,
        versioning_mode: request.versioning_mode,
        allowed_link_relations: request.allowed_link_relations,
        default_retention: request.default_retention,
        redaction_rules: request.redaction_rules,
        materialization_rules: request.materialization_rules,
        required_capabilities: request.required_capabilities,
        owner_worker_id: request.owner_worker_id,
        revision,
        created_at,
        updated_at,
    }
}

fn builtin_type(
    kind: &str,
    schema_id: &str,
    schema: Value,
    lifecycle_states: Vec<&str>,
    allowed_link_relations: Vec<&str>,
    required_capabilities: Value,
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
        required_capabilities,
        owner_worker_id: WorkerId::new("resource").expect("valid static worker id"),
    }
}
