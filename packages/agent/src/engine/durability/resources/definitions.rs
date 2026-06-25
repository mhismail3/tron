//! Built-in resource type definitions for the collapsed substrate.

use chrono::{DateTime, Utc};
use serde_json::{Value, json};

use super::git_definitions::git_resource_type_definitions;
use super::goal_definitions::goal_question_resource_type_definitions;
use super::import_history_definitions::import_history_resource_type_definitions;
use super::job_definitions::job_resource_type_definitions;
use super::media_definitions::media_resource_type_definitions;
use super::memory_definitions::memory_resource_type_definitions;
use super::notification_definitions::notification_resource_type_definitions;
use super::procedural_definitions::procedural_resource_type_definitions;
use super::scheduler_definitions::scheduler_resource_type_definitions;
use super::subagent_definitions::subagent_resource_type_definitions;
use super::tool_source_definitions::tool_source_resource_type_definitions;
use super::types::{
    APPROVAL_DECISION_KIND, APPROVAL_DECISION_SCHEMA_ID, APPROVAL_REQUEST_KIND,
    APPROVAL_REQUEST_SCHEMA_ID, CATALOG_DISCOVERY_REPORT_KIND, CATALOG_DISCOVERY_REPORT_SCHEMA_ID,
    EngineResourceTypeDefinition, EngineResourceVersioningMode, RegisterResourceType,
    UI_SURFACE_KIND, UI_SURFACE_SCHEMA_ID,
};
use super::ui_surface::ui_surface_schema;
use super::web_definitions::web_resource_type_definitions;
use crate::engine::kernel::ids::WorkerId;

/// Built-in resource kinds for the collapsed modular substrate.
#[must_use]
pub fn builtin_resource_type_definitions() -> Vec<RegisterResourceType> {
    let mut definitions = vec![
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
            APPROVAL_REQUEST_KIND,
            APPROVAL_REQUEST_SCHEMA_ID,
            json!({
                "type": "object",
                "required": [
                    "schemaVersion",
                    "state",
                    "requester",
                    "action",
                    "scope",
                    "riskClass",
                    "createdAt",
                    "expiresAt",
                    "freshness",
                    "evidenceRefs",
                    "resourceSelectors",
                    "traceRefs",
                    "replayRefs",
                    "denialBehavior",
                    "idempotency",
                    "revision"
                ],
                "additionalProperties": true,
                "properties": {
                    "schemaVersion": {"type": "string"},
                    "state": {"type": "string", "enum": ["pending", "decided", "expired", "revoked"]},
                    "requester": {"type": "object"},
                    "action": {"type": "object"},
                    "scope": {"type": "object"},
                    "riskClass": {"type": "string"},
                    "createdAt": {"type": "string"},
                    "expiresAt": {"type": "string"},
                    "freshness": {"type": "object"},
                    "evidenceRefs": {"type": "array"},
                    "resourceSelectors": {"type": "array"},
                    "traceRefs": {"type": "array"},
                    "replayRefs": {"type": "array"},
                    "denialBehavior": {"type": "object"},
                    "idempotency": {"type": "object"},
                    "revision": {"type": "object"}
                }
            }),
            vec!["pending", "decided", "expired", "revoked", "archived"],
            vec![
                "requested_by",
                "evidence_for",
                "supported_by",
                "derived_from",
                "decided_by",
                "supersedes",
                "revoked_by",
            ],
            json!({
                "read": ["approval.read", "resource.read"],
                "write": ["approval.write", "resource.write"]
            }),
        ),
        builtin_type(
            APPROVAL_DECISION_KIND,
            APPROVAL_DECISION_SCHEMA_ID,
            json!({
                "type": "object",
                "required": [
                    "schemaVersion",
                    "requestResourceId",
                    "requestVersionId",
                    "state",
                    "decisionActor",
                    "decidedAt",
                    "expiresAt",
                    "action",
                    "scope",
                    "riskClass",
                    "evidenceRefs",
                    "resourceSelectors",
                    "traceRefs",
                    "replayRefs",
                    "denialBehavior",
                    "idempotency",
                    "revision"
                ],
                "additionalProperties": true,
                "properties": {
                    "schemaVersion": {"type": "string"},
                    "requestResourceId": {"type": "string"},
                    "requestVersionId": {"type": "string"},
                    "state": {"type": "string", "enum": ["approved", "denied", "revoked"]},
                    "decisionActor": {"type": "object"},
                    "decidedAt": {"type": "string"},
                    "expiresAt": {"type": "string"},
                    "freshnessUntil": {"type": "string"},
                    "action": {"type": "object"},
                    "scope": {"type": "object"},
                    "riskClass": {"type": "string"},
                    "evidenceRefs": {"type": "array"},
                    "resourceSelectors": {"type": "array"},
                    "traceRefs": {"type": "array"},
                    "replayRefs": {"type": "array"},
                    "denialBehavior": {"type": "object"},
                    "idempotency": {"type": "object"},
                    "revision": {"type": "object"}
                }
            }),
            vec!["approved", "denied", "revoked", "expired", "archived"],
            vec![
                "decision_for",
                "requested_by",
                "evidence_for",
                "supported_by",
                "derived_from",
                "supersedes",
                "revokes",
            ],
            json!({
                "read": ["approval.read", "resource.read"],
                "write": ["approval.write", "resource.write"]
            }),
        ),
        builtin_type(
            CATALOG_DISCOVERY_REPORT_KIND,
            CATALOG_DISCOVERY_REPORT_SCHEMA_ID,
            json!({
                "type": "object",
                "required": [
                    "schemaVersion",
                    "status",
                    "catalogRevision",
                    "summary",
                    "checks",
                    "protected"
                ],
                "additionalProperties": true,
                "properties": {
                    "schemaVersion": {"type": "string"},
                    "status": {"type": "string"},
                    "catalogRevision": {"type": "integer"},
                    "reason": {"type": "string"},
                    "actor": {"type": "object"},
                    "summary": {"type": "object"},
                    "checks": {"type": "array"},
                    "visible": {"type": "object"},
                    "protected": {"type": "object"},
                    "resourceEvidence": {"type": "object"}
                }
            }),
            vec!["passed", "failed", "quarantined", "archived"],
            vec![
                "evidence_for",
                "derived_from",
                "supersedes",
                "supports",
                "supported_by",
                "renders",
            ],
            json!({
                "read": ["catalog_discovery.read", "resource.read"],
                "write": ["catalog_discovery.write", "resource.write"]
            }),
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
        builtin_type(
            "worker_package",
            "tron.resource.worker_package.v1",
            json!({
                "type": "object",
                "required": [
                    "schemaVersion",
                    "packageId",
                    "packageVersion",
                    "packageDigest",
                    "provenance",
                    "source",
                    "workerId",
                    "namespaceClaims",
                    "launchCommand",
                    "workingDirectory",
                    "envAllowlist",
                    "expectedFunctions",
                    "expectedTriggers",
                    "requestedGrants",
                    "conformancePolicy",
                    "rollbackPolicy",
                    "status"
                ],
                "additionalProperties": true,
                "properties": {
                    "schemaVersion": {"type": "string"},
                    "packageId": {"type": "string"},
                    "packageVersion": {"type": "string"},
                    "packageDigest": {"type": "string"},
                    "provenance": {"type": "object"},
                    "source": {"type": "object"},
                    "workerId": {"type": "string"},
                    "namespaceClaims": {"type": "array", "items": {"type": "string"}},
                    "launchCommand": {"type": "array", "items": {"type": "string"}},
                    "workingDirectory": {"type": "string"},
                    "envAllowlist": {"type": "array", "items": {"type": "string"}},
                    "expectedFunctions": {"type": "array", "items": {"type": "string"}},
                    "expectedTriggers": {"type": "array", "items": {"type": "string"}},
                    "requestedGrants": {"type": "object"},
                    "conformancePolicy": {"type": "object"},
                    "rollbackPolicy": {"type": "object"},
                    "status": {"type": "string"}
                }
            }),
            vec![
                "proposed",
                "installed",
                "enabled",
                "disabled",
                "launching",
                "running",
                "unhealthy",
                "failed",
                "retired",
            ],
            vec![
                "installation",
                "proposal",
                "launch_attempt",
                "conformance_report",
                "supersedes",
                "rollback_of",
                "retired_by",
                "derived_from",
                "evidence_for",
            ],
            json!({"read": ["worker.lifecycle.read", "resource.read"], "write": ["worker.lifecycle.write", "resource.write"]}),
        ),
        builtin_type(
            "worker_package_installation",
            "tron.resource.worker_package_installation.v1",
            json!({
                "type": "object",
                "required": ["packageId", "packageVersion", "packageDigest", "workerId", "status"],
                "additionalProperties": true,
                "properties": {
                    "packageId": {"type": "string"},
                    "packageVersion": {"type": "string"},
                    "packageDigest": {"type": "string"},
                    "workerId": {"type": "string"},
                    "packageResourceId": {"type": "string"},
                    "status": {"type": "string"},
                    "installedAt": {"type": "string"},
                    "enabledAt": {"type": "string"},
                    "disabledAt": {"type": "string"},
                    "retiredAt": {"type": "string"},
                    "reason": {"type": "string"},
                    "authorityGrantId": {"type": "string"},
                    "rollbackRef": {"type": "object"}
                }
            }),
            vec![
                "installed",
                "enabled",
                "disabled",
                "launching",
                "running",
                "unhealthy",
                "failed",
                "retired",
            ],
            vec![
                "package",
                "launch_attempt",
                "conformance_report",
                "supersedes",
                "rollback_of",
                "evidence_for",
            ],
            json!({"read": ["worker.lifecycle.read", "resource.read"], "write": ["worker.lifecycle.write", "resource.write"]}),
        ),
        builtin_type(
            "worker_package_proposal",
            "tron.resource.worker_package_proposal.v1",
            json!({
                "type": "object",
                "required": ["packageId", "packageVersion", "summary", "status"],
                "additionalProperties": true,
                "properties": {
                    "packageId": {"type": "string"},
                    "packageVersion": {"type": "string"},
                    "summary": {"type": "string"},
                    "status": {"type": "string"},
                    "manifest": {"type": "object"},
                    "proposedBy": {"type": "string"},
                    "createdAt": {"type": "string"},
                    "authorityGrantId": {"type": "string"}
                }
            }),
            vec!["proposed", "accepted", "rejected", "discarded", "archived"],
            vec!["package", "derived_from", "evidence_for"],
            json!({"read": ["worker.lifecycle.read", "resource.read"], "write": ["worker.lifecycle.propose", "resource.write"]}),
        ),
        builtin_type(
            "worker_package_conformance_report",
            "tron.resource.worker_package_conformance_report.v1",
            json!({
                "type": "object",
                "required": ["packageId", "packageVersion", "workerId", "status", "checks"],
                "additionalProperties": true,
                "properties": {
                    "packageId": {"type": "string"},
                    "packageVersion": {"type": "string"},
                    "workerId": {"type": "string"},
                    "status": {"type": "string"},
                    "checks": {"type": "array"},
                    "launchAttemptResourceId": {"type": "string"},
                    "catalogRevision": {"type": "integer"},
                    "createdAt": {"type": "string"}
                }
            }),
            vec!["passed", "failed", "quarantined", "archived"],
            vec!["package", "installation", "launch_attempt", "evidence_for"],
            json!({"read": ["worker.lifecycle.read", "resource.read"], "write": ["worker.lifecycle.write", "resource.write"]}),
        ),
        builtin_type(
            "worker_launch_attempt",
            "tron.resource.worker_launch_attempt.v1",
            json!({
                "type": "object",
                "required": ["packageId", "packageVersion", "workerId", "status", "argv", "endpoint"],
                "additionalProperties": true,
                "properties": {
                    "packageId": {"type": "string"},
                    "packageVersion": {"type": "string"},
                    "workerId": {"type": "string"},
                    "status": {"type": "string"},
                    "argv": {"type": "array", "items": {"type": "string"}},
                    "workingDirectory": {"type": "string"},
                    "envKeys": {"type": "array", "items": {"type": "string"}},
                    "endpoint": {"type": "string"},
                    "tokenGrantId": {"type": "string"},
                    "processId": {"type": "integer"},
                    "launchedAt": {"type": "string"},
                    "stoppedAt": {"type": "string"},
                    "failure": {"type": "object"}
                }
            }),
            vec![
                "launching",
                "running",
                "stopped",
                "failed",
                "unhealthy",
                "retired",
            ],
            vec![
                "package",
                "installation",
                "conformance_report",
                "evidence_for",
            ],
            json!({"read": ["worker.lifecycle.read", "resource.read"], "write": ["worker.lifecycle.write", "resource.write"]}),
        ),
    ];
    definitions.extend(git_resource_type_definitions());
    definitions.extend(goal_question_resource_type_definitions());
    definitions.extend(job_resource_type_definitions());
    definitions.extend(import_history_resource_type_definitions());
    definitions.extend(memory_resource_type_definitions());
    definitions.extend(media_resource_type_definitions());
    definitions.extend(notification_resource_type_definitions());
    definitions.extend(procedural_resource_type_definitions());
    definitions.extend(scheduler_resource_type_definitions());
    definitions.extend(web_resource_type_definitions());
    definitions.extend(tool_source_resource_type_definitions());
    definitions.extend(subagent_resource_type_definitions());
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
