//! Git handler: clone.

use async_trait::async_trait;
use serde_json::Value;

use crate::context::RpcContext;
use crate::errors::RpcError;
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

/// Clone a git repository.
pub struct CloneHandler;

#[async_trait]
impl MethodHandler for CloneHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _url = require_string_param(params.as_ref(), "url")?;
        Ok(serde_json::json!({ "stub": true, "cloned": false }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn clone_success() {
        let ctx = make_test_context();
        let result = CloneHandler
            .handle(Some(json!({"url": "https://github.com/example/repo"})), &ctx)
            .await
            .unwrap();
        assert!(result.is_object());
    }

    #[tokio::test]
    async fn clone_missing_url() {
        let ctx = make_test_context();
        let err = CloneHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }
}
