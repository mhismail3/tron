//! Search handlers: content, events.

use async_trait::async_trait;
use serde_json::Value;

use crate::context::RpcContext;
use crate::errors::RpcError;
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

/// Search file contents.
pub struct ContentSearchHandler;

#[async_trait]
impl MethodHandler for ContentSearchHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _query = require_string_param(params.as_ref(), "query")?;
        Ok(serde_json::json!({ "results": [] }))
    }
}

/// Search events.
pub struct EventSearchHandler;

#[async_trait]
impl MethodHandler for EventSearchHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _query = require_string_param(params.as_ref(), "query")?;
        Ok(serde_json::json!({ "results": [] }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn content_search_success() {
        let ctx = make_test_context();
        let result = ContentSearchHandler
            .handle(Some(json!({"query": "hello"})), &ctx)
            .await
            .unwrap();
        assert!(result["results"].is_array());
    }

    #[tokio::test]
    async fn content_search_missing_query() {
        let ctx = make_test_context();
        let err = ContentSearchHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn event_search_success() {
        let ctx = make_test_context();
        let result = EventSearchHandler
            .handle(Some(json!({"query": "error"})), &ctx)
            .await
            .unwrap();
        assert!(result["results"].is_array());
    }

    #[tokio::test]
    async fn event_search_missing_query() {
        let ctx = make_test_context();
        let err = EventSearchHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }
}
