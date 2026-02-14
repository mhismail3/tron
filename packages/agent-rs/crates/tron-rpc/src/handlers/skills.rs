//! Skills handlers: list, get, refresh, remove.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::context::RpcContext;
use crate::errors::{self, RpcError};
use crate::handlers::require_string_param;
use crate::registry::MethodHandler;

/// List available skills.
pub struct ListSkillsHandler;

#[async_trait]
impl MethodHandler for ListSkillsHandler {
    #[instrument(skip(self, ctx), fields(method = "skill.list"))]
    async fn handle(&self, _params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let registry = ctx.skill_registry.read();
        let skills = registry.list(None);
        let mut response = serde_json::json!({ "skills": skills });
        // ADAPTER(ios-compat): iOS expects totalCount in skill.list response.
        // REMOVE: revert to `Ok(json!({ "skills": skills }))`
        crate::adapters::adapt_skill_list(&mut response);
        Ok(response)
    }
}

/// Get a specific skill by name.
pub struct GetSkillHandler;

#[async_trait]
impl MethodHandler for GetSkillHandler {
    #[instrument(skip(self, ctx), fields(method = "skill.get"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let name = require_string_param(params.as_ref(), "name")?;
        let registry = ctx.skill_registry.read();

        let skill = registry.get(&name).ok_or_else(|| RpcError::NotFound {
            code: errors::NOT_FOUND.into(),
            message: format!("Skill '{name}' not found"),
        })?;

        serde_json::to_value(skill).map_err(|e| RpcError::Internal {
            message: format!("Failed to serialize skill '{name}': {e}"),
        })
    }
}

/// Refresh skills from disk.
pub struct RefreshSkillsHandler;

#[async_trait]
impl MethodHandler for RefreshSkillsHandler {
    #[instrument(skip(self, ctx), fields(method = "skill.refresh"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let working_dir = params
            .as_ref()
            .and_then(|p| p.get("workingDirectory"))
            .and_then(Value::as_str)
            .unwrap_or("/tmp");

        let mut registry = ctx.skill_registry.write();
        registry.initialize(working_dir);
        let count = registry.list(None).len();

        Ok(serde_json::json!({ "success": true, "skillCount": count }))
    }
}

/// Remove a skill.
pub struct RemoveSkillHandler;

#[async_trait]
impl MethodHandler for RemoveSkillHandler {
    #[instrument(skip(self, ctx), fields(method = "skill.remove"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let name = params
            .as_ref()
            .and_then(|p| p.get("skillName").or_else(|| p.get("name")))
            .and_then(Value::as_str)
            .ok_or_else(|| RpcError::InvalidParams {
                message: "Missing required parameter: skillName".into(),
            })?;

        let session_id = params
            .as_ref()
            .and_then(|p| p.get("sessionId"))
            .and_then(Value::as_str);

        let mut registry = ctx.skill_registry.write();
        if !registry.has(name) {
            return Err(RpcError::NotFound {
                code: errors::NOT_FOUND.into(),
                message: format!("Skill '{name}' not found"),
            });
        }

        let _ = registry.remove(name);

        // Broadcast skill removed event
        if let Some(sid) = session_id {
            let _ = ctx.orchestrator.broadcast().emit(
                tron_core::events::TronEvent::SkillRemoved {
                    base: tron_core::events::BaseEvent::now(sid),
                    skill_name: name.to_owned(),
                },
            );
        }

        Ok(serde_json::json!({
            "success": true,
            "removedSkill": name,
        }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::handlers::test_helpers::make_test_context;
    use serde_json::json;
    use tron_skills::types::{SkillFrontmatter, SkillMetadata, SkillSource};

    fn make_skill(name: &str) -> SkillMetadata {
        SkillMetadata {
            name: name.to_string(),
            display_name: name.to_string(),
            description: format!("{name} skill"),
            content: format!("{name} content"),
            frontmatter: SkillFrontmatter::default(),
            source: SkillSource::Global,
            path: String::new(),
            skill_md_path: String::new(),
            additional_files: Vec::new(),
            last_modified: 0,
        }
    }

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
        assert_eq!(result["success"], true);
        assert!(result["skillCount"].is_number());
    }

    #[tokio::test]
    async fn refresh_skills_ios_field_names() {
        let ctx = make_test_context();
        let result = RefreshSkillsHandler.handle(None, &ctx).await.unwrap();
        assert!(result.get("success").is_some());
        assert!(result.get("skillCount").is_some());
        assert!(result.get("refreshed").is_none());
        assert!(result.get("count").is_none());
    }

    #[tokio::test]
    async fn remove_skill_success() {
        let ctx = make_test_context();
        ctx.skill_registry.write().insert(make_skill("test-skill"));

        let result = RemoveSkillHandler
            .handle(Some(json!({"skillName": "test-skill", "sessionId": "s1"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["success"], true);
        assert_eq!(result["removedSkill"], "test-skill");
        assert!(!ctx.skill_registry.read().has("test-skill"));
    }

    #[tokio::test]
    async fn remove_skill_not_found() {
        let ctx = make_test_context();
        let err = RemoveSkillHandler
            .handle(Some(json!({"skillName": "nonexistent"})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "NOT_FOUND");
    }

    #[tokio::test]
    async fn remove_skill_missing_params() {
        let ctx = make_test_context();
        let err = RemoveSkillHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn remove_skill_accepts_name_param() {
        let ctx = make_test_context();
        ctx.skill_registry.write().insert(make_skill("other"));

        let result = RemoveSkillHandler
            .handle(Some(json!({"name": "other"})), &ctx)
            .await
            .unwrap();
        assert_eq!(result["success"], true);
    }

    #[tokio::test]
    async fn remove_skill_emits_event() {
        let ctx = make_test_context();
        ctx.skill_registry.write().insert(make_skill("my-skill"));
        let mut rx = ctx.orchestrator.subscribe();

        let _ = RemoveSkillHandler
            .handle(Some(json!({"skillName": "my-skill", "sessionId": "s1"})), &ctx)
            .await
            .unwrap();

        let event = rx.try_recv().unwrap();
        assert_eq!(event.event_type(), "skill_removed");
    }

    #[tokio::test]
    async fn list_skills_sorted_alphabetically() {
        let ctx = make_test_context();
        let result = ListSkillsHandler.handle(None, &ctx).await.unwrap();
        assert!(result["skills"].as_array().unwrap().is_empty());
    }

    #[tokio::test]
    async fn list_skills_has_total_count() {
        let ctx = make_test_context();
        ctx.skill_registry.write().insert(make_skill("alpha"));
        ctx.skill_registry.write().insert(make_skill("beta"));

        let result = ListSkillsHandler.handle(None, &ctx).await.unwrap();
        assert_eq!(result["totalCount"], 2);
    }
}
