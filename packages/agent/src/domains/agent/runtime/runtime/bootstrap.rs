use super::pending::{
    format_process_results, format_user_job_actions, get_pending_process_results,
    get_pending_user_job_actions,
};
use super::{EventType, collect_dynamic_rule_paths};
use crate::domains::session::context::ContextArtifactsService;
use crate::domains::session::event_store::EventStore;
use crate::shared::server::context::run_blocking_task;
use crate::shared::server::errors::CapabilityError;
use std::sync::Arc;

#[derive(Default)]
pub struct PromptContextArtifacts {
    pub rules_content: Option<String>,
    pub rules_index: Option<crate::domains::agent::runner::context::rules_index::RulesIndex>,
    pub pre_activated_rules: Vec<String>,
    pub workspace_id: Option<String>,
}

pub struct PromptBootstrapData {
    pub artifacts: PromptContextArtifacts,
    pub subagent_results_context: Option<String>,
    pub process_results_context: Option<String>,
    pub user_job_actions_context: Option<String>,
}

fn load_prompt_context_artifacts(
    context_artifacts: &ContextArtifactsService,
    event_store: &crate::domains::session::event_store::EventStore,
    session_id: &str,
    working_dir: &str,
    settings: &crate::domains::settings::TronSettings,
    is_resumed: bool,
    source: Option<&str>,
) -> PromptContextArtifacts {
    // Chat sessions skip context artifacts (rules, workspace memory)
    if source == Some("chat") {
        return PromptContextArtifacts::default();
    }

    let artifacts = context_artifacts.load(event_store, working_dir, settings);
    let pre_activated_rules = if is_resumed {
        collect_dynamic_rule_paths(event_store, session_id)
    } else {
        Vec::new()
    };

    PromptContextArtifacts {
        rules_content: artifacts.session.rules.merged_content,
        rules_index: artifacts.rules_index,
        pre_activated_rules,
        workspace_id: artifacts.workspace_id,
    }
}

/// Local-model variant of `load_prompt_bootstrap`: loads only the cheap artifacts
/// (rules files + dynamic rule paths) and skips the three DB queries for pending
/// subagent/process/user-job results. Local models never receive those
/// result blocks in context (see `build_turn_context` in `turn_runner.rs`), so
/// producing them is pure waste that adds to TTFT.
///
/// Pending results stay queued in the event store — if the user switches back to
/// a cloud model in a later prompt, they will be consumed and injected then.
pub async fn load_prompt_bootstrap_minimal(
    context_artifacts: Arc<ContextArtifactsService>,
    event_store: Arc<EventStore>,
    session_id: String,
    working_dir: String,
    settings: crate::domains::settings::TronSettings,
    is_resumed: bool,
    source: Option<String>,
) -> Result<PromptBootstrapData, CapabilityError> {
    run_blocking_task("agent.prompt.bootstrap.minimal", move || {
        let artifacts = load_prompt_context_artifacts(
            context_artifacts.as_ref(),
            event_store.as_ref(),
            &session_id,
            &working_dir,
            &settings,
            is_resumed,
            source.as_deref(),
        );
        Ok(PromptBootstrapData {
            artifacts,
            subagent_results_context: None,
            process_results_context: None,
            user_job_actions_context: None,
        })
    })
    .await
}

pub async fn load_prompt_bootstrap(
    context_artifacts: Arc<ContextArtifactsService>,
    event_store: Arc<EventStore>,
    session_id: String,
    working_dir: String,
    settings: crate::domains::settings::TronSettings,
    is_resumed: bool,
    source: Option<String>,
) -> Result<PromptBootstrapData, CapabilityError> {
    run_blocking_task("agent.prompt.bootstrap", move || {
        let artifacts = load_prompt_context_artifacts(
            context_artifacts.as_ref(),
            event_store.as_ref(),
            &session_id,
            &working_dir,
            &settings,
            is_resumed,
            source.as_deref(),
        );

        let subagent_results_context = None;

        let pending_procs = get_pending_process_results(event_store.as_ref(), &session_id);
        let process_results_context = if pending_procs.is_empty() {
            None
        } else {
            let event_ids: Vec<String> = pending_procs.iter().map(|(id, _)| id.clone()).collect();
            let formatted = format_process_results(&pending_procs);
            if formatted.is_some() {
                let _ = event_store.append(&crate::domains::session::event_store::AppendOptions {
                    session_id: &session_id,
                    event_type: EventType::ProcessResultsConsumed,
                    payload: serde_json::json!({
                        "consumedEventIds": event_ids,
                        "count": pending_procs.len(),
                    }),
                    parent_id: None,
                    sequence: None,
                });
            }
            formatted
        };

        // Inject user job actions (backgrounded / cancelled from iOS).
        let user_job_actions = get_pending_user_job_actions(event_store.as_ref(), &session_id);
        let user_job_actions_context = if user_job_actions.is_empty() {
            None
        } else {
            let event_ids: Vec<String> =
                user_job_actions.iter().map(|(id, _)| id.clone()).collect();
            let formatted = format_user_job_actions(&user_job_actions);
            let _ = event_store.append(&crate::domains::session::event_store::AppendOptions {
                session_id: &session_id,
                event_type: EventType::UserJobActionsConsumed,
                payload: serde_json::json!({
                    "consumedEventIds": event_ids,
                    "count": user_job_actions.len(),
                }),
                parent_id: None,
                sequence: None,
            });
            Some(formatted)
        };

        Ok(PromptBootstrapData {
            artifacts,
            subagent_results_context,
            process_results_context,
            user_job_actions_context,
        })
    })
    .await
}
