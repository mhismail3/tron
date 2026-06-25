//! Web-owned built-in resource definitions.

use serde_json::json;

use super::types::{
    EngineResourceVersioningMode, RegisterResourceType, WEB_ROBOTS_POLICY_KIND,
    WEB_ROBOTS_POLICY_SCHEMA_ID, WEB_SOURCE_KIND, WEB_SOURCE_SCHEMA_ID,
};
use crate::engine::kernel::ids::WorkerId;

pub(super) fn web_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![web_source_definition(), web_robots_policy_definition()]
}

fn web_source_definition() -> RegisterResourceType {
    RegisterResourceType {
        kind: WEB_SOURCE_KIND.to_owned(),
        schema_id: WEB_SOURCE_SCHEMA_ID.to_owned(),
        schema: json!({
            "type": "object",
            "required": [
                "schemaVersion",
                "operation",
                "state",
                "requestedUrl",
                "finalUrl",
                "fetchedAt",
                "status",
                "contentType",
                "byteEvidence",
                "textEvidence",
                "redaction",
                "authority",
                "traceRefs",
                "replayRefs",
                "cache",
                "idempotency",
                "revision"
            ],
            "additionalProperties": true,
            "properties": {
                "schemaVersion": {"type": "string"},
                "operation": {"type": "string", "enum": ["web_fetch"]},
                "state": {"type": "string", "enum": ["fetched", "archived"]},
                "requestedUrl": {"type": "string"},
                "finalUrl": {"type": "string"},
                "fetchedAt": {"type": "string"},
                "status": {"type": "integer"},
                "contentType": {"type": ["string", "null"]},
                "byteEvidence": {"type": "object"},
                "textEvidence": {
                    "type": "object",
                    "additionalProperties": true,
                    "properties": {
                        "preview": {"type": "string"},
                        "textBytes": {"type": "integer"},
                        "maxOutputBytes": {"type": "integer"},
                        "outputTextTruncated": {"type": "boolean"},
                        "binaryBodyOmitted": {"type": "boolean"},
                        "extractionMode": {"type": "string"},
                        "extractorId": {"type": "string"},
                        "extractorVersion": {"type": "string"},
                        "title": {"type": ["string", "null"]},
                        "extractedTextBytes": {"type": "integer"},
                        "extractedTextTruncated": {"type": "boolean"}
                    }
                },
                "redaction": {"type": "object"},
                "redirects": {"type": "object"},
                "robotsPolicyRefs": {"type": "array"},
                "authority": {"type": "object"},
                "traceRefs": {"type": "array"},
                "replayRefs": {"type": "array"},
                "cache": {"type": "object"},
                "idempotency": {"type": "object"},
                "revision": {"type": "integer"}
            }
        }),
        lifecycle_states: ["fetched", "archived"]
            .into_iter()
            .map(str::to_owned)
            .collect(),
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        allowed_link_relations: ["evidence_for", "derived_from", "supersedes"]
            .into_iter()
            .map(str::to_owned)
            .collect(),
        default_retention: json!({"class": "source_provenance"}),
        redaction_rules: json!({"preview": "bounded_redacted_text_only"}),
        materialization_rules: json!({"durableOutputsRequireResourceVersion": true}),
        required_capabilities: json!({
            "read": ["web.read", "resource.read"],
            "write": ["web.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("resource").expect("valid static worker id"),
    }
}

fn web_robots_policy_definition() -> RegisterResourceType {
    RegisterResourceType {
        kind: WEB_ROBOTS_POLICY_KIND.to_owned(),
        schema_id: WEB_ROBOTS_POLICY_SCHEMA_ID.to_owned(),
        schema: json!({
            "type": "object",
            "required": [
                "schemaVersion",
                "operation",
                "state",
                "origin",
                "targetUrl",
                "robotsUrl",
                "fetchedAt",
                "status",
                "bodyEvidence",
                "parser",
                "policy",
                "sitemaps",
                "authority",
                "traceRefs",
                "replayRefs",
                "cache",
                "idempotency",
                "revision"
            ],
            "additionalProperties": true,
            "properties": {
                "schemaVersion": {"type": "string"},
                "operation": {"type": "string", "enum": ["web_robots_check"]},
                "state": {"type": "string", "enum": ["checked"]},
                "origin": {"type": "string"},
                "targetUrl": {"type": "string"},
                "targetUrlFingerprint": {"type": "object"},
                "robotsUrl": {"type": "string"},
                "finalRobotsUrl": {"type": "string"},
                "fetchedAt": {"type": "string"},
                "status": {"type": "integer"},
                "missing": {"type": "boolean"},
                "bodyEvidence": {"type": "object"},
                "parser": {"type": "object"},
                "policy": {"type": "object"},
                "sitemaps": {"type": "object"},
                "boundedBody": {"type": "object"},
                "redirects": {"type": "object"},
                "authority": {"type": "object"},
                "traceRefs": {"type": "array"},
                "replayRefs": {"type": "array"},
                "cache": {"type": "object"},
                "idempotency": {"type": "object"},
                "revision": {"type": "integer"}
            }
        }),
        lifecycle_states: ["checked"].into_iter().map(str::to_owned).collect(),
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        allowed_link_relations: ["evidence_for", "derived_from", "supersedes"]
            .into_iter()
            .map(str::to_owned)
            .collect(),
        default_retention: json!({"class": "robots_policy_evidence"}),
        redaction_rules: json!({"preview": "bounded_redacted_text_only"}),
        materialization_rules: json!({"durableOutputsRequireResourceVersion": true}),
        required_capabilities: json!({
            "read": ["web.read", "resource.read"],
            "write": ["web.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("resource").expect("valid static worker id"),
    }
}
