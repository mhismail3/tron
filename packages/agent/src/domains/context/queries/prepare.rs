use super::{
    Deps, PreparedSessionContext, RwLock, build_active_skill_context,
    build_context_manager_for_session, model_capability_definitions, retry_context_read,
};
use crate::domains::skills::registry::SkillRegistry;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;
use serde_json::Value;
use std::sync::Arc;

pub(crate) async fn prepare_session_context(
    deps: &Deps,
    task_name: &'static str,
    session_id: &str,
) -> Result<PreparedSessionContext, CapabilityError> {
    let session_manager = deps.session_manager.clone();
    let event_store = deps.event_store.clone();
    let context_artifacts = deps.context_artifacts.clone();
    let profile_runtime = deps.profile_runtime.clone();
    let capabilities_for_model = model_capability_definitions(deps, session_id).await;
    let session_id = session_id.to_owned();
    run_blocking_task(task_name, move || {
        retry_context_read(task_name, || {
            build_context_manager_for_session(
                &session_id,
                session_manager.as_ref(),
                event_store.as_ref(),
                context_artifacts.as_ref(),
                profile_runtime.as_ref(),
                capabilities_for_model.clone(),
            )
        })
    })
    .await
}

/// Reconstruct volatile token estimates from session state so snapshots
/// queried between turns reflect active skills accurately.
pub(super) fn set_volatile_tokens_from_session(
    context_manager: &mut crate::domains::agent::runner::context::context_manager::ContextManager,
    added_skills: &[Value],
    skill_registry: &Arc<RwLock<SkillRegistry>>,
    server_origin: Option<&str>,
) {
    let active_skill_names: Vec<String> = added_skills
        .iter()
        .filter_map(|skill| skill.get("name").and_then(Value::as_str).map(String::from))
        .collect();
    let skill_context = build_active_skill_context(&active_skill_names, skill_registry);
    let skill_context_tokens = skill_context.as_ref().map_or(0, |s| s.len() as u64 / 4);

    context_manager.set_volatile_tokens(skill_context_tokens, 0, 0);
    context_manager.set_server_origin(server_origin.map(String::from));
}
