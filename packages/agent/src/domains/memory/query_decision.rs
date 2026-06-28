use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};

use crate::engine::{
    CreateResource, EngineHostHandle, EngineResourceInspection, Invocation, ListResources, WorkerId,
};
use crate::shared::protocol::memory::{
    MEMORY_SCHEMA_VERSION, MemoryDecisionEvidence, MemoryQueryEvidence, MemoryResourceRef,
};
use crate::shared::server::errors::CapabilityError;

use super::errors::{engine_error, invalid_params};
use super::query_decision_validation::{
    bounded_array, bounded_object, bounded_string, reason_codes, required_datetime,
    validate_bounded_metadata,
};
use super::retrieval::{
    metadata_only_retrieval, module_evidence, policy_evidence, query_terms_from_payload,
    retrieval_limit, retrieval_requested, retrieval_snippet_bytes, retrieve_memory_records,
    validate_retrieval_payload,
};
use super::service::resolve_policy;
use super::support::*;
use super::{
    MEMORY_DECISION_KIND, MEMORY_DECISION_SCHEMA_ID, MEMORY_QUERY_KIND, MEMORY_QUERY_SCHEMA_ID,
    MEMORY_RECORD_KIND, WORKER,
};

const QUERY_IDEMPOTENCY_ALGORITHM: &str = "sha256:tron.memory_query.idempotency.v1";
const QUERY_IDEMPOTENCY_DOMAIN: &[u8] = b"tron.memory_query.idempotency.v1\0";
const DECISION_IDEMPOTENCY_ALGORITHM: &str = "sha256:tron.memory_decision.idempotency.v1";
const DECISION_IDEMPOTENCY_DOMAIN: &[u8] = b"tron.memory_decision.idempotency.v1\0";
pub(crate) async fn record_memory_query_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    validate_bounded_metadata(payload, "memory_query", 0)?;
    validate_retrieval_payload(payload)?;
    let occurred_at = required_datetime(payload, "occurredAt")?;
    let policy = resolve_policy(engine_host, invocation, false).await?;
    let query_kind = bounded_string(&required_string(payload, "queryKind")?, "queryKind")?;
    let query_id = optional_string(payload, "queryId")?
        .map(|value| bounded_string(&value, "queryId"))
        .transpose()?
        .unwrap_or_else(|| invocation.id.as_str().to_owned());
    let idempotency_key = idempotency_key(invocation)?;
    let scope = resource_scope(invocation);
    let resource_id = scoped_resource_id(
        MEMORY_QUERY_KIND,
        &scope,
        &query_id,
        &idempotency_key,
        QUERY_IDEMPOTENCY_DOMAIN,
    );
    if let Some(existing) = engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_kind_and_scope(&existing, MEMORY_QUERY_KIND, invocation)?;
        let (version_id, payload) = current_payload(&existing)
            .ok_or_else(|| invalid_params("memory query has no payload"))?;
        return Ok(json!({
            "schemaVersion": MEMORY_SCHEMA_VERSION,
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "queryResourceId": resource_id,
            "queryVersionId": version_id,
            "query": redacted_query_payload(&payload),
            "resourceRefs": [resource_ref(&existing.resource, "memory_query")]
        }));
    }

    let retrieval_executed = retrieval_requested(payload);
    let (selected_refs, excluded_refs, retrieval, results) = if retrieval_executed {
        let terms = query_terms_from_payload(payload)?;
        let evidence = retrieve_memory_records(
            engine_host,
            invocation,
            &policy.record,
            &terms,
            retrieval_limit(payload),
            retrieval_snippet_bytes(payload),
        )
        .await?;
        (
            evidence.selected_refs,
            evidence.excluded_refs,
            evidence.retrieval,
            evidence.results,
        )
    } else {
        (
            existing_ref_array(
                engine_host,
                invocation,
                payload,
                "selectedRefs",
                MEMORY_RECORD_KIND,
            )
            .await?,
            existing_ref_array(
                engine_host,
                invocation,
                payload,
                "excludedRefs",
                MEMORY_RECORD_KIND,
            )
            .await?,
            metadata_only_retrieval(),
            Vec::new(),
        )
    };
    let decision_refs = existing_ref_array(
        engine_host,
        invocation,
        payload,
        "decisionRefs",
        MEMORY_DECISION_KIND,
    )
    .await?;
    let evidence = MemoryQueryEvidence {
        schema_version: MEMORY_SCHEMA_VERSION.to_owned(),
        query_kind,
        intent: bounded_object(payload, "intent")?.unwrap_or_else(|| {
            json!({
                "kind": "metadata_only",
                "rawPromptStored": false,
                "summaryStored": false
            })
        }),
        filters: bounded_object(payload, "filters")?.unwrap_or_else(|| json!({})),
        engine_id: policy
            .record
            .active_engine_id
            .clone()
            .unwrap_or_else(|| "none".to_owned()),
        mode: policy.record.mode.clone(),
        selected_refs,
        excluded_refs,
        retrieval,
        results,
        decision_refs,
        policy: policy_evidence(&policy, None),
        module: module_evidence(),
        redaction: redaction_proof(!retrieval_executed, retrieval_executed),
        trace_refs: merge_trace_refs(optional_array(payload, "traceRefs")?, invocation),
        replay_refs: merge_replay_refs(optional_array(payload, "replayRefs")?, invocation),
        lifecycle: json!({
            "state": "recorded",
            "occurredAt": occurred_at.to_rfc3339(),
            "retrievalExecuted": retrieval_executed,
            "promptContentIncluded": false
        }),
        idempotency: idempotency_evidence(
            &idempotency_key,
            QUERY_IDEMPOTENCY_ALGORITHM,
            QUERY_IDEMPOTENCY_DOMAIN,
        ),
        occurred_at,
    };
    let resource = engine_host
        .create_resource(CreateResource {
            resource_id: Some(resource_id.clone()),
            kind: MEMORY_QUERY_KIND.to_owned(),
            schema_id: Some(MEMORY_QUERY_SCHEMA_ID.to_owned()),
            scope,
            owner_worker_id: WorkerId::new(WORKER).map_err(engine_error)?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("recorded".to_owned()),
            policy: memory_policy("query"),
            initial_payload: Some(to_value(&evidence, "memory query evidence")?),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let _ = publish_lifecycle_event(
        engine_host,
        invocation,
        "memory.query_recorded",
        json!({
            "queryResourceId": resource.resource_id.clone(),
            "queryVersionId": resource.current_version_id.clone(),
            "queryKind": evidence.query_kind,
            "mode": evidence.mode.as_str(),
            "selected": evidence.selected_refs.len(),
            "excluded": evidence.excluded_refs.len(),
            "retrievalExecuted": retrieval_executed,
            "promptContentIncluded": false
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": MEMORY_SCHEMA_VERSION,
        "status": "recorded",
        "idempotentReplay": false,
        "queryResourceId": resource.resource_id.clone(),
        "queryVersionId": resource.current_version_id.clone(),
        "query": redacted_query_payload(&to_value(&evidence, "memory query evidence")?),
        "resourceRefs": [resource_ref(&resource, "memory_query")]
    }))
}

pub(crate) async fn record_memory_decision_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    validate_bounded_metadata(payload, "memory_decision", 0)?;
    let occurred_at = required_datetime(payload, "occurredAt")?;
    let policy = resolve_policy(engine_host, invocation, false).await?;
    let decision_kind = bounded_string(&required_string(payload, "decisionKind")?, "decisionKind")?;
    let decision_id = optional_string(payload, "decisionId")?
        .map(|value| bounded_string(&value, "decisionId"))
        .transpose()?
        .unwrap_or_else(|| invocation.id.as_str().to_owned());
    let idempotency_key = idempotency_key(invocation)?;
    let scope = resource_scope(invocation);
    let resource_id = scoped_resource_id(
        MEMORY_DECISION_KIND,
        &scope,
        &decision_id,
        &idempotency_key,
        DECISION_IDEMPOTENCY_DOMAIN,
    );
    if let Some(existing) = engine_host
        .inspect_resource(&resource_id)
        .await
        .map_err(engine_error)?
    {
        ensure_kind_and_scope(&existing, MEMORY_DECISION_KIND, invocation)?;
        let (version_id, payload) = current_payload(&existing)
            .ok_or_else(|| invalid_params("memory decision has no payload"))?;
        return Ok(json!({
            "schemaVersion": MEMORY_SCHEMA_VERSION,
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "decisionResourceId": resource_id,
            "decisionVersionId": version_id,
            "decision": redacted_decision_payload(&payload),
            "resourceRefs": [resource_ref(&existing.resource, "memory_decision")]
        }));
    }

    let subject_ref = optional_ref(
        engine_host,
        invocation,
        payload,
        "subjectRef",
        MEMORY_RECORD_KIND,
    )
    .await?;
    let query_ref = optional_ref(
        engine_host,
        invocation,
        payload,
        "queryRef",
        MEMORY_QUERY_KIND,
    )
    .await?;
    let source_refs = bounded_array(payload, "sourceRefs")?;
    let prompt_inclusion = bounded_object(payload, "promptInclusion")?.unwrap_or_else(|| {
        json!({
            "appliedToPrompt": false,
            "boundedPreviewSnippetsOnly": false,
            "privateBodyIncluded": false
        })
    });
    let retention_evidence = bounded_object(payload, "retentionEvidence")?.unwrap_or_else(|| {
        json!({
            "automaticRetentionPerformed": false,
            "retentionMutationPerformed": false
        })
    });
    let policy_evidence = bounded_object(payload, "policyEvidence")?
        .unwrap_or_else(|| policy_evidence(&policy, None));
    let decision_applied_to_prompt = prompt_inclusion
        .get("appliedToPrompt")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let automatic_retention_performed = retention_evidence
        .get("automaticRetentionPerformed")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let evidence = MemoryDecisionEvidence {
        schema_version: MEMORY_SCHEMA_VERSION.to_owned(),
        decision_kind,
        reason_codes: reason_codes(payload)?,
        subject_ref,
        query_ref,
        source_refs,
        prompt_inclusion,
        retention_evidence,
        policy_evidence,
        redaction: redaction_proof(true, decision_applied_to_prompt),
        trace_refs: merge_trace_refs(optional_array(payload, "traceRefs")?, invocation),
        replay_refs: merge_replay_refs(optional_array(payload, "replayRefs")?, invocation),
        lifecycle: json!({
            "state": "recorded",
            "occurredAt": occurred_at.to_rfc3339(),
            "decisionAppliedToPrompt": decision_applied_to_prompt,
            "automaticRetentionPerformed": automatic_retention_performed
        }),
        idempotency: idempotency_evidence(
            &idempotency_key,
            DECISION_IDEMPOTENCY_ALGORITHM,
            DECISION_IDEMPOTENCY_DOMAIN,
        ),
        occurred_at,
    };
    let resource = engine_host
        .create_resource(CreateResource {
            resource_id: Some(resource_id.clone()),
            kind: MEMORY_DECISION_KIND.to_owned(),
            schema_id: Some(MEMORY_DECISION_SCHEMA_ID.to_owned()),
            scope,
            owner_worker_id: WorkerId::new(WORKER).map_err(engine_error)?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("recorded".to_owned()),
            policy: memory_policy("decision"),
            initial_payload: Some(to_value(&evidence, "memory decision evidence")?),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let _ = publish_lifecycle_event(
        engine_host,
        invocation,
        "memory.decision_recorded",
        json!({
            "decisionResourceId": resource.resource_id.clone(),
            "decisionVersionId": resource.current_version_id.clone(),
            "decisionKind": evidence.decision_kind,
            "reasonCodeCount": evidence.reason_codes.len(),
            "decisionAppliedToPrompt": decision_applied_to_prompt,
            "automaticRetentionPerformed": automatic_retention_performed
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": MEMORY_SCHEMA_VERSION,
        "status": "recorded",
        "idempotentReplay": false,
        "decisionResourceId": resource.resource_id.clone(),
        "decisionVersionId": resource.current_version_id.clone(),
        "decision": redacted_decision_payload(&to_value(&evidence, "memory decision evidence")?),
        "resourceRefs": [resource_ref(&resource, "memory_decision")]
    }))
}

pub(crate) async fn list_memory_queries_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    list_evidence(
        engine_host,
        invocation,
        payload,
        MEMORY_QUERY_KIND,
        "queries",
    )
    .await
}

pub(crate) async fn inspect_memory_query_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    inspect_evidence(
        engine_host,
        invocation,
        payload,
        "queryResourceId",
        MEMORY_QUERY_KIND,
    )
    .await
}

pub(crate) async fn list_memory_decisions_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    list_evidence(
        engine_host,
        invocation,
        payload,
        MEMORY_DECISION_KIND,
        "decisions",
    )
    .await
}

pub(crate) async fn inspect_memory_decision_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    inspect_evidence(
        engine_host,
        invocation,
        payload,
        "decisionResourceId",
        MEMORY_DECISION_KIND,
    )
    .await
}

async fn list_evidence(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
    kind: &str,
    field: &str,
) -> Result<Value, CapabilityError> {
    let limit = payload
        .get("limit")
        .and_then(Value::as_u64)
        .unwrap_or(50)
        .clamp(1, 500) as usize;
    let resources = engine_host
        .list_resources(ListResources {
            kind: Some(kind.to_owned()),
            scope: Some(resource_scope(invocation)),
            lifecycle: optional_string(payload, "lifecycle")?,
            limit,
        })
        .await
        .map_err(engine_error)?;
    let mut records = Vec::new();
    for resource in resources {
        if let Some(inspection) = engine_host
            .inspect_resource(&resource.resource_id)
            .await
            .map_err(engine_error)?
            && let Some((version_id, payload)) = current_payload(&inspection)
        {
            records.push(json!({
                "resource": inspection.resource,
                "currentVersionId": version_id,
                "record": redacted_evidence_payload(kind, &payload)
            }));
        }
    }
    Ok(json!({
        "schemaVersion": MEMORY_SCHEMA_VERSION,
        field: records,
        "redacted": true,
        "retrievalExecuted": false,
        "promptContentIncluded": false
    }))
}

async fn inspect_evidence(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
    id_field: &str,
    kind: &str,
) -> Result<Value, CapabilityError> {
    let resource_id = required_string(payload, id_field)?;
    let inspection = require_kind(engine_host, &resource_id, kind).await?;
    ensure_kind_and_scope(&inspection, kind, invocation)?;
    let versions = inspection
        .versions
        .iter()
        .map(|version| {
            json!({
                "versionId": version.version_id,
                "parentVersionId": version.parent_version_id,
                "contentHash": version.content_hash,
                "state": version.state,
                "createdAt": version.created_at,
                "record": redacted_evidence_payload(kind, &version.payload)
            })
        })
        .collect::<Vec<_>>();
    Ok(json!({
        "schemaVersion": MEMORY_SCHEMA_VERSION,
        "resource": redacted_resource_projection(&inspection.resource),
        "versions": versions,
        "events": redacted_resource_events(&inspection.events),
        "redacted": true,
        "retrievalExecuted": false,
        "promptContentIncluded": false
    }))
}

async fn existing_ref_array(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
    field: &str,
    kind: &str,
) -> Result<Vec<MemoryResourceRef>, CapabilityError> {
    let mut refs = Vec::new();
    for value in optional_array(payload, field)? {
        refs.push(parse_existing_ref(engine_host, invocation, &value, field, kind).await?);
    }
    Ok(refs)
}

async fn optional_ref(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
    field: &str,
    kind: &str,
) -> Result<Option<MemoryResourceRef>, CapabilityError> {
    match payload.get(field) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => Ok(Some(
            parse_existing_ref(engine_host, invocation, value, field, kind).await?,
        )),
    }
}

async fn parse_existing_ref(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    value: &Value,
    field: &str,
    expected_kind: &str,
) -> Result<MemoryResourceRef, CapabilityError> {
    validate_bounded_metadata(value, field, 0)?;
    let reference: MemoryResourceRef = serde_json::from_value(value.clone())
        .map_err(|err| invalid_params(format!("{field} must be a memory resource ref: {err}")))?;
    if reference.kind != expected_kind {
        return Err(invalid_params(format!(
            "{field} wrong kind: expected {expected_kind}, actual {}",
            reference.kind
        )));
    }
    bounded_string(&reference.resource_id, field)?;
    let inspection = require_kind(engine_host, &reference.resource_id, expected_kind).await?;
    ensure_kind_and_scope(&inspection, expected_kind, invocation)?;
    if let Some(expected_version) = reference.version_id.as_deref()
        && inspection.resource.current_version_id.as_deref() != Some(expected_version)
    {
        return Err(invalid_params(format!(
            "{field} stale version: expected {expected_version}, actual {}",
            inspection
                .resource
                .current_version_id
                .as_deref()
                .unwrap_or("none")
        )));
    }
    Ok(reference)
}

async fn require_kind(
    engine_host: &EngineHostHandle,
    resource_id: &str,
    kind: &str,
) -> Result<EngineResourceInspection, CapabilityError> {
    let inspection = engine_host
        .inspect_resource(resource_id)
        .await
        .map_err(engine_error)?
        .ok_or_else(|| invalid_params(format!("{kind} resource {resource_id} missing")))?;
    if inspection.resource.kind != kind {
        return Err(invalid_params(format!(
            "resource {resource_id} wrong kind: expected {kind}, actual {}",
            inspection.resource.kind
        )));
    }
    Ok(inspection)
}

fn ensure_kind_and_scope(
    inspection: &EngineResourceInspection,
    kind: &str,
    invocation: &Invocation,
) -> Result<(), CapabilityError> {
    if inspection.resource.kind != kind {
        return Err(invalid_params(format!(
            "resource {} wrong kind: expected {kind}, actual {}",
            inspection.resource.resource_id, inspection.resource.kind
        )));
    }
    let expected = resource_scope(invocation);
    if inspection.resource.scope != expected {
        return Err(invalid_params(format!(
            "{kind} scope mismatch: expected {}:{}, actual {}:{}",
            expected.kind(),
            expected.value(),
            inspection.resource.scope.kind(),
            inspection.resource.scope.value()
        )));
    }
    Ok(())
}

fn idempotency_key(invocation: &Invocation) -> Result<String, CapabilityError> {
    invocation
        .causal_context
        .idempotency_key
        .as_ref()
        .filter(|value| !value.trim().is_empty())
        .cloned()
        .ok_or_else(|| invalid_params("idempotency key is required for memory evidence writes"))
}

fn idempotency_evidence(key: &str, algorithm: &str, domain: &[u8]) -> Value {
    json!({
        "algorithm": algorithm,
        "fingerprint": idempotency_fingerprint(key, domain),
        "rawKeyStored": false
    })
}

fn scoped_resource_id(
    kind: &str,
    scope: &crate::engine::EngineResourceScope,
    id: &str,
    key: &str,
    domain: &[u8],
) -> String {
    let mut hasher = Sha256::new();
    hasher.update(scope.kind().as_bytes());
    hasher.update(b":");
    hasher.update(scope.value().as_bytes());
    hasher.update(b":");
    hasher.update(id.as_bytes());
    hasher.update(b":");
    hasher.update(idempotency_fingerprint(key, domain).as_bytes());
    format!("{kind}:{}", hex::encode(hasher.finalize()))
}

fn idempotency_fingerprint(key: &str, domain: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(domain);
    hasher.update(key.as_bytes());
    hex::encode(hasher.finalize())
}

fn redaction_proof(metadata_only: bool, bounded_preview_snippets: bool) -> Value {
    json!({
        "metadataOnly": metadata_only,
        "boundedPreviewSnippetsOnly": bounded_preview_snippets,
        "rawPromptStored": false,
        "rawProviderPayloadStored": false,
        "memoryBodyStored": false,
        "memoryBodyIncludedInPrompt": false,
        "summaryStored": false,
        "secretsStored": false,
        "unsafePathsStored": false,
        "rawIdempotencyKeyStored": false
    })
}

fn redacted_query_payload(payload: &Value) -> Value {
    pick_fields(
        payload,
        &[
            "schemaVersion",
            "queryKind",
            "intent",
            "filters",
            "engineId",
            "mode",
            "selectedRefs",
            "excludedRefs",
            "retrieval",
            "results",
            "decisionRefs",
            "policy",
            "module",
            "redaction",
            "traceRefs",
            "replayRefs",
            "lifecycle",
            "idempotency",
            "occurredAt",
        ],
        &[
            "selectedRefs",
            "excludedRefs",
            "results",
            "decisionRefs",
            "traceRefs",
            "replayRefs",
        ],
    )
}

fn redacted_decision_payload(payload: &Value) -> Value {
    pick_fields(
        payload,
        &[
            "schemaVersion",
            "decisionKind",
            "reasonCodes",
            "subjectRef",
            "queryRef",
            "sourceRefs",
            "promptInclusion",
            "retentionEvidence",
            "policyEvidence",
            "redaction",
            "traceRefs",
            "replayRefs",
            "lifecycle",
            "idempotency",
            "occurredAt",
        ],
        &["reasonCodes", "sourceRefs", "traceRefs", "replayRefs"],
    )
}

fn pick_fields(payload: &Value, fields: &[&str], array_fields: &[&str]) -> Value {
    let mut object = Map::new();
    for field in fields {
        let fallback = if array_fields.contains(field) {
            json!([])
        } else {
            Value::Null
        };
        object.insert(
            (*field).to_owned(),
            payload.get(*field).cloned().unwrap_or(fallback),
        );
    }
    Value::Object(object)
}

fn redacted_evidence_payload(kind: &str, payload: &Value) -> Value {
    if kind == MEMORY_QUERY_KIND {
        redacted_query_payload(payload)
    } else {
        redacted_decision_payload(payload)
    }
}
fn merge_trace_refs(mut refs: Vec<Value>, invocation: &Invocation) -> Vec<Value> {
    refs.extend(trace_refs(invocation));
    refs
}

fn merge_replay_refs(mut refs: Vec<Value>, invocation: &Invocation) -> Vec<Value> {
    refs.extend(replay_refs(invocation));
    refs
}
