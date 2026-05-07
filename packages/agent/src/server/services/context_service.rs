use std::sync::Arc;
use std::time::Duration;

use crate::core::tools::Tool;
use crate::events::sqlite::contention::{self, BusyRetryPolicy};
use crate::runtime::context::context_manager::ContextManager;
use crate::runtime::context::summarizer::{KeywordSummarizer, Summarizer};
use crate::runtime::context::types::{CompactionConfig, ContextManagerConfig};
use crate::runtime::orchestrator::session_manager::SessionManager;
use crate::skills::registry::SkillRegistry;
use parking_lot::RwLock;

use crate::server::capabilities::errors::{self, CapabilityError};
use crate::server::services::context::ServerCapabilityContext;
use crate::server::services::session_context::SessionContextArtifacts;

pub(crate) struct PreparedSessionContext {
    pub(crate) session: crate::events::sqlite::row_types::SessionRow,
    pub(crate) artifacts: SessionContextArtifacts,
    pub(crate) context_manager: ContextManager,
}

pub(crate) fn build_context_manager_for_session(
    session_id: &str,
    session_manager: &SessionManager,
    event_store: &crate::events::EventStore,
    context_artifacts: &crate::server::services::session_context::ContextArtifactsService,
    profile_runtime: &crate::runtime::ProfileRuntime,
    tool_definitions: Vec<Tool>,
) -> Result<PreparedSessionContext, CapabilityError> {
    let session = session_manager
        .get_session(session_id)
        .map_err(|error| CapabilityError::Internal {
            message: error.to_string(),
        })?
        .ok_or_else(|| CapabilityError::NotFound {
            code: errors::SESSION_NOT_FOUND.into(),
            message: format!("Session '{session_id}' not found"),
        })?;

    let state = match session_manager.resume_session(session_id) {
        Ok(active) => active.state.clone(),
        Err(_) => crate::runtime::ReconstructedState {
            model: session.latest_model.clone(),
            working_directory: Some(session.working_directory.clone()),
            ..Default::default()
        },
    };

    let profile_name = session.profile.as_str();
    let session_plan = profile_runtime
        .plan_session(crate::runtime::SessionPlanRequest {
            requested_profile: Some(profile_name.to_string()),
            model: state.model.clone(),
            source: session.source.clone(),
            entrypoint: None,
        })
        .map_err(|error| CapabilityError::Internal {
            message: format!("invalid session profile `{profile_name}`: {error}"),
        })?;
    let settings = session_plan.settings.clone();
    let is_chat = profile_name == crate::core::profile::CHAT_PROFILE
        || session.source.as_deref() == Some("chat");
    let artifacts = if is_chat {
        SessionContextArtifacts::default()
    } else {
        context_artifacts
            .load(event_store, &session.working_directory, &settings)
            .session
    };

    let context_limit = crate::llm::model_context_window(&state.model);
    let compactor_settings = &settings.context.compactor;
    let mut context_manager = ContextManager::new(ContextManagerConfig {
        model: state.model.clone(),
        system_prompt: if profile_name == crate::core::profile::NORMAL_PROFILE {
            crate::runtime::context::instruction_prompts::load_system_prompt_from_file(
                &session.working_directory,
            )
            .or_else(crate::runtime::context::instruction_prompts::load_global_system_prompt)
            .map(|loaded| loaded.content)
            .or_else(|| {
                session_plan
                    .prompt
                    .as_ref()
                    .map(|prompt| prompt.content.clone())
            })
        } else {
            session_plan
                .prompt
                .as_ref()
                .map(|prompt| prompt.content.clone())
        },
        context_policy: session_plan.runtime_context_policy(),
        working_directory: state.working_directory.clone(),
        tools: tool_definitions,
        rules_content: artifacts.rules.merged_content.clone(),
        compaction: CompactionConfig {
            threshold: compactor_settings.compaction_threshold,
            preserve_recent_turns: compactor_settings.preserve_recent_count,
            context_limit,
        },
    });

    if !state.messages.is_empty() {
        context_manager.set_messages(state.messages.clone());
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
    mut operation: impl FnMut() -> Result<T, CapabilityError>,
) -> Result<T, CapabilityError> {
    let policy = BusyRetryPolicy {
        deadline: Duration::from_millis(750),
        backoff_step: Duration::from_millis(10),
        max_backoff: Duration::from_millis(75),
        jitter_percent: 15,
    };

    match contention::retry_on_busy(operation_name, policy, &mut operation, is_busy_rpc_error) {
        Ok(value) => Ok(value),
        Err(contention::RetryError::Inner(error)) => Err(error),
        Err(contention::RetryError::BusyTimeout(timeout)) => Err(CapabilityError::Internal {
            message: format!(
                "database busy during {operation_name} after {} attempts: {}",
                timeout.attempts, timeout.last_error
            ),
        }),
    }
}

fn is_busy_rpc_error(error: &CapabilityError) -> bool {
    let CapabilityError::Internal { message } = error else {
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

    let context = crate::skills::injector::build_skill_context(&found);
    if context.is_empty() {
        None
    } else {
        Some(context)
    }
}

pub(crate) fn build_summarizer(
    ctx: &ServerCapabilityContext,
    session_id: &str,
    working_directory: &str,
) -> Box<dyn Summarizer> {
    if let Some(manager) = ctx.subagent_manager.as_ref() {
        let process_plan = manager.plan_process("compaction").ok();
        let spawner = crate::runtime::agent::compaction_handler::SubagentManagerSpawner {
            manager: manager.clone(),
            parent_session_id: session_id.to_owned(),
            working_directory: working_directory.to_owned(),
            system_prompt: process_plan
                .and_then(|plan| plan.prompt.map(|prompt| prompt.content))
                .unwrap_or_default(),
            model: None,
        };
        Box::new(crate::runtime::context::llm_summarizer::LlmSummarizer::new(
            spawner,
        ))
    } else {
        Box::new(KeywordSummarizer::new())
    }
}

pub(crate) fn tool_definitions(ctx: &ServerCapabilityContext) -> Vec<Tool> {
    ctx.agent_deps
        .as_ref()
        .map(|deps| (deps.tool_factory)().definitions())
        .unwrap_or_default()
}
