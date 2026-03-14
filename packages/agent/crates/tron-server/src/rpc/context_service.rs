use std::sync::Arc;
use std::time::Duration;

use parking_lot::RwLock;
use tron_core::tools::Tool;
use tron_events::sqlite::contention::{self, BusyRetryPolicy};
use tron_runtime::context::context_manager::ContextManager;
use tron_runtime::context::summarizer::{KeywordSummarizer, Summarizer};
use tron_runtime::context::types::{CompactionConfig, ContextManagerConfig};
use tron_runtime::orchestrator::session_manager::SessionManager;
use tron_skills::registry::SkillRegistry;

use crate::rpc::context::RpcContext;
use crate::rpc::errors::{self, RpcError};
use crate::rpc::session_context::SessionContextArtifacts;

pub(crate) struct PreparedSessionContext {
    pub(crate) session: tron_events::sqlite::row_types::SessionRow,
    pub(crate) artifacts: SessionContextArtifacts,
    pub(crate) context_manager: ContextManager,
}

pub(crate) fn build_context_manager_for_session(
    session_id: &str,
    session_manager: &SessionManager,
    event_store: &tron_events::EventStore,
    context_artifacts: &crate::rpc::session_context::ContextArtifactsService,
    tool_definitions: Vec<Tool>,
) -> Result<PreparedSessionContext, RpcError> {
    let session = session_manager
        .get_session(session_id)
        .map_err(|error| RpcError::Internal {
            message: error.to_string(),
        })?
        .ok_or_else(|| RpcError::NotFound {
            code: errors::SESSION_NOT_FOUND.into(),
            message: format!("Session '{session_id}' not found"),
        })?;

    let state = match session_manager.resume_session(session_id) {
        Ok(active) => active.state.clone(),
        Err(_) => tron_runtime::ReconstructedState {
            model: session.latest_model.clone(),
            working_directory: Some(session.working_directory.clone()),
            ..Default::default()
        },
    };

    let settings = tron_settings::get_settings();
    let is_chat = session.source.as_deref() == Some("chat");
    let artifacts = context_artifacts
        .load(event_store, &session.working_directory, &settings, is_chat)
        .session;

    let context_limit = tron_llm::model_context_window(&state.model);
    let compactor_settings = &settings.context.compactor;
    let mut context_manager = ContextManager::new(ContextManagerConfig {
        model: state.model.clone(),
        system_prompt: None,
        working_directory: state.working_directory.clone(),
        tools: tool_definitions,
        rules_content: artifacts.rules.merged_content.clone(),
        compaction: CompactionConfig {
            threshold: compactor_settings.compaction_threshold,
            preserve_recent_turns: compactor_settings.preserve_recent_count,
            max_preserved_ratio: compactor_settings.max_preserved_ratio,
            context_limit,
        },
    });

    if !state.messages.is_empty() {
        context_manager.set_messages(state.messages.clone());
    }
    if let Some(memory) = artifacts.memory.as_ref() {
        context_manager.set_memory_content(Some(memory.content.clone()));
    }

    let last_turn = session.last_turn_input_tokens;
    if last_turn > 0 {
        #[allow(clippy::cast_sign_loss)]
        context_manager.set_api_context_tokens(last_turn as u64);
    }

    Ok(PreparedSessionContext {
        session,
        artifacts,
        context_manager,
    })
}

pub(crate) fn retry_context_read<T>(
    operation_name: &'static str,
    mut operation: impl FnMut() -> Result<T, RpcError>,
) -> Result<T, RpcError> {
    let policy = BusyRetryPolicy {
        deadline: Duration::from_millis(750),
        backoff_step: Duration::from_millis(10),
        max_backoff: Duration::from_millis(75),
        jitter_percent: 15,
    };

    match contention::retry_on_busy(operation_name, policy, &mut operation, is_busy_rpc_error) {
        Ok(value) => Ok(value),
        Err(contention::RetryError::Inner(error)) => Err(error),
        Err(contention::RetryError::BusyTimeout(timeout)) => Err(RpcError::Internal {
            message: format!(
                "database busy during {operation_name} after {} attempts: {}",
                timeout.attempts, timeout.last_error
            ),
        }),
    }
}

fn is_busy_rpc_error(error: &RpcError) -> bool {
    let RpcError::Internal { message } = error else {
        return false;
    };

    let message = message.to_ascii_lowercase();
    message.contains("database busy")
        || message.contains("database is locked")
        || message.contains("database table is locked")
        || message.contains("database schema is locked")
}

pub(crate) fn build_active_skill_context(
    skill_names: &[String],
    skill_registry: &Arc<RwLock<SkillRegistry>>,
) -> Option<String> {
    if skill_names.is_empty() {
        return None;
    }

    let registry = skill_registry.read();
    let name_refs: Vec<&str> = skill_names.iter().map(String::as_str).collect();
    let (found, _) = registry.get_many(&name_refs);
    if found.is_empty() {
        return None;
    }

    let context = tron_skills::injector::build_skill_context(&found);
    if context.is_empty() {
        None
    } else {
        Some(context)
    }
}

pub(crate) fn build_summarizer(
    ctx: &RpcContext,
    session_id: &str,
    working_directory: &str,
) -> Box<dyn Summarizer> {
    if let Some(manager) = ctx.subagent_manager.as_ref() {
        let spawner = tron_runtime::agent::compaction_handler::SubagentManagerSpawner {
            manager: manager.clone(),
            parent_session_id: session_id.to_owned(),
            working_directory: working_directory.to_owned(),
            system_prompt: tron_runtime::context::system_prompts::COMPACTION_SUMMARIZER_PROMPT
                .to_string(),
            model: None,
        };
        Box::new(tron_runtime::context::llm_summarizer::LlmSummarizer::new(
            spawner,
        ))
    } else {
        Box::new(KeywordSummarizer::new())
    }
}

pub(crate) fn tool_definitions(ctx: &RpcContext) -> Vec<Tool> {
    ctx.agent_deps
        .as_ref()
        .map(|deps| (deps.tool_factory)().definitions())
        .unwrap_or_default()
}
