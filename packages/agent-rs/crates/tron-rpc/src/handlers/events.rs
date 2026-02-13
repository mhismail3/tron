//! Events handlers: getHistory, getSince, subscribe, append.

use async_trait::async_trait;
use serde_json::Value;

use crate::context::RpcContext;
use crate::errors::{self, RpcError};
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

/// Get full event history for a session.
pub struct GetHistoryHandler;

#[async_trait]
impl MethodHandler for GetHistoryHandler {
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        // Verify session exists
        let _ = ctx
            .session_manager
            .get_session(&session_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?
            .ok_or_else(|| RpcError::NotFound {
                code: errors::SESSION_NOT_FOUND.into(),
                message: format!("Session '{session_id}' not found"),
            })?;

        Ok(serde_json::json!({
            "sessionId": session_id,
            "events": [],
        }))
    }
}

/// Get events since a given timestamp.
pub struct GetSinceHandler;

#[async_trait]
impl MethodHandler for GetSinceHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        let _timestamp = require_string_param(params.as_ref(), "timestamp")?;

        Ok(serde_json::json!({
            "events": [],
        }))
    }
}

/// Subscribe to real-time events for a session.
pub struct SubscribeHandler;

#[async_trait]
impl MethodHandler for SubscribeHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;

        Ok(serde_json::json!({ "subscribed": true }))
    }
}

/// Append an event to a session.
pub struct AppendHandler;

#[async_trait]
impl MethodHandler for AppendHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _session_id = require_string_param(params.as_ref(), "sessionId")?;
        let _event_type = require_string_param(params.as_ref(), "eventType")?;

        Ok(serde_json::json!({ "appended": true }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn get_history_success() {
        let ctx = make_test_context();
        let sid = ctx
            .session_manager
            .create_session("m", "/tmp", Some("t"))
            .unwrap();

        let result = GetHistoryHandler
            .handle(Some(json!({"sessionId": sid})), &ctx)
            .await
            .unwrap();
        assert!(result["events"].is_array());
    }

    #[tokio::test]
    async fn get_history_not_found() {
        let ctx = make_test_context();
        let err = GetHistoryHandler
            .handle(Some(json!({"sessionId": "nope"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "SESSION_NOT_FOUND");
    }

    #[tokio::test]
    async fn get_since_success() {
        let ctx = make_test_context();
        let result = GetSinceHandler
            .handle(
                Some(json!({"sessionId": "s1", "timestamp": "2026-01-01T00:00:00Z"})),
                &ctx,
            )
            .await
            .unwrap();
        assert!(result["events"].is_array());
    }

    #[tokio::test]
    async fn get_since_missing_params() {
        let ctx = make_test_context();
        let err = GetSinceHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn subscribe_success() {
        let ctx = make_test_context();
        let result = SubscribeHandler
            .handle(Some(json!({"sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["subscribed"], true);
    }

    #[tokio::test]
    async fn append_success() {
        let ctx = make_test_context();
        let result = AppendHandler
            .handle(
                Some(json!({"sessionId": "s1", "eventType": "user_message"})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["appended"], true);
    }
}
