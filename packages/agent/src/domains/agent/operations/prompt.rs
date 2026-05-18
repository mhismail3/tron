//! Agent workflow operations.
use super::{
    AgentCommandService, ENGINE_INTERNAL_INVOKE_SCOPE, PromptEngineCausality, PromptRequest,
    drain_prompt_queue, errors,
};
use crate::domains::agent::Deps;
use crate::domains::agent::runtime::service::spawn_prompt_run;
use crate::engine::{ActorContext, FunctionId, FunctionRevision, Invocation};
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::opt_array;
use crate::shared::server::params::opt_string;
use crate::shared::server::params::require_string_param;
use crate::shared::server::validation;
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
    invoke_agent_function_sync(
        invocation,
        deps,
        &submission.session_id,
        "agent::prompt_apply",
        "agent::prompt_apply",
        apply_payload,
    )
    .await
}

pub(crate) async fn run_goal_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let goal_id = require_string_param(Some(&invocation.payload), "goalResourceId")?;
    let promoted_resource_ids = invocation
        .payload
        .get("promotedResourceIds")
        .and_then(Value::as_array)
        .ok_or_else(|| CapabilityError::InvalidParams {
            message: "agent::run_goal requires promotedResourceIds".to_owned(),
        })?
        .iter()
        .map(|value| {
            value
                .as_str()
                .map(str::to_owned)
                .ok_or_else(|| CapabilityError::InvalidParams {
                    message: "promotedResourceIds must be a string array".to_owned(),
                })
        })
        .collect::<Result<Vec<_>, _>>()?;
    if promoted_resource_ids.is_empty() {
        return Err(CapabilityError::InvalidParams {
            message: "agent::run_goal requires at least one promoted resource".to_owned(),
        });
    }
    let decision_payload = invocation.payload.get("decision").cloned().ok_or_else(|| {
        CapabilityError::InvalidParams {
            message: "agent::run_goal requires decision".to_owned(),
        }
    })?;
    let final_message = invocation
        .payload
        .get("finalMessage")
        .and_then(Value::as_str)
        .unwrap_or("Goal run completed with promoted resource outputs.");

    let agent_result = invoke_engine_json(
        invocation,
        deps,
        "resource::create",
        json!({
            "kind": "agent_result",
            "scope": invocation.payload.get("scope").and_then(Value::as_str).unwrap_or("session"),
            "sessionId": invocation.payload.get("sessionId").cloned().or_else(|| invocation.causal_context.session_id.clone().map(Value::String)),
            "workspaceId": invocation.payload.get("workspaceId").cloned().or_else(|| invocation.causal_context.workspace_id.clone().map(Value::String)),
            "payload": {
                "message": final_message,
                "promotedRefs": promoted_resource_ids.clone(),
                "decisionRefs": [],
                "subgoalRefs": [],
                "stopReason": "goal_completed",
                "tokenUsage": {},
                "metadata": {
                    "goalResourceId": goal_id,
                    "coordinatorWorker": invocation.payload.get("coordinatorWorker").cloned().unwrap_or_else(|| json!("agent")),
                    "runMode": invocation.payload.get("runMode").cloned().unwrap_or_else(|| json!("resource_native"))
                }
            }
        }),
        "agent.run_goal.agent_result",
    )
    .await?;
    let agent_result_id = agent_result
        .get("resource")
        .and_then(|resource| resource.get("resourceId"))
        .and_then(Value::as_str)
        .ok_or_else(|| CapabilityError::Internal {
            message: "resource::create did not return agent_result resource id".to_owned(),
        })?
        .to_owned();

    let completion = invoke_engine_json(
        invocation,
        deps,
        "goal::complete",
        json!({
            "goalResourceId": goal_id,
            "agentResultResourceId": agent_result_id,
            "promotedResourceIds": promoted_resource_ids,
            "decision": decision_payload,
            "metadata": {
                "source": "agent::run_goal",
                "parentInvocationId": invocation.id.as_str()
            }
        }),
        "agent.run_goal.complete",
    )
    .await?;
    let working_set = invoke_engine_json(
        invocation,
        deps,
        "goal::working_set",
        json!({"goalResourceId": goal_id, "limit": 100}),
        "agent.run_goal.working_set",
    )
    .await
    .unwrap_or_else(|error| json!({"error": error.to_string()}));

    let mut resource_refs = agent_result
        .get("resourceRefs")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    resource_refs.extend(
        completion
            .get("resourceRefs")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default(),
    );
    Ok(json!({
        "goalResourceId": goal_id,
        "agentResult": agent_result["resource"].clone(),
        "decision": completion["decision"].clone(),
        "workingSet": working_set,
        "resourceRefs": resource_refs,
    }))
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
    invoke_agent_function_sync(
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
        crate::domains::session::event_store::sqlite::row_types::SessionRow,
        crate::shared::server::context::AgentDeps,
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

pub(crate) async fn invoke_agent_function_sync(
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
    let mut context = invocation.causal_context.clone();
    context.parent_invocation_id = Some(invocation.id.clone());
    context.authority_scopes = authority_scopes;
    context.idempotency_key = Some(format!("{idempotency_prefix}:{}", invocation.id));
    context.delivery_mode = crate::engine::DeliveryMode::Sync;
    let mut child = Invocation::new_sync(function_id.clone(), payload, context);
    child.expected_function_revision =
        target_revision_for_enqueue(&deps.engine_host, &function_id, invocation).await?;
    publish_prompt_stream(
        invocation,
        deps,
        invocation
            .causal_context
            .session_id
            .as_deref()
            .unwrap_or_default(),
        "apply_enqueued",
        json!({"function": idempotency_prefix}),
    )
    .await;

    let result = tokio::time::timeout(
        std::time::Duration::from_secs(5),
        deps.engine_host.invoke(child),
    )
    .await
    .map_err(|_| CapabilityError::Internal {
        message: format!("Timed out waiting for prompt command {idempotency_prefix}"),
    })?;
    if let Some(error) = &result.error {
        publish_prompt_stream(
            invocation,
            deps,
            session_id,
            "apply_failed",
            json!({
                "error": error.to_string(),
            }),
        )
        .await;
    }
    crate::shared::server::error_mapping::result_to_capability_value(result)
}

async fn invoke_engine_json(
    invocation: &Invocation,
    deps: &Deps,
    function_id: &str,
    payload: Value,
    idempotency_prefix: &str,
) -> Result<Value, CapabilityError> {
    let function_id = FunctionId::new(function_id).map_err(|e| CapabilityError::Internal {
        message: e.to_string(),
    })?;
    let mut context = invocation.causal_context.clone();
    context.parent_invocation_id = Some(invocation.id.clone());
    add_scope_once(&mut context.authority_scopes, ENGINE_INTERNAL_INVOKE_SCOPE);
    add_scope_once(&mut context.authority_scopes, "resource.write");
    add_scope_once(&mut context.authority_scopes, "resource.read");
    context.idempotency_key = Some(format!("{idempotency_prefix}:{}", invocation.id));
    context.delivery_mode = crate::engine::DeliveryMode::Sync;
    let result = deps
        .engine_host
        .invoke(Invocation::new_sync(function_id, payload, context))
        .await;
    crate::shared::server::error_mapping::result_to_capability_value(result)
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
    crate::domains::agent::stream::AgentStreamPublisher::new(&deps.engine_host)
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
        .map_err(crate::shared::server::error_mapping::engine_error_to_capability_error)?;
    Ok(Some(function.revision))
}

fn add_scope_once(scopes: &mut Vec<String>, scope: &str) {
    if !scopes.iter().any(|existing| existing == scope) {
        scopes.push(scope.to_owned());
    }
}
