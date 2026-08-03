//! Closed worker-to-client artifact delivery admission.
//!
//! A worker may name only bytes inside its own validated result. The engine
//! decodes and verifies those bytes before invocation completion, then gives
//! them durable content-addressed custody in the same transaction as the
//! canonical result. Filesystem paths, URLs, client commands, and draft
//! mutations are intentionally absent.

use std::collections::BTreeSet;

use base64::Engine;
use serde::Deserialize;
use serde_json::Value;

use super::types::{WorkerBundle, WorkerClientDelivery};

pub(super) const MAX_ARTIFACTS_PER_INVOCATION: usize = 8;
pub(super) const MAX_ARTIFACT_CONTENT_BYTES: usize = 2 * 1_048_576;

const ALLOWED_MEDIA_TYPES: &[&str] = &[
    "application/json",
    "application/pdf",
    "application/rtf",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "image/gif",
    "image/heic",
    "image/jpeg",
    "image/png",
    "image/webp",
    "text/csv",
    "text/markdown",
    "text/plain",
];

/// One validated, self-referenced artifact awaiting transactional custody.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct ArtifactIntent {
    pub(super) artifact_id: String,
    pub(super) display_name: String,
    pub(super) media_type: String,
    pub(super) size_bytes: usize,
    pub(super) content_pointer: String,
    pub(super) content: Vec<u8>,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct ArtifactDeliveriesRequest {
    #[serde(default = "default_artifact_limit")]
    pub(super) limit: usize,
    #[serde(default)]
    pub(super) offset: usize,
}

fn default_artifact_limit() -> usize {
    100
}

#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct ArtifactIdentityRequest {
    pub(super) worker_id: String,
    pub(super) artifact_id: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RawArtifactDelivery {
    artifact_id: String,
    display_name: String,
    media_type: String,
    size_bytes: usize,
    content_reference: RawArtifactContentReference,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RawArtifactContentReference {
    kind: String,
    invocation_id: String,
    pointer: String,
    encoding: String,
}

/// Parse the reserved artifact output only for a declaring immutable bundle.
pub(super) fn artifact_intents_for_bundle(
    bundle: &WorkerBundle,
    invocation_id: &str,
    output: &Value,
) -> Result<Vec<ArtifactIntent>, String> {
    let declared = bundle
        .client_deliveries
        .contains(&WorkerClientDelivery::ArtifactDelivery);
    if !declared {
        if output.get("artifactDeliveries").is_some() {
            return Err(
                "worker output uses reserved artifactDeliveries without declaring clientDeliveries artifact_delivery"
                    .to_owned(),
            );
        }
        return Ok(Vec::new());
    }
    let Some(raw) = output.get("artifactDeliveries") else {
        return Ok(Vec::new());
    };
    let deliveries = raw
        .as_array()
        .ok_or_else(|| "artifactDeliveries must be an array".to_owned())?;
    if deliveries.len() > MAX_ARTIFACTS_PER_INVOCATION {
        return Err(format!(
            "artifactDeliveries may contain at most {MAX_ARTIFACTS_PER_INVOCATION} items"
        ));
    }

    let mut artifact_ids = BTreeSet::new();
    let mut total_bytes = 0usize;
    let mut intents = Vec::with_capacity(deliveries.len());
    for (index, value) in deliveries.iter().enumerate() {
        let raw: RawArtifactDelivery = serde_json::from_value(value.clone())
            .map_err(|error| format!("artifactDeliveries[{index}] is invalid: {error}"))?;
        validate_artifact_id(&raw.artifact_id, index)?;
        if !artifact_ids.insert(raw.artifact_id.clone()) {
            return Err(format!(
                "artifactDeliveries[{index}].artifactId must be unique within one invocation"
            ));
        }
        validate_display_name(&raw.display_name, index)?;
        if !ALLOWED_MEDIA_TYPES.contains(&raw.media_type.as_str()) {
            return Err(format!(
                "artifactDeliveries[{index}].mediaType is not in the closed artifact allowlist"
            ));
        }
        if raw.size_bytes == 0 || raw.size_bytes > MAX_ARTIFACT_CONTENT_BYTES {
            return Err(format!(
                "artifactDeliveries[{index}].sizeBytes must be between 1 and {MAX_ARTIFACT_CONTENT_BYTES}"
            ));
        }
        if raw.content_reference.kind != "worker_result_reference"
            || raw.content_reference.encoding != "base64"
        {
            return Err(format!(
                "artifactDeliveries[{index}].contentReference must be a base64 worker_result_reference"
            ));
        }
        if raw.content_reference.invocation_id != invocation_id {
            return Err(format!(
                "artifactDeliveries[{index}].contentReference must name the current invocation"
            ));
        }
        validate_json_pointer(&raw.content_reference.pointer, index)?;
        let encoded = output
            .pointer(&raw.content_reference.pointer)
            .and_then(Value::as_str)
            .ok_or_else(|| {
                format!(
                    "artifactDeliveries[{index}].contentReference pointer must resolve to a base64 string"
                )
            })?;
        let content = base64::engine::general_purpose::STANDARD
            .decode(encoded)
            .map_err(|_| {
                format!(
                    "artifactDeliveries[{index}].contentReference does not resolve to valid base64"
                )
            })?;
        if content.len() != raw.size_bytes {
            return Err(format!(
                "artifactDeliveries[{index}].sizeBytes does not match decoded content"
            ));
        }
        total_bytes = total_bytes
            .checked_add(content.len())
            .ok_or_else(|| "artifactDeliveries decoded size overflowed".to_owned())?;
        if total_bytes > MAX_ARTIFACT_CONTENT_BYTES {
            return Err(format!(
                "artifactDeliveries decoded content must total at most {MAX_ARTIFACT_CONTENT_BYTES} bytes"
            ));
        }
        intents.push(ArtifactIntent {
            artifact_id: raw.artifact_id,
            display_name: raw.display_name,
            media_type: raw.media_type,
            size_bytes: raw.size_bytes,
            content_pointer: raw.content_reference.pointer,
            content,
        });
    }
    Ok(intents)
}

fn validate_artifact_id(value: &str, index: usize) -> Result<(), String> {
    if value.is_empty()
        || value.len() > 128
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b':'))
    {
        return Err(format!(
            "artifactDeliveries[{index}].artifactId must be 1..128 ASCII identifier bytes"
        ));
    }
    Ok(())
}

fn validate_display_name(value: &str, index: usize) -> Result<(), String> {
    if value.is_empty()
        || value.len() > 160
        || value == "."
        || value == ".."
        || value
            .chars()
            .any(|character| character.is_control() || matches!(character, '/' | '\\' | '\0'))
    {
        return Err(format!(
            "artifactDeliveries[{index}].displayName must be a safe 1..160 byte file name"
        ));
    }
    Ok(())
}

fn validate_json_pointer(pointer: &str, index: usize) -> Result<(), String> {
    if pointer.is_empty() {
        return Err(format!(
            "artifactDeliveries[{index}].contentReference.pointer must not select the complete result"
        ));
    }
    if pointer.len() > 256 || !pointer.starts_with('/') {
        return Err(format!(
            "artifactDeliveries[{index}].contentReference.pointer must be an RFC 6901 pointer of at most 256 bytes"
        ));
    }
    let bytes = pointer.as_bytes();
    let mut position = 0;
    while position < bytes.len() {
        if bytes[position] == b'~' {
            if position + 1 >= bytes.len() || !matches!(bytes[position + 1], b'0' | b'1') {
                return Err(format!(
                    "artifactDeliveries[{index}].contentReference.pointer contains an invalid RFC 6901 escape"
                ));
            }
            position += 2;
        } else {
            position += 1;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn bundle() -> WorkerBundle {
        serde_json::from_value(json!({
            "schemaVersion":"tron.worker_bundle.v1",
            "workerId":"document-artifact",
            "name":"Document Artifact",
            "description":"Create one document",
            "modelExposure":"internal",
            "inputSchema":{"type":"object"},
            "outputSchema":{
                "type":"object",
                "properties":{"artifactDeliveries":{"type":"array"}}
            },
            "runner":{"kind":"command","command":["python3","worker.py"]},
            "provenance":[{"source":"test:artifact"}],
            "clientDeliveries":["artifact_delivery"]
        }))
        .expect("bundle")
    }

    #[test]
    fn self_result_reference_decodes_exact_bytes() {
        let bundle = bundle();
        let output = json!({
            "document":{"data":"aGVsbG8="},
            "artifactDeliveries":[{
                "artifactId":"report-1",
                "displayName":"report.md",
                "mediaType":"text/markdown",
                "sizeBytes":5,
                "contentReference":{
                    "kind":"worker_result_reference",
                    "invocationId":"worker_run_1",
                    "pointer":"/document/data",
                    "encoding":"base64"
                }
            }]
        });
        let parsed =
            artifact_intents_for_bundle(&bundle, "worker_run_1", &output).expect("artifact");
        assert_eq!(parsed[0].content, b"hello");
    }

    #[test]
    fn external_result_url_and_active_content_are_rejected() {
        let bundle = bundle();
        for delivery in [
            json!({
                "artifactId":"report-1","displayName":"report.md",
                "mediaType":"text/markdown","sizeBytes":5,
                "contentReference":{"url":"https://example.com/report.md"}
            }),
            json!({
                "artifactId":"report-1","displayName":"report.html",
                "mediaType":"text/html","sizeBytes":5,
                "contentReference":{
                    "kind":"worker_result_reference","invocationId":"worker_run_1",
                    "pointer":"/document/data","encoding":"base64"
                }
            }),
        ] {
            let output = json!({
                "document":{"data":"aGVsbG8="},
                "artifactDeliveries":[delivery]
            });
            assert!(artifact_intents_for_bundle(&bundle, "worker_run_1", &output).is_err());
        }
    }
}
