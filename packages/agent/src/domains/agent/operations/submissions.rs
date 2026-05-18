//! Agent workflow operations.
use super::{BaseEvent, EventType, PromptQueueService, TronEvent};
use super::{
    agent_capability_identity, emit_run_status, persist_lifecycle_event, persist_pause_record,
    persist_run_record, persist_run_status, publish_agent_queue_stream, resolve_pause_record,
    start_or_queue_prompt, string_param_or_context,
};
use crate::domains::agent::Deps;
use crate::domains::capability::types::{CapabilityPauseRecord, CapabilityRunRecord};
use crate::domains::capability_support::implementations::traits::{
    SubagentConfig, SubagentMode, SubagentOps, SubagentSpawner,
};
use crate::engine::{ActorKind, Invocation};
use crate::shared::content::CapabilityResultContent;
use crate::shared::model_capabilities::{CapabilityResult, CapabilityResultBody};
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::require_string_param;
use crate::shared::user_interaction::{UserInteractionParams, validate_params};
use chrono::{Duration, Utc};
use serde::Deserialize;
use serde_json::Value;
use serde_json::json;

pub(crate) async fn clear_queue_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let event_store = deps.event_store.clone();
    let sid = session_id.clone();

    let pending = run_blocking_task("agent.clearQueue.query", {
        let es = event_store.clone();
        let s = sid.clone();
        move || PromptQueueService::get_pending_queue(&es, &s)
    })
    .await?;

    let cleared = run_blocking_task("agent::clear_queue", move || {
        PromptQueueService::clear_queue(&event_store, &sid)
    })
    .await?;

    for item in &pending {
        let _ = deps
            .orchestrator
            .broadcast()
            .emit(TronEvent::MessageDequeued {
                base: BaseEvent::now(&session_id),
                queue_id: item.queue_id.clone(),
                reason: "cleared".into(),
            });
    }
    publish_agent_queue_stream(
        invocation,
        deps,
        &session_id,
        "cleared",
        json!({"cleared": cleared, "items": pending}),
    )
    .await;

    Ok(json!({ "cleared": cleared }))
}

pub(crate) async fn ask_user_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let payload = params.cloned().unwrap_or(Value::Null);
    let interaction: UserInteractionParams =
        serde_json::from_value(payload.clone()).map_err(|error| {
            CapabilityError::InvalidParams {
                message: format!("Invalid agent::ask_user payload: {error}"),
            }
        })?;
    let validation = validate_params(&interaction);
    if !validation.valid {
        return Err(CapabilityError::InvalidParams {
            message: validation
                .error
                .unwrap_or_else(|| "Invalid user interaction payload".to_owned()),
        });
    }

    let session_id = string_param_or_context(params, invocation, "sessionId")?;
    let pause_id = format!("pause_{}", uuid::Uuid::now_v7());
    let invocation_id = invocation.id.as_str().to_owned();
    let trace_id = invocation.causal_context.trace_id.as_str().to_owned();
    let expires_at = Utc::now() + Duration::hours(24);
    let identity = agent_capability_identity(invocation, "agent::ask_user");
    let prompt_payload = json!({
        "questions": interaction.questions,
        "context": interaction.context,
        "pauseId": pause_id,
        "invocationId": invocation_id,
        "interactionStatus": "pending"
    });
    let resume_schema = Some(json!({
        "type": "object",
        "required": ["sessionId", "questions"],
        "additionalProperties": false,
        "properties": {
            "pauseId": {"type": "string"},
            "invocationId": {"type": "string"},
            "sessionId": {"type": "string"},
            "questions": {"type": "array"}
        }
    }));
    let record = CapabilityPauseRecord {
        pause_id: pause_id.clone(),
        invocation_id: invocation_id.clone(),
        contract_id: "agent::ask_user".to_owned(),
        implementation_id: "first_party.agent.v1.ask_user".to_owned(),
        function_id: "agent::ask_user".to_owned(),
        plugin_id: Some("first_party.agent".to_owned()),
        worker_id: Some("agent".to_owned()),
        kind: "user_input".to_owned(),
        status: "pending".to_owned(),
        prompt_payload: prompt_payload.clone(),
        resume_schema: resume_schema.clone(),
        answer_authority: "user_client".to_owned(),
        expires_at: Some(expires_at.to_rfc3339()),
        trace_id: Some(trace_id.clone()),
        root_invocation_id: Some(invocation_id.clone()),
        binding_decision_id: invocation
            .causal_context
            .runtime_metadata
            .get("bindingDecisionId")
            .cloned(),
    };
    persist_pause_record(deps, record.clone()).await?;
    persist_lifecycle_event(
        deps,
        &session_id,
        EventType::CapabilityPauseRequested,
        json!({
            "pauseId": pause_id,
            "invocationId": invocation_id,
            "kind": "user_input",
            "status": "pending",
            "promptPayload": prompt_payload,
            "resumeSchema": resume_schema,
            "answerAuthority": "user_client",
            "expiresAt": expires_at.to_rfc3339(),
            "modelPrimitiveName": "execute",
            "contractId": "agent::ask_user",
            "implementationId": "first_party.agent.v1.ask_user",
            "functionId": "agent::ask_user",
            "pluginId": "first_party.agent",
            "workerId": "agent",
            "trustTier": "first_party_signed",
            "riskLevel": "Medium",
            "effectClass": "ExternalSideEffect",
            "traceId": trace_id,
            "rootInvocationId": invocation.id.as_str(),
        }),
    )
    .await?;
    let _ = deps
        .orchestrator
        .broadcast()
        .emit(TronEvent::CapabilityPauseRequested {
            base: BaseEvent::now(&session_id)
                .with_trace_context(Some(trace_id), Some(invocation.id.as_str().to_owned())),
            pause_id: record.pause_id.clone(),
            invocation_id: record.invocation_id.clone(),
            kind: record.kind.clone(),
            status: record.status.clone(),
            prompt_payload: record.prompt_payload.clone(),
            resume_schema: record.resume_schema.clone(),
            answer_authority: record.answer_authority.clone(),
            expires_at: record.expires_at.clone(),
            capability_identity: identity,
        });

    let result = CapabilityResult {
        content: CapabilityResultBody::Blocks(vec![CapabilityResultContent::text(
            "Waiting for user input.",
        )]),
        details: Some(json!({
            "status": "paused",
            "pause": record,
            "lifecycle": {
                "kind": "user_input",
                "stopsTurn": true,
                "resumeContractId": "agent::submit_answers"
            }
        })),
        is_error: None,
        stop_turn: Some(true),
    };
    serde_json::to_value(result).map_err(|error| CapabilityError::Internal {
        message: format!("serialize user interaction result: {error}"),
    })
}

#[derive(Deserialize)]
pub(crate) struct AnswerSubmission {
    #[serde(default)]
    id: Option<String>,
    question: String,
    #[serde(default)]
    #[serde(rename = "selectedValues")]
    selected_values: Vec<String>,
    #[serde(rename = "otherValue")]
    other_value: Option<String>,
}

pub(crate) async fn submit_answers_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    if matches!(
        invocation.causal_context.actor_kind,
        ActorKind::Agent | ActorKind::Worker | ActorKind::Cron | ActorKind::Queue
    ) {
        return Err(CapabilityError::Custom {
            code: "USER_INPUT_AUTHORITY_REQUIRED".to_owned(),
            message: "agent::submit_answers can only resolve user-input pauses from user/client authority".to_owned(),
            details: Some(json!({
                "actorKind": format!("{:?}", invocation.causal_context.actor_kind),
                "requiredAuthority": "user_client"
            })),
        });
    }
    let session_id = require_string_param(params, "sessionId")?;
    let pause_id = require_string_param(params, "pauseId")?;
    let questions_value =
        params
            .and_then(|p| p.get("questions"))
            .ok_or_else(|| CapabilityError::InvalidParams {
                message: "Missing required param: questions".into(),
            })?;
    let answers: Vec<AnswerSubmission> =
        serde_json::from_value(questions_value.clone()).map_err(|e| {
            CapabilityError::InvalidParams {
                message: format!("Invalid questions format: {e}"),
            }
        })?;
    if answers.is_empty() {
        return Err(CapabilityError::InvalidParams {
            message: "questions array must not be empty".into(),
        });
    }
    resolve_pause_record(deps, &pause_id, "resumed", questions_value.clone()).await?;
    persist_lifecycle_event(
        deps,
        &session_id,
        EventType::CapabilityPauseResolved,
        json!({
            "pauseId": pause_id,
            "invocationId": params
                .and_then(|p| p.get("invocationId"))
                .and_then(Value::as_str)
                .unwrap_or(invocation.id.as_str()),
            "status": "resumed",
            "resolution": {"answerCount": answers.len()},
            "modelPrimitiveName": "execute",
            "contractId": "agent::ask_user",
            "implementationId": "first_party.agent.v1.ask_user",
            "functionId": "agent::ask_user",
            "pluginId": "first_party.agent",
            "workerId": "agent",
            "traceId": invocation.causal_context.trace_id.as_str(),
            "rootInvocationId": invocation.id.as_str(),
        }),
    )
    .await?;
    let _ = deps
        .orchestrator
        .broadcast()
        .emit(TronEvent::CapabilityPauseResolved {
            base: BaseEvent::now(&session_id).with_trace_context(
                Some(invocation.causal_context.trace_id.as_str().to_owned()),
                Some(invocation.id.as_str().to_owned()),
            ),
            pause_id: pause_id.to_owned(),
            invocation_id: params
                .and_then(|p| p.get("invocationId"))
                .and_then(Value::as_str)
                .unwrap_or(invocation.id.as_str())
                .to_owned(),
            status: "resumed".to_owned(),
            resolution: Some(json!({"answerCount": answers.len()})),
            capability_identity: agent_capability_identity(invocation, "agent::ask_user"),
        });
    let mut lines = vec!["[Answers to your questions]".to_string(), String::new()];
    for answer in &answers {
        lines.push(format!("**{}**", answer.question));
        if let Some(id) = answer.id.as_deref()
            && !id.is_empty()
        {
            lines.push(format!("Question ID: {id}"));
        }
        if let Some(ref other) = answer.other_value {
            if !other.is_empty() {
                lines.push(format!("Answer: [Other] {other}"));
            } else if !answer.selected_values.is_empty() {
                lines.push(format!("Answer: {}", answer.selected_values.join(", ")));
            } else {
                lines.push("Answer: (no selection)".to_string());
            }
        } else if !answer.selected_values.is_empty() {
            lines.push(format!("Answer: {}", answer.selected_values.join(", ")));
        } else {
            lines.push("Answer: (no selection)".to_string());
        }
        lines.push(String::new());
    }
    start_or_queue_prompt(
        deps,
        session_id,
        lines.join("\n"),
        Some(json!({
            "messageKind": "answered_questions",
            "answerCount": answers.len(),
        })),
        "agent.submitAnswers.queue",
        true,
    )
    .await
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SubagentSpawnRequest {
    session_id: String,
    task: String,
    #[serde(default)]
    workspace_id: Option<String>,
    #[serde(default)]
    model: Option<String>,
    #[serde(default)]
    system_prompt: Option<String>,
    #[serde(default)]
    working_directory: Option<String>,
    #[serde(default)]
    max_turns: Option<u32>,
    #[serde(default)]
    timeout_ms: Option<u64>,
    #[serde(default)]
    blocking_timeout_ms: Option<u64>,
    #[serde(default)]
    denied_contracts: Vec<String>,
    #[serde(default)]
    skills: Option<Vec<String>>,
    #[serde(default)]
    max_depth: Option<u32>,
}

pub(crate) async fn spawn_subagent_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let request: SubagentSpawnRequest =
        serde_json::from_value(params.cloned().unwrap_or(Value::Null)).map_err(|error| {
            CapabilityError::InvalidParams {
                message: format!("Invalid agent::spawn_subagent payload: {error}"),
            }
        })?;
    if request.task.trim().is_empty() {
        return Err(CapabilityError::InvalidParams {
            message: "task must not be empty".to_owned(),
        });
    }
    let manager = deps
        .subagent_manager
        .as_ref()
        .ok_or_else(|| CapabilityError::Internal {
            message: "Subagent manager is not available".to_owned(),
        })?;
    let working_directory = request.working_directory.unwrap_or_else(|| {
        deps.session_manager
            .get_session(&request.session_id)
            .ok()
            .flatten()
            .map(|session| session.working_directory)
            .unwrap_or_default()
    });
    let config = SubagentConfig {
        task: request.task.clone(),
        mode: SubagentMode::InProcess,
        blocking_timeout_ms: request.blocking_timeout_ms.or(Some(0)),
        model: request.model,
        parent_session_id: Some(request.session_id.clone()),
        system_prompt: request.system_prompt,
        working_directory,
        max_turns: request.max_turns.unwrap_or(6),
        timeout_ms: request.timeout_ms.unwrap_or(600_000),
        denied_contracts: request.denied_contracts,
        skills: request.skills,
        max_depth: request.max_depth.unwrap_or(0),
        current_depth: 0,
        invocation_id: Some(invocation.id.as_str().to_owned()),
    };
    let handle = manager
        .spawn(config)
        .await
        .map_err(|error| CapabilityError::Internal {
            message: format!("Failed to spawn subagent: {error}"),
        })?;
    let status = if handle.success.is_some() {
        "completed"
    } else {
        "running"
    };
    let payload = json!({
        "runId": handle.session_id,
        "invocationId": invocation.id.as_str(),
        "status": status,
        "kind": "agent",
        "task": request.task,
        "sessionId": request.session_id,
        "workspaceId": request.workspace_id,
        "handle": handle,
    });
    persist_run_record(
        deps,
        CapabilityRunRecord {
            run_id: payload
                .get("runId")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_owned(),
            invocation_id: invocation.id.as_str().to_owned(),
            contract_id: "agent::spawn_subagent".to_owned(),
            implementation_id: "first_party.agent.v1.spawn_subagent".to_owned(),
            function_id: "agent::spawn_subagent".to_owned(),
            plugin_id: Some("first_party.agent".to_owned()),
            worker_id: Some("agent".to_owned()),
            status: status.to_owned(),
            stream_topic: Some("agent.runtime".to_owned()),
            child_invocations: Vec::new(),
            details: payload.clone(),
            trace_id: Some(invocation.causal_context.trace_id.as_str().to_owned()),
            root_invocation_id: Some(invocation.id.as_str().to_owned()),
            binding_decision_id: invocation
                .causal_context
                .runtime_metadata
                .get("bindingDecisionId")
                .cloned(),
        },
    )
    .await?;
    emit_run_status(
        deps,
        &request.session_id,
        invocation,
        "agent::spawn_subagent",
        payload.clone(),
    );
    Ok(payload)
}

pub(crate) fn subagent_status_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let subagent_session_id = require_string_param(params, "subagentSessionId")?;
    let manager = deps
        .subagent_manager
        .as_ref()
        .ok_or_else(|| CapabilityError::Internal {
            message: "Subagent manager is not available".to_owned(),
        })?;
    let jobs = manager.list_active_jobs(&session_id);
    let job = jobs.into_iter().find(|job| job.id == subagent_session_id);
    Ok(json!({
        "subagentSessionId": subagent_session_id,
        "job": job,
        "status": job.as_ref().map(|job| format!("{:?}", job.state)).unwrap_or_else(|| "unknown".to_owned())
    }))
}

pub(crate) fn subagent_result_value(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let subagent_session_id = require_string_param(params, "subagentSessionId")?;
    let manager = deps
        .subagent_manager
        .as_ref()
        .ok_or_else(|| CapabilityError::Internal {
            message: "Subagent manager is not available".to_owned(),
        })?;
    match manager.get_subagent_result(&subagent_session_id) {
        Some(result) => Ok(json!({ "subagentSessionId": subagent_session_id, "result": result })),
        None => Err(CapabilityError::NotFound {
            code: "SUBAGENT_RESULT_NOT_READY".to_owned(),
            message: format!("No completed result found for subagent {subagent_session_id}"),
        }),
    }
}

pub(crate) async fn cancel_subagent_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, CapabilityError> {
    let session_id = require_string_param(params, "sessionId")?;
    let subagent_session_id = require_string_param(params, "subagentSessionId")?;
    let manager = deps
        .subagent_manager
        .as_ref()
        .ok_or_else(|| CapabilityError::Internal {
            message: "Subagent manager is not available".to_owned(),
        })?;
    manager
        .cancel_subagent(&subagent_session_id)
        .map_err(|error| CapabilityError::Internal {
            message: format!("Failed to cancel subagent: {error}"),
        })?;
    persist_run_status(
        deps,
        &subagent_session_id,
        "cancelled",
        json!({
            "runId": subagent_session_id,
            "invocationId": invocation.id.as_str(),
            "status": "cancelled",
            "kind": "agent"
        }),
    )
    .await?;
    emit_run_status(
        deps,
        &session_id,
        invocation,
        "agent::cancel_subagent",
        json!({
            "runId": subagent_session_id,
            "invocationId": invocation.id.as_str(),
            "status": "cancelled",
            "kind": "agent"
        }),
    );
    Ok(json!({
        "subagentSessionId": subagent_session_id,
        "cancelled": true
    }))
}
