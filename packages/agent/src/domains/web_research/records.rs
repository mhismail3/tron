use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::engine::{EngineResource, EngineResourceScope, EngineResourceVersion, Invocation};

use super::contract::{
    READ_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE, WEB_RESEARCH_REQUEST_SCHEMA_VERSION,
    WEB_RESEARCH_REVIEW_SCHEMA_VERSION, WEB_RESEARCH_SOURCE_SCHEMA_VERSION, WORKER, WRITE_SCOPE,
};
use super::{WEB_RESEARCH_REQUEST_KIND, WEB_RESEARCH_REVIEW_KIND, WEB_RESEARCH_SOURCE_KIND};

const REQUEST_IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str =
    "sha256:tron.web_research_request.idempotency.v1";
const REVIEW_IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str =
    "sha256:tron.web_research_review.idempotency.v1";
const SOURCE_IDEMPOTENCY_FINGERPRINT_ALGORITHM: &str =
    "sha256:tron.web_research_source.idempotency.v1";
const REQUEST_IDEMPOTENCY_FINGERPRINT_DOMAIN: &[u8] = b"tron.web_research_request.idempotency.v1\0";
const REVIEW_IDEMPOTENCY_FINGERPRINT_DOMAIN: &[u8] = b"tron.web_research_review.idempotency.v1\0";
const SOURCE_IDEMPOTENCY_FINGERPRINT_DOMAIN: &[u8] = b"tron.web_research_source.idempotency.v1\0";

pub(super) struct RequestInput<'a> {
    pub(super) request_id: &'a str,
    pub(super) state: &'a str,
    pub(super) scope: &'a EngineResourceScope,
    pub(super) title: &'a str,
    pub(super) question_summary: &'a str,
    pub(super) scope_summary: Option<&'a str>,
    pub(super) policy_labels: Vec<String>,
    pub(super) source_refs: Vec<Value>,
    pub(super) citation_refs: Vec<Value>,
    pub(super) robots_evidence_refs: Vec<Value>,
    pub(super) dependency_request_refs: Vec<Value>,
    pub(super) current_scope_refs: Vec<Value>,
    pub(super) evidence_refs: Vec<Value>,
    pub(super) created_at: &'a str,
    pub(super) updated_at: &'a str,
    pub(super) invocation: &'a Invocation,
    pub(super) idempotency_key: &'a str,
}

pub(super) fn request_record(input: RequestInput<'_>) -> Value {
    json!({
        "schemaVersion": WEB_RESEARCH_REQUEST_SCHEMA_VERSION,
        "state": input.state,
        "requestId": input.request_id,
        "scope": scope_ref(input.scope),
        "title": input.title,
        "research": {
            "questionSummary": input.question_summary,
            "scopeSummary": input.scope_summary,
            "policyLabels": input.policy_labels,
            "networkPolicy": "none",
            "browserAutomationRequested": false,
            "searchProviderIntegration": false,
            "cookieReuseRequested": false,
            "rawPageCaptureStored": false
        },
        "refs": {
            "sourceRefs": input.source_refs,
            "citationRefs": input.citation_refs,
            "robotsEvidenceRefs": input.robots_evidence_refs,
            "dependencyRequestRefs": input.dependency_request_refs,
            "currentScopeRefs": input.current_scope_refs,
            "evidenceRefs": input.evidence_refs
        },
        "traceRefs": trace_refs(input.invocation),
        "replayRefs": replay_refs(input.invocation),
        "authority": authority_record(),
        "idempotency": idempotency_evidence(
            input.idempotency_key,
            REQUEST_IDEMPOTENCY_FINGERPRINT_ALGORITHM,
            REQUEST_IDEMPOTENCY_FINGERPRINT_DOMAIN,
        ),
        "sideEffectProof": side_effect_proof(),
        "createdAt": input.created_at,
        "updatedAt": input.updated_at,
        "revision": 1
    })
}

pub(super) struct ReviewInput<'a> {
    pub(super) review_id: &'a str,
    pub(super) state: &'a str,
    pub(super) request_resource: &'a EngineResource,
    pub(super) request_version: &'a EngineResourceVersion,
    pub(super) outcome: &'a str,
    pub(super) summary: &'a str,
    pub(super) policy_labels: Vec<String>,
    pub(super) source_refs: Vec<Value>,
    pub(super) citation_refs: Vec<Value>,
    pub(super) robots_evidence_refs: Vec<Value>,
    pub(super) dependency_request_refs: Vec<Value>,
    pub(super) evidence_refs: Vec<Value>,
    pub(super) created_at: &'a str,
    pub(super) updated_at: &'a str,
    pub(super) invocation: &'a Invocation,
    pub(super) idempotency_key: &'a str,
}

pub(super) fn review_record(input: ReviewInput<'_>) -> Value {
    json!({
        "schemaVersion": WEB_RESEARCH_REVIEW_SCHEMA_VERSION,
        "state": input.state,
        "reviewId": input.review_id,
        "scope": scope_ref(&input.request_resource.scope),
        "request": version_ref(input.request_resource, input.request_version, "web_research_request"),
        "review": {
            "outcome": input.outcome,
            "summary": input.summary,
            "policyLabels": input.policy_labels,
            "networkPolicy": "none",
            "metadataOnly": true,
            "independentAcceptance": false
        },
        "refs": {
            "sourceRefs": input.source_refs,
            "citationRefs": input.citation_refs,
            "robotsEvidenceRefs": input.robots_evidence_refs,
            "dependencyRequestRefs": input.dependency_request_refs,
            "evidenceRefs": input.evidence_refs
        },
        "traceRefs": trace_refs(input.invocation),
        "replayRefs": replay_refs(input.invocation),
        "authority": authority_record(),
        "idempotency": idempotency_evidence(
            input.idempotency_key,
            REVIEW_IDEMPOTENCY_FINGERPRINT_ALGORITHM,
            REVIEW_IDEMPOTENCY_FINGERPRINT_DOMAIN,
        ),
        "sideEffectProof": side_effect_proof(),
        "createdAt": input.created_at,
        "updatedAt": input.updated_at,
        "revision": 1
    })
}

pub(super) struct SourceInput<'a> {
    pub(super) source_id: &'a str,
    pub(super) state: &'a str,
    pub(super) scope: &'a EngineResourceScope,
    pub(super) request_ref: Option<Value>,
    pub(super) review_ref: Option<Value>,
    pub(super) artifact_kind: &'a str,
    pub(super) title: &'a str,
    pub(super) summary: &'a str,
    pub(super) policy_labels: Vec<String>,
    pub(super) source_refs: Vec<Value>,
    pub(super) citation_refs: Vec<Value>,
    pub(super) robots_evidence_refs: Vec<Value>,
    pub(super) dependency_request_refs: Vec<Value>,
    pub(super) evidence_refs: Vec<Value>,
    pub(super) created_at: &'a str,
    pub(super) updated_at: &'a str,
    pub(super) invocation: &'a Invocation,
    pub(super) idempotency_key: &'a str,
}

pub(super) fn source_record(input: SourceInput<'_>) -> Value {
    json!({
        "schemaVersion": WEB_RESEARCH_SOURCE_SCHEMA_VERSION,
        "state": input.state,
        "sourceArtifactId": input.source_id,
        "scope": scope_ref(input.scope),
        "request": input.request_ref,
        "review": input.review_ref,
        "artifact": {
            "kind": input.artifact_kind,
            "title": input.title,
            "summary": input.summary,
            "policyLabels": input.policy_labels,
            "boundedSummaryOnly": true,
            "rawHtmlStored": false,
            "pageDumpStored": false,
            "browserLogsStored": false,
            "cookiesStored": false,
            "networkPolicy": "none"
        },
        "refs": {
            "sourceRefs": input.source_refs,
            "citationRefs": input.citation_refs,
            "robotsEvidenceRefs": input.robots_evidence_refs,
            "dependencyRequestRefs": input.dependency_request_refs,
            "evidenceRefs": input.evidence_refs
        },
        "traceRefs": trace_refs(input.invocation),
        "replayRefs": replay_refs(input.invocation),
        "authority": authority_record(),
        "idempotency": idempotency_evidence(
            input.idempotency_key,
            SOURCE_IDEMPOTENCY_FINGERPRINT_ALGORITHM,
            SOURCE_IDEMPOTENCY_FINGERPRINT_DOMAIN,
        ),
        "sideEffectProof": side_effect_proof(),
        "createdAt": input.created_at,
        "updatedAt": input.updated_at,
        "revision": 1
    })
}

pub(super) fn request_resource_id(
    scope: &EngineResourceScope,
    request_id: &str,
    idempotency_key: &str,
) -> String {
    stable_resource_id(
        WEB_RESEARCH_REQUEST_KIND,
        scope,
        request_id,
        idempotency_key,
    )
}

pub(super) fn review_resource_id(
    scope: &EngineResourceScope,
    review_id: &str,
    request_resource_id: &str,
    idempotency_key: &str,
) -> String {
    stable_resource_id(
        WEB_RESEARCH_REVIEW_KIND,
        scope,
        &format!("{review_id}:{request_resource_id}"),
        idempotency_key,
    )
}

pub(super) fn source_resource_id(
    scope: &EngineResourceScope,
    source_id: &str,
    parent_resource_id: &str,
    idempotency_key: &str,
) -> String {
    stable_resource_id(
        WEB_RESEARCH_SOURCE_KIND,
        scope,
        &format!("{source_id}:{parent_resource_id}"),
        idempotency_key,
    )
}

fn stable_resource_id(
    kind: &str,
    scope: &EngineResourceScope,
    visible_id: &str,
    idempotency_key: &str,
) -> String {
    let mut hasher = Sha256::new();
    hasher.update(scope.kind().as_bytes());
    hasher.update(b":");
    hasher.update(scope.value().as_bytes());
    hasher.update(b":");
    hasher.update(visible_id.as_bytes());
    hasher.update(b":");
    hasher.update(idempotency_key.as_bytes());
    format!("{kind}:{}", hex::encode(hasher.finalize()))
}

fn idempotency_evidence(idempotency_key: &str, algorithm: &str, domain: &[u8]) -> Value {
    json!({
        "fingerprint": idempotency_fingerprint(idempotency_key, domain),
        "fingerprintAlgorithm": algorithm,
        "keyRedacted": true,
        "rawKeyStored": false
    })
}

fn idempotency_fingerprint(idempotency_key: &str, domain: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(domain);
    hasher.update(idempotency_key.as_bytes());
    hex::encode(hasher.finalize())
}

pub(super) fn resource_policy(kind: &str) -> Value {
    json!({
        "owner": WORKER,
        "kind": kind,
        "authority": WRITE_SCOPE,
        "retention": "explicit",
        "metadataOnly": true,
        "researchCustody": "summary_and_refs_only",
        "browserAutomation": "forbidden",
        "searchProviderIntegration": "forbidden",
        "cookieReuse": "forbidden",
        "rawPageCapture": "forbidden",
        "execution": "forbidden",
        "networkPolicy": "none"
    })
}

fn authority_record() -> Value {
    json!({
        "grantRedacted": true,
        "rawAuthorityIdsStored": false,
        "derivedRuntimeGrantRequired": true,
        "requiredScopes": [READ_SCOPE, WRITE_SCOPE, RESOURCE_READ_SCOPE, RESOURCE_WRITE_SCOPE],
        "resourceKinds": [
            WEB_RESEARCH_REQUEST_KIND,
            WEB_RESEARCH_REVIEW_KIND,
            WEB_RESEARCH_SOURCE_KIND
        ],
        "wildcardGrantsAllowed": false
    })
}

pub(super) fn side_effect_proof() -> Value {
    json!({
        "metadataOnly": true,
        "networkPolicy": "none",
        "networkAccessPerformed": false,
        "browserAutomationPerformed": false,
        "searchPerformed": false,
        "crawlPerformed": false,
        "loginOrCookieReusePerformed": false,
        "rawHtmlStored": false,
        "pageDumpStored": false,
        "browserLogsStored": false,
        "cookiesStored": false,
        "credentialsStored": false,
        "rawLocalPathsStored": false,
        "rawCommandsStored": false,
        "rawCodeOrFileContentsStored": false,
        "rawGrantIdsStored": false,
        "rawAuthorityIdsStored": false,
        "packageManagerOutputStored": false,
        "rawDependencyArtifactsStored": false
    })
}

pub(super) fn scope_ref(scope: &EngineResourceScope) -> Value {
    json!({
        "kind": scope.kind(),
        "value": scope.value(),
    })
}

pub(super) fn resource_ref(resource: &EngineResource, role: &str) -> Value {
    json!({
        "kind": resource.kind,
        "resourceId": resource.resource_id,
        "role": role,
        "schemaId": resource.schema_id,
        "lifecycle": resource.lifecycle,
        "currentVersionId": resource.current_version_id,
    })
}

pub(super) fn version_ref(
    resource: &EngineResource,
    version: &EngineResourceVersion,
    role: &str,
) -> Value {
    json!({
        "kind": resource.kind,
        "resourceId": resource.resource_id,
        "role": role,
        "schemaId": resource.schema_id,
        "lifecycle": resource.lifecycle,
        "versionId": version.version_id,
        "payloadHash": version.content_hash,
    })
}

fn trace_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({
        "kind": "trace",
        "resourceId": invocation.causal_context.trace_id.as_str(),
        "role": "web_research_trace",
        "storedRawPayload": false
    })]
}

fn replay_refs(invocation: &Invocation) -> Vec<Value> {
    vec![json!({
        "kind": "replay",
        "resourceId": invocation.id.as_str(),
        "role": "web_research_replay",
        "idempotent": true,
        "storedRawPayload": false
    })]
}
