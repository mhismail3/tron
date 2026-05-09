//! Prompt-run hook setup and lifecycle dispatch.

use std::sync::Arc;

use tracing::debug;

use crate::domains::agent::runner::hooks::builtin;
use crate::domains::agent::runner::hooks::discovery::discover_hooks;
use crate::domains::agent::runner::hooks::engine::HookEngine;
use crate::domains::agent::runner::hooks::registry::HookRegistry;
use crate::domains::agent::runner::hooks::types::{DiscoveryConfig, HookAction, HookContext};

pub(super) fn build_prompt_hooks(
    subagent_manager: &Option<
        Arc<crate::domains::agent::runner::orchestrator::subagent_manager::SubagentManager>,
    >,
    broadcast: &Arc<crate::domains::agent::runner::EventEmitter>,
    event_store: &Arc<crate::domains::session::event_store::EventStore>,
    worktree_coordinator: &Option<Arc<crate::domains::worktree::WorktreeCoordinator>>,
    hook_abort_tracker: &Arc<crate::domains::agent::runner::hooks::abort_tracker::HookAbortTracker>,
    working_dir: &str,
) -> Option<Arc<HookEngine>> {
    let settings = crate::domains::settings::get_settings();
    let hook_settings = &settings.hooks;

    let mut engine = HookEngine::new(HookRegistry::new());
    engine.set_error_policy(hook_settings.error_policy);

    if let Some(mgr) = subagent_manager {
        builtin::register_builtins(
            &mut engine,
            &hook_settings.llm_model,
            &hook_settings.builtin_hooks,
            mgr,
            broadcast,
            Some(event_store),
            worktree_coordinator.as_ref(),
            hook_abort_tracker,
        );
    }

    let discovered = discover_hooks(&DiscoveryConfig {
        project_path: Some(working_dir.to_owned()),
        user_home: None,
        include_user_hooks: true,
        extensions: hook_settings.extensions.iter().cloned().collect(),
        ..Default::default()
    });

    if !discovered.is_empty() {
        engine.load_discovered_hooks(
            discovered,
            hook_settings.default_timeout_ms,
            &hook_settings.llm_model,
            subagent_manager.as_ref(),
            Some(broadcast),
        );
    }

    Some(Arc::new(engine))
}

pub(super) async fn fire_worktree_acquired_hook(
    hooks: &Option<Arc<HookEngine>>,
    session_id: &str,
    worktree_info: Option<&crate::domains::worktree::WorktreeInfo>,
    freshly_acquired: bool,
) {
    if !freshly_acquired {
        return;
    }
    if let (Some(hook_engine), Some(wt_info)) = (hooks, worktree_info) {
        debug!(session_id = %session_id, "[hooks] firing WorktreeAcquired");
        let hook_ctx = HookContext::WorktreeAcquired {
            session_id: session_id.to_owned(),
            timestamp: chrono::Utc::now().to_rfc3339(),
            branch: wt_info.branch.clone(),
            repo_root: wt_info.repo_root.to_string_lossy().to_string(),
            base_branch: wt_info.base_branch.clone(),
            working_directory: wt_info.worktree_path.to_string_lossy().to_string(),
        };
        let _ = hook_engine.execute(&hook_ctx).await;
        debug!(session_id = %session_id, "[hooks] WorktreeAcquired returned");
    }
}

pub(super) async fn fire_session_start_hook(
    hooks: &Option<Arc<HookEngine>>,
    session_id: &str,
    working_dir: &str,
) {
    if let Some(hook_engine) = hooks {
        debug!(session_id = %session_id, "[hooks] firing SessionStart");
        let hook_ctx = HookContext::SessionStart {
            session_id: session_id.to_owned(),
            timestamp: chrono::Utc::now().to_rfc3339(),
            working_directory: working_dir.to_owned(),
        };
        let _ = hook_engine.execute(&hook_ctx).await;
        debug!(session_id = %session_id, "[hooks] SessionStart returned");
    }
}

pub(super) async fn apply_user_prompt_submit_hook(
    hooks: &Option<Arc<HookEngine>>,
    session_id: &str,
    prompt: &str,
) -> (String, Option<String>) {
    let mut effective_prompt = prompt.to_owned();
    let mut hook_context = None;
    if let Some(hook_engine) = hooks {
        debug!(session_id = %session_id, "[hooks] firing UserPromptSubmit");
        let hook_ctx = HookContext::UserPromptSubmit {
            session_id: session_id.to_owned(),
            timestamp: chrono::Utc::now().to_rfc3339(),
            prompt: prompt.to_owned(),
        };
        let hook_result = hook_engine.execute(&hook_ctx).await;
        if hook_result.action == HookAction::AddContext
            && let Some(content) = hook_result.added_context
            && !content.is_empty()
        {
            debug!(
                session_id = %session_id,
                bytes = content.len(),
                "[hooks] UserPromptSubmit injected added_context into prompt"
            );
            hook_context = Some(content.clone());
            effective_prompt = format!(
                "<hook-context>\n{content}\n</hook-context>\n\n{prompt}",
                content = content,
                prompt = prompt,
            );
        }
        debug!(session_id = %session_id, "[hooks] UserPromptSubmit returned");
    }
    (effective_prompt, hook_context)
}
