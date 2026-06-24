use chrono::Utc;
use serde_json::{Value, json};
use tracing::warn;

use crate::engine::{
    ActorId, ActorKind, CausalContext, CreateResource, EngineHostHandle, FunctionId, Invocation,
    ListResources, TraceId, WorkerId,
};
use crate::shared::protocol::memory::{
    MEMORY_SCHEMA_VERSION, MemoryMode, MemoryPromptDecision, MemoryPromptTrace,
};
use crate::shared::server::errors::CapabilityError;

use super::errors::engine_error;
use super::service::resolve_policy;
use super::support::*;
use super::{
    MEMORY_PROMPT_TRACE_KIND, MEMORY_PROMPT_TRACE_SCHEMA_ID, PROMPT_TRACE_FUNCTION, WORKER,
};

/// Record a prompt inclusion trace and return the provider-safe context text.
pub(crate) async fn record_prompt_trace_value(
    engine_host: &EngineHostHandle,
    invocation: &Invocation,
    payload: &Value,
) -> Result<Value, CapabilityError> {
    let trace = build_prompt_trace(engine_host, invocation, payload).await?;
    let trace_payload = to_value(&trace, "memory prompt trace")?;
    let resource = engine_host
        .create_resource(CreateResource {
            resource_id: Some(format!("memory_prompt_trace:{}", invocation.id.as_str())),
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
        "trace": {
            "mode": trace.mode.as_str(),
            "engineId": trace.engine_id,
            "considered": trace.considered.len(),
            "included": trace.included.len(),
            "excluded": trace.excluded.len(),
            "privateContentLogged": false
        },
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
    let limit = payload
        .get("limit")
        .and_then(Value::as_u64)
        .unwrap_or(50)
        .clamp(1, 500) as usize;
    let mut considered = Vec::new();
    let mut excluded = Vec::new();
    if policy.record.mode != MemoryMode::Disabled {
        let resources = engine_host
            .list_resources(ListResources {
                kind: Some(super::MEMORY_RECORD_KIND.to_owned()),
                scope: Some(resource_scope(invocation)),
                lifecycle: None,
                limit,
            })
            .await
            .map_err(engine_error)?;
        for resource in resources {
            let decision = MemoryPromptDecision {
                resource_ref: resource_ref(&resource, "considered_memory_record"),
                reason: "resource_backed_engine_has_no_prompt_retrieval_algorithm".to_owned(),
                metadata: json!({"privateContentLogged": false}),
            };
            considered.push(decision.clone());
            excluded.push(MemoryPromptDecision {
                resource_ref: decision.resource_ref,
                reason: if policy.record.mode == MemoryMode::Shadow {
                    "memory_shadow_mode_excludes_prompt_inclusion".to_owned()
                } else if policy.record.mode == MemoryMode::Compare {
                    "memory_compare_mode_excludes_prompt_inclusion".to_owned()
                } else {
                    "prompt_inclusion_requires_future_retrieval_policy".to_owned()
                },
                metadata: json!({"privateContentLogged": false}),
            });
        }
    }
    Ok(MemoryPromptTrace {
        schema_version: MEMORY_SCHEMA_VERSION.to_owned(),
        mode: policy.record.mode.clone(),
        engine_id: policy.record.active_engine_id.clone(),
        considered,
        included: Vec::new(),
        excluded,
        prompt_budget: json!({"recordLimit": limit, "includedContentBytes": 0}),
        redaction: json!({
            "privateContentLogged": false,
            "promptReceivesRecordBody": false,
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
    format!(
        "## Memory\n\nMemory mode: {mode}\nActive engine: {engine}\nPrompt trace: {resource}\nRecords considered: {considered}\nRecords included: {included}\nRecords excluded: {excluded}\nPrivate memory content included: no\n",
        mode = trace.mode.as_str(),
        considered = trace.considered.len(),
        included = trace.included.len(),
        excluded = trace.excluded.len(),
    )
}
