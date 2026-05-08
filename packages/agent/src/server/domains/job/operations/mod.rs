//! Job operation implementations.
//!
//! Queue-backed job commands, hidden apply functions, and job subscription
//! helpers live here behind canonical `job::*` functions.

use super::*;
use crate::engine::policy::ENGINE_INTERNAL_INVOKE_SCOPE;
use crate::engine::queue::publish_queue_lifecycle_event;
use crate::engine::{
    AuthorityRequirement, CompensationContract, CompensationKind, EffectClass, EngineQueueDrainer,
    EnqueueInvocation, FunctionDefinition, FunctionId, IdempotencyContract, Invocation, Provenance,
    RiskLevel,
};
use crate::server::shared::errors::CapabilityError;
use serde_json::{Value, json};
use tokio_util::sync::CancellationToken;

static ACTIVE_SUBSCRIPTIONS: std::sync::LazyLock<dashmap::DashMap<String, CancellationToken>> =
    std::sync::LazyLock::new(dashmap::DashMap::new);

pub(crate) fn hidden_function_registrations(
    deps: &DomainSetupContext,
) -> crate::engine::Result<Vec<DomainFunctionRegistration>> {
    let domain_deps = Deps::from_engine(deps);
    [
        (
            "job::background_apply",
            "job::background",
            "apply a queued background-job command",
        ),
        (
            "job::cancel_apply",
            "job::cancel",
            "apply a queued job-cancel command",
        ),
    ]
    .into_iter()
    .map(|(id, public_method, description)| {
        let mut definition = FunctionDefinition::new(
            FunctionId::new(id)?,
            catalog::worker_id("job")?,
            description,
            VisibilityScope::Internal,
            EffectClass::ReversibleSideEffect,
        )
        .with_risk(RiskLevel::High)
        .with_required_authority(AuthorityRequirement::scope("job.write"))
        .with_idempotency(IdempotencyContract::caller_system_engine_ledger())
        .with_compensation(CompensationContract::new(
            CompensationKind::ManualOnly,
            "hidden job apply functions delegate to the process manager; queue/idempotency records prevent duplicate starts or cancellations",
        ))
        .with_provenance(Provenance::system());
        if let Some(public_contract) = contract::capabilities()?
            .into_iter()
            .find(|spec| spec.method == public_method)
        {
            if let Some(schema) = public_contract.request_schema {
                definition = definition.with_request_schema(schema);
            }
            if let Some(schema) = public_contract.response_schema {
                definition = definition.with_response_schema(schema);
            }
        }
        definition.metadata = json!({
            "internal": true,
            "canonicalCapability": id,
            "hiddenApplyFunction": true,
        });
        Ok(DomainFunctionRegistration {
            definition,
            handler: Arc::new(DomainFunctionHandler {
                method: id,
                deps: domain_deps.clone(),
                handler: super::job_handler,
            }),
        })
    })
    .collect()
}

pub(super) async fn enqueue_and_sync_drain_job_apply(
    function_id: &str,
    idempotency_prefix: &str,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let function_id = FunctionId::new(function_id).map_err(|e| CapabilityError::Internal {
        message: e.to_string(),
    })?;
    let mut authority_scopes = invocation.causal_context.authority_scopes.clone();
    if !authority_scopes
        .iter()
        .any(|scope| scope == ENGINE_INTERNAL_INVOKE_SCOPE)
    {
        authority_scopes.push(ENGINE_INTERNAL_INVOKE_SCOPE.to_owned());
    }
    let item = deps
        .engine_host
        .enqueue_invocation(EnqueueInvocation {
            queue: "jobs".to_owned(),
            function_id,
            target_revision: None,
            payload: invocation.payload.clone(),
            actor_id: invocation.causal_context.actor_id.clone(),
            actor_kind: invocation.causal_context.actor_kind.clone(),
            authority_grant_id: invocation.causal_context.authority_grant_id.clone(),
            authority_scopes,
            trace_id: invocation.causal_context.trace_id.clone(),
            parent_invocation_id: Some(invocation.id.clone()),
            trigger_id: invocation.causal_context.trigger_id.clone(),
            session_id: invocation.causal_context.session_id.clone(),
            workspace_id: invocation.causal_context.workspace_id.clone(),
            idempotency_key: Some(format!("{idempotency_prefix}:{}", invocation.id)),
        })
        .await
        .map_err(crate::server::shared::error_mapping::engine_error_to_capability_error)?;
    publish_queue_lifecycle_event(&deps.engine_host, "enqueue", &item, None).await;

    let drained = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        EngineQueueDrainer::drain_receipt(&deps.engine_host, &item.receipt_id, "engine-job-sync"),
    )
    .await
    .map_err(|_| CapabilityError::Internal {
        message: format!(
            "Timed out waiting for queued job command receipt {}",
            item.receipt_id
        ),
    })?
    .map_err(crate::server::shared::error_mapping::engine_error_to_capability_error)?;
    let Some(result) = drained else {
        return Err(CapabilityError::Internal {
            message: format!(
                "Queued job command receipt {} was not claimable",
                item.receipt_id
            ),
        });
    };
    crate::server::shared::error_mapping::result_to_capability_value(result)
}

pub(super) async fn job_background_apply_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let job_id = require_string_param(params, "jobId")?;
    let session_id = require_string_param(params, "sessionId")?;
    let pm = deps
        .process_manager
        .as_ref()
        .ok_or_else(|| CapabilityError::Internal {
            message: "Process manager not available".into(),
        })?;
    pm.promote_to_background(&job_id)
        .map_err(|e| CapabilityError::Internal {
            message: format!("Failed to background: {e}"),
        })?;
    let label = pm
        .list_processes(&session_id)
        .into_iter()
        .find(|p| p.process_id == job_id)
        .map(|p| p.label)
        .unwrap_or_default();
    persist_user_action(
        &deps.event_store,
        &session_id,
        &job_id,
        "backgrounded",
        &label,
    );
    publish_job_stream(invocation, deps, &session_id, &job_id, "backgrounded").await;
    Ok(json!({
        "jobId": job_id,
        "backgrounded": true,
    }))
}

pub(super) async fn job_cancel_apply_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let job_id = require_string_param(params, "jobId")?;
    let session_id = require_string_param(params, "sessionId")?;
    if let Some(ref jm) = deps.job_manager {
        jm.cancel_job(&job_id, true)
            .map_err(|e| CapabilityError::Internal {
                message: format!("Failed to cancel: {e}"),
            })?;
    } else if let Some(ref pm) = deps.process_manager {
        pm.cancel_process(&job_id, true)
            .map_err(|e| CapabilityError::Internal {
                message: format!("Failed to cancel: {e}"),
            })?;
    } else {
        return Err(CapabilityError::Internal {
            message: "No job manager available".into(),
        });
    }
    let label = deps
        .process_manager
        .as_ref()
        .map(|pm| {
            pm.list_processes(&session_id)
                .into_iter()
                .find(|p| p.process_id == job_id)
                .map(|p| p.label)
                .unwrap_or_default()
        })
        .unwrap_or_default();
    persist_user_action(&deps.event_store, &session_id, &job_id, "cancelled", &label);
    publish_job_stream(invocation, deps, &session_id, &job_id, "cancelled").await;
    Ok(json!({
        "jobId": job_id,
        "cancelled": true,
    }))
}

pub(super) fn job_list_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    if let Some(ref jm) = deps.job_manager {
        Ok(json!({ "jobs": jm.list_jobs(&session_id) }))
    } else if let Some(ref pm) = deps.process_manager {
        Ok(json!({ "jobs": pm.list_processes(&session_id) }))
    } else {
        Ok(json!({ "jobs": [] }))
    }
}

fn persist_user_action(
    event_store: &Arc<crate::events::EventStore>,
    session_id: &str,
    job_id: &str,
    action: &str,
    label: &str,
) {
    match event_store.append(&crate::events::AppendOptions {
        session_id,
        event_type: crate::events::EventType::NotificationUserJobAction,
        payload: json!({
            "jobId": job_id,
            "action": action,
            "label": label,
        }),
        parent_id: None,
        sequence: None,
    }) {
        Ok(event) => tracing::info!(
            job_id,
            action,
            session_id,
            event_id = %event.id,
            "persisted user job action"
        ),
        Err(error) => tracing::error!(
            job_id,
            action,
            session_id,
            error = %error,
            "failed to persist user job action"
        ),
    }
}

async fn publish_job_stream(
    invocation: &Invocation,
    deps: &Deps,
    session_id: &str,
    job_id: &str,
    action: &str,
) {
    let _ = deps
        .engine_host
        .publish_stream_event(crate::engine::PublishStreamEvent {
            topic: contract::STREAM_TOPICS[0].to_owned(),
            payload: json!({
                "sessionId": session_id,
                "jobId": job_id,
                "action": action,
            }),
            visibility: crate::engine::VisibilityScope::Session,
            session_id: Some(session_id.to_owned()),
            workspace_id: invocation.causal_context.workspace_id.clone(),
            producer: "job".to_owned(),
            trace_id: Some(invocation.causal_context.trace_id.clone()),
            parent_invocation_id: Some(invocation.id.clone()),
        })
        .await;
}

pub(super) async fn job_subscribe_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let job_id = require_string_param(params, "jobId")?;
    let session_id = require_string_param(params, "sessionId")?;
    let registry =
        deps.output_buffer_registry
            .as_ref()
            .ok_or_else(|| CapabilityError::Internal {
                message: "Output buffer registry not available".into(),
            })?;
    let (buffer, tool_call_id) =
        registry
            .get(&job_id)
            .ok_or_else(|| CapabilityError::InvalidParams {
                message: format!("No output buffer for job: {job_id}"),
            })?;

    if let Some((_, old_cancel)) = ACTIVE_SUBSCRIPTIONS.remove(&job_id) {
        old_cancel.cancel();
    }
    let cancel = CancellationToken::new();
    let _ = ACTIVE_SUBSCRIPTIONS.insert(job_id.clone(), cancel.clone());
    let emitter = deps.orchestrator.broadcast().clone();
    let sub_job_id = job_id.clone();
    drop(tokio::spawn(async move {
        run_subscriber(buffer, &tool_call_id, &session_id, &emitter, cancel).await;
        let _ = ACTIVE_SUBSCRIPTIONS.remove(&sub_job_id);
    }));

    Ok(json!({
        "subscribed": true,
        "jobId": job_id,
    }))
}

pub(super) fn job_unsubscribe_value(params: Option<&Value>) -> Result<Value, CapabilityError> {
    let job_id = require_string_param(params, "jobId")?;
    let cancelled = if let Some((_, cancel)) = ACTIVE_SUBSCRIPTIONS.remove(&job_id) {
        cancel.cancel();
        true
    } else {
        false
    };
    Ok(json!({
        "jobId": job_id,
        "unsubscribed": cancelled,
    }))
}

async fn run_subscriber(
    buffer: Arc<crate::runtime::orchestrator::output_buffer::SharedOutputBuffer>,
    tool_call_id: &str,
    session_id: &str,
    emitter: &Arc<crate::runtime::agent::event_emitter::EventEmitter>,
    cancel: CancellationToken,
) {
    let mut offset = 0;
    loop {
        let notified = buffer.notifier().notified();
        let (chunks, new_offset) = buffer.read_from(offset);
        offset = new_offset;
        for chunk in chunks {
            let _ = emitter.emit(crate::core::events::TronEvent::ToolExecutionUpdate {
                base: crate::core::events::BaseEvent::now(session_id),
                tool_call_id: tool_call_id.to_owned(),
                update: chunk,
            });
        }
        if buffer.is_closed() {
            let (final_chunks, _) = buffer.read_from(offset);
            for chunk in final_chunks {
                let _ = emitter.emit(crate::core::events::TronEvent::ToolExecutionUpdate {
                    base: crate::core::events::BaseEvent::now(session_id),
                    tool_call_id: tool_call_id.to_owned(),
                    update: chunk,
                });
            }
            break;
        }
        tokio::select! {
            () = cancel.cancelled() => break,
            () = notified => {}
        }
    }
}
