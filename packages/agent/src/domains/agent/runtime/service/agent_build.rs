//! Provider and agent construction for a prompt run.

use std::sync::Arc;

use tracing::warn;

use crate::domains::agent::runner::context::soul::AGENT_SOUL;

use super::{AgentConfig, AgentFactory, CreateAgentOpts};

pub(super) struct BuiltPromptAgent {
    pub(super) agent: crate::domains::agent::runner::agent::tron_agent::TronAgent,
    pub(super) provider_type: String,
}

pub(super) async fn build_prompt_agent(
    provider_factory: Arc<dyn crate::domains::model::providers::provider::ProviderFactory>,
    health_tracker: Arc<crate::domains::model::providers::ProviderHealthTracker>,
    engine_host: crate::engine::EngineHostHandle,
    broadcast: &Arc<crate::domains::agent::runner::EventEmitter>,
    settings: &crate::domains::settings::TronSettings,
    session_id: &str,
    model: &str,
    working_dir: &str,
    server_origin: String,
    messages: Vec<crate::shared::protocol::messages::Message>,
    initial_turn_count: u32,
    resolved_workspace_id: Option<String>,
) -> Result<BuiltPromptAgent, ()> {
    let provider = match provider_factory.create_for_model(model).await {
        Ok(provider) => provider,
        Err(error) => {
            warn!(
                model = %model,
                error = %error,
                "failed to create provider for model"
            );
            let _ = broadcast.emit(crate::shared::protocol::events::TronEvent::Error {
                base: crate::shared::protocol::events::BaseEvent::now(session_id),
                error: error.to_string(),
                context: None,
                code: None,
                provider: None,
                category: Some(error.category().to_owned()),
                suggestion: None,
                retryable: Some(error.is_retryable()),
                status_code: None,
                error_type: Some(error.category().to_owned()),
                model: Some(model.to_owned()),
            });
            return Err(());
        }
    };

    let compactor_settings = &settings.context.compactor;
    let context_limit = provider.context_window();
    let config = AgentConfig {
        model: model.to_owned(),
        working_directory: Some(working_dir.to_owned()),
        server_origin: Some(server_origin),
        system_prompt: Some(AGENT_SOUL.to_owned()),
        enable_thinking: true,
        max_turns: settings.agent.max_turns,
        compaction: crate::domains::agent::runner::context::types::CompactionConfig {
            threshold: compactor_settings.compaction_threshold,
            preserve_recent_turns: compactor_settings.preserve_recent_count,
            context_limit,
        },
        retry: Some(crate::shared::foundation::retry::RetryConfig {
            max_retries: settings.retry.max_retries,
            base_delay_ms: settings.retry.base_delay_ms,
            max_delay_ms: settings.retry.max_delay_ms,
            jitter_factor: settings.retry.jitter_factor,
        }),
        health_tracker: Some(health_tracker),
        workspace_id: resolved_workspace_id,
        ..AgentConfig::default()
    };

    let provider_type = provider.provider_type().as_str().to_string();
    let agent = AgentFactory::create_agent(
        config,
        session_id.to_owned(),
        CreateAgentOpts::primitive(
            provider,
            messages,
            initial_turn_count,
            compactor_settings.into(),
            Some(engine_host),
        ),
    );

    Ok(BuiltPromptAgent {
        agent,
        provider_type,
    })
}
