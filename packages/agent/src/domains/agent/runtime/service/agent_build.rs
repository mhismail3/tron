//! Provider and agent construction for a prompt run.

use std::sync::Arc;

use tracing::warn;

use crate::domains::agent::context::seed::AGENT_SEED;
use crate::domains::agent::r#loop::orchestrator::invocation_abort_registry::InvocationAbortRegistry;
use crate::shared::server::failure::FailureEnvelope;

use super::{AgentConfig, AgentFactory, CreateAgentOpts};

pub(super) struct BuiltPromptAgent {
    pub(super) agent: crate::domains::agent::r#loop::tron_agent::TronAgent,
    pub(super) provider_type: String,
}

pub(super) async fn build_prompt_agent(
    responder_factory: Arc<dyn crate::domains::model::responder::ModelResponderFactory>,
    engine_host: crate::engine::EngineHostHandle,
    invocation_abort_registry: Arc<InvocationAbortRegistry>,
    settings: &crate::domains::settings::TronSettings,
    session_id: &str,
    model: &str,
    working_dir: &str,
    server_origin: String,
    messages: Vec<crate::shared::protocol::messages::Message>,
    initial_turn_offset: u32,
    resolved_workspace_id: Option<String>,
) -> Result<BuiltPromptAgent, FailureEnvelope> {
    let responder = match responder_factory
        .create_for_model(model, &settings.api)
        .await
    {
        Ok(responder) => responder,
        Err(error) => {
            warn!(
                model = %model,
                error = %error,
                "failed to create provider for model"
            );
            let mut failure = error.failure().clone();
            if failure.model.is_none() {
                failure.model = Some(model.to_owned());
            }
            return Err(failure);
        }
    };

    let compactor_settings = &settings.context.compactor;
    let responder_info = responder.info();
    let context_limit = responder_info.context_window;
    let config = AgentConfig {
        model: model.to_owned(),
        working_directory: Some(working_dir.to_owned()),
        server_origin: Some(server_origin),
        system_prompt: Some(AGENT_SEED.to_owned()),
        enable_thinking: true,
        max_turns: settings.agent.max_turns,
        compaction: crate::domains::agent::context::types::CompactionConfig {
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
        workspace_id: resolved_workspace_id,
        ..AgentConfig::default()
    };

    let provider_type = responder_info.provider_name.to_string();
    let agent = AgentFactory::create_agent(
        config,
        session_id.to_owned(),
        CreateAgentOpts::primitive(
            responder,
            messages,
            initial_turn_offset,
            compactor_settings.into(),
            invocation_abort_registry,
            engine_host,
        ),
    );

    Ok(BuiltPromptAgent {
        agent,
        provider_type,
    })
}
