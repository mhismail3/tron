//! Content-free program execution resource definitions.

use serde_json::json;

use super::types::{
    EngineResourceVersioningMode, PROGRAM_EXECUTION_KIND, PROGRAM_EXECUTION_SCHEMA_ID,
    RegisterResourceType,
};
use crate::engine::kernel::ids::WorkerId;

/// Built-in resource definitions for program execution metadata records.
#[must_use]
pub(crate) fn program_execution_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![RegisterResourceType {
        kind: PROGRAM_EXECUTION_KIND.to_owned(),
        schema_id: PROGRAM_EXECUTION_SCHEMA_ID.to_owned(),
        schema: json!({
            "type": "object",
            "required": [
                "schemaVersion",
                "state",
                "programId",
                "scope",
                "runtimeId",
                "languageId",
                "programFingerprint",
                "resourceLimits",
                "ioEnvelope",
                "createdAt",
                "updatedAt",
                "retention",
                "metadata",
                "refs",
                "traceRefs",
                "replayRefs",
                "authority",
                "idempotency",
                "revision"
            ],
            "additionalProperties": true,
            "properties": {
                "schemaVersion": {"type": "string"},
                "state": {"type": "string", "enum": ["active", "archived"]},
                "programId": {"type": "string"},
                "scope": {"type": "object"},
                "runtimeId": {"type": "string"},
                "languageId": {"type": "string"},
                "programFingerprint": {"type": "string"},
                "sourceRef": {"type": "object"},
                "inputRef": {"type": "object"},
                "outputRef": {"type": "object"},
                "resourceLimits": {"type": "object"},
                "ioEnvelope": {"type": "object"},
                "createdAt": {"type": "string"},
                "updatedAt": {"type": "string"},
                "retention": {"type": "object"},
                "metadata": {"type": "object"},
                "refs": {"type": "object"},
                "traceRefs": {"type": "array"},
                "replayRefs": {"type": "array"},
                "authority": {"type": "object"},
                "idempotency": {"type": "object"},
                "revision": {"type": "integer"}
            }
        }),
        lifecycle_states: ["active", "archived"]
            .into_iter()
            .map(str::to_owned)
            .collect(),
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        allowed_link_relations: [
            "source",
            "input",
            "output",
            "evidence_for",
            "derived_from",
            "program_fingerprint",
            "runtime_metadata",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect(),
        default_retention: json!({
            "class": "program_execution_metadata",
            "maxAgeDays": 90,
            "archiveKeepsEvidence": true
        }),
        redaction_rules: json!({
            "preview": "metadata_only",
            "neverReturn": ["code", "sourceCode", "rawCode", "script", "command", "shellCommand", "stdin", "stdout", "stderr", "rawStdin", "rawStdout", "rawStderr", "absolutePath", "workingDirectory", "blobBytes", "fileContents"],
            "io": "refs_and_fingerprints_only"
        }),
        materialization_rules: json!({
            "durableOutputsRequireResourceVersion": true,
            "payloadStoresProgramExecutionMetadataOnly": true,
            "contentFreeProgramExecution": true,
            "runtimeExecutionPerformed": false,
            "processLaunched": false,
            "subprocessLaunched": false,
            "rawCodeStored": false,
            "rawIoStored": false,
            "fileWritesPerformed": false,
            "networkAccessPerformed": false,
            "packageInstallPerformed": false
        }),
        required_capabilities: json!({
            "read": ["program_execution.read", "resource.read"],
            "write": ["program_execution.write", "resource.write"],
            "delete": ["program_execution.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("program_execution").expect("valid static worker id"),
    }]
}
