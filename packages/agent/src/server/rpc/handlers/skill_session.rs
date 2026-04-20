//! Session-scoped skill activation/deactivation RPCs.
//!
//! These handlers manage per-session skill state via the event store.
//! State is event-sourced: `skill.activated` / `skill.deactivated` events
//! are appended, and [`reconstruct_tracker`] rebuilds the current state on
//! read. All three handlers go through that single helper so they query the
//! same event-type set and apply the same compaction policy.
//!
//! ## Handlers
//!
//! - [`ActivateHandler`] — `skill.activate` — add a skill to the session
//! - [`DeactivateHandler`] — `skill.deactivate` — remove a skill from the session
//! - [`ActiveHandler`] — `skill.active` — query currently active skills

use async_trait::async_trait;
use serde_json::Value;
use tracing::instrument;

use crate::server::rpc::context::RpcContext;
use crate::server::rpc::errors::{self, RpcError};
use crate::server::rpc::handlers::require_string_param;
use crate::server::rpc::registry::MethodHandler;
use crate::settings::types::CompactionPolicy;
use crate::skills::tracker::SkillTracker;

/// Activate a skill in a session.
///
/// Writes a `skill.activated` event. Idempotent: if the skill is already
/// active, returns success without writing a duplicate event.
pub struct ActivateHandler;

#[async_trait]
impl MethodHandler for ActivateHandler {
    #[instrument(skip(self, ctx), fields(method = "skill.activate"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let skill_name = require_string_param(params.as_ref(), "skillName")?;

        // Verify session exists
        let _ = ctx.session_manager
            .get_session(&session_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?
            .ok_or_else(|| RpcError::NotFound {
                code: errors::NOT_FOUND.into(),
                message: format!("Session '{session_id}' not found"),
            })?;

        // Look up skill in registry
        let (source, service, tokens) = {
            let registry = ctx.skill_registry.read();
            let skill = registry.get(&skill_name).ok_or_else(|| RpcError::NotFound {
                code: errors::NOT_FOUND.into(),
                message: format!("Skill '{skill_name}' not found"),
            })?;
            (
                skill.source.to_string(),
                skill.service.clone(),
                skill.content.len() as u64 / 4,
            )
        };

        // Check if already active (idempotent)
        let already_active =
            reconstruct_tracker(&ctx.event_store, &session_id, &CompactionPolicy::ClearAll)
                .has_skill(&skill_name);

        if already_active {
            return Ok(serde_json::json!({
                "success": true,
                "alreadyActive": true,
                "skill": {
                    "name": skill_name,
                    "source": source,
                    "service": service,
                    "tokens": tokens,
                }
            }));
        }

        // Write skill.activated event
        let _ = ctx.event_store.append(&crate::events::AppendOptions {
            session_id: &session_id,
            event_type: crate::events::EventType::SkillActivated,
            payload: serde_json::json!({
                "skillName": skill_name,
                "source": source,
            }),
            parent_id: None,
            sequence: None,
        });

        // Invalidate cached session so next prompt picks up new skill
        ctx.session_manager.invalidate_session(&session_id);

        Ok(serde_json::json!({
            "success": true,
            "skill": {
                "name": skill_name,
                "source": source,
                "service": service,
                "tokens": tokens,
            }
        }))
    }
}

/// Deactivate a skill from a session.
///
/// Writes a `skill.deactivated` event. Idempotent: if the skill is not
/// active, returns success without writing an event.
pub struct DeactivateHandler;

#[async_trait]
impl MethodHandler for DeactivateHandler {
    #[instrument(skip(self, ctx), fields(method = "skill.deactivate"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let skill_name = require_string_param(params.as_ref(), "skillName")?;

        // Verify session exists
        let _ = ctx.session_manager
            .get_session(&session_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?
            .ok_or_else(|| RpcError::NotFound {
                code: errors::NOT_FOUND.into(),
                message: format!("Session '{session_id}' not found"),
            })?;

        // Check if currently active
        let is_active =
            reconstruct_tracker(&ctx.event_store, &session_id, &CompactionPolicy::ClearAll)
                .has_skill(&skill_name);

        if !is_active {
            return Ok(serde_json::json!({
                "success": true,
                "wasActive": false,
                "deactivatedSkill": skill_name,
            }));
        }

        // Write skill.deactivated event
        let _ = ctx.event_store.append(&crate::events::AppendOptions {
            session_id: &session_id,
            event_type: crate::events::EventType::SkillDeactivated,
            payload: serde_json::json!({
                "skillName": skill_name,
            }),
            parent_id: None,
            sequence: None,
        });

        // Invalidate cached session
        ctx.session_manager.invalidate_session(&session_id);

        Ok(serde_json::json!({
            "success": true,
            "wasActive": true,
            "deactivatedSkill": skill_name,
        }))
    }
}

/// Query currently active skills in a session.
///
/// Reconstructs skill state from events and returns the list of
/// active skills with metadata.
pub struct ActiveHandler;

#[async_trait]
impl MethodHandler for ActiveHandler {
    #[instrument(skip(self, ctx), fields(method = "skill.active"))]
    async fn handle(&self, params: Option<Value>, ctx: &RpcContext) -> Result<Value, RpcError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;

        // Verify session exists
        let _ = ctx.session_manager
            .get_session(&session_id)
            .map_err(|e| RpcError::Internal {
                message: e.to_string(),
            })?
            .ok_or_else(|| RpcError::NotFound {
                code: errors::NOT_FOUND.into(),
                message: format!("Session '{session_id}' not found"),
            })?;

        let tracker =
            reconstruct_tracker(&ctx.event_store, &session_id, &CompactionPolicy::ClearAll);

        let skills: Vec<Value> = {
            let registry = ctx.skill_registry.read();
            tracker
                .added_skills()
                .iter()
                .map(|s| {
                    let added_via = match s.added_via {
                        crate::skills::types::SkillAddMethod::Mention => "mention",
                        crate::skills::types::SkillAddMethod::Explicit => "explicit",
                    };
                    // Enrich with service via registry lookup; unknown when the
                    // underlying skill was deleted from disk after activation.
                    let service = registry
                        .get(&s.name)
                        .map(|m| m.service.clone())
                        .unwrap_or_else(|| "unknown".to_string());
                    serde_json::json!({
                        "name": s.name,
                        "source": s.source.to_string(),
                        "service": service,
                        "addedVia": added_via,
                        "tokens": s.tokens,
                    })
                })
                .collect()
        };

        Ok(serde_json::json!({
            "skills": skills,
        }))
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Reconstruct a SkillTracker from the event store for a given session.
///
/// Queries all skill-related events and builds the tracker.
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
        .filter_map(|e| {
            serde_json::from_str::<Value>(&e.payload).ok().map(|payload| {
                serde_json::json!({
                    "type": e.event_type,
                    "id": e.id,
                    "payload": payload,
                })
            })
        })
        .collect();
    SkillTracker::from_events_with_policy(&json_events, policy)
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
            content: format!("{name} content — this is the full skill body"),
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

    // ── skill.activate ──────────────────────────────────────────────

    #[tokio::test]
    async fn test_skill_activate_success() {
        let ctx = make_test_context();
        ctx.skill_registry.write().insert(make_skill("browser"));
        let session_id = create_test_session(&ctx);

        let result = ActivateHandler
            .handle(
                Some(json!({"sessionId": session_id, "skillName": "browser"})),
                &ctx,
            )
            .await
            .unwrap();

        assert_eq!(result["success"], true);
        assert_eq!(result["skill"]["name"], "browser");
        assert_eq!(result["skill"]["source"], "global");
        assert!(result["skill"]["tokens"].is_number());
        assert!(result.get("alreadyActive").is_none());
    }

    #[tokio::test]
    async fn test_skill_activate_not_found() {
        let ctx = make_test_context();
        let session_id = create_test_session(&ctx);

        let err = ActivateHandler
            .handle(
                Some(json!({"sessionId": session_id, "skillName": "nonexistent"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "NOT_FOUND");
    }

    #[tokio::test]
    async fn test_skill_activate_missing_session() {
        let ctx = make_test_context();
        ctx.skill_registry.write().insert(make_skill("browser"));

        let err = ActivateHandler
            .handle(
                Some(json!({"sessionId": "no-such-session", "skillName": "browser"})),
                &ctx,
            )
            .await
            .unwrap_err();
        assert_eq!(err.code(), "NOT_FOUND");
    }

    #[tokio::test]
    async fn test_skill_activate_missing_params() {
        let ctx = make_test_context();

        let err = ActivateHandler
            .handle(Some(json!({})), &ctx)
            .await
            .unwrap_err();
        assert_eq!(err.code(), "INVALID_PARAMS");
    }

    #[tokio::test]
    async fn test_skill_activate_idempotent() {
        let ctx = make_test_context();
        ctx.skill_registry.write().insert(make_skill("browser"));
        let session_id = create_test_session(&ctx);

        // Activate first time
        let _ = ActivateHandler
            .handle(
                Some(json!({"sessionId": session_id, "skillName": "browser"})),
                &ctx,
            )
            .await
            .unwrap();

        // Activate again — idempotent
        let result = ActivateHandler
            .handle(
                Some(json!({"sessionId": session_id, "skillName": "browser"})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["success"], true);
        assert_eq!(result["alreadyActive"], true);

        // Should only have one skill.activated event
        let events = ctx
            .event_store
            .get_events_by_type(&session_id, &["skill.activated"], None)
            .unwrap();
        assert_eq!(events.len(), 1);
    }

    // ── skill.deactivate ────────────────────────────────────────────

    #[tokio::test]
    async fn test_skill_deactivate_success() {
        let ctx = make_test_context();
        ctx.skill_registry.write().insert(make_skill("browser"));
        let session_id = create_test_session(&ctx);

        // Activate first
        let _ = ActivateHandler
            .handle(
                Some(json!({"sessionId": session_id, "skillName": "browser"})),
                &ctx,
            )
            .await
            .unwrap();

        // Deactivate
        let result = DeactivateHandler
            .handle(
                Some(json!({"sessionId": session_id, "skillName": "browser"})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["success"], true);
        assert_eq!(result["wasActive"], true);
        assert_eq!(result["deactivatedSkill"], "browser");
    }

    #[tokio::test]
    async fn test_skill_deactivate_not_active() {
        let ctx = make_test_context();
        let session_id = create_test_session(&ctx);

        let result = DeactivateHandler
            .handle(
                Some(json!({"sessionId": session_id, "skillName": "browser"})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["success"], true);
        assert_eq!(result["wasActive"], false);

        // No deactivation event written
        let events = ctx
            .event_store
            .get_events_by_type(&session_id, &["skill.deactivated"], None)
            .unwrap();
        assert!(events.is_empty());
    }

    // ── skill.active ────────────────────────────────────────────────

    #[tokio::test]
    async fn test_skill_active_returns_list() {
        let ctx = make_test_context();
        ctx.skill_registry.write().insert(make_skill("browser"));
        ctx.skill_registry.write().insert(make_skill("git"));
        let session_id = create_test_session(&ctx);

        // Activate two skills
        let _ = ActivateHandler
            .handle(
                Some(json!({"sessionId": session_id, "skillName": "browser"})),
                &ctx,
            )
            .await
            .unwrap();
        let _ = ActivateHandler
            .handle(
                Some(json!({"sessionId": session_id, "skillName": "git"})),
                &ctx,
            )
            .await
            .unwrap();

        let result = ActiveHandler
            .handle(Some(json!({"sessionId": session_id})), &ctx)
            .await
            .unwrap();

        let skills = result["skills"].as_array().unwrap();
        assert_eq!(skills.len(), 2);
        let names: Vec<&str> = skills
            .iter()
            .map(|s| s["name"].as_str().unwrap())
            .collect();
        assert!(names.contains(&"browser"));
        assert!(names.contains(&"git"));
    }

    #[tokio::test]
    async fn test_skill_active_empty_session() {
        let ctx = make_test_context();
        let session_id = create_test_session(&ctx);

        let result = ActiveHandler
            .handle(Some(json!({"sessionId": session_id})), &ctx)
            .await
            .unwrap();

        let skills = result["skills"].as_array().unwrap();
        assert!(skills.is_empty());
    }

    // ── reconstruct_tracker helper ──────────────────────────────────

    #[tokio::test]
    async fn test_reconstruct_tracker_helper() {
        let ctx = make_test_context();
        ctx.skill_registry.write().insert(make_skill("browser"));
        let session_id = create_test_session(&ctx);

        let _ = ActivateHandler
            .handle(
                Some(json!({"sessionId": session_id, "skillName": "browser"})),
                &ctx,
            )
            .await
            .unwrap();

        let tracker = reconstruct_tracker(&ctx.event_store, &session_id, &crate::settings::types::CompactionPolicy::ClearAll);
        assert!(tracker.has_skill("browser"));
        assert_eq!(tracker.count(), 1);
    }

    // ── Activate then deactivate flow ───────────────────────────────

    #[tokio::test]
    async fn test_activate_deactivate_flow() {
        let ctx = make_test_context();
        ctx.skill_registry.write().insert(make_skill("browser"));
        let session_id = create_test_session(&ctx);

        // Activate
        let _ = ActivateHandler
            .handle(
                Some(json!({"sessionId": session_id, "skillName": "browser"})),
                &ctx,
            )
            .await
            .unwrap();

        // Verify active
        let tracker = reconstruct_tracker(&ctx.event_store, &session_id, &crate::settings::types::CompactionPolicy::ClearAll);
        assert!(tracker.has_skill("browser"));

        // Deactivate
        let _ = DeactivateHandler
            .handle(
                Some(json!({"sessionId": session_id, "skillName": "browser"})),
                &ctx,
            )
            .await
            .unwrap();

        // Verify not active, pending removal
        let tracker = reconstruct_tracker(&ctx.event_store, &session_id, &crate::settings::types::CompactionPolicy::ClearAll);
        assert!(!tracker.has_skill("browser"));
        assert!(tracker.pending_removal_notices().contains("browser"));
    }

    // ── service wire tagging ────────────────────────────────────────
    // These guard against the same class of regression that bit skill.get:
    // iOS now decodes `service` on every skill-shaped wire payload; any
    // handler that omits it silently breaks the UI.

    #[tokio::test]
    async fn activate_response_includes_service() {
        let ctx = make_test_context();
        let mut skill = make_skill("browser");
        skill.service = "claude".to_string();
        ctx.skill_registry.write().insert(skill);
        let session_id = create_test_session(&ctx);

        let result = ActivateHandler
            .handle(
                Some(json!({"sessionId": session_id, "skillName": "browser"})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(result["skill"]["service"], "claude");
    }

    #[tokio::test]
    async fn activate_already_active_response_includes_service() {
        let ctx = make_test_context();
        let mut skill = make_skill("browser");
        skill.service = "claude".to_string();
        ctx.skill_registry.write().insert(skill);
        let session_id = create_test_session(&ctx);

        let _ = ActivateHandler
            .handle(
                Some(json!({"sessionId": session_id, "skillName": "browser"})),
                &ctx,
            )
            .await
            .unwrap();
        let again = ActivateHandler
            .handle(
                Some(json!({"sessionId": session_id, "skillName": "browser"})),
                &ctx,
            )
            .await
            .unwrap();
        assert_eq!(again["alreadyActive"], true);
        assert_eq!(again["skill"]["service"], "claude");
    }

    #[tokio::test]
    async fn active_response_includes_service_per_skill() {
        let ctx = make_test_context();
        let mut tron_skill = make_skill("tron-one");
        tron_skill.service = "tron".to_string();
        let mut claude_skill = make_skill("claude-one");
        claude_skill.service = "claude".to_string();
        ctx.skill_registry.write().insert(tron_skill);
        ctx.skill_registry.write().insert(claude_skill);
        let session_id = create_test_session(&ctx);

        for name in ["tron-one", "claude-one"] {
            let _ = ActivateHandler
                .handle(
                    Some(json!({"sessionId": session_id, "skillName": name})),
                    &ctx,
                )
                .await
                .unwrap();
        }

        let result = ActiveHandler
            .handle(Some(json!({"sessionId": session_id})), &ctx)
            .await
            .unwrap();
        let skills = result["skills"].as_array().unwrap();
        let tron = skills.iter().find(|s| s["name"] == "tron-one").unwrap();
        let claude = skills.iter().find(|s| s["name"] == "claude-one").unwrap();
        assert_eq!(tron["service"], "tron");
        assert_eq!(claude["service"], "claude");
    }

    #[tokio::test]
    async fn pending_skill_payloads_emit_service() {
        // Regression for the user-message chip display: iOS parses
        // payload.skills[].service and renders a claude badge on sent
        // messages. Server must enrich the payload via the registry.
        use crate::server::rpc::handlers::agent::prompt_runtime::collect_pending_skill_payloads;

        let ctx = make_test_context();
        let mut skill = make_skill("probe");
        skill.service = "claude".to_string();
        ctx.skill_registry.write().insert(skill);
        let session_id = create_test_session(&ctx);

        let _ = ActivateHandler
            .handle(
                Some(json!({"sessionId": session_id, "skillName": "probe"})),
                &ctx,
            )
            .await
            .unwrap();

        let registry = ctx.skill_registry.read();
        let payload = collect_pending_skill_payloads(
            &ctx.event_store,
            &session_id,
            Some(&*registry),
        )
        .expect("skills_json should be Some");
        let arr = payload.as_array().unwrap();
        let probe = arr.iter().find(|s| s["name"] == "probe").unwrap();
        assert_eq!(probe["service"], "claude");
        assert!(probe.get("displayName").is_some());
    }

    #[tokio::test]
    async fn pending_skill_payloads_service_unknown_when_skill_missing() {
        use crate::server::rpc::handlers::agent::prompt_runtime::collect_pending_skill_payloads;

        let ctx = make_test_context();
        ctx.skill_registry.write().insert(make_skill("ephemeral"));
        let session_id = create_test_session(&ctx);

        let _ = ActivateHandler
            .handle(
                Some(json!({"sessionId": session_id, "skillName": "ephemeral"})),
                &ctx,
            )
            .await
            .unwrap();

        // Remove from registry to simulate the skill being deleted on disk
        let _ = ctx.skill_registry.write().remove("ephemeral");

        let registry = ctx.skill_registry.read();
        let payload = collect_pending_skill_payloads(
            &ctx.event_store,
            &session_id,
            Some(&*registry),
        )
        .expect("skills_json should be Some");
        let arr = payload.as_array().unwrap();
        let skill = arr.iter().find(|s| s["name"] == "ephemeral").unwrap();
        assert_eq!(skill["service"], "unknown");
    }

    #[tokio::test]
    async fn active_response_service_is_unknown_for_deleted_skill() {
        // Skill was activated, then removed from disk → registry lookup fails.
        // Wire payload must report `"unknown"` so iOS decode still succeeds
        // and the chip renders without a service badge.
        let ctx = make_test_context();
        ctx.skill_registry.write().insert(make_skill("ghost"));
        let session_id = create_test_session(&ctx);
        let _ = ActivateHandler
            .handle(
                Some(json!({"sessionId": session_id, "skillName": "ghost"})),
                &ctx,
            )
            .await
            .unwrap();

        // Simulate skill removal from disk by dropping it from the registry.
        let _ = ctx.skill_registry.write().remove("ghost");

        let result = ActiveHandler
            .handle(Some(json!({"sessionId": session_id})), &ctx)
            .await
            .unwrap();
        let skill = result["skills"]
            .as_array()
            .unwrap()
            .iter()
            .find(|s| s["name"] == "ghost")
            .unwrap();
        assert_eq!(skill["service"], "unknown");
    }
}
