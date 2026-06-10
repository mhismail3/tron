//! Agent workflow operations.
use super::{
    AgentCommandService, ENGINE_INTERNAL_INVOKE_SCOPE, PromptEngineCausality, PromptRequest, errors,
};
use crate::domains::agent::Deps;
use crate::domains::agent::runtime::service::spawn_prompt_run;
use crate::engine::{FunctionId, Invocation};
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
        crate::domains::session::event_store::SessionRow,
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
    let context = trusted_agent_internal_child_context(invocation, idempotency_prefix);
    let child = Invocation::new_sync(function_id.clone(), payload, context);
    publish_prompt_stream(
        invocation,
        deps,
        invocation
            .causal_context
            .session_id
            .as_deref()
            .unwrap_or_default(),
        "apply_invoked",
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

fn trusted_agent_internal_child_context(
    invocation: &Invocation,
    idempotency_prefix: &str,
) -> crate::engine::CausalContext {
    let mut context = invocation.causal_context.clone();
    context.actor_id = crate::engine::ActorId::new("system:agent-runtime").expect("valid actor id");
    context.actor_kind = crate::engine::ActorKind::System;
    context.authority_grant_id =
        crate::engine::AuthorityGrantId::new("engine-system").expect("valid grant id");
    context.parent_invocation_id = Some(invocation.id.clone());
    if !context
        .authority_scopes
        .iter()
        .any(|scope| scope == ENGINE_INTERNAL_INVOKE_SCOPE)
    {
        context
            .authority_scopes
            .push(ENGINE_INTERNAL_INVOKE_SCOPE.to_owned());
    }
    context.idempotency_key = Some(format!("{idempotency_prefix}:{}", invocation.id));
    context.delivery_mode = crate::engine::DeliveryMode::Sync;
    context
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::{ActorId, ActorKind, AuthorityGrantId, CausalContext, FunctionId, TraceId};

    #[test]
    fn hidden_prompt_child_context_is_engine_owned_not_public_caller() {
        let parent = Invocation::new_sync(
            FunctionId::new("agent::prompt").expect("function id"),
            json!({"sessionId": "session-a", "prompt": "hello"}),
            CausalContext::new(
                ActorId::new("engine-client").expect("actor id"),
                ActorKind::Client,
                AuthorityGrantId::new("engine-transport").expect("grant id"),
                TraceId::new("prompt-parent").expect("trace id"),
            )
            .with_scope("agent.write")
            .with_session_id("session-a")
            .with_workspace_id("workspace-a"),
        );

        let child = trusted_agent_internal_child_context(&parent, "agent::prompt_apply");

        assert_eq!(child.actor_id.as_str(), "system:agent-runtime");
        assert_eq!(child.actor_kind, ActorKind::System);
        assert_eq!(child.authority_grant_id.as_str(), "engine-system");
        assert_eq!(child.parent_invocation_id, Some(parent.id));
        assert_eq!(child.session_id.as_deref(), Some("session-a"));
        assert_eq!(child.workspace_id.as_deref(), Some("workspace-a"));
        assert!(
            child
                .authority_scopes
                .iter()
                .any(|scope| scope == ENGINE_INTERNAL_INVOKE_SCOPE)
        );
        assert!(
            child
                .idempotency_key
                .as_deref()
                .is_some_and(|key| key.starts_with("agent::prompt_apply:"))
        );
    }
}
