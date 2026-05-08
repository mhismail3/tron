//! Agent workflow operations.
use super::{
    AgentCommandService, ENGINE_INTERNAL_INVOKE_SCOPE, EngineQueueDrainer, EnqueueInvocation,
    FunctionId, PromptEngineCausality, PromptRequest, drain_prompt_queue, errors,
    publish_queue_lifecycle_event,
};
use crate::engine::{ActorContext, FunctionRevision, Invocation};
use crate::server::domains::agent::Deps;
use crate::server::domains::agent::runtime::service::spawn_prompt_run;
use crate::server::shared::errors::CapabilityError;
use crate::server::shared::params::opt_array;
use crate::server::shared::params::opt_string;
use crate::server::shared::params::require_string_param;
use crate::server::shared::validation;
use serde_json::Value;
use serde_json::json;

pub(crate) struct PromptSubmission {
    session_id: String,
    prompt: String,
    reasoning_level: Option<String>,
    images: Option<Vec<Value>>,
    attachments: Option<Vec<Value>>,
    source: Option<String>,
}

pub(crate) async fn prompt_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let (submission, _, _) = validate_prompt_submission(Some(&invocation.payload), deps).await?;
    let run_id = uuid::Uuid::now_v7().to_string();
    let mut apply_payload = invocation.payload.clone();
    let Some(object) = apply_payload.as_object_mut() else {
        return Err(CapabilityError::InvalidParams {
            message: "agent.prompt params must be an object".into(),
        });
    };
    object.insert("runId".to_owned(), json!(run_id));
    publish_prompt_stream(
        invocation,
        deps,
        &submission.session_id,
        "accepted",
        json!({"runId": run_id}),
    )
    .await;
    enqueue_and_sync_drain_agent_function(
        invocation,
        deps,
        &submission.session_id,
        "agent::prompt_apply",
        "agent::prompt_apply",
        apply_payload,
    )
    .await
}

pub(crate) async fn prompt_apply_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let run_id = require_string_param(params, "runId")?;
    let (submission, _session, _agent_deps) = validate_prompt_submission(params, deps).await?;

    publish_prompt_stream(
        invocation,
        deps,
        &submission.session_id,
        "apply_started",
        json!({"runId": run_id}),
    )
    .await;
    enqueue_and_sync_drain_agent_function(
        invocation,
        deps,
        &submission.session_id,
        "agent::run_turn",
        "agent::run_turn",
        params.cloned().unwrap_or_else(|| json!({})),
    )
    .await
}

pub(crate) async fn run_turn_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let run_id = require_string_param(params, "runId")?;
    let (submission, session, agent_deps) = validate_prompt_submission(params, deps).await?;

    let started_run = deps
        .orchestrator
        .begin_run(&submission.session_id, &run_id)
        .map_err(|e| CapabilityError::Custom {
            code: e.category().to_uppercase(),
            message: e.to_string(),
            details: None,
        })?;

    record_prompt_history_through_engine(
        invocation,
        deps,
        &submission.session_id,
        &run_id,
        &submission.prompt,
        submission.source.as_deref(),
    );
    publish_prompt_stream(
        invocation,
        deps,
        &submission.session_id,
        "run_turn_started",
        json!({
            "runId": run_id,
            "model": session.latest_model,
            "provider": "unknown",
            "catalogRevision": invocation.causal_context.catalog_revision.0,
        }),
    )
    .await;
    spawn_prompt_run(
        &deps.prompt_runtime(),
        &agent_deps,
        &session,
        started_run,
        run_id.clone(),
        PromptRequest {
            session_id: submission.session_id,
            prompt: submission.prompt,
            reasoning_level: submission.reasoning_level,
            images: submission.images,
            attachments: submission.attachments,
            message_metadata: None,
            engine_causality: Some(PromptEngineCausality::from_invocation(invocation)),
        },
    );

    Ok(json!({
        "acknowledged": true,
        "runId": run_id,
    }))
}

pub(crate) async fn prompt_queue_drain_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let session = AgentCommandService::load_prompt_session(deps, &session_id).await?;
    let agent_deps = deps
        .agent_deps
        .as_ref()
        .ok_or_else(|| CapabilityError::NotAvailable {
            message: "Agent execution dependencies are not configured".into(),
        })?;
    let outcome = drain_prompt_queue(
        &deps.event_store,
        &deps.orchestrator,
        &deps.session_manager,
        &session_id,
        &session.latest_model,
        &session.working_directory,
        deps.orchestrator.broadcast().clone(),
        agent_deps.provider_factory.clone(),
        agent_deps.guardrails.clone(),
        deps.health_tracker.clone(),
        deps.context_artifacts.clone(),
        deps.skill_registry.clone(),
        deps.memory_registry.clone(),
        deps.profile_runtime.clone(),
        deps.subagent_manager.clone(),
        deps.shutdown_coordinator
            .as_ref()
            .map(|coord| coord.token()),
        deps.worktree_coordinator.clone(),
        deps.process_manager.clone(),
        deps.job_manager.clone(),
        deps.output_buffer_registry.clone(),
        deps.hook_abort_tracker.clone(),
        deps.origin.clone(),
        deps.engine_host.clone(),
        Some(PromptEngineCausality::from_invocation(invocation)),
    )?;
    publish_prompt_stream(
        invocation,
        deps,
        &session_id,
        "queue_drained",
        serde_json::to_value(&outcome).unwrap_or_else(|_| json!({})),
    )
    .await;
    serde_json::to_value(outcome).map_err(|e| CapabilityError::Internal {
        message: format!("Failed to serialize prompt queue drain outcome: {e}"),
    })
}

pub(crate) async fn validate_prompt_submission(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<
    (
        PromptSubmission,
        crate::events::sqlite::row_types::SessionRow,
        crate::server::shared::context::AgentDeps,
    ),
    CapabilityError,
> {
    let session_id = require_string_param(params, "sessionId")?;
    let prompt = require_string_param(params, "prompt")?;
    validation::validate_string_param(&prompt, "prompt", validation::MAX_PROMPT_LENGTH)?;
    let images = opt_array(params, "images").cloned();
    let attachments = opt_array(params, "attachments").cloned();
    validate_attachment_arrays(images.as_deref(), attachments.as_deref())?;

    if let Some(active_run_id) = deps.orchestrator.get_run_id(&session_id) {
        return Err(CapabilityError::Custom {
            code: errors::SESSION_BUSY.into(),
            message: format!("Session '{session_id}' is already processing run '{active_run_id}'"),
            details: Some(json!({ "runId": active_run_id })),
        });
    }

    let session = AgentCommandService::load_prompt_session(deps, &session_id).await?;
    let agent_deps =
        deps.agent_deps
            .as_ref()
            .cloned()
            .ok_or_else(|| CapabilityError::NotAvailable {
                message: "Agent execution dependencies are not configured".into(),
            })?;
    Ok((
        PromptSubmission {
            session_id,
            prompt,
            reasoning_level: opt_string(params, "reasoningLevel"),
            images,
            attachments,
            source: opt_string(params, "source"),
        },
        session,
        agent_deps,
    ))
}

pub(crate) fn validate_attachment_arrays(
    images: Option<&[Value]>,
    attachments: Option<&[Value]>,
) -> Result<(), CapabilityError> {
    if let Some(images) = images {
        for image in images {
            if let Some(data) = image.get("data").and_then(Value::as_str) {
                validation::validate_attachment_size(data)?;
            }
        }
    }
    if let Some(attachments) = attachments {
        for attachment in attachments {
            if let Some(data) = attachment.get("data").and_then(Value::as_str) {
                validation::validate_attachment_size(data)?;
            }
        }
    }
    Ok(())
}

pub(crate) async fn enqueue_and_sync_drain_agent_function(
    invocation: &Invocation,
    deps: &Deps,
    session_id: &str,
    function_id: &str,
    idempotency_prefix: &str,
    payload: Value,
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
            queue: "agent".to_owned(),
            target_revision: target_revision_for_enqueue(
                &deps.engine_host,
                &function_id,
                invocation,
            )
            .await?,
            function_id,
            payload,
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
    publish_prompt_stream(
        invocation,
        deps,
        invocation
            .causal_context
            .session_id
            .as_deref()
            .unwrap_or_default(),
        "apply_enqueued",
        json!({"receiptId": item.receipt_id, "queue": item.queue, "function": idempotency_prefix}),
    )
    .await;

    let drained = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        EngineQueueDrainer::drain_receipt(&deps.engine_host, &item.receipt_id, "engine-agent-sync"),
    )
    .await
    .map_err(|_| CapabilityError::Internal {
        message: format!(
            "Timed out waiting for queued prompt command receipt {}",
            item.receipt_id
        ),
    })?
    .map_err(crate::server::shared::error_mapping::engine_error_to_capability_error)?;
    let Some(result) = drained else {
        return Err(CapabilityError::Internal {
            message: format!(
                "Queued prompt command receipt {} was not claimable",
                item.receipt_id
            ),
        });
    };
    if let Some(error) = &result.error {
        publish_prompt_stream(
            invocation,
            deps,
            session_id,
            "apply_failed",
            json!({
                "receiptId": item.receipt_id,
                "error": error.to_string(),
            }),
        )
        .await;
    }
    crate::server::shared::error_mapping::result_to_capability_value(result)
}

pub(crate) fn record_prompt_history_through_engine(
    invocation: &Invocation,
    deps: &Deps,
    session_id: &str,
    run_id: &str,
    prompt: &str,
    source: Option<&str>,
) {
    let function_id = match FunctionId::new("prompt_library::history_record") {
        Ok(id) => id,
        Err(error) => {
            tracing::warn!(session_id, run_id, error = %error, "invalid prompt history function id");
            return;
        }
    };
    let mut context = invocation.causal_context.clone();
    context.parent_invocation_id = Some(invocation.id.clone());
    context.session_id = Some(session_id.to_owned());
    add_scope_once(&mut context.authority_scopes, ENGINE_INTERNAL_INVOKE_SCOPE);
    add_scope_once(&mut context.authority_scopes, "prompt_library.write");
    context.idempotency_key = Some(format!(
        "prompt_library.history_record:{session_id}:{run_id}:{}",
        invocation.id
    ));
    let payload = json!({
        "sessionId": session_id,
        "prompt": prompt,
        "source": source,
        "workspaceId": invocation.causal_context.workspace_id.clone(),
    });
    let host = deps.engine_host.clone();
    let shutdown = deps.shutdown_coordinator.clone();
    let handle = tokio::spawn(async move {
        let result = host
            .invoke(Invocation::new_sync(function_id.clone(), payload, context))
            .await;
        if let Some(error) = result.error {
            tracing::warn!(
                function_id = %function_id,
                error = %error,
                "prompt history record engine invocation failed"
            );
        }
    });
    if let Some(shutdown) = shutdown {
        shutdown.register_task(handle);
    }
}

pub(crate) async fn publish_prompt_stream(
    invocation: &Invocation,
    deps: &Deps,
    session_id: &str,
    action: &str,
    payload: Value,
) {
    crate::server::domains::agent::stream::AgentStreamPublisher::new(&deps.engine_host)
        .prompt(invocation, session_id, action, payload)
        .await;
}

async fn target_revision_for_enqueue(
    engine_host: &crate::engine::EngineHostHandle,
    function_id: &FunctionId,
    invocation: &Invocation,
) -> Result<Option<FunctionRevision>, CapabilityError> {
    let mut actor = ActorContext::new(
        invocation.causal_context.actor_id.clone(),
        invocation.causal_context.actor_kind.clone(),
        invocation.causal_context.authority_grant_id.clone(),
    );
    actor.authority_scopes = invocation.causal_context.authority_scopes.clone();
    add_scope_once(&mut actor.authority_scopes, ENGINE_INTERNAL_INVOKE_SCOPE);
    actor.session_id = invocation.causal_context.session_id.clone();
    actor.workspace_id = invocation.causal_context.workspace_id.clone();
    let function = engine_host
        .inspect_function(function_id, Some(&actor))
        .await
        .map_err(crate::server::shared::error_mapping::engine_error_to_capability_error)?;
    Ok(Some(function.revision))
}

fn add_scope_once(scopes: &mut Vec<String>, scope: &str) {
    if !scopes.iter().any(|existing| existing == scope) {
        scopes.push(scope.to_owned());
    }
}
