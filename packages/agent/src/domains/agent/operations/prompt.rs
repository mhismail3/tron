//! Agent workflow operations.
use super::{
    AgentCommandService, ENGINE_INTERNAL_INVOKE_SCOPE, PromptEngineCausality, PromptRequest, errors,
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
    attachments: Option<Vec<Value>>,
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
    let attachments = opt_array(params, "attachments").cloned();
    validate_attachment_array(attachments.as_deref())?;

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
            attachments,
        },
        session,
        agent_deps,
    ))
}

pub(crate) fn validate_attachment_array(
    attachments: Option<&[Value]>,
) -> Result<(), CapabilityError> {
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
