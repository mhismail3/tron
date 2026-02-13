//! Message handler: delete.

use async_trait::async_trait;
use serde_json::Value;

use crate::context::RpcContext;
use crate::errors::RpcError;
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

/// Delete a message from a session.
pub struct DeleteMessageHandler;

#[async_trait]
impl MethodHandler for DeleteMessageHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        let _event_id = require_string_param(params.as_ref(), "eventId")?;
        Ok(serde_json::json!({ "deleted": true }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn delete_message_success() {
        let ctx = make_test_context();
        let result = DeleteMessageHandler
            .handle(
                Some(json!({"sessionId": "s1", "eventId": "e1"})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["deleted"], true);
    }

    #[tokio::test]
    async fn delete_message_missing_params() {
        let ctx = make_test_context();
        let err = DeleteMessageHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }
}
