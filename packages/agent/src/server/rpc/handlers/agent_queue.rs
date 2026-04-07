//! Agent queue handlers: queuePrompt, dequeuePrompt, clearQueue.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::core::events::{BaseEvent, TronEvent};
use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::RpcError;
use crate::server::rpc::handlers::require_string_param;
use crate::server::rpc::prompt_queue::PromptQueueService;
use crate::server::rpc::registry::MethodHandler;
use crate::server::rpc::validation;

/// Queue a prompt for later delivery when the agent becomes ready.
pub struct QueuePromptHandler;

#[async_trait]
impl MethodHandler for QueuePromptHandler {
    #[instrument(skip(self, ctx), fields(method = "agent.queuePrompt", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let prompt = require_string_param(params.as_ref(), "prompt")?;

        validation::validate_string_param(
            &prompt,
            "prompt",
            validation::MAX_PROMPT_LENGTH,
        )?;

        let event_store = ctx.event_store.clone();
        let sid = session_id.clone();

        let item = ctx.run_blocking("agent.queuePrompt", move || {
            PromptQueueService::enqueue(&event_store, &sid, &prompt)
        })
        .await?;

        // Broadcast for real-time WebSocket delivery
        let _ = ctx.orchestrator.broadcast().emit(TronEvent::MessageQueued {
            base: BaseEvent::now(&session_id),
            queue_id: item.queue_id.clone(),
            text: item.text.clone(),
            position: item.position,
        });

        Ok(serde_json::to_value(&item).map_err(|e| RpcError::Internal {
            message: format!("Failed to serialize queue item: {e}"),
        })?)
    }
}

/// Cancel a specific queued prompt.
pub struct DequeuePromptHandler;

#[async_trait]
impl MethodHandler for DequeuePromptHandler {
    #[instrument(skip(self, ctx), fields(method = "agent.dequeuePrompt", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let queue_id = require_string_param(params.as_ref(), "queueId")?;

        let event_store = ctx.event_store.clone();
        let sid = session_id.clone();
        let qid = queue_id.clone();

        ctx.run_blocking("agent.dequeuePrompt", move || {
            PromptQueueService::dequeue(&event_store, &sid, &qid, "cancelled")
        })
        .await?;

        let _ = ctx.orchestrator.broadcast().emit(TronEvent::MessageDequeued {
            base: BaseEvent::now(&session_id),
            queue_id,
            reason: "cancelled".into(),
        });

        Ok(serde_json::json!({ "ok": true }))
    }
}

/// Clear all queued prompts for a session.
pub struct ClearQueueHandler;

#[async_trait]
impl MethodHandler for ClearQueueHandler {
    #[instrument(skip(self, ctx), fields(method = "agent.clearQueue", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        let event_store = ctx.event_store.clone();
        let sid = session_id.clone();

        // Get pending items before clearing (for broadcast)
        let pending = ctx.run_blocking("agent.clearQueue.query", {
            let es = event_store.clone();
            let s = sid.clone();
            move || PromptQueueService::get_pending_queue(&es, &s)
        })
        .await?;

        let cleared = ctx.run_blocking("agent.clearQueue", move || {
            PromptQueueService::clear_queue(&event_store, &sid)
        })
        .await?;

        // Broadcast dequeue for each cleared item
        for item in &pending {
            let _ = ctx.orchestrator.broadcast().emit(TronEvent::MessageDequeued {
                base: BaseEvent::now(&session_id),
                queue_id: item.queue_id.clone(),
                reason: "cleared".into(),
            });
        }

        Ok(serde_json::json!({ "cleared": cleared }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::rpc::handlers::test_helpers::make_test_context;

    #[tokio::test]
    async fn queue_prompt_missing_session_id() {
        let ctx = make_test_context();
        let handler = QueuePromptHandler;
        let params = Some(serde_json::json!({ "prompt": "hello" }));
        let err = handler.handle(params, &ctx).await.unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn queue_prompt_missing_prompt() {
        let ctx = make_test_context();
        let handler = QueuePromptHandler;
        let params = Some(serde_json::json!({ "sessionId": "s1" }));
        let err = handler.handle(params, &ctx).await.unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn queue_prompt_success() {
        let ctx = make_test_context();
        let result = ctx
            .event_store
            .create_session("claude-opus-4-6", "/tmp", None, None, None)
            .unwrap();
        let sid = result.session.id;

        let handler = QueuePromptHandler;
        let params = Some(serde_json::json!({
            "sessionId": sid,
            "prompt": "hello world"
        }));
        let response = handler.handle(params, &ctx).await.unwrap();
        assert_eq!(response["text"], "hello world");
        assert_eq!(response["position"], 0);
        assert!(response["queueId"].is_string());
    }

    #[tokio::test]
    async fn dequeue_prompt_success() {
        let ctx = make_test_context();
        let result = ctx
            .event_store
            .create_session("claude-opus-4-6", "/tmp", None, None, None)
            .unwrap();
        let sid = result.session.id;

        // Enqueue first
        let item = PromptQueueService::enqueue(&ctx.event_store, &sid, "hello").unwrap();

        let handler = DequeuePromptHandler;
        let params = Some(serde_json::json!({
            "sessionId": sid,
            "queueId": item.queue_id,
        }));
        let response = handler.handle(params, &ctx).await.unwrap();
        assert_eq!(response["ok"], true);

        // Verify empty
        let pending = PromptQueueService::get_pending_queue(&ctx.event_store, &sid).unwrap();
        assert!(pending.is_empty());
    }

    #[tokio::test]
    async fn clear_queue_success() {
        let ctx = make_test_context();
        let result = ctx
            .event_store
            .create_session("claude-opus-4-6", "/tmp", None, None, None)
            .unwrap();
        let sid = result.session.id;

        PromptQueueService::enqueue(&ctx.event_store, &sid, "a").unwrap();
        PromptQueueService::enqueue(&ctx.event_store, &sid, "b").unwrap();

        let handler = ClearQueueHandler;
        let params = Some(serde_json::json!({ "sessionId": sid }));
        let response = handler.handle(params, &ctx).await.unwrap();
        assert_eq!(response["cleared"], 2);

        let pending = PromptQueueService::get_pending_queue(&ctx.event_store, &sid).unwrap();
        assert!(pending.is_empty());
    }

    #[tokio::test]
    async fn queue_at_capacity_returns_error() {
        let ctx = make_test_context();
        let result = ctx
            .event_store
            .create_session("claude-opus-4-6", "/tmp", None, None, None)
            .unwrap();
        let sid = result.session.id;

        for i in 0..3 {
            PromptQueueService::enqueue(&ctx.event_store, &sid, &format!("msg{i}")).unwrap();
        }

        let handler = QueuePromptHandler;
        let params = Some(serde_json::json!({
            "sessionId": sid,
            "prompt": "overflow"
        }));
        let err = handler.handle(params, &ctx).await.unwrap_err();
        assert_eq!(err.code(), "QUEUE_FULL");
    }
}
