//! Message handler: delete.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::rpc::context::RpcContext;
use crate::rpc::errors::{self, RpcError};
use crate::rpc::handlers::require_string_param;
use crate::rpc::registry::MethodHandler;

/// Delete a message from a session.
pub struct DeleteMessageHandler;

#[async_trait]
impl MethodHandler for DeleteMessageHandler {
    #[instrument(skip(self, ctx), fields(method = "message.delete", session_id))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let event_id = require_string_param(params.as_ref(), "targetEventId")?;

        let reason = params
            .as_ref()
            .and_then(|p| p.get("reason"))
            .and_then(Value::as_str);

        let deletion_event = ctx
            .event_store
            .delete_message(&session_id, &event_id, reason)
            .map_err(|e| {
                let msg = e.to_string();
                if msg.contains("not found") {
                    RpcError::NotFound {
                        code: errors::NOT_FOUND.into(),
                        message: format!("Event '{event_id}' not found"),
                    }
                } else {
                    RpcError::Internal { message: msg }
                }
            })?;

        // Emit message deleted event via broadcast
        let _ = ctx.orchestrator.broadcast().emit(
            tron_core::events::TronEvent::MessageDeleted {
                base: tron_core::events::BaseEvent::now(&session_id),
                target_event_id: event_id.clone(),
                target_type: deletion_event.event_type.clone(),
                target_turn: None,
                reason: reason.map(String::from),
            },
        );

        Ok(serde_json::json!({
            "success": true,
            "deletionEventId": deletion_event.id,
            "targetType": deletion_event.event_type,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn delete_message_missing_params() {
        let ctx = make_test_context();
        let err = DeleteMessageHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn delete_message_missing_event_id() {
        let ctx = make_test_context();
        let err = DeleteMessageHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn delete_message_event_not_found() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let err = DeleteMessageHandler
            .handle(
                Some(json!({"sessionId": sid, "targetEventId": "nonexistent"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "NOT_FOUND");
    }

    #[tokio::test]
    async fn delete_message_emits_event() {
        use tron_events::{AppendOptions, EventType};

        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        // Append an event to delete
        let event = ctx
            .event_store
            .append(&AppendOptions {
                session_id: &sid,
                event_type: EventType::MessageUser,
                payload: json!({"text": "hello"}),
                parent_id: None,
            })
            .unwrap();

        let mut rx = ctx.orchestrator.subscribe();

        let _ = DeleteMessageHandler
            .handle(
                Some(json!({"sessionId": sid, "targetEventId": event.id})),
                &ctx,
            )
            .await
            .unwrap();

        let emitted = rx.try_recv().unwrap();
        assert_eq!(emitted.event_type(), "message_deleted");
    }

    #[tokio::test]
    async fn delete_message_event_has_target_id() {
        use tron_events::{AppendOptions, EventType};

        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let event = ctx
            .event_store
            .append(&AppendOptions {
                session_id: &sid,
                event_type: EventType::MessageUser,
                payload: json!({"text": "hello"}),
                parent_id: None,
            })
            .unwrap();
        let event_id = event.id.clone();

        let mut rx = ctx.orchestrator.subscribe();

        let _ = DeleteMessageHandler
            .handle(
                Some(json!({"sessionId": sid, "targetEventId": event_id, "reason": "test cleanup"})),
                &ctx,
            )
            .await
            .unwrap();

        let emitted = rx.try_recv().unwrap();
        if let tron_core::events::TronEvent::MessageDeleted {
            target_event_id,
            reason,
            ..
        } = emitted
        {
            assert_eq!(target_event_id, event_id);
            assert_eq!(reason.as_deref(), Some("test cleanup"));
        } else {
            panic!("expected MessageDeleted event");
        }
    }
}
