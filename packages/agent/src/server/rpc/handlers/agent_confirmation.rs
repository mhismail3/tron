//! Handlers for `agent.submitConfirmation` and `agent.submitAnswers`.
//! Replaces client-side text protocol construction for GetConfirmation and AskUserQuestion
//! tool responses. The server constructs the agent-facing prompt and spawns a prompt run.

use async_trait::async_trait;
use serde::Deserialize;
use serde_json::Value;
use tracing::instrument;

use crate::server::rpc::agent_commands::AgentCommandService;
use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::handlers::agent::prompt_service::{PromptRequest, spawn_prompt_run};
use crate::server::rpc::handlers::require_string_param;
use crate::server::rpc::registry::MethodHandler;

/// Submit a confirmation decision (Approved/Denied) for a GetConfirmation tool call.
/// The server constructs the prompt text and spawns a prompt run.
pub struct SubmitConfirmationHandler;

#[async_trait]
impl MethodHandler for SubmitConfirmationHandler {
    #[instrument(
        skip(self, ctx),
        fields(method = "agent.submitConfirmation", session_id)
    )]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let action = require_string_param(params.as_ref(), "action")?;
        let decision = require_string_param(params.as_ref(), "decision")?;
        let note = params
            .as_ref()
            .and_then(|p| p.get("note"))
            .and_then(|v| v.as_str())
            .map(String::from);

        // Construct the agent-facing prompt text
        let mut lines = vec![
            "[Confirmation response]".to_string(),
            String::new(),
            format!("Action: {action}"),
            format!("Decision: {decision}"),
        ];
        if let Some(ref note) = note {
            if !note.is_empty() {
                lines.push(format!("Note: {note}"));
            }
        }
        let prompt = lines.join("\n");

        // Structured metadata for iOS chip rendering (persisted in the
        // message.user event payload alongside the text content).
        let mut metadata_obj = serde_json::Map::new();
        let _ = metadata_obj.insert(
            "messageKind".into(),
            serde_json::json!("confirmation_response"),
        );
        let _ = metadata_obj.insert("confirmationDecision".into(), serde_json::json!(decision));
        if let Some(ref n) = note {
            if !n.is_empty() {
                let _ = metadata_obj.insert("confirmationNote".into(), serde_json::json!(n));
            }
        }
        let message_metadata = Some(Value::Object(metadata_obj));

        let session = AgentCommandService::load_prompt_session(ctx, &session_id).await?;
        let deps = ctx
            .agent_deps
            .as_ref()
            .ok_or_else(|| RpcError::NotAvailable {
                message: "Agent execution dependencies are not configured".into(),
            })?;

        let run_id = uuid::Uuid::now_v7().to_string();
        match ctx.orchestrator.begin_run(&session_id, &run_id) {
            Ok(started_run) => {
                spawn_prompt_run(
                    ctx,
                    deps,
                    &session,
                    started_run,
                    run_id.clone(),
                    PromptRequest {
                        session_id,
                        prompt,
                        reasoning_level: None,
                        images: None,
                        attachments: None,
                        message_metadata,
                    },
                );
                Ok(serde_json::json!({
                    "acknowledged": true,
                    "queued": false,
                    "runId": run_id,
                }))
            }
            Err(_) => {
                // Session is busy — queue the prompt along with its
                // structured metadata so the drained message still
                // renders as a chip on iOS (see PromptQueueService).
                let event_store = ctx.event_store.clone();
                let sid = session_id.clone();
                let queued_metadata = message_metadata.clone();
                let _ = ctx
                    .run_blocking("agent.submitConfirmation.queue", move || {
                        crate::server::rpc::prompt_queue::PromptQueueService::enqueue_with_metadata(
                            &event_store,
                            &sid,
                            &prompt,
                            queued_metadata,
                        )
                        .map_err(|e| RpcError::Internal {
                            message: e.to_string(),
                        })
                    })
                    .await?;

                Ok(serde_json::json!({
                    "acknowledged": true,
                    "queued": true,
                }))
            }
        }
    }
}

/// Submit answers for an AskUserQuestion tool call.
/// The server constructs the prompt text and spawns a prompt run.
pub struct SubmitAnswersHandler;

#[derive(Deserialize)]
struct AnswerSubmission {
    question: String,
    #[serde(default)]
    #[serde(rename = "selectedValues")]
    selected_values: Vec<String>,
    #[serde(rename = "otherValue")]
    other_value: Option<String>,
}

#[async_trait]
impl MethodHandler for SubmitAnswersHandler {
    #[instrument(skip(self, ctx), fields(method = "agent.submitAnswers", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        let questions_value = params
            .as_ref()
            .and_then(|p| p.get("questions"))
            .ok_or_else(|| RpcError::InvalidParams {
                message: "Missing required param: questions".into(),
            })?;

        let answers: Vec<AnswerSubmission> = serde_json::from_value(questions_value.clone())
            .map_err(|e| RpcError::InvalidParams {
                message: format!("Invalid questions format: {e}"),
            })?;

        if answers.is_empty() {
            return Err(RpcError::InvalidParams {
                message: "questions array must not be empty".into(),
            });
        }

        // Construct the agent-facing prompt text
        let mut lines = vec!["[Answers to your questions]".to_string(), String::new()];
        for answer in &answers {
            lines.push(format!("**{}**", answer.question));
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
        let prompt = lines.join("\n");

        // Structured metadata for iOS chip rendering.
        let message_metadata = Some(serde_json::json!({
            "messageKind": "answered_questions",
            "answerCount": answers.len(),
        }));

        let session = AgentCommandService::load_prompt_session(ctx, &session_id).await?;
        let deps = ctx
            .agent_deps
            .as_ref()
            .ok_or_else(|| RpcError::NotAvailable {
                message: "Agent execution dependencies are not configured".into(),
            })?;

        let run_id = uuid::Uuid::now_v7().to_string();
        match ctx.orchestrator.begin_run(&session_id, &run_id) {
            Ok(started_run) => {
                spawn_prompt_run(
                    ctx,
                    deps,
                    &session,
                    started_run,
                    run_id.clone(),
                    PromptRequest {
                        session_id,
                        prompt,
                        reasoning_level: None,
                        images: None,
                        attachments: None,
                        message_metadata,
                    },
                );
                Ok(serde_json::json!({
                    "acknowledged": true,
                    "queued": false,
                    "runId": run_id,
                }))
            }
            Err(_) => {
                // Session is busy — queue with structured metadata so the
                // drained prompt renders the answered-questions chip.
                let event_store = ctx.event_store.clone();
                let sid = session_id.clone();
                let queued_metadata = message_metadata.clone();
                let _ = ctx
                    .run_blocking("agent.submitAnswers.queue", move || {
                        crate::server::rpc::prompt_queue::PromptQueueService::enqueue_with_metadata(
                            &event_store,
                            &sid,
                            &prompt,
                            queued_metadata,
                        )
                        .map_err(|e| RpcError::Internal {
                            message: e.to_string(),
                        })
                    })
                    .await?;

                Ok(serde_json::json!({
                    "acknowledged": true,
                    "queued": true,
                }))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn submit_confirmation_missing_params() {
        let ctx = make_test_context();
        let err = SubmitConfirmationHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn submit_confirmation_missing_decision() {
        let ctx = make_test_context();
        let err = SubmitConfirmationHandler
            .handle(
                Some(json!({"sessionId": "s1", "action": "delete file"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn submit_answers_missing_questions() {
        let ctx = make_test_context();
        let err = SubmitAnswersHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn submit_answers_empty_questions() {
        let ctx = make_test_context();
        let err = SubmitAnswersHandler
            .handle(Some(json!({"sessionId": "s1", "questions": []})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }
}
