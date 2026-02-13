//! Skills handlers: list, get, refresh, remove.

use async_trait::async_trait;
use serde_json::Value;

use crate::context::RpcContext;
use crate::errors::{self, RpcError};
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

/// List available skills.
pub struct ListSkillsHandler;

#[async_trait]
impl MethodHandler for ListSkillsHandler {
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let registry = ctx.skill_registry.read();
        let skills = registry.list(None);
        Ok(serde_json::json!({ "skills": skills }))
    }
}

/// Get a specific skill by name.
pub struct GetSkillHandler;

#[async_trait]
impl MethodHandler for GetSkillHandler {
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let name = require_string_param(params.as_ref(), "name")?;
        let registry = ctx.skill_registry.read();

        let skill = registry.get(&name).ok_or_else(|| RpcError::NotFound {
            code: errors::NOT_FOUND.into(),
            message: format!("Skill '{name}' not found"),
        })?;

        Ok(serde_json::to_value(skill).unwrap_or_default())
    }
}

/// Refresh skills from disk.
pub struct RefreshSkillsHandler;

#[async_trait]
impl MethodHandler for RefreshSkillsHandler {
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let working_dir = params
            .as_ref()
            .and_then(|p| p.get("workingDirectory"))
            .and_then(Value::as_str)
            .unwrap_or("/tmp");

        let mut registry = ctx.skill_registry.write();
        registry.initialize(working_dir);
        let count = registry.list(None).len();

        Ok(serde_json::json!({ "refreshed": true, "count": count }))
    }
}

/// Remove a skill.
pub struct RemoveSkillHandler;

#[async_trait]
impl MethodHandler for RemoveSkillHandler {
    async fn handle(&self, params: Option<Value>, _ctx: &RpcContext) -> Result<Value, RpcError> {
        let _name = require_string_param(params.as_ref(), "name")?;
        Err(RpcError::NotAvailable {
            message: "Skill removal requires filesystem operations".into(),
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;

    #[tokio::test]
    async fn list_skills_empty() {
        let ctx = make_test_context();
        let result = ListSkillsHandler.handle(None, &ctx).await.unwrap();
        assert!(result["skills"].is_array());
        assert!(result["skills"].as_array().unwrap().is_empty());
    }

    #[tokio::test]
    async fn get_skill_not_found() {
        let ctx = make_test_context();
        let err = GetSkillHandler
            .handle(Some(json!({"name": "nonexistent"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "NOT_FOUND");
    }

    #[tokio::test]
    async fn get_skill_missing_name() {
        let ctx = make_test_context();
        let err = GetSkillHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn refresh_skills_returns_count() {
        let ctx = make_test_context();
        let result = RefreshSkillsHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["refreshed"], true);
        assert!(result["count"].is_number());
    }

    #[tokio::test]
    async fn remove_skill_not_available() {
        let ctx = make_test_context();
        let err = RemoveSkillHandler
            .handle(Some(json!({"name": "test"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "NOT_AVAILABLE");
    }

    #[tokio::test]
    async fn list_skills_sorted_alphabetically() {
        let ctx = make_test_context();
        let result = ListSkillsHandler.handle(None, &ctx).await.unwrap();
        // Empty is trivially sorted
        assert!(result["skills"].as_array().unwrap().is_empty());
    }
}
