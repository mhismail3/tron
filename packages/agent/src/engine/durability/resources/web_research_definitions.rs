//! Web research request, review, and source-artifact resource definitions.
//!
//! These resources store bounded metadata and refs only. They do not perform
//! browser automation, search, crawling, login/cookie reuse, raw page capture,
//! runtime execution, or network access.

use serde_json::json;

use super::types::{
    EngineResourceVersioningMode, RegisterResourceType, WEB_RESEARCH_REQUEST_KIND,
    WEB_RESEARCH_REQUEST_SCHEMA_ID, WEB_RESEARCH_REVIEW_KIND, WEB_RESEARCH_REVIEW_SCHEMA_ID,
    WEB_RESEARCH_SOURCE_KIND, WEB_RESEARCH_SOURCE_SCHEMA_ID,
};
use crate::engine::kernel::ids::WorkerId;

pub(crate) const WEB_RESEARCH_REQUEST_PAYLOAD_SCHEMA_VERSION: &str = "tron.web_research_request.v1";
pub(crate) const WEB_RESEARCH_REVIEW_PAYLOAD_SCHEMA_VERSION: &str = "tron.web_research_review.v1";
pub(crate) const WEB_RESEARCH_SOURCE_PAYLOAD_SCHEMA_VERSION: &str = "tron.web_research_source.v1";

pub(super) fn web_research_resource_type_definitions() -> Vec<RegisterResourceType> {
    vec![
        web_research_request_definition(),
        web_research_review_definition(),
        web_research_source_definition(),
    ]
}

fn web_research_request_definition() -> RegisterResourceType {
    definition(
        WEB_RESEARCH_REQUEST_KIND,
        WEB_RESEARCH_REQUEST_SCHEMA_ID,
        WEB_RESEARCH_REQUEST_PAYLOAD_SCHEMA_VERSION,
        ["pending_review", "superseded", "archived"].as_slice(),
        [
            "web_research_request",
            "source_ref",
            "citation_ref",
            "robots_evidence",
            "dependency_request",
            "current_scope",
            "evidence_for",
            "derived_from",
            "supersedes",
        ]
        .as_slice(),
        json!({
            "required": [
                "schemaVersion", "state", "requestId", "scope", "title",
                "research", "refs", "traceRefs", "replayRefs", "authority",
                "idempotency", "sideEffectProof", "createdAt", "updatedAt",
                "revision"
            ],
            "properties": {
                "requestId": {"type": "string"},
                "title": {"type": "string"},
                "research": {"type": "object"},
                "refs": {"type": "object"}
            }
        }),
    )
}

fn web_research_review_definition() -> RegisterResourceType {
    definition(
        WEB_RESEARCH_REVIEW_KIND,
        WEB_RESEARCH_REVIEW_SCHEMA_ID,
        WEB_RESEARCH_REVIEW_PAYLOAD_SCHEMA_VERSION,
        ["pending_review", "accepted", "rejected", "archived"].as_slice(),
        [
            "review_for",
            "web_research_request",
            "source_ref",
            "citation_ref",
            "robots_evidence",
            "dependency_request",
            "evidence_for",
            "derived_from",
            "supersedes",
        ]
        .as_slice(),
        json!({
            "required": [
                "schemaVersion", "state", "reviewId", "scope", "request",
                "review", "refs", "traceRefs", "replayRefs", "authority",
                "idempotency", "sideEffectProof", "createdAt", "updatedAt",
                "revision"
            ],
            "properties": {
                "reviewId": {"type": "string"},
                "request": {"type": "object"},
                "review": {"type": "object"},
                "refs": {"type": "object"}
            }
        }),
    )
}

fn web_research_source_definition() -> RegisterResourceType {
    definition(
        WEB_RESEARCH_SOURCE_KIND,
        WEB_RESEARCH_SOURCE_SCHEMA_ID,
        WEB_RESEARCH_SOURCE_PAYLOAD_SCHEMA_VERSION,
        ["available", "superseded", "archived"].as_slice(),
        [
            "artifact_for",
            "web_research_request",
            "web_research_review",
            "source_ref",
            "citation_ref",
            "robots_evidence",
            "dependency_request",
            "evidence_for",
            "derived_from",
            "supersedes",
        ]
        .as_slice(),
        json!({
            "required": [
                "schemaVersion", "state", "sourceArtifactId", "scope",
                "artifact", "refs", "traceRefs", "replayRefs", "authority",
                "idempotency", "sideEffectProof", "createdAt", "updatedAt",
                "revision"
            ],
            "properties": {
                "sourceArtifactId": {"type": "string"},
                "request": {"type": ["object", "null"]},
                "review": {"type": ["object", "null"]},
                "artifact": {"type": "object"},
                "refs": {"type": "object"}
            }
        }),
    )
}

fn definition(
    kind: &str,
    schema_id: &str,
    payload_schema_version: &str,
    lifecycle_states: &[&str],
    link_relations: &[&str],
    payload_contract: serde_json::Value,
) -> RegisterResourceType {
    RegisterResourceType {
        kind: kind.to_owned(),
        schema_id: schema_id.to_owned(),
        schema: json!({
            "type": "object",
            "required": [
                "schemaVersion",
                "state",
                "scope",
                "traceRefs",
                "replayRefs",
                "authority",
                "idempotency",
                "sideEffectProof",
                "createdAt",
                "updatedAt",
                "revision"
            ],
            "additionalProperties": true,
            "properties": {
                "schemaVersion": {"type": "string", "const": payload_schema_version},
                "state": {"type": "string", "enum": lifecycle_states},
                "scope": {"type": "object"},
                "traceRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                "replayRefs": {"type": "array", "maxItems": 25, "items": {"type": "object"}},
                "authority": {"type": "object"},
                "idempotency": {"type": "object"},
                "sideEffectProof": {
                    "type": "object",
                    "required": [
                        "metadataOnly",
                        "networkPolicy",
                        "networkAccessPerformed",
                        "browserAutomationPerformed",
                        "searchPerformed",
                        "crawlPerformed",
                        "loginOrCookieReusePerformed",
                        "rawHtmlStored",
                        "pageDumpStored",
                        "browserLogsStored",
                        "cookiesStored",
                        "credentialsStored"
                    ],
                    "properties": {
                        "metadataOnly": {"type": "boolean", "const": true},
                        "networkPolicy": {"type": "string", "const": "none"},
                        "networkAccessPerformed": {"type": "boolean", "const": false},
                        "browserAutomationPerformed": {"type": "boolean", "const": false},
                        "searchPerformed": {"type": "boolean", "const": false},
                        "crawlPerformed": {"type": "boolean", "const": false},
                        "loginOrCookieReusePerformed": {"type": "boolean", "const": false},
                        "rawHtmlStored": {"type": "boolean", "const": false},
                        "pageDumpStored": {"type": "boolean", "const": false},
                        "browserLogsStored": {"type": "boolean", "const": false},
                        "cookiesStored": {"type": "boolean", "const": false},
                        "credentialsStored": {"type": "boolean", "const": false}
                    }
                },
                "createdAt": {"type": "string"},
                "updatedAt": {"type": "string"},
                "revision": {"type": "integer"}
            },
            "payloadContract": payload_contract
        }),
        lifecycle_states: lifecycle_states
            .iter()
            .map(|state| (*state).to_owned())
            .collect(),
        versioning_mode: EngineResourceVersioningMode::AppendOnly,
        allowed_link_relations: link_relations
            .iter()
            .map(|relation| (*relation).to_owned())
            .collect(),
        default_retention: json!({"class": "web_research_metadata", "metadataOnly": true}),
        redaction_rules: json!({
            "projection": "provider_safe",
            "rawHtml": "forbidden",
            "pageDumps": "forbidden",
            "browserLogs": "forbidden",
            "cookies": "forbidden",
            "credentials": "forbidden",
            "localPaths": "forbidden",
            "commands": "forbidden",
            "codeOrFileContents": "forbidden",
            "grantIds": "forbidden",
            "authorityIds": "forbidden",
            "tokenLikeMaterial": "forbidden",
            "personalInfoLiterals": "forbidden"
        }),
        materialization_rules: json!({
            "durableOutputsRequireResourceVersion": true,
            "browserAutomation": "forbidden",
            "search": "forbidden",
            "crawl": "forbidden",
            "loginOrCookieReuse": "forbidden",
            "networkPolicy": "none"
        }),
        required_capabilities: json!({
            "read": ["web_research.read", "resource.read"],
            "write": ["web_research.write", "resource.write"]
        }),
        owner_worker_id: WorkerId::new("web_research").expect("valid static worker id"),
    }
}
