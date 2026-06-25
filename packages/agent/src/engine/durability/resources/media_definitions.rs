//! Media and voice-note resource definitions.

use serde_json::json;

use super::types::{
    EngineResourceVersioningMode, MEDIA_ARTIFACT_KIND, MEDIA_ARTIFACT_SCHEMA_ID,
    RegisterResourceType,
};
use crate::engine::kernel::ids::WorkerId;

/// Built-in resource definitions for media artifacts and voice notes.
#[must_use]
pub(crate) fn media_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![RegisterResourceType {
        kind: MEDIA_ARTIFACT_KIND.to_owned(),
        schema_id: MEDIA_ARTIFACT_SCHEMA_ID.to_owned(),
        schema: json!({
            "type": "object",
            "required": [
                "schemaVersion",
                "state",
                "mediaId",
                "mediaKind",
                "mimeType",
                "sizeBytes",
                "storage",
                "scope",
                "createdAt",
                "updatedAt",
                "retention",
                "transcription",
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
                "mediaId": {"type": "string"},
                "mediaKind": {"type": "string", "enum": ["voice_note", "audio", "image", "document"]},
                "mimeType": {"type": "string"},
                "sizeBytes": {"type": "integer", "minimum": 1},
                "title": {"type": "string"},
                "summary": {"type": "string"},
                "durationMs": {"type": "integer", "minimum": 0},
                "storage": {
                    "type": "object",
                    "required": [
                        "blobRef",
                        "storageClass",
                        "rawBytesStoredInResource",
                        "providerVisibleRawAudio"
                    ],
                    "properties": {
                        "blobRef": {"type": "string"},
                        "contentHash": {"type": "string"},
                        "storageClass": {"type": "string"},
                        "rawBytesStoredInResource": {"type": "boolean"},
                        "providerVisibleRawAudio": {"type": "boolean"}
                    }
                },
                "scope": {"type": "object"},
                "createdAt": {"type": "string"},
                "updatedAt": {"type": "string"},
                "archivedAt": {"type": ["string", "null"]},
                "retention": {"type": "object"},
                "transcription": {"type": "object"},
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
            "derived_from",
            "transcription_of",
            "attached_to",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect(),
        default_retention: json!({
            "class": "user_media",
            "maxAgeDays": 90,
            "archiveKeepsEvidence": true
        }),
        redaction_rules: json!({
            "preview": "metadata_only",
            "neverReturn": ["rawAudio", "audioBase64", "data", "bytes"],
            "transcription": "bounded_preview"
        }),
        materialization_rules: json!({
            "durableOutputsRequireResourceVersion": true,
            "payloadStoresBlobRefsOnly": true,
            "rawAudioProviderProjection": "forbidden_without_explicit_resource_authorization"
        }),
        required_capabilities: json!({
            "read": ["media.read", "resource.read"],
            "write": ["media.write", "resource.write"],
            "delete": ["media.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("media").expect("valid static worker id"),
    }]
}
