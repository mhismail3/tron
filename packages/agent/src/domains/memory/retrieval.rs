use chrono::Utc;
use serde_json::{Map, Value, json};

use crate::engine::{EngineHostHandle, Invocation, ListResources};
use crate::shared::protocol::memory::{
    MEMORY_SCHEMA_VERSION, MemoryMode, MemoryPolicyRecord, MemoryRecord,
};
use crate::shared::server::errors::CapabilityError;

use super::MEMORY_RECORD_KIND;
use super::errors::{engine_error, invalid_params};
use super::query_decision_validation::{bounded_string, validate_bounded_metadata};
use super::support::{
    current_payload, ensure_provider_safe_text, provider_safe_optional_string, resource_ref,
    resource_scope,
};

pub(super) const RETRIEVAL_ALGORITHM: &str = "deterministic_resource_backed_preview_retrieval_v1";
const MAX_QUERY_TERMS: usize = 8;
const MAX_RETRIEVAL_LIMIT: usize = 50;
const MAX_PROMPT_SNIPPETS: usize = 5;
const DEFAULT_PROMPT_SNIPPETS: usize = 3;
const DEFAULT_SNIPPET_BYTES: usize = 160;
const MAX_SNIPPET_BYTES: usize = 512;

pub(super) struct RetrievalEvidence {
    pub(super) selected_refs: Vec<crate::shared::protocol::memory::MemoryResourceRef>,
    pub(super) excluded_refs: Vec<crate::shared::protocol::memory::MemoryResourceRef>,
    pub(super) results: Vec<Value>,
    pub(super) retrieval: Value,
}

pub(super) struct PromptSnippetPolicy {
    pub(super) enabled: bool,
    pub(super) max_snippets: usize,
    pub(super) max_snippet_bytes: usize,
    pub(super) reason: String,
    pub(super) evidence: Value,
}

pub(super) fn query_terms_from_payload(payload: &Value) -> Result<Vec<String>, CapabilityError> {
    let Some(terms) = payload
        .get("retrieval")
        .and_then(|retrieval| retrieval.get("terms"))
    else {
        return Ok(Vec::new());
    };
    let terms = terms
        .as_array()
        .ok_or_else(|| invalid_params("retrieval.terms must be an array"))?;
    if terms.len() > MAX_QUERY_TERMS {
        return Err(invalid_params("retrieval.terms has too many entries"));
    }
    terms
        .iter()
        .map(|term| {
            let value = term
                .as_str()
                .ok_or_else(|| invalid_params("retrieval.terms entries must be strings"))?;
            let value = bounded_string(value, "retrieval.terms")?;
            ensure_provider_safe_text(&value, "retrieval.terms")?;
            Ok(value.to_ascii_lowercase())
        })
        .collect()
}

pub(super) fn retrieval_requested(payload: &Value) -> bool {
    payload.get("retrieval").is_some()
}

pub(super) fn retrieval_limit(payload: &Value) -> usize {
    payload
        .get("retrieval")
        .and_then(|retrieval| retrieval.get("limit"))
        .and_then(Value::as_u64)
        .unwrap_or(10)
        .clamp(1, MAX_RETRIEVAL_LIMIT as u64) as usize
}

pub(super) fn retrieval_snippet_bytes(payload: &Value) -> usize {
    payload
        .get("retrieval")
        .and_then(|retrieval| retrieval.get("maxSnippetBytes"))
        .and_then(Value::as_u64)
        .unwrap_or(DEFAULT_SNIPPET_BYTES as u64)
        .clamp(40, MAX_SNIPPET_BYTES as u64) as usize
}

pub(super) async fn retrieve_memory_records(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    policy: &MemoryPolicyRecord,
    terms: &[String],
    limit: usize,
    max_snippet_bytes: usize,
) -> Result<RetrievalEvidence, CapabilityError> {
    let resources = engine_host
        .list_resources(ListResources {
            kind: Some(MEMORY_RECORD_KIND.to_owned()),
            scope: Some(resource_scope(invocation)),
            lifecycle: None,
            limit: limit.saturating_mul(4).clamp(1, 500),
        })
        .await
        .map_err(engine_error)?;

    let mut selected = Vec::new();
    let mut excluded_refs = Vec::new();
    let mut exclusions = Vec::new();
    for resource in resources {
        let Some(inspection) = engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
        else {
            continue;
        };
        let resource_reference = resource_ref(&inspection.resource, "retrieved_memory_record");
        let Some((_version_id, payload)) = current_payload(&inspection) else {
            excluded_refs.push(resource_reference.clone());
            exclusions.push(exclusion(
                resource_reference,
                "memory_record_payload_missing",
            ));
            continue;
        };
        let record = match serde_json::from_value::<MemoryRecord>(payload) {
            Ok(record) => record,
            Err(_) => {
                excluded_refs.push(resource_reference.clone());
                exclusions.push(exclusion(
                    resource_reference,
                    "memory_record_payload_malformed",
                ));
                continue;
            }
        };
        let lifecycle_state = record
            .lifecycle
            .get("state")
            .and_then(Value::as_str)
            .unwrap_or(inspection.resource.lifecycle.as_str());
        if lifecycle_state == "tombstoned" || inspection.resource.lifecycle == "tombstoned" {
            excluded_refs.push(resource_reference.clone());
            exclusions.push(exclusion(resource_reference, "memory_record_tombstoned"));
            continue;
        }
        if record
            .expires_at
            .is_some_and(|expires_at| expires_at <= Utc::now())
        {
            excluded_refs.push(resource_reference.clone());
            exclusions.push(exclusion(resource_reference, "memory_record_expired"));
            continue;
        }
        let Some(snippet) = provider_safe_snippet(&record.preview, max_snippet_bytes) else {
            excluded_refs.push(resource_reference.clone());
            exclusions.push(exclusion(
                resource_reference,
                "memory_record_preview_not_provider_safe",
            ));
            continue;
        };
        let score = retrieval_score(terms, &record.subject, &record.preview);
        if !terms.is_empty() && score == 0 {
            excluded_refs.push(resource_reference.clone());
            exclusions.push(exclusion(resource_reference, "memory_record_no_term_match"));
            continue;
        }
        selected.push(Candidate {
            resource_ref: resource_reference,
            subject: provider_safe_optional_string(&record.subject, 96)
                .unwrap_or_else(|| format!("memory {}", selected.len().saturating_add(1))),
            snippet,
            score,
            confidence: confidence_projection(&record.confidence, score, terms.is_empty()),
            provenance: provenance_projection(&record.provenance),
            retention: retention_projection(&record.retention),
            source_refs: source_ref_projection(&record.source_refs),
        });
    }

    selected.sort_by(|left, right| {
        right.score.cmp(&left.score).then_with(|| {
            left.resource_ref
                .resource_id
                .cmp(&right.resource_ref.resource_id)
        })
    });
    selected.truncate(limit);

    let selected_refs = selected
        .iter()
        .map(|candidate| candidate.resource_ref.clone())
        .collect::<Vec<_>>();
    let selected_count = selected_refs.len();
    let results = selected
        .into_iter()
        .enumerate()
        .map(|(index, candidate)| {
            json!({
                "rank": index + 1,
                "resourceRef": candidate.resource_ref,
                "subject": candidate.subject,
                "snippet": candidate.snippet,
                "score": candidate.score,
                "confidence": candidate.confidence,
                "provenance": candidate.provenance,
                "sourceRefs": candidate.source_refs,
                "retention": candidate.retention,
                "redaction": {
                    "bodyRead": false,
                    "bodyIncluded": false,
                    "snippetSource": "memory_record.preview",
                    "generatedSummary": false
                }
            })
        })
        .collect::<Vec<_>>();

    Ok(RetrievalEvidence {
        selected_refs,
        excluded_refs,
        results,
        retrieval: json!({
            "schemaVersion": MEMORY_SCHEMA_VERSION,
            "executed": true,
            "algorithm": RETRIEVAL_ALGORITHM,
            "engineId": policy
                .active_engine_id
                .clone()
                .unwrap_or_else(|| "none".to_owned()),
            "mode": policy.mode.as_str(),
            "termsStored": !terms.is_empty(),
            "termCount": terms.len(),
            "resultCount": selected_count,
            "excludedCount": exclusions.len(),
            "limit": limit,
            "maxSnippetBytes": max_snippet_bytes,
            "bodyRead": false,
            "embeddings": false,
            "networkPolicy": "none",
            "exclusions": exclusions
        }),
    })
}

pub(super) fn metadata_only_retrieval() -> Value {
    json!({
        "schemaVersion": MEMORY_SCHEMA_VERSION,
        "executed": false,
        "algorithm": "none",
        "bodyRead": false,
        "embeddings": false,
        "networkPolicy": "none"
    })
}

pub(super) fn prompt_snippet_policy(policy: &MemoryPolicyRecord) -> PromptSnippetPolicy {
    let requested = policy
        .inclusion
        .get("promptInclusion")
        .and_then(Value::as_str)
        .unwrap_or("disabled");
    let mode_allows = policy.mode == MemoryMode::Active;
    let enabled = mode_allows && matches!(requested, "bounded_snippets" | "enabled");
    let reason = if enabled {
        "bounded_snippets_policy_enabled"
    } else if policy.mode == MemoryMode::Disabled {
        "memory_disabled"
    } else if policy.mode == MemoryMode::Shadow {
        "memory_shadow_mode_excludes_prompt_inclusion"
    } else if policy.mode == MemoryMode::Compare {
        "memory_compare_mode_excludes_prompt_inclusion"
    } else {
        "prompt_inclusion_policy_not_enabled"
    }
    .to_owned();
    let max_snippets = policy
        .inclusion
        .get("maxSnippets")
        .and_then(Value::as_u64)
        .unwrap_or(DEFAULT_PROMPT_SNIPPETS as u64)
        .clamp(1, MAX_PROMPT_SNIPPETS as u64) as usize;
    let max_snippet_bytes = policy
        .inclusion
        .get("maxSnippetBytes")
        .and_then(Value::as_u64)
        .unwrap_or(DEFAULT_SNIPPET_BYTES as u64)
        .clamp(40, MAX_SNIPPET_BYTES as u64) as usize;
    PromptSnippetPolicy {
        enabled,
        max_snippets,
        max_snippet_bytes,
        reason,
        evidence: json!({
            "mode": policy.mode.as_str(),
            "promptInclusion": requested,
            "enabledForPrompt": enabled,
            "maxSnippets": max_snippets,
            "maxSnippetBytes": max_snippet_bytes,
            "privateBodyIncluded": false,
            "networkPolicy": "none"
        }),
    }
}

pub(super) fn policy_evidence(
    policy: &super::service::ResolvedPolicy,
    snippet_policy: Option<&PromptSnippetPolicy>,
) -> Value {
    json!({
        "scope": policy.scope.clone(),
        "policyResourceId": policy.resource_id.clone(),
        "policyVersionId": policy.version_id.clone(),
        "implicit": policy.implicit,
        "parseError": policy.parse_error.clone(),
        "mode": policy.record.mode.as_str(),
        "activeEngineId": policy.record.active_engine_id.clone(),
        "revision": policy.record.revision,
        "inclusion": policy.record.inclusion.clone(),
        "promptSnippetPolicy": snippet_policy.map(|policy| policy.evidence.clone()),
        "networkPolicy": "none"
    })
}

pub(super) fn module_evidence() -> Value {
    json!({
        "modulePackId": "memory_engine_module",
        "engineKind": "resource_backed_preview",
        "algorithm": RETRIEVAL_ALGORITHM,
        "swappable": true,
        "embeddings": false,
        "generatedSummaries": false,
        "networkPolicy": "none"
    })
}

pub(super) fn prompt_result_decision_metadata(
    result: &Value,
    decision_resource_id: Option<&str>,
    policy: &PromptSnippetPolicy,
) -> Value {
    json!({
        "snippet": result.get("snippet").cloned().unwrap_or(Value::Null),
        "rank": result.get("rank").cloned().unwrap_or(Value::Null),
        "score": result.get("score").cloned().unwrap_or(Value::Null),
        "confidence": result.get("confidence").cloned().unwrap_or(Value::Null),
        "policy": policy.evidence,
        "decisionResourceId": decision_resource_id,
        "bodyIncluded": false,
        "generatedSummary": false
    })
}

#[derive(Clone)]
struct Candidate {
    resource_ref: crate::shared::protocol::memory::MemoryResourceRef,
    subject: String,
    snippet: String,
    score: u64,
    confidence: Value,
    provenance: Value,
    retention: Value,
    source_refs: Vec<Value>,
}

fn retrieval_score(terms: &[String], subject: &str, preview: &str) -> u64 {
    if terms.is_empty() {
        return 1;
    }
    let haystack = format!(
        "{} {}",
        subject.to_ascii_lowercase(),
        preview.to_ascii_lowercase()
    );
    terms
        .iter()
        .filter(|term| haystack.contains(term.as_str()))
        .count() as u64
}

fn provider_safe_snippet(text: &str, max_bytes: usize) -> Option<String> {
    let compact = text.split_whitespace().collect::<Vec<_>>().join(" ");
    provider_safe_optional_string(&compact, max_bytes)
}

fn exclusion(
    resource_ref: crate::shared::protocol::memory::MemoryResourceRef,
    reason: &str,
) -> Value {
    json!({
        "resourceRef": resource_ref,
        "reason": reason,
        "bodyRead": false
    })
}

fn confidence_projection(confidence: &Value, score: u64, uses_default_order: bool) -> Value {
    let mut projection = Map::new();
    projection.insert(
        "basis".to_owned(),
        json!(if uses_default_order {
            "deterministic_resource_order"
        } else {
            "deterministic_preview_subject_match"
        }),
    );
    projection.insert("score".to_owned(), json!(score));
    if let Some(value) = confidence.get("score").and_then(Value::as_f64) {
        projection.insert("recordConfidence".to_owned(), json!(value));
    }
    Value::Object(projection)
}

fn provenance_projection(provenance: &Value) -> Value {
    json!({
        "source": safe_field(provenance, "source"),
        "snippetSource": "memory_record.preview",
        "bodyRead": false,
        "generatedSummary": false,
        "algorithm": RETRIEVAL_ALGORITHM
    })
}

fn retention_projection(retention: &Value) -> Value {
    json!({
        "policy": safe_field(retention, "policy"),
        "until": safe_field(retention, "until"),
        "redacted": true,
        "hardDelete": false
    })
}

fn safe_field(object: &Value, field: &str) -> Value {
    object
        .get(field)
        .and_then(Value::as_str)
        .and_then(|value| provider_safe_optional_string(value, 96))
        .map(Value::String)
        .unwrap_or(Value::Null)
}

fn source_ref_projection(refs: &[Value]) -> Vec<Value> {
    refs.iter().take(8).filter_map(project_source_ref).collect()
}

fn project_source_ref(value: &Value) -> Option<Value> {
    let object = value.as_object()?;
    let mut projection = Map::new();
    for field in [
        "kind",
        "id",
        "resourceId",
        "versionId",
        "role",
        "traceId",
        "invocationId",
    ] {
        if let Some(text) = object
            .get(field)
            .and_then(Value::as_str)
            .and_then(|value| provider_safe_optional_string(value, 96))
        {
            projection.insert(field.to_owned(), Value::String(text));
        }
    }
    (!projection.is_empty()).then_some(Value::Object(projection))
}

pub(super) fn validate_retrieval_payload(payload: &Value) -> Result<(), CapabilityError> {
    if let Some(retrieval) = payload.get("retrieval") {
        validate_bounded_metadata(retrieval, "retrieval", 0)?;
    }
    Ok(())
}
