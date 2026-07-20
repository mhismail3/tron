//! Built-in durable resource definitions retained by the worker-first kernel.
//!
//! Worker bundles and operational records have their own filesystem/SQLite
//! contract. The generic engine resource substrate now carries only neutral
//! artifacts, decisions, claims, evidence, filesystem materialization records,
//! and the product-owned context, memory, and private device records still used
//! by fixed clients.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::context_control_definitions::context_control_resource_type_definitions;
use super::device_definitions::device_resource_type_definitions;
use super::memory_definitions::memory_resource_type_definitions;
use super::types::{
    EngineResourceTypeDefinition, EngineResourceVersioningMode, RegisterResourceType,
};
use crate::engine::kernel::ids::WorkerId;

/// Fixed resource kinds for the worker-first kernel.
#[must_use]
pub fn builtin_resource_type_definitions() -> Vec<RegisterResourceType> {
    let mut definitions = vec![
        builtin_type(
            "artifact",
            "tron.resource.artifact.v1",
            json!({
                "type":"object",
                "required":["title","body"],
                "additionalProperties":true,
                "properties":{
                    "title":{"type":"string"},
                    "body":{},
                    "format":{"type":"string"},
                    "summary":{"type":"string"},
                    "metadata":{"type":"object"}
                }
            }),
            vec!["draft", "promoted", "discarded", "archived"],
            vec![
                "produced",
                "supported_by",
                "contradicted_by",
                "derived_from",
            ],
        ),
        builtin_type(
            "decision",
            "tron.resource.decision.v1",
            json!({
                "type":"object",
                "required":["status","summary"],
                "additionalProperties":true,
                "properties":{
                    "status":{"type":"string"},
                    "summary":{"type":"string"},
                    "metadata":{"type":"object"}
                }
            }),
            vec!["draft", "final", "archived"],
            vec!["decides", "supports", "derived_from", "supersedes"],
        ),
        builtin_type(
            "claim",
            "tron.resource.claim.v1",
            json!({
                "type":"object",
                "required":["statement"],
                "additionalProperties":true,
                "properties":{
                    "statement":{"type":"string"},
                    "confidence":{"type":"number"},
                    "metadata":{"type":"object"}
                }
            }),
            vec!["draft", "accepted", "rejected", "archived"],
            vec!["supported_by", "contradicted_by", "derived_from"],
        ),
        builtin_type(
            "evidence",
            "tron.resource.evidence.v1",
            json!({
                "type":"object",
                "required":["summary"],
                "additionalProperties":true,
                "properties":{
                    "summary":{"type":"string"},
                    "source":{"type":"string"},
                    "resourceRef":{"type":"string"},
                    "metadata":{"type":"object"}
                }
            }),
            vec!["draft", "accepted", "rejected", "archived"],
            vec![
                "evidence_for",
                "supports",
                "contradicted_by",
                "derived_from",
            ],
        ),
        builtin_type(
            "materialized_file",
            "tron.resource.materialized_file.v1",
            json!({
                "type":"object",
                "required":["canonicalPath","relativePath","entryType","contentHash","sizeBytes"],
                "additionalProperties":true,
                "properties":{
                    "canonicalPath":{"type":"string"},
                    "relativePath":{"type":"string"},
                    "entryType":{"type":"string","enum":["file","directory"]},
                    "content":{"type":"string"},
                    "contentHash":{"type":"string"},
                    "sizeBytes":{"type":"integer"},
                    "mimeType":{"type":"string"},
                    "metadata":{"type":"object"}
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
        ),
        builtin_type(
            "patch_proposal",
            "tron.resource.patch_proposal.v1",
            json!({
                "type":"object",
                "required":["targetPath","diff","status"],
                "additionalProperties":true,
                "properties":{
                    "targetPath":{"type":"string"},
                    "targetResourceId":{"type":"string"},
                    "baseVersionId":{"type":"string"},
                    "baseContentHash":{"type":"string"},
                    "diff":{"type":"string"},
                    "status":{"type":"string"},
                    "result":{"type":"object"}
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
        ),
    ];
    definitions.extend(context_control_resource_type_definitions());
    definitions.extend(memory_resource_type_definitions());
    definitions.extend(device_resource_type_definitions());
    definitions
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
        default_retention: json!({"class":"project"}),
        redaction_rules: json!({"preview":"metadata_only"}),
        materialization_rules: json!({"durableOutputsRequireResourceVersion":true}),
        required_capabilities: json!({
            "read":["resource.read"],
            "write":["resource.write"]
        }),
        owner_worker_id: WorkerId::new("resource").expect("valid static worker id"),
    }
}
