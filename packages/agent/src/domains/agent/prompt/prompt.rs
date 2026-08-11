//! Agent workflow operations.
use std::sync::Arc;

use super::{AgentCommandService, PromptEngineCausality, PromptRequest, errors};
use crate::domains::agent::Deps;
use crate::domains::agent::runtime::service::spawn_prompt_run;
use crate::domains::model::responder::ModelResponderFactory;
use crate::engine::{FunctionId, Invocation};
use crate::shared::server::errors::ToolError;
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
    user_input_answer: Option<Value>,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct UserInputAnswerSubmission {
    question_id: String,
    selected_label: Option<String>,
    free_text: Option<String>,
}

#[derive(serde::Deserialize)]
struct UserInputRequestDefinition {
    questions: Vec<UserInputQuestionDefinition>,
}

#[derive(serde::Deserialize)]
struct UserInputQuestionDefinition {
    id: String,
    options: Vec<UserInputOptionDefinition>,
}

#[derive(serde::Deserialize)]
struct UserInputOptionDefinition {
    label: String,
}

pub(crate) async fn request_user_input_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, ToolError> {
    if invocation.causal_context.origin_worker_id().is_some() {
        return Err(ToolError::NotAvailable {
            message: "Delegated workers return missing information to their parent agent; only the user-facing session can request input".into(),
        });
    }
    let session_id = invocation
        .causal_context
        .session_id
        .as_deref()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| ToolError::InvalidParams {
            message: "request_user_input requires a source session".into(),
        })?;
    let invocation_id = invocation
        .causal_context
        .model_tool_invocation_id()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| ToolError::InvalidParams {
            message: "request_user_input requires a provider invocation id".into(),
        })?;
    let request = serde_json::from_value::<UserInputRequestDefinition>(invocation.payload.clone())
        .map_err(|error| ToolError::InvalidParams {
            message: format!("invalid user input request: {error}"),
        })?;
    validate_user_input_request(&request)?;
    let _ = AgentCommandService::load_prompt_session(deps, session_id).await?;
    Ok(json!({
        "invocationId": invocation_id,
        "status": "pending",
    }))
}

fn validate_user_input_request(request: &UserInputRequestDefinition) -> Result<(), ToolError> {
    let mut question_ids = std::collections::BTreeSet::new();
    for question in &request.questions {
        if !question_ids.insert(question.id.as_str()) {
            return Err(ToolError::InvalidParams {
                message: format!("Question id '{}' is duplicated", question.id),
            });
        }
        let mut option_labels = std::collections::BTreeSet::new();
        for option in &question.options {
            let normalized = option.label.trim().to_lowercase();
            if normalized == "other" {
                return Err(ToolError::InvalidParams {
                    message: "Do not provide an Other option; the client adds it automatically"
                        .into(),
                });
            }
            if !option_labels.insert(normalized) {
                return Err(ToolError::InvalidParams {
                    message: format!(
                        "Option labels for question '{}' must be unique",
                        question.id
                    ),
                });
            }
        }
    }
    Ok(())
}

pub(crate) async fn answer_user_input_value(
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, ToolError> {
    let session_id = require_string_param(Some(&invocation.payload), "sessionId")?;
    let invocation_id = require_string_param(Some(&invocation.payload), "invocationId")?;
    let answers =
        invocation
            .payload
            .get("answers")
            .cloned()
            .ok_or_else(|| ToolError::InvalidParams {
                message: "answers are required".into(),
            })?;
    let decoded = serde_json::from_value::<Vec<UserInputAnswerSubmission>>(answers.clone())
        .map_err(|error| ToolError::InvalidParams {
            message: format!("invalid user input answers: {error}"),
        })?;
    let event_store = deps.event_store.clone();
    let lookup_session_id = session_id.clone();
    let lookup_invocation_id = invocation_id.clone();
    let (state, request_arguments) =
        crate::shared::server::context::run_blocking_task("agent.user_input.state", move || {
            let state = event_store
                .user_input_request_state(&lookup_session_id, &lookup_invocation_id)
                .map_err(crate::shared::server::error_mapping::map_event_store_error)?;
            let arguments =
                if state == crate::domains::session::event_store::UserInputRequestState::Pending {
                    event_store
                        .user_input_request_arguments(&lookup_session_id, &lookup_invocation_id)
                        .map_err(crate::shared::server::error_mapping::map_event_store_error)?
                } else {
                    None
                };
            Ok((state, arguments))
        })
        .await?;
    match state {
        crate::domains::session::event_store::UserInputRequestState::Missing => {
            return Err(ToolError::InvalidParams {
                message: "The requested question is not pending in this session".into(),
            });
        }
        crate::domains::session::event_store::UserInputRequestState::Answered => {
            return Ok(json!({
                "acknowledged": true,
                "runId": "",
                "alreadyAnswered": true,
            }));
        }
        crate::domains::session::event_store::UserInputRequestState::Pending => {}
    }
    let request_arguments = request_arguments.ok_or_else(|| ToolError::InvalidParams {
        message: "The pending question is missing its canonical arguments".into(),
    })?;
    validate_user_input_answers(&request_arguments, &decoded)?;

    let prompt = format_user_input_answer(&decoded);
    let mut forwarded = invocation.clone();
    forwarded.payload = json!({
        "sessionId": session_id,
        "prompt": prompt,
        "userInputAnswer": {
            "invocationId": invocation_id,
            "answers": answers,
        }
    });
    prompt_value(&forwarded, deps).await
}

fn validate_user_input_answers(
    request_arguments: &Value,
    answers: &[UserInputAnswerSubmission],
) -> Result<(), ToolError> {
    let request = serde_json::from_value::<UserInputRequestDefinition>(request_arguments.clone())
        .map_err(|error| ToolError::InvalidParams {
        message: format!("The pending question is invalid: {error}"),
    })?;
    if answers.is_empty() {
        return Err(ToolError::InvalidParams {
            message: "At least one pending question requires an answer".into(),
        });
    }
    let mut seen = std::collections::BTreeSet::new();
    for answer in answers {
        if !seen.insert(answer.question_id.as_str()) {
            return Err(ToolError::InvalidParams {
                message: format!(
                    "Question '{}' was answered more than once",
                    answer.question_id
                ),
            });
        }
        let question = request
            .questions
            .iter()
            .find(|question| question.id == answer.question_id)
            .ok_or_else(|| ToolError::InvalidParams {
                message: format!("Question '{}' is not pending", answer.question_id),
            })?;
        let selected = answer
            .selected_label
            .as_deref()
            .filter(|value| !value.trim().is_empty());
        let custom = answer
            .free_text
            .as_deref()
            .filter(|value| !value.trim().is_empty());
        if selected.is_some() == custom.is_some() {
            return Err(ToolError::InvalidParams {
                message: format!(
                    "Question '{}' requires one selected option or one custom answer",
                    answer.question_id
                ),
            });
        }
        if let Some(selected) = selected
            && !question
                .options
                .iter()
                .any(|option| option.label == selected)
        {
            return Err(ToolError::InvalidParams {
                message: format!(
                    "Option '{selected}' was not offered for question '{}'",
                    answer.question_id
                ),
            });
        }
    }
    Ok(())
}

fn format_user_input_answer(answers: &[UserInputAnswerSubmission]) -> String {
    let lines = answers
        .iter()
        .map(|answer| {
            let value = answer
                .free_text
                .as_deref()
                .filter(|value| !value.trim().is_empty())
                .or(answer.selected_label.as_deref())
                .unwrap_or("No answer");
            format!("- {}: {}", answer.question_id, value.trim())
        })
        .collect::<Vec<_>>()
        .join("\n");
    format!(
        "User answered your pending questions:\n{lines}\nContinue the task using these answers."
    )
}

pub(crate) async fn prompt_value(invocation: &Invocation, deps: &Deps) -> Result<Value, ToolError> {
    let (submission, _, _) = validate_prompt_submission(Some(&invocation.payload), deps).await?;
    let run_id = uuid::Uuid::now_v7().to_string();
    let mut apply_payload = invocation.payload.clone();
    let Some(object) = apply_payload.as_object_mut() else {
        return Err(ToolError::InvalidParams {
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
) -> Result<Value, ToolError> {
    let run_id = require_string_param(params, "runId")?;
    let (submission, _session, _responder_factory) =
        validate_prompt_submission(params, deps).await?;

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
) -> Result<Value, ToolError> {
    let run_id = require_string_param(params, "runId")?;
    let (submission, session, responder_factory) = validate_prompt_submission(params, deps).await?;

    let started_run = deps
        .orchestrator
        .begin_run(&submission.session_id, &run_id)
        .map_err(|e| ToolError::Custom {
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
        responder_factory,
        &session,
        started_run,
        run_id.clone(),
        PromptRequest {
            session_id: submission.session_id,
            trigger: crate::domains::agent::r#loop::types::AgentRunTrigger::UserPrompt {
                prompt: submission.prompt,
            },
            reasoning_level: submission.reasoning_level,
            attachments: submission.attachments,
            user_event_metadata: submission.user_input_answer,
            engine_causality: Some(PromptEngineCausality::from_invocation(invocation)),
        },
    );

    Ok(json!({
        "acknowledged": true,
        "runId": run_id,
    }))
}

pub(crate) async fn delivery_wake_value(
    params: Option<&Value>,
    invocation: &Invocation,
    deps: &Deps,
) -> Result<Value, ToolError> {
    let session_id = require_string_param(params, "sessionId")?;
    let selected_delivery_ids = opt_array(params, "deliveryIds")
        .map(|values| {
            values
                .iter()
                .map(|value| {
                    value
                        .as_str()
                        .filter(|value| !value.trim().is_empty())
                        .map(ToOwned::to_owned)
                        .ok_or_else(|| ToolError::InvalidParams {
                            message: "deliveryIds must contain non-empty strings".to_owned(),
                        })
                })
                .collect::<Result<Vec<_>, _>>()
        })
        .transpose()?;
    if deps.orchestrator.has_active_run(&session_id) {
        return Ok(json!({
            "acknowledged":false,
            "reason":"session_busy",
        }));
    }
    let event_store = deps.event_store.clone();
    let wake_session_id = session_id.clone();
    let requested_delivery_ids = selected_delivery_ids.clone();
    let deliveries = crate::shared::server::context::run_blocking_task(
        "agent.delivery_wake.pending",
        move || {
            let records = if let Some(delivery_ids) = requested_delivery_ids {
                event_store.selected_agent_wake_batch_for_session(&wake_session_id, &delivery_ids)
            } else {
                event_store.pending_agent_wake_batch_for_session(
                    &wake_session_id,
                    crate::domains::session::event_store::MAX_DELIVERIES_PER_TURN,
                )
            };
            records.map_err(crate::shared::server::error_mapping::map_event_store_error)
        },
    )
    .await?;
    let delivery_ids = deliveries
        .iter()
        .map(|delivery| delivery.delivery_id.clone())
        .collect::<Vec<_>>();
    if delivery_ids.is_empty() {
        return Ok(json!({
            "acknowledged":false,
            "reason":"no_pending_wake",
        }));
    }
    let session = AgentCommandService::load_prompt_session(deps, &session_id).await?;
    if session.ended_at.is_some() {
        return Ok(json!({
            "acknowledged":false,
            "reason":"session_archived",
        }));
    }
    // A hidden reusable-agent transcript may never fall back to the ordinary
    // root surface. Generic completion/unarchive reconsideration carries no
    // WorkerStore authority snapshot, so it deliberately leaves the delivery
    // pending for the coordination dispatcher to re-admit with either the
    // active assignment grant or the bounded idle auxiliary grant.
    if session.is_agent_session()
        && (invocation.causal_context.agent_id().is_none()
            || invocation
                .causal_context
                .delegated_function_grant()
                .is_none())
    {
        return Ok(json!({
            "acknowledged":false,
            "reason":"coordination_context_required",
        }));
    }
    let responder_factory =
        deps.responder_factory
            .clone()
            .ok_or_else(|| ToolError::NotAvailable {
                message: "Agent execution dependencies are not configured".into(),
            })?;
    let run_id = uuid::Uuid::now_v7().to_string();
    let started_run = match deps.orchestrator.begin_run_with_admission_key(
        &session_id,
        &run_id,
        invocation.causal_context.idempotency_key.as_deref(),
    ) {
        Ok(started) => started,
        Err(crate::domains::agent::r#loop::errors::RuntimeError::SessionBusy(_)) => {
            return Ok(json!({
                "acknowledged":false,
                "reason":"session_busy",
            }));
        }
        Err(error) => {
            return Err(ToolError::Custom {
                code: error.category().to_uppercase(),
                message: error.to_string(),
                details: None,
            });
        }
    };
    let engine_causality = if selected_delivery_ids.is_some() {
        PromptEngineCausality::from_invocation(invocation)
    } else {
        let mut context = invocation.causal_context.clone();
        if let Some(first) = deliveries.first() {
            if let Some(trace_id) = first
                .source_trace_id
                .as_deref()
                .and_then(|value| crate::engine::TraceId::new(value.to_owned()).ok())
            {
                context.trace_id = trace_id;
            }
            context = context.with_trigger_depth(first.causal_depth);
            if let Some(parent) = first
                .source_invocation_id
                .as_deref()
                .and_then(|value| crate::engine::InvocationId::new(value.to_owned()).ok())
            {
                context = context.with_parent_invocation(parent);
            }
        }
        let autonomous_wake_hop = deps
            .event_store
            .agent_wake_batch_autonomous_hop(&deliveries)
            .map_err(crate::shared::server::error_mapping::map_event_store_error)?;
        context = context.with_autonomous_wake_hop(autonomous_wake_hop);
        PromptEngineCausality::from_invocation_with_context(invocation, context)
    };
    spawn_prompt_run(
        &deps.prompt_runtime(),
        responder_factory,
        &session,
        started_run,
        run_id.clone(),
        PromptRequest {
            session_id,
            trigger: crate::domains::agent::r#loop::types::AgentRunTrigger::DeliveryWake {
                delivery_ids,
            },
            reasoning_level: opt_string(params, "reasoningLevel"),
            attachments: None,
            user_event_metadata: None,
            engine_causality: Some(engine_causality),
        },
    );
    Ok(json!({
        "acknowledged":true,
        "runId":run_id,
    }))
}

pub(crate) async fn validate_prompt_submission(
    params: Option<&Value>,
    deps: &Deps,
) -> Result<
    (
        PromptSubmission,
        crate::domains::session::event_store::SessionRow,
        Arc<dyn ModelResponderFactory>,
    ),
    ToolError,
> {
    let session_id = require_string_param(params, "sessionId")?;
    let prompt = require_string_param(params, "prompt")?;
    validation::validate_string_param(&prompt, "prompt", validation::MAX_PROMPT_LENGTH)?;
    let attachments = opt_array(params, "attachments").cloned();
    let user_input_answer = params
        .and_then(|value| value.get("userInputAnswer"))
        .cloned();

    if let Some(active_run_id) = deps.orchestrator.get_run_id(&session_id) {
        return Err(ToolError::Custom {
            code: errors::SESSION_BUSY.into(),
            message: format!("Session '{session_id}' is already processing run '{active_run_id}'"),
            details: Some(json!({ "runId": active_run_id })),
        });
    }

    let session = AgentCommandService::load_prompt_session(deps, &session_id).await?;
    if attachments.as_ref().is_some_and(|items| !items.is_empty()) {
        let auth_path =
            crate::domains::auth::credentials::openai::infer_auth_path(&deps.auth_path, None)
                .unwrap_or(crate::domains::auth::credentials::OpenAIAuthPath::ChatGptCodex);
        let policy = crate::domains::model::routing::attachments::for_model(
            &session.latest_model,
            auth_path,
        )
        .ok_or_else(|| ToolError::InvalidParams {
            message: format!(
                "Attachments are unavailable because model '{}' has no attachment policy",
                session.latest_model
            ),
        })?;
        validate_attachment_array(attachments.as_deref(), &policy)?;
    }
    let responder_factory =
        deps.responder_factory
            .clone()
            .ok_or_else(|| ToolError::NotAvailable {
                message: "Agent execution dependencies are not configured".into(),
            })?;
    Ok((
        PromptSubmission {
            session_id,
            prompt,
            reasoning_level: opt_string(params, "reasoningLevel"),
            attachments,
            user_input_answer,
        },
        session,
        responder_factory,
    ))
}

pub(crate) fn validate_attachment_array(
    attachments: Option<&[Value]>,
    policy: &crate::domains::model::routing::attachments::AttachmentPolicy,
) -> Result<(), ToolError> {
    if let Some(attachments) = attachments {
        for attachment in attachments {
            let data = attachment
                .get("data")
                .and_then(Value::as_str)
                .ok_or_else(|| ToolError::InvalidParams {
                    message: "Attachment is missing base64 data".into(),
                })?;
            let mime_type = attachment
                .get("mimeType")
                .and_then(Value::as_str)
                .ok_or_else(|| ToolError::InvalidParams {
                    message: "Attachment is missing mimeType".into(),
                })?;

            let max_bytes = if mime_type.starts_with("image/") {
                if policy.max_image_bytes == 0 || !policy.accepts_image_mime_type(mime_type) {
                    return Err(ToolError::InvalidParams {
                        message: format!("Model does not accept attachment type '{mime_type}'"),
                    });
                }
                policy.max_image_bytes
            } else if mime_type == "application/pdf" {
                if !policy.supports_pdf_content {
                    return Err(ToolError::InvalidParams {
                        message: "Model does not accept PDF content".into(),
                    });
                }
                policy.max_document_bytes
            } else if matches!(mime_type, "text/plain" | "application/json") {
                if !policy.supports_text_files {
                    return Err(ToolError::InvalidParams {
                        message: "Model does not accept text file content".into(),
                    });
                }
                policy.max_document_bytes
            } else {
                return Err(ToolError::InvalidParams {
                    message: format!("Unsupported attachment type '{mime_type}'"),
                });
            };

            validation::validate_attachment_size_with_limit(data, max_bytes)?;
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
) -> Result<Value, ToolError> {
    let function_id = FunctionId::new(function_id).map_err(|e| ToolError::Internal {
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
    .map_err(|_| ToolError::Internal {
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
    crate::shared::server::error_mapping::result_to_tool_value(result)
}

fn trusted_agent_internal_child_context(
    invocation: &Invocation,
    idempotency_prefix: &str,
) -> crate::engine::CausalContext {
    let parent = &invocation.causal_context;
    let mut context = crate::engine::CausalContext::new(
        crate::engine::ActorId::new("system:agent-runtime").expect("valid actor id"),
        crate::engine::ActorKind::System,
        parent.trace_id.clone(),
    )
    .with_parent_invocation(invocation.id.clone())
    .with_idempotency_key(format!("{idempotency_prefix}:{}", invocation.id))
    .with_trigger_depth(parent.trigger_depth())
    .with_autonomous_wake_hop(parent.autonomous_wake_hop());
    if let Some(session_id) = &parent.session_id {
        context = context.with_session_id(session_id.clone());
    }
    if let Some(workspace_id) = &parent.workspace_id {
        context = context.with_workspace_id(workspace_id.clone());
    }
    if let Some(working_directory) = parent.working_directory() {
        context = context.with_working_directory(working_directory);
    }
    if let Some(worker_id) = parent.origin_worker_id() {
        context = context.with_origin_worker_id(worker_id.to_owned());
    }
    if let Some(invocation_id) = parent.origin_worker_invocation_id() {
        context = context.with_origin_worker_invocation_id(invocation_id.to_owned());
    }
    if let Some(max_turns) = parent.worker_max_agent_turns() {
        context = context.with_worker_max_agent_turns(max_turns);
    }
    if let Some(agent_tools) = parent.worker_agent_tools() {
        context = context.with_worker_agent_tools(agent_tools.to_vec());
    }
    if let Some(agent_id) = parent.agent_id() {
        context = match (parent.agent_assignment_id(), parent.agent_execution_id()) {
            (Some(assignment_id), Some(execution_id)) => {
                context.with_agent_execution(agent_id, assignment_id, execution_id)
            }
            _ => context.with_agent_identity(agent_id),
        };
    }
    if let Some(grant) = parent.delegated_function_grant() {
        context = context.with_delegated_function_grant(grant.to_vec());
    }
    if let Some(limits) = parent.agent_limits() {
        context = context.with_agent_limits(limits.clone());
    }
    if let Some(scopes) = parent.agent_write_scopes() {
        context = context.with_agent_write_scopes(scopes.to_vec());
    }
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
    use crate::domains::registration::composition::DomainRegistrationContext;
    use crate::engine::{ActorId, ActorKind, CausalContext, FunctionId, TraceId};
    use crate::shared::server::test_support::make_test_context;

    #[tokio::test]
    async fn prompt_validation_requires_a_responder_factory() {
        let context = make_test_context();
        let session_id = context
            .session_manager
            .create_session("claude-opus-4-6", "/tmp", Some("test"))
            .unwrap();
        let registration = DomainRegistrationContext::from_context(&context);
        let deps = crate::domains::agent::Deps::from_engine(&registration);
        let params = json!({"sessionId": session_id, "prompt": "hello"});

        let result = validate_prompt_submission(Some(&params), &deps).await;

        assert!(matches!(
            result,
            Err(ToolError::NotAvailable { message })
                if message == "Agent execution dependencies are not configured"
        ));
    }

    #[test]
    fn hidden_prompt_child_context_is_engine_owned_not_public_caller() {
        let parent = Invocation::new_sync(
            FunctionId::new("agent::prompt").expect("function id"),
            json!({"sessionId": "session-a", "prompt": "hello"}),
            CausalContext::new(
                ActorId::new("engine-client").expect("actor id"),
                ActorKind::Client,
                TraceId::new("prompt-parent").expect("trace id"),
            )
            .with_session_id("session-a")
            .with_workspace_id("workspace-a")
            .with_working_directory("/tmp/session-a")
            .with_advertised_function(
                crate::engine::FunctionRevision(7),
                Some("parent-worker-version".to_owned()),
            )
            .with_trigger_depth(3),
        );

        let child = trusted_agent_internal_child_context(&parent, "agent::prompt_apply");

        assert_eq!(child.actor_id.as_str(), "system:agent-runtime");
        assert_eq!(child.actor_kind, ActorKind::System);
        assert_eq!(child.parent_invocation_id, Some(parent.id));
        assert_eq!(child.session_id.as_deref(), Some("session-a"));
        assert_eq!(child.workspace_id.as_deref(), Some("workspace-a"));
        assert_eq!(child.working_directory(), Some("/tmp/session-a"));
        assert_eq!(child.origin_worker_id(), None);
        assert_eq!(child.trigger_depth(), 3);
        assert_eq!(child.advertised_function_revision(), None);
        assert_eq!(child.advertised_worker_version(), None);
        assert!(
            child
                .idempotency_key
                .as_deref()
                .is_some_and(|key| key.starts_with("agent::prompt_apply:"))
        );
    }

    #[test]
    fn hidden_prompt_child_context_preserves_worker_origin_as_causal_evidence() {
        let parent = Invocation::new_sync(
            FunctionId::new("agent::prompt").expect("function id"),
            json!({"sessionId": "worker-child", "prompt": "run"}),
            CausalContext::new(
                ActorId::new("worker:research-coordinator").expect("actor id"),
                ActorKind::Worker,
                TraceId::new("worker-prompt-parent").expect("trace id"),
            )
            .with_session_id("worker-child")
            .with_origin_worker_invocation_id("worker_run_parent")
            .with_worker_max_agent_turns(7)
            .with_worker_agent_tools(vec!["web_fetch".to_owned()]),
        );

        let child = trusted_agent_internal_child_context(&parent, "agent::prompt_apply");

        assert_eq!(child.actor_id.as_str(), "system:agent-runtime");
        assert_eq!(child.actor_kind, ActorKind::System);
        assert_eq!(child.origin_worker_id(), Some("research-coordinator"));
        assert_eq!(
            child.origin_worker_invocation_id(),
            Some("worker_run_parent")
        );
        assert_eq!(child.worker_max_agent_turns(), Some(7));
        assert_eq!(
            child.worker_agent_tools(),
            Some(["web_fetch".to_owned()].as_slice())
        );
    }

    #[test]
    fn attachment_validation_enforces_model_policy() {
        let policy = crate::domains::model::routing::attachments::AttachmentPolicy {
            supports_pdf_content: false,
            supports_text_files: true,
            max_image_dimension: 1_568,
            max_image_bytes: 10,
            max_document_bytes: 20,
            supported_image_mime_types: &["image/jpeg"],
        };

        assert!(
            validate_attachment_array(
                Some(&[json!({"data": "YWJj", "mimeType": "image/jpeg"})]),
                &policy,
            )
            .is_ok()
        );
        assert!(
            validate_attachment_array(
                Some(&[json!({"data": "YWJj", "mimeType": "image/png"})]),
                &policy,
            )
            .is_err()
        );
        assert!(
            validate_attachment_array(
                Some(&[json!({"data": "YWJj", "mimeType": "application/pdf"})]),
                &policy,
            )
            .is_err()
        );
    }

    #[test]
    fn user_input_answers_must_match_each_canonical_question() {
        let request = json!({
            "questions":[{
                "id":"format",
                "options":[{"label":"Markdown"},{"label":"HTML"}]
            }]
        });
        assert!(
            validate_user_input_answers(
                &request,
                &[UserInputAnswerSubmission {
                    question_id: "format".into(),
                    selected_label: Some("Markdown".into()),
                    free_text: None,
                }]
            )
            .is_ok()
        );
        assert!(
            validate_user_input_answers(
                &request,
                &[UserInputAnswerSubmission {
                    question_id: "format".into(),
                    selected_label: Some("PDF".into()),
                    free_text: None,
                }]
            )
            .is_err()
        );
        assert!(
            validate_user_input_answers(
                &request,
                &[UserInputAnswerSubmission {
                    question_id: "other".into(),
                    selected_label: None,
                    free_text: Some("Custom".into()),
                }]
            )
            .is_err()
        );

        let multiple = json!({
            "questions":[
                {"id":"format","options":[{"label":"Markdown"},{"label":"HTML"}]},
                {"id":"tone","options":[{"label":"Direct"},{"label":"Warm"}]}
            ]
        });
        assert!(
            validate_user_input_answers(
                &multiple,
                &[UserInputAnswerSubmission {
                    question_id: "tone".into(),
                    selected_label: Some("Warm".into()),
                    free_text: None,
                }]
            )
            .is_ok()
        );
        assert!(validate_user_input_answers(&multiple, &[]).is_err());
    }

    #[test]
    fn user_input_request_rejects_ambiguous_native_identifiers() {
        let duplicate_questions = serde_json::from_value::<UserInputRequestDefinition>(json!({
            "questions":[
                {"id":"format","options":[{"label":"Markdown"},{"label":"HTML"}]},
                {"id":"format","options":[{"label":"Short"},{"label":"Long"}]}
            ]
        }))
        .unwrap();
        assert!(validate_user_input_request(&duplicate_questions).is_err());

        let reserved_other = serde_json::from_value::<UserInputRequestDefinition>(json!({
            "questions":[{
                "id":"format",
                "options":[{"label":"Markdown"},{"label":"Other"}]
            }]
        }))
        .unwrap();
        assert!(validate_user_input_request(&reserved_other).is_err());
    }
}
