//! Skills RPC group.
//!
//! All `skill.*` methods are marker-registered in `handlers::mod` and executed
//! by canonical `skills::*` engine functions. Session skill state lives in
//! [`super::skill_session`].

#[cfg(test)]
mod tests {
    use crate::server::rpc::context::RpcContext;
    use crate::server::rpc::handlers::test_helpers::make_test_context;
    use crate::server::rpc::registry::MethodRegistry;
    use crate::server::rpc::types::{RpcErrorBody, RpcRequest};
    use crate::skills::types::{SkillFrontmatter, SkillMetadata, SkillSource};
    use serde_json::{Value, json};

    async fn dispatch_skill_ok(ctx: &RpcContext, method: &str, params: Value) -> Value {
        let mut registry = MethodRegistry::new();
        crate::server::rpc::handlers::register_all(&mut registry);
        let response = registry
            .dispatch(
                RpcRequest {
                    id: format!("test-{method}"),
                    method: method.to_owned(),
                    params: Some(params),
                },
                ctx,
            )
            .await;
        assert!(response.success, "{method}: {:?}", response.error);
        response.result.unwrap()
    }

    async fn dispatch_skill_err(ctx: &RpcContext, method: &str, params: Value) -> RpcErrorBody {
        let mut registry = MethodRegistry::new();
        crate::server::rpc::handlers::register_all(&mut registry);
        let response = registry
            .dispatch(
                RpcRequest {
                    id: format!("test-{method}"),
                    method: method.to_owned(),
                    params: Some(params),
                },
                ctx,
            )
            .await;
        assert!(!response.success, "{method}: {:?}", response.result);
        response.error.unwrap()
    }

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

    fn stable_working_dir() -> tempfile::TempDir {
        tempfile::tempdir().expect("create stable skill test working dir")
    }

    fn working_dir_string(dir: &tempfile::TempDir) -> String {
        dir.path().to_string_lossy().into_owned()
    }

    #[tokio::test]
    async fn list_skills_returns_array() {
        let ctx = make_test_context();
        let result = dispatch_skill_ok(&ctx, "skill.list", json!({})).await;
        assert!(result["skills"].is_array());
    }

    #[tokio::test]
    async fn get_skill_not_found() {
        let ctx = make_test_context();
        let err = dispatch_skill_err(&ctx, "skill.get", json!({"name": "nonexistent"})).await;
        assert_eq!(err.code, "NOT_FOUND");
    }

    #[tokio::test]
    async fn get_skill_missing_name() {
        let ctx = make_test_context();
        let err = dispatch_skill_err(&ctx, "skill.get", json!({})).await;
        assert_eq!(err.code, "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn refresh_skills_returns_count() {
        let ctx = make_test_context();
        let result = dispatch_skill_ok(&ctx, "skill.refresh", json!({})).await;
        assert_eq!(result["success"], true);
        assert!(result["skillCount"].is_number());
    }

    #[tokio::test]
    async fn get_skill_returns_wrapped_response() {
        let ctx = make_test_context();
        let dir = stable_working_dir();
        let working_dir = working_dir_string(&dir);
        ctx.skill_registry.write().refresh(&working_dir);
        ctx.skill_registry.write().insert(make_skill("my-skill"));

        let result = dispatch_skill_ok(
            &ctx,
            "skill.get",
            json!({"name": "my-skill", "workingDirectory": working_dir}),
        )
        .await;

        assert_eq!(result["found"], true);
        assert!(result["skill"].is_object());
        assert_eq!(result["skill"]["name"], "my-skill");
        assert_eq!(result["skill"]["description"], "my-skill skill");
    }

    #[tokio::test]
    async fn list_skills_sorted_alphabetically() {
        let ctx = make_test_context();
        let dir = stable_working_dir();
        let working_dir = working_dir_string(&dir);
        ctx.skill_registry.write().refresh(&working_dir);
        ctx.skill_registry.write().insert(make_skill("zebra"));
        ctx.skill_registry.write().insert(make_skill("alpha"));

        let result =
            dispatch_skill_ok(&ctx, "skill.list", json!({"workingDirectory": working_dir})).await;
        let names: Vec<&str> = result["skills"]
            .as_array()
            .unwrap()
            .iter()
            .map(|skill| skill["name"].as_str().unwrap())
            .collect();
        let alpha_idx = names.iter().position(|name| *name == "alpha").unwrap();
        let zebra_idx = names.iter().position(|name| *name == "zebra").unwrap();
        assert!(alpha_idx < zebra_idx);
    }

    #[tokio::test]
    async fn refresh_clears_stale_skills() {
        let ctx = make_test_context();
        ctx.skill_registry.write().insert(make_skill("stale-skill"));
        assert!(ctx.skill_registry.read().has("stale-skill"));

        let result = dispatch_skill_ok(
            &ctx,
            "skill.refresh",
            json!({"workingDirectory": "/tmp/empty-nonexistent"}),
        )
        .await;
        assert_eq!(result["success"], true);
        assert!(!ctx.skill_registry.read().has("stale-skill"));
    }

    #[tokio::test]
    async fn list_skills_returns_canonical_shape() {
        let ctx = make_test_context();
        let dir = stable_working_dir();
        let working_dir = working_dir_string(&dir);
        ctx.skill_registry.write().refresh(&working_dir);
        ctx.skill_registry.write().insert(make_skill("alpha"));
        ctx.skill_registry.write().insert(make_skill("beta"));

        let result =
            dispatch_skill_ok(&ctx, "skill.list", json!({"workingDirectory": working_dir})).await;
        let skills = result["skills"].as_array().unwrap();
        assert!(skills.iter().any(|skill| skill["name"] == "alpha"));
        assert!(skills.iter().any(|skill| skill["name"] == "beta"));
        assert!(result.get("totalCount").is_none());
    }

    #[tokio::test]
    async fn get_skill_wire_includes_all_ios_fields() {
        let ctx = make_test_context();
        let dir = stable_working_dir();
        let working_dir = working_dir_string(&dir);
        ctx.skill_registry.write().refresh(&working_dir);
        let mut meta = make_skill("xcode");
        meta.service = "claude".to_string();
        ctx.skill_registry.write().insert(meta);

        let result = dispatch_skill_ok(
            &ctx,
            "skill.get",
            json!({"name": "xcode", "workingDirectory": working_dir}),
        )
        .await;

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
                "skill.get wire is missing required field `{key}`"
            );
        }
        assert_eq!(skill["service"], "claude");
    }

    #[tokio::test]
    async fn get_skill_follows_symlinked_global_dir() {
        use std::os::unix::fs::symlink;
        use tempfile::TempDir;

        let fake_home = TempDir::new().unwrap();
        let dotfiles = TempDir::new().unwrap();
        let real_skills = dotfiles.path().join("claude").join("skills");
        std::fs::create_dir_all(&real_skills).unwrap();
        let skill_dir = real_skills.join("probe");
        std::fs::create_dir_all(&skill_dir).unwrap();
        std::fs::write(
            skill_dir.join("SKILL.md"),
            "---\nname: Probe\ndescription: from symlink\n---\n# Probe\n\nbody\n",
        )
        .unwrap();

        std::fs::create_dir_all(fake_home.path().join(".claude")).unwrap();
        symlink(
            &real_skills,
            fake_home.path().join(".claude").join("skills"),
        )
        .unwrap();

        let (global, _) = crate::skills::loader::scan_all_for_home(
            fake_home.path().to_str().unwrap(),
            fake_home.path().to_str().unwrap(),
        );

        let probe = global
            .skills
            .iter()
            .find(|skill| skill.name == "probe")
            .expect("probe skill must be discovered through the symlink");
        assert_eq!(probe.service, "claude");
        assert!(probe.content.contains("body"));
        assert_eq!(probe.display_name, "Probe");
    }
}
