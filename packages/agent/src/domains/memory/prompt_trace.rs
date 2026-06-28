use chrono::Utc;
use serde_json::{Value, json};
use tracing::warn;

use crate::engine::{
    ActorId, ActorKind, CausalContext, CreateResource, EngineHostHandle, FunctionId, Invocation,
    TraceId, WorkerId,
};
use crate::shared::protocol::memory::{
    MEMORY_SCHEMA_VERSION, MemoryMode, MemoryPromptDecision, MemoryPromptTrace, MemoryResourceRef,
};
use crate::shared::server::errors::CapabilityError;

use super::errors::{engine_error, invalid_params};
use super::query_decision::{record_memory_decision_value, record_memory_query_value};
use super::retrieval::{policy_evidence, prompt_result_decision_metadata, prompt_snippet_policy};
use super::service::resolve_policy;
use super::support::*;
use super::{
    MEMORY_PROMPT_TRACE_KIND, MEMORY_PROMPT_TRACE_SCHEMA_ID, MEMORY_QUERY_KIND,
    PROMPT_TRACE_FUNCTION, WORKER,
};

/// Record a prompt inclusion trace and return the provider-safe context text.
pub(crate) async fn record_prompt_trace_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let trace_resource_id = format!("memory_prompt_trace:{}", invocation.id.as_str());
    if let Some(existing) = engine_host
        .inspect_resource(&trace_resource_id)
        .await
        .map_err(engine_error)?
    {
        if existing.resource.kind != MEMORY_PROMPT_TRACE_KIND {
            return Err(invalid_params(
                "memory prompt trace resource id kind mismatch",
            ));
        }
        if existing.resource.scope != resource_scope(invocation) {
            return Err(invalid_params("memory prompt trace scope mismatch"));
        }
        let (version_id, payload) = current_payload(&existing)
            .ok_or_else(|| invalid_params("memory prompt trace has no payload"))?;
        let trace: MemoryPromptTrace = serde_json::from_value(payload)
            .map_err(|err| invalid_params(format!("malformed memory prompt trace: {err}")))?;
        return Ok(json!({
            "schemaVersion": MEMORY_SCHEMA_VERSION,
            "status": existing.resource.lifecycle,
            "idempotentReplay": true,
            "traceResourceId": trace_resource_id,
            "traceVersionId": version_id,
            "context": prompt_context_text(&trace, Some(&existing.resource.resource_id)),
            "trace": trace_projection(&trace),
            "resourceRefs": [resource_ref(&existing.resource, "memory_prompt_trace")]
        }));
    }
    let trace = build_prompt_trace(engine_host, invocation, payload).await?;
    let trace_payload = to_value(&trace, "memory prompt trace")?;
    let resource = engine_host
        .create_resource(CreateResource {
            resource_id: Some(trace_resource_id),
            kind: MEMORY_PROMPT_TRACE_KIND.to_owned(),
            schema_id: Some(MEMORY_PROMPT_TRACE_SCHEMA_ID.to_owned()),
            scope: resource_scope(invocation),
            owner_worker_id: WorkerId::new(WORKER).map_err(engine_error)?,
            owner_actor_id: invocation.causal_context.actor_id.clone(),
            lifecycle: Some("recorded".to_owned()),
            policy: memory_policy("prompt_trace"),
            initial_payload: Some(trace_payload),
            locations: Vec::new(),
            trace_id: invocation.causal_context.trace_id.clone(),
            invocation_id: Some(invocation.id.clone()),
        })
        .await
        .map_err(engine_error)?;
    let _ = publish_lifecycle_event(
        engine_host,
        invocation,
        "memory.prompt_trace_recorded",
        json!({
            "traceResourceId": resource.resource_id.clone(),
            "traceVersionId": resource.current_version_id.clone(),
            "mode": trace.mode.as_str(),
            "considered": trace.considered.len(),
            "included": trace.included.len(),
            "excluded": trace.excluded.len(),
            "privateContentLogged": false
        }),
    )
    .await?;
    Ok(json!({
        "schemaVersion": MEMORY_SCHEMA_VERSION,
        "status": "recorded",
        "traceResourceId": resource.resource_id.clone(),
        "traceVersionId": resource.current_version_id.clone(),
        "context": prompt_context_text(&trace, Some(&resource.resource_id)),
        "trace": trace_projection(&trace),
        "resourceRefs": [resource_ref(&resource, "memory_prompt_trace")]
    }))
}

/// Load memory prompt audit text for agent context assembly.
pub(crate) async fn load_prompt_memory_context(
    engine_host: &EngineHostHandle,
    session_id: &str,
    workspace_id: Option<&str>,
    trace_id: Option<TraceId>,
) -> Option<String> {
    let resolved_trace_id =
        trace_id.unwrap_or_else(|| TraceId::new("memory-context").expect("static trace id"));
    let causal = CausalContext::new(
        ActorId::new("system:memory-context").ok()?,
        ActorKind::System,
        crate::engine::AuthorityGrantId::new("engine-system").ok()?,
        resolved_trace_id.clone(),
    )
    .with_scope(super::READ_SCOPE)
    .with_scope(super::WRITE_SCOPE)
    .with_session_id(session_id)
    .with_idempotency_key(format!(
        "memory-context:{session_id}:{}",
        resolved_trace_id.as_str()
    ));
    let causal = if let Some(workspace_id) = workspace_id {
        causal.with_workspace_id(workspace_id)
    } else {
        causal
    };
    let result = engine_host
        .invoke(Invocation::new_sync(
            FunctionId::new(PROMPT_TRACE_FUNCTION).ok()?,
            json!({"source": "prompt_context", "limit": 50}),
            causal,
        ))
        .await;
    if let Some(error) = result.error {
        warn!(error = %error, "failed to record memory prompt trace");
        return Some(
            "## Memory\n\nMemory status: unavailable; prompt memory inclusion disabled for this turn. Prompt trace recording failed before any memory content was considered."
                .to_owned(),
        );
    }
    result.value.and_then(|value| {
        value
            .get("context")
            .and_then(Value::as_str)
            .map(str::to_owned)
    })
}

async fn build_prompt_trace(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<MemoryPromptTrace, CapabilityError> {
    let policy = resolve_policy(engine_host, invocation, false).await?;
    let snippet_policy = prompt_snippet_policy(&policy.record);
    let limit = payload
        .get("limit")
        .and_then(Value::as_u64)
        .unwrap_or(50)
        .clamp(1, 500) as usize;
    let mut considered = Vec::new();
    let mut excluded = Vec::new();
    let mut included = Vec::new();
    let mut query_ref = None;
    let mut decision_resource_id = None;
    let mut decision_version_id = None;
    let trace_resource_id = format!("memory_prompt_trace:{}", invocation.id.as_str());
    if policy.record.mode != MemoryMode::Disabled {
        let now = Utc::now();
        let query = record_memory_query_value(
            engine_host,
            invocation,
            &json!({
                "queryId": format!("prompt-retrieval:{}", invocation.id.as_str()),
                "queryKind": "resource_backed_prompt_retrieval",
                "intent": {
                    "kind": "prompt_memory_context",
                    "rawPromptStored": false,
                    "summaryStored": false
                },
                "filters": {
                    "scope": "current_memory_scope",
                    "source": payload
                        .get("source")
                        .and_then(Value::as_str)
                        .unwrap_or("prompt_trace")
                },
                "retrieval": {
                    "mode": "resource_backed_preview",
                    "terms": payload
                        .get("terms")
                        .cloned()
                        .unwrap_or_else(|| json!([])),
                    "limit": limit,
                    "maxSnippetBytes": snippet_policy.max_snippet_bytes
                },
                "occurredAt": now.to_rfc3339()
            }),
        )
        .await?;
        let query_resource_id = query["queryResourceId"]
            .as_str()
            .unwrap_or("memory_query:unknown")
            .to_owned();
        let query_version_id = query["queryVersionId"].as_str().map(str::to_owned);
        query_ref = Some(MemoryResourceRef {
            kind: MEMORY_QUERY_KIND.to_owned(),
            resource_id: query_resource_id.clone(),
            version_id: query_version_id.clone(),
            role: "prompt_retrieval_query".to_owned(),
        });
        let results = query["query"]["results"]
            .as_array()
            .cloned()
            .unwrap_or_default();
        for result in results {
            let Some(resource_ref) = result_resource_ref(&result)? else {
                continue;
            };
            let considered_decision = MemoryPromptDecision {
                resource_ref: resource_ref.clone(),
                reason: "resource_backed_preview_retrieved".to_owned(),
                metadata: prompt_result_decision_metadata(&result, None, &snippet_policy),
            };
            considered.push(considered_decision);
            let include_index = included.len();
            if snippet_policy.enabled && include_index < snippet_policy.max_snippets {
                included.push(MemoryPromptDecision {
                    resource_ref,
                    reason: snippet_policy.reason.clone(),
                    metadata: prompt_result_decision_metadata(&result, None, &snippet_policy),
                });
            } else {
                excluded.push(MemoryPromptDecision {
                    resource_ref,
                    reason: snippet_policy.reason.clone(),
                    metadata: json!({
                        "policy": snippet_policy.evidence,
                        "privateContentLogged": false,
                        "bodyIncluded": false
                    }),
                });
            }
        }
        if !considered.is_empty() || policy.record.mode == MemoryMode::Active {
            let source_refs = included
                .iter()
                .map(|decision| {
                    json!({
                        "kind": decision.resource_ref.kind.clone(),
                        "resourceId": decision.resource_ref.resource_id.clone(),
                        "versionId": decision.resource_ref.version_id.clone(),
                        "role": "included_prompt_memory"
                    })
                })
                .collect::<Vec<_>>();
            let decision = record_memory_decision_value(
                engine_host,
                invocation,
                &json!({
                    "decisionId": format!("prompt-inclusion:{}", invocation.id.as_str()),
                    "decisionKind": "prompt_inclusion",
                    "reasonCodes": [snippet_policy.reason.clone()],
                    "queryRef": query_ref.clone(),
                    "sourceRefs": source_refs,
                    "promptInclusion": {
                        "appliedToPrompt": !included.is_empty(),
                        "boundedPreviewSnippetsOnly": !included.is_empty(),
                        "privateBodyIncluded": false,
                        "generatedSummary": false,
                        "includedCount": included.len(),
                        "excludedCount": excluded.len(),
                        "consideredCount": considered.len(),
                        "queryResourceId": query_resource_id,
                        "traceResourceId": trace_resource_id,
                        "proof": "policy_checked_resource_backed_preview_refs"
                    },
                    "retentionEvidence": {
                        "automaticRetentionPerformed": false,
                        "retentionMutationPerformed": false
                    },
                    "policyEvidence": policy_evidence(&policy, Some(&snippet_policy)),
                    "occurredAt": now.to_rfc3339()
                }),
            )
            .await?;
            decision_resource_id = decision["decisionResourceId"].as_str().map(str::to_owned);
            decision_version_id = decision["decisionVersionId"].as_str().map(str::to_owned);
            for decision in &mut included {
                decision.metadata = patch_decision_ref(
                    decision.metadata.clone(),
                    decision_resource_id.as_deref(),
                    &snippet_policy,
                );
            }
        }
    }
    let included_content_bytes = included_snippet_bytes(&included);
    let has_included = !included.is_empty();
    Ok(MemoryPromptTrace {
        schema_version: MEMORY_SCHEMA_VERSION.to_owned(),
        mode: policy.record.mode.clone(),
        engine_id: policy.record.active_engine_id.clone(),
        considered,
        included,
        excluded,
        prompt_budget: json!({
            "recordLimit": limit,
            "includedContentBytes": included_content_bytes,
            "queryRef": query_ref.clone(),
            "decisionResourceId": decision_resource_id,
            "decisionVersionId": decision_version_id,
            "snippetPolicy": snippet_policy.evidence
        }),
        redaction: json!({
            "privateContentLogged": false,
            "promptReceivesRecordBody": false,
            "promptReceivesBoundedRecordPreviews": has_included,
            "ordinaryLogsReceiveRecordBody": false
        }),
        trace_refs: trace_refs(invocation),
        replay_refs: replay_refs(invocation),
        created_at: Utc::now(),
    })
}

fn prompt_context_text(trace: &MemoryPromptTrace, trace_resource_id: Option<&str>) -> String {
    let engine = trace.engine_id.as_deref().unwrap_or("none");
    let resource = trace_resource_id.unwrap_or("not_recorded");
    let decision = trace
        .prompt_budget
        .get("decisionResourceId")
        .and_then(Value::as_str)
        .unwrap_or("none");
    let mut text = format!(
        "## Memory\n\nMemory mode: {mode}\nActive engine: {engine}\nPrompt trace: {resource}\nRecords considered: {considered}\nRecords included: {included}\nRecords excluded: {excluded}\nPrivate memory content included: no\n",
        mode = trace.mode.as_str(),
        considered = trace.considered.len(),
        included = trace.included.len(),
        excluded = trace.excluded.len(),
    );
    text.push_str(&format!(
        "Prompt inclusion decision: {decision}\nBounded record previews included: {}\n",
        if trace.included.is_empty() {
            "no"
        } else {
            "yes"
        }
    ));
    if !trace.included.is_empty() {
        text.push_str("Included memory previews:\n");
        for (index, decision) in trace.included.iter().enumerate() {
            let snippet = decision
                .metadata
                .get("snippet")
                .and_then(Value::as_str)
                .unwrap_or("[redacted]");
            let safe_ref = provider_safe_optional_string(&decision.resource_ref.resource_id, 96)
                .unwrap_or_else(|| "[redacted-ref]".to_owned());
            text.push_str(&format!("{}. {} (ref: {})\n", index + 1, snippet, safe_ref));
        }
    }
    text
}

fn trace_projection(trace: &MemoryPromptTrace) -> Value {
    json!({
        "mode": trace.mode.as_str(),
        "engineId": trace.engine_id.clone(),
        "considered": trace.considered.len(),
        "included": trace.included.len(),
        "excluded": trace.excluded.len(),
        "decisionResourceId": trace.prompt_budget.get("decisionResourceId").cloned().unwrap_or(Value::Null),
        "privateContentLogged": false,
        "privateBodyIncluded": false
    })
}

fn result_resource_ref(result: &Value) -> Result<Option<MemoryResourceRef>, CapabilityError> {
    let Some(value) = result.get("resourceRef") else {
        return Ok(None);
    };
    serde_json::from_value::<MemoryResourceRef>(value.clone())
        .map(Some)
        .map_err(|err| invalid_params(format!("malformed retrieval result ref: {err}")))
}

fn patch_decision_ref(
    mut metadata: Value,
    decision_resource_id: Option<&str>,
    policy: &super::retrieval::PromptSnippetPolicy,
) -> Value {
    if let Some(object) = metadata.as_object_mut() {
        object.insert(
            "decisionResourceId".to_owned(),
            decision_resource_id.map(Value::from).unwrap_or(Value::Null),
        );
        object.insert("policy".to_owned(), policy.evidence.clone());
    }
    metadata
}

fn included_snippet_bytes(included: &[MemoryPromptDecision]) -> usize {
    included
        .iter()
        .filter_map(|decision| decision.metadata.get("snippet").and_then(Value::as_str))
        .map(str::len)
        .sum()
}
