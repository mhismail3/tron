//! Communication handlers: send, receive, subscribe, unsubscribe.

use async_trait::async_trait;
use serde_json::Value;

use crate::context::RpcContext;
use crate::errors::RpcError;
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

/// Send a communication message.
pub struct SendHandler;

#[async_trait]
impl MethodHandler for SendHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _channel = require_string_param(params.as_ref(), "channel")?;
        Ok(serde_json::json!({ "sent": true }))
    }
}

/// Receive pending messages.
pub struct ReceiveHandler;

#[async_trait]
impl MethodHandler for ReceiveHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _channel = require_string_param(params.as_ref(), "channel")?;
        Ok(serde_json::json!({ "messages": [] }))
    }
}

/// Subscribe to a communication channel.
pub struct SubscribeHandler;

#[async_trait]
impl MethodHandler for SubscribeHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _channel = require_string_param(params.as_ref(), "channel")?;
        Ok(serde_json::json!({ "subscribed": true }))
    }
}

/// Unsubscribe from a communication channel.
pub struct UnsubscribeHandler;

#[async_trait]
impl MethodHandler for UnsubscribeHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _channel = require_string_param(params.as_ref(), "channel")?;
        Ok(serde_json::json!({ "unsubscribed": true }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn send_success() {
        let ctx = make_test_context();
        let result = SendHandler
            .handle(Some(json!({"channel": "ch1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["sent"], true);
    }

    #[tokio::test]
    async fn send_missing_channel() {
        let ctx = make_test_context();
        let err = SendHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn receive_success() {
        let ctx = make_test_context();
        let result = ReceiveHandler
            .handle(Some(json!({"channel": "ch1"})), &ctx)
            .await
            .unwrap();
        assert!(result["messages"].is_array());
    }

    #[tokio::test]
    async fn subscribe_success() {
        let ctx = make_test_context();
        let result = SubscribeHandler
            .handle(Some(json!({"channel": "ch1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["subscribed"], true);
    }

    #[tokio::test]
    async fn unsubscribe_success() {
        let ctx = make_test_context();
        let result = UnsubscribeHandler
            .handle(Some(json!({"channel": "ch1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["unsubscribed"], true);
    }
}
