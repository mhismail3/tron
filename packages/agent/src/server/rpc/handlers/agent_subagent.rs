//! Handler for `agent.deliverSubagentResults` — delivers pending subagent results
//! as a server-constructed prompt, replacing the client-side text construction pattern.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::events::EventType;
use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::handlers::agent::prompt_runtime::{
    format_subagent_results, get_pending_subagent_results,
};
use crate::server::rpc::handlers::agent::prompt_service::{PromptRequest, spawn_prompt_run};
use crate::server::rpc::handlers::require_string_param;
use crate::server::rpc::registry::MethodHandler;

/// Deliver pending subagent results as a server-constructed prompt.
/// The server retrieves unconsumed `notification.subagent_result` events,
/// formats them into markdown, persists a `subagent.results_consumed` event,
/// and spawns a prompt run (or queues if the session is busy).
pub struct DeliverSubagentResultsHandler;

#[async_trait]
impl MethodHandler for DeliverSubagentResultsHandler {
    #[instrument(
        skip(self, ctx),
        fields(method = "agent.deliverSubagentResults", session_id)
    )]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        // Verify the session exists
        let sm = ctx.session_manager.clone();
        let sid_check = session_id.clone();
        let session = ctx
            .run_blocking("agent.deliverSubagentResults.verify", move || {
                sm.get_session(&sid_check)
                    .map_err(|e| RpcError::Internal {
                        message: e.to_string(),
                    })?
                    .ok_or_else(|| RpcError::NotFound {
                        code: errors::SESSION_NOT_FOUND.into(),
                        message: format!("Session '{sid_check}' not found"),
                    })
            })
            .await?;

        // Get pending subagent results
        let event_store = ctx.event_store.clone();
        let sid = session_id.clone();
        let (prompt, count) = ctx
            .run_blocking("agent.deliverSubagentResults.format", move || {
                let pending = get_pending_subagent_results(&event_store, &sid);
                if pending.is_empty() {
                    return Err(RpcError::NotFound {
                        code: "NO_PENDING_RESULTS".into(),
                        message: "No unconsumed subagent results found".into(),
                    });
                }

                let count = pending.len();
                let event_ids: Vec<String> = pending.iter().map(|(id, _)| id.clone()).collect();
                let formatted =
                    format_subagent_results(&pending).ok_or_else(|| RpcError::Internal {
                        message: "Failed to format subagent results".into(),
                    })?;

                // Mark results as consumed
                let _ = event_store.append(&crate::events::AppendOptions {
                    session_id: &sid,
                    event_type: EventType::SubagentResultsConsumed,
                    payload: serde_json::json!({
                        "consumedEventIds": event_ids,
                        "count": count,
                    }),
                    parent_id: None,
                    sequence: None,
                });

                Ok((formatted, count))
            })
            .await?;

        // Tag the message.user event so iOS renders a chip instead of raw markdown.
        let metadata = serde_json::json!({
            "messageKind": "subagent_results_delivered",
            "subagentCount": count,
        });

        // Try to start a prompt run; if session is busy or agent deps unavailable, queue
        let run_id = uuid::Uuid::now_v7().to_string();
        if let Some(deps) = ctx.agent_deps.as_ref() {
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
                            message_metadata: Some(metadata),
                            engine_causality: None,
                        },
                    );
                    return Ok(serde_json::json!({
                        "acknowledged": true,
                        "queued": false,
                        "subagentCount": count,
                        "runId": run_id,
                    }));
                }
                Err(_) => {} // Fall through to queue
            }
        }

        // Session is busy or agent deps not available — queue the formatted prompt
        let event_store = ctx.event_store.clone();
        let sid_for_queue = session_id.clone();
        let _ = ctx
            .run_blocking("agent.deliverSubagentResults.queue", move || {
                crate::server::rpc::prompt_queue::PromptQueueService::enqueue_with_metadata(
                    &event_store,
                    &sid_for_queue,
                    &prompt,
                    Some(metadata),
                )
                .map_err(|e| RpcError::Internal {
                    message: e.to_string(),
                })
            })
            .await?;

        Ok(serde_json::json!({
            "acknowledged": true,
            "queued": true,
            "subagentCount": count,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn deliver_subagent_results_missing_session_id() {
        let ctx = make_test_context();
        let err = DeliverSubagentResultsHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    fn create_test_session(ctx: &RpcContext) -> String {
        let result = ctx
            .event_store
            .create_session("m", "/tmp", None, None, None, None)
            .unwrap();
        result.session.id
    }

    #[tokio::test]
    async fn deliver_subagent_results_no_pending() {
        let ctx = make_test_context();
        let sid = create_test_session(&ctx);

        let err = DeliverSubagentResultsHandler
            .handle(Some(json!({"sessionId": &sid})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "NO_PENDING_RESULTS");
    }

    #[tokio::test]
    async fn deliver_subagent_results_success() {
        let ctx = make_test_context();
        let sid = create_test_session(&ctx);

        // Insert a subagent result notification
        let _ = ctx.event_store.append(&crate::events::AppendOptions {
            session_id: &sid,
            event_type: EventType::NotificationSubagentResult,
            payload: json!({
                "subagentSessionId": "sub-1",
                "task": "test task",
                "success": true,
                "totalTurns": 3,
                "duration": 5000,
                "output": "test output"
            }),
            parent_id: None,
            sequence: None,
        });

        let result = DeliverSubagentResultsHandler
            .handle(Some(json!({"sessionId": &sid})), &ctx)
            .await
            .unwrap();

        assert_eq!(result["acknowledged"], true);
        assert_eq!(result["subagentCount"], 1);

        // Verify results are now consumed (second call should fail)
        let err = DeliverSubagentResultsHandler
            .handle(Some(json!({"sessionId": &sid})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "NO_PENDING_RESULTS");
    }
}
