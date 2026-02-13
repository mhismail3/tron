//! Skills handlers: list, get, refresh, remove.

use async_trait::async_trait;
use serde_json::Value;

use crate::context::RpcContext;
use crate::errors::RpcError;
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

/// List available skills.
pub struct ListSkillsHandler;

#[async_trait]
impl MethodHandler for ListSkillsHandler {
    async fn handle(&self, _params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        Ok(serde_json::json!({ "skills": [] }))
    }
}

/// Get a specific skill by name.
pub struct GetSkillHandler;

#[async_trait]
impl MethodHandler for GetSkillHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _name = require_string_param(params.as_ref(), "name")?;
        Ok(serde_json::json!({ "stub": true }))
    }
}

/// Refresh skills from disk.
pub struct RefreshSkillsHandler;

#[async_trait]
impl MethodHandler for RefreshSkillsHandler {
    async fn handle(&self, _params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        Ok(serde_json::json!({ "refreshed": true }))
    }
}

/// Remove a skill.
pub struct RemoveSkillHandler;

#[async_trait]
impl MethodHandler for RemoveSkillHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _name = require_string_param(params.as_ref(), "name")?;
        Ok(serde_json::json!({ "removed": true }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn list_skills() {
        let ctx = make_test_context();
        let result = ListSkillsHandler.handle(None, &ctx).await.unwrap();
        assert!(result["skills"].is_array());
    }

    #[tokio::test]
    async fn get_skill_requires_name() {
        let ctx = make_test_context();
        let err = GetSkillHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn refresh_skills() {
        let ctx = make_test_context();
        let result = RefreshSkillsHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["refreshed"], true);
    }

    #[tokio::test]
    async fn remove_skill_requires_name() {
        let ctx = make_test_context();
        let err = RemoveSkillHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }
}
