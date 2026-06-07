use std::time::Duration;

use crate::domains::agent::runner::context::context_manager::ContextManager;
use crate::domains::agent::runner::context::summarizer::{KeywordSummarizer, Summarizer};
use crate::domains::agent::runner::context::types::{CompactionConfig, ContextManagerConfig};
use crate::domains::agent::runner::orchestrator::session_manager::SessionManager;
use crate::domains::session::event_store::sqlite::contention::{self, BusyRetryPolicy};
use crate::shared::model_capabilities::ModelCapability;

use crate::domains::context::Deps;
use crate::shared::server::errors::{self, CapabilityError};

pub(crate) struct PreparedSessionContext {
    pub(crate) session: crate::domains::session::event_store::sqlite::row_types::SessionRow,
    pub(crate) context_manager: ContextManager,
}

pub(crate) fn build_context_manager_for_session(
    session_id: &str,
    session_manager: &SessionManager,
    profile_runtime: &crate::domains::agent::runner::ProfileRuntime,
    model_capability_definitions: Vec<ModelCapability>,
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
        Err(_) => crate::domains::agent::runner::ReconstructedState {
            model: session.latest_model.clone(),
            working_directory: Some(session.working_directory.clone()),
            ..Default::default()
        },
    };

    let session_plan = profile_runtime
        .plan_session(crate::domains::agent::runner::SessionPlanRequest {
            requested_profile: None,
            model: state.model.clone(),
            source: None,
            entrypoint: None,
        })
        .map_err(|error| CapabilityError::Internal {
            message: format!("invalid active runtime profile: {error}"),
        })?;
    let profile_name = session_plan.profile_name.as_str();
    let settings = session_plan.settings.clone();
    let context_limit = crate::domains::model::providers::model_context_window(&state.model);
    let compactor_settings = &settings.context.compactor;
    let mut context_manager = ContextManager::new(ContextManagerConfig {
        model: state.model.clone(),
        system_prompt: if profile_name == crate::shared::profile::NORMAL_PROFILE {
            crate::domains::agent::runner::context::instruction_prompts::load_system_prompt_from_file(
                &session.working_directory,
            )
            .or_else(crate::domains::agent::runner::context::instruction_prompts::load_global_system_prompt)
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
        working_directory: state.working_directory.clone(),
        capabilities: model_capability_definitions,
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

    match contention::retry_on_busy(
        operation_name,
        policy,
        &mut operation,
        is_busy_capability_error,
    ) {
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

fn is_busy_capability_error(error: &CapabilityError) -> bool {
    let CapabilityError::Internal { message } = error else {
        return false;
    };

    let message = message.to_ascii_lowercase();
    message.contains("database busy")
        || message.contains("database is locked")
        || message.contains("database table is locked")
        || message.contains("database schema is locked")
}

pub(crate) fn build_summarizer(
    _deps: &Deps,
    _session_id: &str,
    _working_directory: &str,
) -> Box<dyn Summarizer> {
    Box::new(KeywordSummarizer::new())
}

pub(crate) async fn model_capability_definitions(
    deps: &Deps,
    session_id: &str,
) -> Vec<ModelCapability> {
    match crate::domains::capability_support::implementations::primitive_surface::list_model_capabilities(
        &deps.engine_host,
        session_id,
        None,
    )
    .await
    {
        Ok(capabilities) => capabilities,
        Err(error) => {
            tracing::warn!(
                session_id,
                error = %error,
                "failed to read live capability catalog for context assembly"
            );
            Vec::new()
        }
    }
}
