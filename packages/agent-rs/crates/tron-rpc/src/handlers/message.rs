//! Message handler: delete.

use async_trait::async_trait;
use serde_json::Value;

use crate::context::RpcContext;
use crate::errors::{self, RpcError};
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

/// Delete a message from a session.
pub struct DeleteMessageHandler;

#[async_trait]
impl MethodHandler for DeleteMessageHandler {
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let event_id = require_string_param(params.as_ref(), "eventId")?;

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
    use crate::handlers::test_helpers::make_test_context;
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
                Some(json!({"sessionId": sid, "eventId": "nonexistent"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "NOT_FOUND");
    }
}
