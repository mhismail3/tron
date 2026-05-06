//! Session-scoped skill state.
//!
//! `skill.activate`, `skill.deactivate`, and `skill.active` are
//! marker-registered in `handlers::mod` and executed by canonical `skills::*`
//! engine functions. This module keeps the event-sourced reconstruction helper
//! used by runtime prompt assembly and wire-compatibility tests for the
//! collapsed skill-session group.

use serde_json::Value;

use crate::skills::tracker::SkillTracker;

/// Reconstruct a [`SkillTracker`] from the event store for a given session.
pub fn reconstruct_tracker(
    event_store: &crate::events::EventStore,
    session_id: &str,
    policy: &crate::settings::types::CompactionPolicy,
) -> SkillTracker {
    let events = event_store
        .get_events_by_type(
            session_id,
            &[
                "skill.activated",
                "skill.deactivated",
                "context.cleared",
                "compact.boundary",
                "skills.cleared",
            ],
            None,
        )
        .unwrap_or_default();
    let json_events: Vec<Value> = events
        .iter()
        .filter_map(
            |event| match serde_json::from_str::<Value>(&event.payload) {
                Ok(payload) => Some(serde_json::json!({
                    "type": event.event_type,
                    "id": event.id,
                    "payload": payload,
                })),
                Err(error) => {
                    tracing::warn!(
                        event_id = %event.id,
                        event_type = %event.event_type,
                        error = %error,
                        "skill_session: corrupt event payload JSON; dropping from skill tracker"
                    );
                    None
                }
            },
        )
        .collect();
    SkillTracker::from_events_with_policy(&json_events, policy)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::rpc::context::RpcContext;
    use crate::server::rpc::handlers::test_helpers::make_test_context;
    use crate::server::rpc::registry::MethodRegistry;
    use crate::server::rpc::types::{RpcErrorBody, RpcRequest};
    use crate::settings::types::CompactionPolicy;
    use crate::skills::types::{SkillFrontmatter, SkillMetadata, SkillSource};
    use serde_json::{Value, json};
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn make_skill(name: &str) -> SkillMetadata {
        SkillMetadata {
            name: name.to_string(),
            display_name: name.to_string(),
            description: format!("{name} skill"),
            content: format!("{name} content - this is the full skill body"),
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

    fn create_test_session(ctx: &RpcContext) -> String {
        ctx.session_manager
            .create_session("test-model", "/tmp", Some("test"), None)
            .unwrap()
    }

    async fn dispatch_skill_state_ok(ctx: &RpcContext, method: &str, params: Value) -> Value {
        static NEXT_ID: AtomicUsize = AtomicUsize::new(1);
        let mut registry = MethodRegistry::new();
        crate::server::rpc::handlers::register_all(&mut registry);
        let response = registry
            .dispatch(
                RpcRequest {
                    id: format!("test-{method}-{}", NEXT_ID.fetch_add(1, Ordering::SeqCst)),
                    method: method.to_owned(),
                    params: Some(params),
                },
                ctx,
            )
            .await;
        assert!(response.success, "{method}: {:?}", response.error);
        response.result.unwrap()
    }

    async fn dispatch_skill_state_err(
        ctx: &RpcContext,
        method: &str,
        params: Value,
    ) -> RpcErrorBody {
        static NEXT_ID: AtomicUsize = AtomicUsize::new(1);
        let mut registry = MethodRegistry::new();
        crate::server::rpc::handlers::register_all(&mut registry);
        let response = registry
            .dispatch(
                RpcRequest {
                    id: format!("test-{method}-{}", NEXT_ID.fetch_add(1, Ordering::SeqCst)),
                    method: method.to_owned(),
                    params: Some(params),
                },
                ctx,
            )
            .await;
        assert!(!response.success, "{method}: {:?}", response.result);
        response.error.unwrap()
    }

    #[tokio::test]
    async fn skill_activate_success() {
        let ctx = make_test_context();
        ctx.skill_registry.write().insert(make_skill("browser"));
        let session_id = create_test_session(&ctx);

        let result = dispatch_skill_state_ok(
            &ctx,
            "skill.activate",
            json!({"sessionId": session_id, "skillName": "browser"}),
        )
        .await;

        assert_eq!(result["success"], true);
        assert_eq!(result["skill"]["name"], "browser");
        assert_eq!(result["skill"]["source"], "global");
        assert_eq!(result["skill"]["service"], "tron");
        assert!(result["skill"]["tokens"].is_number());
        assert!(result.get("alreadyActive").is_none());
    }

    #[tokio::test]
    async fn skill_activate_not_found() {
        let ctx = make_test_context();
        let session_id = create_test_session(&ctx);
        let err = dispatch_skill_state_err(
            &ctx,
            "skill.activate",
            json!({"sessionId": session_id, "skillName": "nonexistent"}),
        )
        .await;
        assert_eq!(err.code, "NOT_FOUND");
    }

    #[tokio::test]
    async fn skill_activate_missing_session() {
        let ctx = make_test_context();
        ctx.skill_registry.write().insert(make_skill("browser"));
        let err = dispatch_skill_state_err(
            &ctx,
            "skill.activate",
            json!({"sessionId": "no-such-session", "skillName": "browser"}),
        )
        .await;
        assert_eq!(err.code, "NOT_FOUND");
    }

    #[tokio::test]
    async fn skill_activate_missing_params() {
        let ctx = make_test_context();
        let err = dispatch_skill_state_err(&ctx, "skill.activate", json!({})).await;
        assert_eq!(err.code, "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn skill_activate_is_legacy_idempotent_and_engine_retry_idempotent() {
        let ctx = make_test_context();
        ctx.skill_registry.write().insert(make_skill("browser"));
        let session_id = create_test_session(&ctx);

        let payload = json!({"sessionId": session_id, "skillName": "browser"});
        let _ = dispatch_skill_state_ok(&ctx, "skill.activate", payload.clone()).await;
        let again = dispatch_skill_state_ok(&ctx, "skill.activate", payload).await;
        assert_eq!(again["success"], true);
        assert_eq!(again["alreadyActive"], true);

        let events = ctx
            .event_store
            .get_events_by_type(&session_id, &["skill.activated"], None)
            .unwrap();
        assert_eq!(events.len(), 1);
    }

    #[tokio::test]
    async fn skill_deactivate_success_and_inactive_noop() {
        let ctx = make_test_context();
        ctx.skill_registry.write().insert(make_skill("browser"));
        let session_id = create_test_session(&ctx);

        let _ = dispatch_skill_state_ok(
            &ctx,
            "skill.activate",
            json!({"sessionId": session_id, "skillName": "browser"}),
        )
        .await;
        let result = dispatch_skill_state_ok(
            &ctx,
            "skill.deactivate",
            json!({"sessionId": session_id, "skillName": "browser"}),
        )
        .await;
        assert_eq!(result["success"], true);
        assert_eq!(result["wasActive"], true);
        assert_eq!(result["deactivatedSkill"], "browser");

        let again = dispatch_skill_state_ok(
            &ctx,
            "skill.deactivate",
            json!({"sessionId": session_id, "skillName": "browser"}),
        )
        .await;
        assert_eq!(again["success"], true);
        assert_eq!(again["wasActive"], false);
    }

    #[tokio::test]
    async fn skill_active_lists_service_metadata() {
        let ctx = make_test_context();
        let mut tron_skill = make_skill("tron-one");
        tron_skill.service = "tron".to_string();
        let mut claude_skill = make_skill("claude-one");
        claude_skill.service = "claude".to_string();
        ctx.skill_registry.write().insert(tron_skill);
        ctx.skill_registry.write().insert(claude_skill);
        let session_id = create_test_session(&ctx);

        for name in ["tron-one", "claude-one"] {
            let _ = dispatch_skill_state_ok(
                &ctx,
                "skill.activate",
                json!({"sessionId": session_id, "skillName": name}),
            )
            .await;
        }

        let result =
            dispatch_skill_state_ok(&ctx, "skill.active", json!({"sessionId": session_id})).await;
        let skills = result["skills"].as_array().unwrap();
        let tron = skills
            .iter()
            .find(|skill| skill["name"] == "tron-one")
            .unwrap();
        let claude = skills
            .iter()
            .find(|skill| skill["name"] == "claude-one")
            .unwrap();
        assert_eq!(tron["service"], "tron");
        assert_eq!(claude["service"], "claude");
    }

    #[tokio::test]
    async fn active_response_service_is_unknown_for_deleted_skill() {
        let ctx = make_test_context();
        ctx.skill_registry.write().insert(make_skill("ghost"));
        let session_id = create_test_session(&ctx);
        let _ = dispatch_skill_state_ok(
            &ctx,
            "skill.activate",
            json!({"sessionId": session_id, "skillName": "ghost"}),
        )
        .await;
        let _ = ctx.skill_registry.write().remove("ghost");

        let result =
            dispatch_skill_state_ok(&ctx, "skill.active", json!({"sessionId": session_id})).await;
        let skill = result["skills"]
            .as_array()
            .unwrap()
            .iter()
            .find(|skill| skill["name"] == "ghost")
            .unwrap();
        assert_eq!(skill["service"], "unknown");
    }

    #[tokio::test]
    async fn reconstruct_tracker_preserves_active_state() {
        let ctx = make_test_context();
        ctx.skill_registry.write().insert(make_skill("browser"));
        let session_id = create_test_session(&ctx);
        let _ = dispatch_skill_state_ok(
            &ctx,
            "skill.activate",
            json!({"sessionId": session_id, "skillName": "browser"}),
        )
        .await;

        let tracker =
            reconstruct_tracker(&ctx.event_store, &session_id, &CompactionPolicy::ClearAll);
        assert!(tracker.has_skill("browser"));
        assert_eq!(tracker.count(), 1);
    }
}
