//! System update diagnostics resource definitions.

use serde_json::json;

use super::types::{
    EngineResourceVersioningMode, RegisterResourceType, UPDATE_DIAGNOSTIC_RECORD_KIND,
    UPDATE_DIAGNOSTIC_RECORD_SCHEMA_ID,
};
use crate::engine::kernel::ids::WorkerId;

/// Built-in resource definitions for signed-release/update diagnostic metadata.
#[must_use]
pub(crate) fn update_diagnostics_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![RegisterResourceType {
        kind: UPDATE_DIAGNOSTIC_RECORD_KIND.to_owned(),
        schema_id: UPDATE_DIAGNOSTIC_RECORD_SCHEMA_ID.to_owned(),
        schema: json!({
            "type": "object",
            "required": [
                "schemaVersion",
                "state",
                "diagnosticId",
                "checkKind",
                "scope",
                "release",
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
                "diagnosticId": {"type": "string"},
                "checkKind": {"type": "string", "enum": ["metadata_snapshot"]},
                "scope": {"type": "object"},
                "release": {"type": "object"},
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
            "evidence_for",
            "provenance",
            "signature",
            "derived_from",
            "diagnostic_for",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect(),
        default_retention: json!({
            "class": "update_diagnostic_metadata",
            "maxAgeDays": 90,
            "archiveKeepsEvidence": true
        }),
        redaction_rules: json!({
            "preview": "signed_release_metadata_only",
            "neverReturn": [
                "rawUpdatePayload",
                "packageBytes",
                "installerBytes",
                "productionEndpoint",
                "downloadUrl",
                "installCommand",
                "restartCommand",
                "deployCommand"
            ],
            "provenance": "bounded_refs_only"
        }),
        materialization_rules: json!({
            "durableOutputsRequireResourceVersion": true,
            "payloadStoresSignedReleaseMetadataOnly": true,
            "liveNetworkCheckPerformed": false,
            "installOrRestartExecuted": false,
            "deployAutomationStored": false,
            "packageBytesStored": false
        }),
        required_capabilities: json!({
            "read": ["update_diagnostics.read", "resource.read"],
            "write": ["update_diagnostics.write", "resource.write"],
            "delete": ["update_diagnostics.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("update_diagnostics").expect("valid static worker id"),
    }]
}
