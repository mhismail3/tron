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
    message_sources: Vec<crate::domains::agent::context::message_store::MessageAuditSource>,
    initial_turn_offset: u32,
    resolved_workspace_id: Option<String>,
    worker_max_agent_turns: Option<u32>,
    assignment_max_turns: Option<u32>,
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
        max_turns: resolved_max_turns(
            settings.agent.max_turns,
            worker_max_agent_turns,
            assignment_max_turns,
        ),
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
            message_sources,
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

fn resolved_max_turns(
    global_limit: u32,
    worker_limit: Option<u32>,
    assignment_limit: Option<u32>,
) -> u32 {
    [worker_limit, assignment_limit]
        .into_iter()
        .flatten()
        .fold(global_limit, u32::min)
}

#[cfg(test)]
mod tests {
    use super::resolved_max_turns;

    #[test]
    fn worker_turn_limit_can_only_tighten_the_global_ceiling() {
        assert_eq!(resolved_max_turns(250, Some(7), None), 7);
        assert_eq!(resolved_max_turns(10, Some(20), Some(8)), 8);
        assert_eq!(resolved_max_turns(250, None, Some(32)), 32);
        assert_eq!(resolved_max_turns(250, None, None), 250);
    }
}
