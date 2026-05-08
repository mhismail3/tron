//! Context read-model queries.
//!
//! The context domain keeps query orchestration here, while focused child
//! modules own snapshot rendering, audit trace reads, payload preview
//! redaction, and blocking context-manager preparation.

use std::path::Path;

use crate::skills::tracker::SkillTracker;
use crate::skills::types::{SkillAddMethod, SkillSource};
use parking_lot::RwLock;
use rusqlite::params;
use serde_json::{Value, json};

use crate::server::domains::context::Deps;
use crate::server::domains::context::service::{
    PreparedSessionContext, build_active_skill_context, build_context_manager_for_session,
    build_summarizer, retry_context_read, tool_definitions,
};
use crate::server::domains::session::context::{RuleFileLevel, collect_dynamic_rule_paths};
use crate::server::shared::context::run_blocking_task;
use crate::server::shared::errors::CapabilityError;

mod audit;
mod payload_preview;
mod prepare;
mod snapshot;

use audit::load_audit_trace;
pub(crate) use prepare::prepare_session_context;
use prepare::set_volatile_tokens_from_session;
use snapshot::{build_added_skills, build_detailed_snapshot_response, snapshot_response};

pub(crate) struct ContextQueryService;

impl ContextQueryService {
    pub(crate) async fn get_snapshot(
        deps: &Deps,
        session_id: String,
    ) -> Result<Value, CapabilityError> {
        let session_manager = deps.session_manager.clone();
        let event_store = deps.event_store.clone();
        let context_artifacts = deps.context_artifacts.clone();
        let profile_runtime = deps.profile_runtime.clone();
        let skill_registry = deps.skill_registry.clone();
        let memory_registry = deps.memory_registry.clone();
        let tool_definitions = tool_definitions(deps);
        let session_id_for_query = session_id.clone();
        run_blocking_task("context.get_snapshot", move || {
            retry_context_read("context.get_snapshot", || {
                let mut prepared = build_context_manager_for_session(
                    &session_id_for_query,
                    session_manager.as_ref(),
                    event_store.as_ref(),
                    context_artifacts.as_ref(),
                    profile_runtime.as_ref(),
                    tool_definitions.clone(),
                )?;
                // Skill index + memory content: skip for local models (stripped at turn time)
                if !prepared.context_manager.is_local_model() {
                    let skill_index_content = {
                        let mut registry = skill_registry.write();
                        let _ = registry.refresh_if_stale(&prepared.session.working_directory);
                        let skills = registry.list(None);
                        let index = crate::skills::injector::build_skill_index(&skills);
                        if index.is_empty() { None } else { Some(index) }
                    };
                    prepared
                        .context_manager
                        .set_skill_index_content(skill_index_content);

                    let memory_content = {
                        let mut reg = memory_registry.lock();
                        Some(reg.content(&crate::core::paths::home_dir()).to_string())
                    };
                    prepared.context_manager.set_memory_content(memory_content);
                }

                // Reconstruct volatile token estimates from session state
                // (runs for all models — users can manually activate skills)
                let added_skills = build_added_skills(
                    event_store.as_ref(),
                    &session_id_for_query,
                    &skill_registry,
                )?;
                set_volatile_tokens_from_session(
                    &mut prepared.context_manager,
                    &added_skills,
                    &skill_registry,
                    prepared.session.origin.as_deref(),
                );

                let snapshot = prepared.context_manager.get_snapshot();
                Ok(snapshot_response(&snapshot))
            })
        })
        .await
    }

    pub(crate) async fn get_detailed_snapshot(
        deps: &Deps,
        session_id: String,
    ) -> Result<Value, CapabilityError> {
        let session_manager = deps.session_manager.clone();
        let event_store = deps.event_store.clone();
        let context_artifacts = deps.context_artifacts.clone();
        let profile_runtime = deps.profile_runtime.clone();
        let skill_registry = deps.skill_registry.clone();
        let memory_registry = deps.memory_registry.clone();
        let tool_definitions = tool_definitions(deps);
        let session_id_for_query = session_id.clone();
        run_blocking_task("context.get_detailed_snapshot", move || {
            retry_context_read("context.get_detailed_snapshot", || {
                let prepared = build_context_manager_for_session(
                    &session_id_for_query,
                    session_manager.as_ref(),
                    event_store.as_ref(),
                    context_artifacts.as_ref(),
                    profile_runtime.as_ref(),
                    tool_definitions.clone(),
                )?;
                build_detailed_snapshot_response(
                    event_store.as_ref(),
                    &session_id_for_query,
                    prepared,
                    &skill_registry,
                    &memory_registry,
                )
            })
        })
        .await
    }

    pub(crate) async fn get_audit_trace(
        deps: &Deps,
        session_id: String,
        turn: Option<u32>,
    ) -> Result<Value, CapabilityError> {
        let event_store = deps.event_store.clone();
        let session_id_for_query = session_id.clone();
        run_blocking_task("context.get_audit_trace", move || {
            let conn = event_store
                .pool()
                .get()
                .map_err(|error| CapabilityError::Internal {
                    message: format!("database connection error: {error}"),
                })?;
            let trace = load_audit_trace(&conn, &session_id_for_query, turn)?;
            trace.ok_or_else(|| CapabilityError::NotFound {
                code: "CONTEXT_AUDIT_NOT_FOUND".into(),
                message: format!(
                    "No context audit trace found for session `{}`{}",
                    session_id_for_query,
                    turn.map_or_else(String::new, |turn| format!(" turn {turn}"))
                ),
            })
        })
        .await
    }

    pub(crate) async fn should_compact(
        deps: &Deps,
        session_id: String,
    ) -> Result<Value, CapabilityError> {
        let session_manager = deps.session_manager.clone();
        let event_store = deps.event_store.clone();
        let context_artifacts = deps.context_artifacts.clone();
        let profile_runtime = deps.profile_runtime.clone();
        let tool_definitions = tool_definitions(deps);
        let session_id_for_query = session_id.clone();
        run_blocking_task("context.should_compact", move || {
            retry_context_read("context.should_compact", || {
                let prepared = build_context_manager_for_session(
                    &session_id_for_query,
                    session_manager.as_ref(),
                    event_store.as_ref(),
                    context_artifacts.as_ref(),
                    profile_runtime.as_ref(),
                    tool_definitions.clone(),
                )?;
                Ok(json!({
                    "shouldCompact": prepared.context_manager.should_compact(),
                }))
            })
        })
        .await
    }

    pub(crate) async fn preview_compaction(
        deps: &Deps,
        session_id: String,
    ) -> Result<Value, CapabilityError> {
        let prepared =
            prepare_session_context(deps, "context.preview_compaction.prepare", &session_id)
                .await?;
        let summarizer = build_summarizer(deps, &session_id, &prepared.session.working_directory);
        let preview = prepared
            .context_manager
            .preview_compaction(summarizer.as_ref())
            .await
            .map_err(|error| CapabilityError::Internal {
                message: format!("Compaction preview failed: {error}"),
            })?;

        Ok(json!({
            "tokensBefore": preview.tokens_before,
            "tokensAfter": preview.tokens_after,
            "compressionRatio": preview.compression_ratio,
            "preservedMessages": preview.preserved_messages,
            "summarizedMessages": preview.summarized_messages,
            "summary": preview.summary,
            "extractedData": preview.extracted_data,
        }))
    }

    pub(crate) async fn can_accept_turn(
        deps: &Deps,
        session_id: String,
    ) -> Result<Value, CapabilityError> {
        let session_manager = deps.session_manager.clone();
        let event_store = deps.event_store.clone();
        let context_artifacts = deps.context_artifacts.clone();
        let profile_runtime = deps.profile_runtime.clone();
        let tool_definitions = tool_definitions(deps);
        let session_id_for_query = session_id.clone();
        run_blocking_task("context.can_accept_turn", move || {
            retry_context_read("context.can_accept_turn", || {
                let prepared = build_context_manager_for_session(
                    &session_id_for_query,
                    session_manager.as_ref(),
                    event_store.as_ref(),
                    context_artifacts.as_ref(),
                    profile_runtime.as_ref(),
                    tool_definitions.clone(),
                )?;
                Ok(json!({
                    "canAcceptTurn": prepared.context_manager.can_accept_turn().can_proceed,
                }))
            })
        })
        .await
    }
}
