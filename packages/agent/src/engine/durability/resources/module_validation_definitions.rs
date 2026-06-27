//! Module validation report resource definitions.
//!
//! Validation reports are inert contract-test harness evidence. They store
//! bounded refs, supplied fingerprints, parity check summaries, lifecycle
//! evidence, and explicit no-install/no-execution proof. They do not run module
//! code, shell commands, package managers, dependency restoration, or network
//! operations.

use serde_json::json;

use super::types::{
    EngineResourceVersioningMode, MODULE_VALIDATION_REPORT_KIND,
    MODULE_VALIDATION_REPORT_SCHEMA_ID, RegisterResourceType,
};
use crate::engine::kernel::ids::WorkerId;

pub(crate) const MODULE_VALIDATION_REPORT_PAYLOAD_SCHEMA_VERSION: &str =
    "tron.module_validation_report.v1";

pub(super) fn module_validation_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![RegisterResourceType {
        kind: MODULE_VALIDATION_REPORT_KIND.to_owned(),
        schema_id: MODULE_VALIDATION_REPORT_SCHEMA_ID.to_owned(),
        schema: json!({
            "type": "object",
            "required": [
                "schemaVersion",
                "state",
                "reportId",
                "scope",
                "identity",
                "subjectRefs",
                "projectionParity",
                "evidence",
                "validation",
                "lifecycle",
                "traceRefs",
                "replayRefs",
                "authority",
                "idempotency",
                "noInstallNoExecutionProof",
                "createdAt",
                "updatedAt",
                "revision"
            ],
            "additionalProperties": false,
            "properties": {
                "schemaVersion": {"type": "string", "const": MODULE_VALIDATION_REPORT_PAYLOAD_SCHEMA_VERSION},
                "state": {"type": "string", "enum": ["pending", "passed", "failed", "superseded", "archived"]},
                "reportId": {"type": "string"},
                "scope": {"type": "object"},
                "identity": {
                    "type": "object",
                    "required": ["title", "summary"],
                    "additionalProperties": false,
                    "properties": {
                        "title": {"type": "string"},
                        "summary": {"type": "string"}
                    }
                },
                "subjectRefs": {
                    "type": "object",
                    "required": ["modules", "proposals"],
                    "additionalProperties": false,
                    "properties": {
                        "modules": {"type": "array", "minItems": 1, "maxItems": 25, "items": {"type": "object"}},
                        "proposals": {"type": "array", "maxItems": 25, "items": {"type": "object"}}
                    }
                },
                "projectionParity": {
                    "type": "object",
                    "required": ["manifest", "resource", "provider"],
                    "additionalProperties": false,
                    "properties": {
                        "manifest": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                        "resource": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                        "provider": {"type": "array", "maxItems": 25, "items": {"type": "object"}}
                    }
                },
                "evidence": {
                    "type": "object",
                    "required": ["docs", "tests", "commands", "results", "failures", "trace", "replay"],
                    "additionalProperties": false,
                    "properties": {
                        "docs": {"type": "array", "minItems": 1, "maxItems": 25, "items": {"type": "object"}},
                        "tests": {"type": "array", "minItems": 1, "maxItems": 25, "items": {"type": "object"}},
                        "commands": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                        "results": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                        "failures": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                        "trace": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                        "replay": {"type": "array", "maxItems": 25, "items": {"type": "object"}}
                    }
                },
                "validation": {
                    "type": "object",
                    "required": ["status", "checks"],
                    "additionalProperties": false,
                    "properties": {
                        "status": {"type": "string"},
                        "checks": {"type": "array", "maxItems": 25, "items": {"type": "object"}}
                    }
                },
                "lifecycle": {"type": "object"},
                "traceRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                "replayRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                "authority": {"type": "object"},
                "idempotency": {"type": "object"},
                "noInstallNoExecutionProof": {
                    "type": "object",
                    "required": [
                        "noInstall",
                        "noExecution",
                        "dependencyRestorePerformed",
                        "packageManagerUsed",
                        "networkPolicy",
                        "networkAccessPerformed",
                        "repoManagedSkillsTouched",
                        "rawValidationReportBodyStored",
                        "rawPromptStored",
                        "rawCommandsStored",
                        "rawLogsStored",
                        "fileContentsStored",
                        "absolutePathsStored"
                    ],
                    "additionalProperties": false,
                    "properties": {
                        "noInstall": {"type": "boolean", "const": true},
                        "noExecution": {"type": "boolean", "const": true},
                        "dependencyRestorePerformed": {"type": "boolean", "const": false},
                        "packageManagerUsed": {"type": "boolean", "const": false},
                        "networkPolicy": {"type": "string", "const": "none"},
                        "networkAccessPerformed": {"type": "boolean", "const": false},
                        "repoManagedSkillsTouched": {"type": "boolean", "const": false},
                        "rawValidationReportBodyStored": {"type": "boolean", "const": false},
                        "rawPromptStored": {"type": "boolean", "const": false},
                        "rawCommandsStored": {"type": "boolean", "const": false},
                        "rawLogsStored": {"type": "boolean", "const": false},
                        "fileContentsStored": {"type": "boolean", "const": false},
                        "absolutePathsStored": {"type": "boolean", "const": false}
                    }
                },
                "createdAt": {"type": "string"},
                "updatedAt": {"type": "string"},
                "revision": {"type": "integer"}
            }
        }),
        lifecycle_states: ["pending", "passed", "failed", "superseded", "archived"]
            .into_iter()
            .map(str::to_owned)
            .collect(),
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        allowed_link_relations: [
            "module",
            "proposal",
            "doc",
            "test",
            "command",
            "result",
            "failure",
            "trace",
            "replay",
            "evidence_for",
            "derived_from",
            "supersedes",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect(),
        default_retention: json!({
            "class": "module_validation_report",
            "scope": "session_or_workspace",
            "archiveKeepsLifecycleEvidence": true
        }),
        redaction_rules: json!({
            "projection": "metadata_only_provider_safe",
            "neverReturn": [
                "code",
                "sourceCode",
                "prompt",
                "messages",
                "command",
                "rawCommand",
                "env",
                "environmentValues",
                "rawLogs",
                "stdout",
                "stderr",
                "fileContents",
                "absolutePath",
                "unsafePath",
                "grantId",
                "authorityId",
                "rawValidationReportBody",
                "debugPayload",
                "chainOfThought"
            ],
            "commands": "identity_and_result_refs_only",
            "refs": "resource_backed_bounded_metadata_only"
        }),
        materialization_rules: json!({
            "durableOutputsRequireResourceVersion": true,
            "install": "forbidden",
            "activation": "forbidden",
            "execution": "forbidden",
            "commandExecution": "forbidden",
            "dependencyRestore": "forbidden",
            "networkPolicy": "none",
            "physicalWorkspaceDirectory": "forbidden"
        }),
        required_capabilities: json!({
            "read": ["module_validation.read", "resource.read"],
            "write": ["module_validation.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("module_validation").expect("valid static worker id"),
    }]
}
