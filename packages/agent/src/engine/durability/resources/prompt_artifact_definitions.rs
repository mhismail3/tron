//! Content-safe prompt artifact resource definitions.

use serde_json::json;

use super::types::{
    EngineResourceVersioningMode, PROMPT_ARTIFACT_KIND, PROMPT_ARTIFACT_SCHEMA_ID,
    RegisterResourceType,
};
use crate::engine::kernel::ids::WorkerId;

/// Built-in resource definitions for prompt artifact metadata records.
#[must_use]
pub(crate) fn prompt_artifact_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![RegisterResourceType {
        kind: PROMPT_ARTIFACT_KIND.to_owned(),
        schema_id: PROMPT_ARTIFACT_SCHEMA_ID.to_owned(),
        schema: json!({
            "type": "object",
            "required": [
                "schemaVersion",
                "state",
                "artifactId",
                "artifactKind",
                "scope",
                "title",
                "content",
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
                "artifactId": {"type": "string"},
                "artifactKind": {"type": "string", "enum": ["history_entry", "snippet", "template", "prompt_reference"]},
                "scope": {"type": "object"},
                "title": {"type": "string"},
                "summary": {"type": "string"},
                "preview": {"type": "string"},
                "content": {"type": "object"},
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
            "content_ref",
            "evidence_for",
            "derived_from",
            "prompt_artifact_fingerprint",
            "retention_evidence",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect(),
        default_retention: json!({
            "class": "prompt_artifact_metadata",
            "maxAgeDays": 90,
            "archiveKeepsEvidence": true
        }),
        redaction_rules: json!({
            "preview": "bounded_redacted_metadata_only",
            "neverReturn": ["prompt", "promptText", "promptBody", "rawPrompt", "rawPromptBody", "body", "content", "messages", "providerPayload", "rawPayload", "snippetBody", "templateBody", "absolutePath", "workingDirectory", "blobBytes", "fileContents", "idempotencyKey"],
            "content": "refs_and_fingerprints_only"
        }),
        materialization_rules: json!({
            "durableOutputsRequireResourceVersion": true,
            "payloadStoresPromptArtifactMetadataOnly": true,
            "explicitOptIn": true,
            "automaticCapturePerformed": false,
            "rawPromptStored": false,
            "providerVisibleRawPayloadStored": false,
            "promptInjectionPerformed": false,
            "promptContextIncluded": false,
            "learnedBehaviorUpdated": false,
            "fileWritesPerformed": false,
            "networkAccessPerformed": false
        }),
        required_capabilities: json!({
            "read": ["prompt_artifacts.read", "resource.read"],
            "write": ["prompt_artifacts.write", "resource.write"],
            "delete": ["prompt_artifacts.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("prompt_artifacts").expect("valid static worker id"),
    }]
}
