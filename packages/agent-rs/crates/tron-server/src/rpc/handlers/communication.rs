//! Communication handlers: send, receive, subscribe, unsubscribe.
//!
//! These are placeholder handlers — the TypeScript server also has stubs for
//! communication features. iOS doesn't use these endpoints.

use async_trait::async_trait;
use serde_json::Value;
use tracing::{debug, instrument};

use crate::rpc::context::RpcContext;
use crate::rpc::errors::RpcError;
use crate::rpc::handlers::require_string_param;
use crate::rpc::registry::MethodHandler;

/// Send a communication message.
pub struct SendHandler;

#[async_trait]
impl MethodHandler for SendHandler {
    #[instrument(skip(self, _ctx), fields(method = "communication.send"))]
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let channel = require_string_param(params.as_ref(), "channel")?;
        debug!(channel, "communication.send (stub)");
        Ok(serde_json::json!({ "sent": true }))
    }
}

/// Receive pending messages.
pub struct ReceiveHandler;

#[async_trait]
impl MethodHandler for ReceiveHandler {
    #[instrument(skip(self, _ctx), fields(method = "communication.receive"))]
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let channel = require_string_param(params.as_ref(), "channel")?;
        debug!(channel, "communication.receive (stub)");
        Ok(serde_json::json!({ "messages": [] }))
    }
}

/// Subscribe to a communication channel.
pub struct SubscribeHandler;

#[async_trait]
impl MethodHandler for SubscribeHandler {
    #[instrument(skip(self, _ctx), fields(method = "communication.subscribe"))]
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let channel = require_string_param(params.as_ref(), "channel")?;
        debug!(channel, "communication.subscribe (stub)");
        Ok(serde_json::json!({ "subscribed": true }))
    }
}

/// Unsubscribe from a communication channel.
pub struct UnsubscribeHandler;

#[async_trait]
impl MethodHandler for UnsubscribeHandler {
    #[instrument(skip(self, _ctx), fields(method = "communication.unsubscribe"))]
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let channel = require_string_param(params.as_ref(), "channel")?;
        debug!(channel, "communication.unsubscribe (stub)");
        Ok(serde_json::json!({ "unsubscribed": true }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::rpc::handlers::test_helpers::make_test_context;
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
