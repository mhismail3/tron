//! Skills handlers: list, get, refresh, remove.

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::{self, RpcError};
use crate::server::rpc::handlers::{opt_string, require_string_param};
use crate::server::rpc::registry::MethodHandler;

/// Shape skill for the wire format (excludes internal fields: skillMdPath, lastModified, frontmatter).
///
/// INVARIANT: must emit every field that iOS's `SkillMetadata` requires. When
/// adding a field to `SkillMetadata`, add it here too — there is a test in
/// this module that pins the expected keys.
fn skill_to_wire(skill: &crate::skills::types::SkillMetadata) -> Value {
    let mut v = serde_json::json!({
        "name": skill.name,
        "displayName": skill.display_name,
        "description": skill.description,
        "source": skill.source,
        "service": skill.service,
        "tags": skill.frontmatter.tags,
        "content": skill.content,
        "path": skill.path,
        "additionalFiles": skill.additional_files,
    });
    if !skill.scope_dir.is_empty() {
        v["scopeDir"] = serde_json::json!(skill.scope_dir);
    }
    v
}

/// Resolve the working directory for skill operations.
///
/// Tries `workingDirectory` param first, then falls back to the session's
/// working directory if `sessionId` is provided, then `/tmp`.
fn resolve_working_dir(params: Option<&Value>, ctx: &RpcContext) -> String {
    if let Some(wd) = opt_string(params, "workingDirectory") {
        return wd;
    }
    if let Some(sid) = opt_string(params, "sessionId") {
        if let Ok(Some(session)) = ctx.session_manager.get_session(&sid) {
            return session.working_directory;
        }
    }
    "/tmp".to_string()
}

/// List available skills.
pub struct ListSkillsHandler;

#[async_trait]
impl MethodHandler for ListSkillsHandler {
    #[instrument(skip(self, ctx), fields(method = "skill.list"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let working_dir = resolve_working_dir(params.as_ref(), ctx);
        let mut registry = ctx.skill_registry.write();
        let _ = registry.refresh_if_stale(&working_dir);
        let skills = registry.list(None);
        Ok(serde_json::json!({ "skills": skills }))
    }
}

/// Get a specific skill by name.
pub struct GetSkillHandler;

#[async_trait]
impl MethodHandler for GetSkillHandler {
    #[instrument(skip(self, ctx), fields(method = "skill.get"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let name = require_string_param(params.as_ref(), "name")?;
        let working_dir = resolve_working_dir(params.as_ref(), ctx);

        let mut registry = ctx.skill_registry.write();
        let _ = registry.refresh_if_stale(&working_dir);

        let skill = registry.get(&name).ok_or_else(|| RpcError::NotFound {
            code: errors::NOT_FOUND.into(),
            message: format!("Skill '{name}' not found"),
        })?;

        Ok(serde_json::json!({
            "skill": skill_to_wire(skill),
            "found": true,
        }))
    }
}

/// Refresh skills from disk.
pub struct RefreshSkillsHandler;

#[async_trait]
impl MethodHandler for RefreshSkillsHandler {
    #[instrument(skip(self, ctx), fields(method = "skill.refresh"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let working_dir = resolve_working_dir(params.as_ref(), ctx);

        let skill_registry = ctx.skill_registry.clone();
        let count = ctx
            .run_blocking("skill.refresh", move || {
                let mut registry = skill_registry.write();
                registry.refresh(&working_dir);
                Ok(registry.list(None).len())
            })
            .await?;

        Ok(serde_json::json!({ "success": true, "skillCount": count }))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::rpc::handlers::test_helpers::make_test_context;
    use crate::skills::types::{SkillFrontmatter, SkillMetadata, SkillSource};
    use serde_json::json;

    fn make_skill(name: &str) -> SkillMetadata {
        SkillMetadata {
            name: name.to_string(),
            display_name: name.to_string(),
            description: format!("{name} skill"),
            content: format!("{name} content"),
            frontmatter: SkillFrontmatter::default(),
            source: SkillSource::Global,
            service: "tron".to_string(),
            scope_dir: String::new(),
            path: String::new(),
            skill_md_path: String::new(),
            additional_files: Vec::new(),
            last_modified: 0,
        }
    }

    #[tokio::test]
    async fn list_skills_returns_array() {
        let ctx = make_test_context();
        let result = ListSkillsHandler.handle(None, &ctx).await.unwrap();
        assert!(result["skills"].is_array());
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
    async fn refresh_skills_wire_format_field_names() {
        let ctx = make_test_context();
        let result = RefreshSkillsHandler.handle(None, &ctx).await.unwrap();
        assert!(result.get("success").is_some());
        assert!(result.get("skillCount").is_some());
        assert!(result.get("refreshed").is_none());
        assert!(result.get("count").is_none());
    }

    #[tokio::test]
    async fn get_skill_returns_wrapped_response() {
        let ctx = make_test_context();
        // Pre-refresh so refresh_if_stale is a no-op, then insert our test skill
        ctx.skill_registry.write().refresh("/tmp");
        ctx.skill_registry.write().insert(make_skill("my-skill"));

        let result = GetSkillHandler
            .handle(Some(json!({"name": "my-skill"})), &ctx)
            .await
            .unwrap();

        // Wire format: { skill: {...}, found: true }
        assert_eq!(result["found"], true);
        assert!(result["skill"].is_object());
        assert_eq!(result["skill"]["name"], "my-skill");
        assert_eq!(result["skill"]["description"], "my-skill skill");
    }

    #[tokio::test]
    async fn list_skills_sorted_alphabetically() {
        let ctx = make_test_context();
        // Pre-refresh so refresh_if_stale is a no-op, then insert test skills
        ctx.skill_registry.write().refresh("/tmp");
        ctx.skill_registry.write().insert(make_skill("zebra"));
        ctx.skill_registry.write().insert(make_skill("alpha"));

        let result = ListSkillsHandler.handle(None, &ctx).await.unwrap();
        let names: Vec<&str> = result["skills"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| s["name"].as_str().unwrap())
            .collect();
        let alpha_idx = names.iter().position(|n| *n == "alpha").unwrap();
        let zebra_idx = names.iter().position(|n| *n == "zebra").unwrap();
        assert!(alpha_idx < zebra_idx);
    }

    #[tokio::test]
    async fn refresh_clears_stale_skills() {
        let ctx = make_test_context();
        ctx.skill_registry.write().insert(make_skill("stale-skill"));
        assert!(ctx.skill_registry.read().has("stale-skill"));

        // Refresh with empty tmpdir — stale-skill should be gone
        let result = RefreshSkillsHandler
            .handle(
                Some(json!({"workingDirectory": "/tmp/empty-nonexistent"})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["success"], true);
        assert!(!ctx.skill_registry.read().has("stale-skill"));
    }

    #[tokio::test]
    async fn list_skills_returns_canonical_shape() {
        let ctx = make_test_context();
        // Pre-refresh so refresh_if_stale is a no-op, then insert test skills
        ctx.skill_registry.write().refresh("/tmp");
        ctx.skill_registry.write().insert(make_skill("alpha"));
        ctx.skill_registry.write().insert(make_skill("beta"));

        let result = ListSkillsHandler.handle(None, &ctx).await.unwrap();
        let skills = result["skills"].as_array().unwrap();
        assert!(skills.iter().any(|s| s["name"] == "alpha"));
        assert!(skills.iter().any(|s| s["name"] == "beta"));
        assert!(result.get("totalCount").is_none());
    }

    /// Pins the skill.get wire schema so any field added to SkillMetadata
    /// that iOS depends on is caught here. Regression from the service-field
    /// refactor where `skill_to_wire` silently omitted `service` and iOS
    /// decode threw "Could not load skill content" on every tap.
    #[tokio::test]
    async fn get_skill_wire_includes_all_ios_fields() {
        let ctx = make_test_context();
        ctx.skill_registry.write().refresh("/tmp");
        let mut meta = make_skill("xcode");
        meta.service = "claude".to_string();
        ctx.skill_registry.write().insert(meta);

        let result = GetSkillHandler
            .handle(Some(json!({"name": "xcode"})), &ctx)
            .await
            .unwrap();

        let skill = &result["skill"];
        for key in [
            "name",
            "displayName",
            "description",
            "source",
            "service",
            "tags",
            "content",
            "path",
            "additionalFiles",
        ] {
            assert!(
                skill.get(key).is_some(),
                "skill.get wire is missing required field `{key}` — iOS SkillMetadata decode will fail"
            );
        }
        assert_eq!(skill["service"], "claude");
    }

    /// End-to-end: `~/.claude/skills` symlinked to another dir must still be
    /// discovered and its SKILL.md content returned via skill.get.
    /// Mirrors the real-world dotfiles setup where `~/.claude/skills` is a
    /// symlink to `~/.dotfiles/claude/skills`.
    #[tokio::test]
    async fn get_skill_follows_symlinked_global_dir() {
        use std::os::unix::fs::symlink;
        use tempfile::TempDir;

        let fake_home = TempDir::new().unwrap();
        let dotfiles = TempDir::new().unwrap();

        // Real skills live under dotfiles/claude/skills/probe/
        let real_skills = dotfiles.path().join("claude").join("skills");
        std::fs::create_dir_all(&real_skills).unwrap();
        let skill_dir = real_skills.join("probe");
        std::fs::create_dir_all(&skill_dir).unwrap();
        std::fs::write(
            skill_dir.join("SKILL.md"),
            "---\nname: Probe\ndescription: from symlink\n---\n# Probe\n\nbody\n",
        )
        .unwrap();

        // ~/.claude/skills -> <dotfiles>/claude/skills (the symlink under test)
        std::fs::create_dir_all(fake_home.path().join(".claude")).unwrap();
        symlink(
            &real_skills,
            fake_home.path().join(".claude").join("skills"),
        )
        .unwrap();

        // Scan via the home-overriding entry point and verify the skill comes back
        // with its loaded content, tagged as the claude service.
        let (global, _) = crate::skills::loader::scan_all_for_home(
            fake_home.path().to_str().unwrap(),
            fake_home.path().to_str().unwrap(),
        );

        let probe = global
            .skills
            .iter()
            .find(|s| s.name == "probe")
            .expect("probe skill must be discovered through the symlink");
        assert_eq!(probe.service, "claude");
        assert!(
            probe.content.contains("body"),
            "SKILL.md content must be read through the symlink"
        );
        assert_eq!(probe.display_name, "Probe");
    }
}
