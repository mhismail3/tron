//! Tool-source proposal resource definitions.

use serde_json::json;

use super::types::{
    EngineResourceVersioningMode, RegisterResourceType, TOOL_SOURCE_CONFORMANCE_REPORT_KIND,
    TOOL_SOURCE_CONFORMANCE_REPORT_SCHEMA_ID, TOOL_SOURCE_PROPOSAL_KIND,
    TOOL_SOURCE_PROPOSAL_SCHEMA_ID,
};
use crate::engine::kernel::ids::WorkerId;

pub(super) fn tool_source_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![
        tool_source_proposal_definition(),
        tool_source_conformance_report_definition(),
    ]
}

fn tool_source_proposal_definition() -> RegisterResourceType {
    RegisterResourceType {
        kind: TOOL_SOURCE_PROPOSAL_KIND.to_owned(),
        schema_id: TOOL_SOURCE_PROPOSAL_SCHEMA_ID.to_owned(),
        schema: json!({
            "type": "object",
            "required": [
                "schemaVersion",
                "state",
                "sourceKind",
                "sourceIdentity",
                "provenance",
                "sandboxPolicy",
                "declaredTools",
                "declaredSchemas",
                "expectedLinkage",
                "authority",
                "traceRefs",
                "replayRefs",
                "evidenceRefs",
                "idempotency",
                "revision"
            ],
            "additionalProperties": true,
            "properties": {
                "schemaVersion": {"type": "string"},
                "state": {"type": "string", "enum": ["proposed", "rejected", "archived"]},
                "sourceKind": {"type": "string"},
                "sourceIdentity": {"type": "object"},
                "provenance": {"type": "object"},
                "sandboxPolicy": {"type": "object"},
                "declaredTools": {"type": "array"},
                "declaredSchemas": {"type": "array"},
                "expectedLinkage": {"type": "object"},
                "authority": {"type": "object"},
                "traceRefs": {"type": "array"},
                "replayRefs": {"type": "array"},
                "evidenceRefs": {"type": "array"},
                "redaction": {"type": "object"},
                "limits": {"type": "object"},
                "idempotency": {"type": "object"},
                "revision": {"type": "integer"}
            }
        }),
        lifecycle_states: ["proposed", "rejected", "archived"]
            .into_iter()
            .map(str::to_owned)
            .collect(),
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        allowed_link_relations: [
            "conformance_report",
            "evidence_for",
            "derived_from",
            "expected_worker_package",
            "supersedes",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect(),
        default_retention: json!({"class": "tool_source_provenance"}),
        redaction_rules: json!({"preview": "metadata_only", "secrets": "reject_inline"}),
        materialization_rules: json!({"durableOutputsRequireResourceVersion": true}),
        required_capabilities: json!({
            "read": ["tool_sources.read", "resource.read"],
            "write": ["tool_sources.propose", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("resource").expect("valid static worker id"),
    }
}

fn tool_source_conformance_report_definition() -> RegisterResourceType {
    RegisterResourceType {
        kind: TOOL_SOURCE_CONFORMANCE_REPORT_KIND.to_owned(),
        schema_id: TOOL_SOURCE_CONFORMANCE_REPORT_SCHEMA_ID.to_owned(),
        schema: json!({
            "type": "object",
            "required": [
                "schemaVersion",
                "state",
                "toolSourceProposalResourceId",
                "proposalVersionId",
                "status",
                "checks",
                "summary",
                "authority",
                "traceRefs",
                "replayRefs",
                "evidenceRefs",
                "idempotency",
                "revision"
            ],
            "additionalProperties": true,
            "properties": {
                "schemaVersion": {"type": "string"},
                "state": {"type": "string", "enum": ["passed", "failed", "quarantined"]},
                "toolSourceProposalResourceId": {"type": "string"},
                "proposalVersionId": {"type": "string"},
                "status": {"type": "string"},
                "checks": {"type": "array"},
                "summary": {"type": "object"},
                "authority": {"type": "object"},
                "traceRefs": {"type": "array"},
                "replayRefs": {"type": "array"},
                "evidenceRefs": {"type": "array"},
                "idempotency": {"type": "object"},
                "revision": {"type": "integer"}
            }
        }),
        lifecycle_states: ["passed", "failed", "quarantined", "archived"]
            .into_iter()
            .map(str::to_owned)
            .collect(),
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        allowed_link_relations: ["proposal", "evidence_for", "derived_from", "supersedes"]
            .into_iter()
            .map(str::to_owned)
            .collect(),
        default_retention: json!({"class": "tool_source_conformance"}),
        redaction_rules: json!({"preview": "metadata_only", "secrets": "reject_inline"}),
        materialization_rules: json!({"durableOutputsRequireResourceVersion": true}),
        required_capabilities: json!({
            "read": ["tool_sources.read", "resource.read"],
            "write": ["tool_sources.propose", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("resource").expect("valid static worker id"),
    }
}
