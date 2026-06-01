//! Provider and agent construction for a prompt run.

use std::sync::Arc;

use tracing::warn;

use super::{AgentConfig, AgentFactory, CreateAgentOpts};

pub(super) struct BuiltPromptAgent {
    pub(super) agent: crate::domains::agent::runner::agent::tron_agent::TronAgent,
    pub(super) provider_type: String,
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn build_prompt_agent(
    provider_factory: Arc<dyn crate::domains::model::providers::provider::ProviderFactory>,
    guardrails: Option<
        Arc<parking_lot::Mutex<crate::domains::agent::runner::guardrails::GuardrailEngine>>,
    >,
    health_tracker: Arc<crate::domains::model::providers::ProviderHealthTracker>,
    process_manager: Option<
        Arc<dyn crate::domains::capability_support::implementations::traits::ProcessManagerOps>,
    >,
    job_manager: Option<
        Arc<dyn crate::domains::capability_support::implementations::traits::JobManagerOps>,
    >,
    output_buffer_registry: Option<
        Arc<crate::domains::agent::runner::orchestrator::output_buffer::OutputBufferRegistry>,
    >,
    subagent_manager: Option<
        Arc<crate::domains::agent::runner::orchestrator::subagent_manager::SubagentManager>,
    >,
    hooks: Option<Arc<crate::domains::agent::runner::hooks::engine::HookEngine>>,
    engine_host: crate::engine::EngineHostHandle,
    broadcast: &Arc<crate::domains::agent::runner::EventEmitter>,
    settings: &crate::domains::settings::TronSettings,
    session_plan: &crate::domains::agent::runner::profile_runtime::SessionExecutionPlan,
    session_id: &str,
    profile: &str,
    model: &str,
    working_dir: &str,
    server_origin: String,
    combined_rules: Option<String>,
    messages: Vec<crate::shared::messages::Message>,
    initial_turn_count: u32,
    memory: Option<String>,
    rules_index: Option<crate::domains::agent::runner::context::rules_index::RulesIndex>,
    pre_activated_rules: Vec<String>,
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
            let _ = broadcast.emit(crate::shared::events::TronEvent::Error {
                base: crate::shared::events::BaseEvent::now(session_id),
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
    let profile_prompt = session_plan
        .prompt
        .as_ref()
        .map(|prompt| prompt.content.clone())
        .unwrap_or_default();
    let system_prompt = if profile == crate::shared::profile::NORMAL_PROFILE {
        crate::domains::agent::runner::context::instruction_prompts::load_system_prompt_from_file(
            working_dir,
        )
        .or_else(
            crate::domains::agent::runner::context::instruction_prompts::load_global_system_prompt,
        )
        .map(|loaded| loaded.content)
        .or(Some(profile_prompt))
    } else {
        Some(profile_prompt)
    };
    let config = AgentConfig {
        model: model.to_owned(),
        working_directory: Some(working_dir.to_owned()),
        server_origin: Some(server_origin),
        system_prompt,
        enable_thinking: true,
        max_turns: settings.agent.max_turns,
        compaction: crate::domains::agent::runner::context::types::CompactionConfig {
            threshold: compactor_settings.compaction_threshold,
            preserve_recent_turns: compactor_settings.preserve_recent_count,
            context_limit,
        },
        retry: Some(crate::shared::retry::RetryConfig {
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
        CreateAgentOpts {
            provider,
            context_policy: session_plan.runtime_context_policy(),
            primitive_surface_policy: session_plan.primitive_surface_policy.clone(),
            capability_execution_policy: session_plan.capability_execution_policy.clone(),
            guardrails,
            hooks,
            is_unattended: false,
            denied_primitives: vec![],
            subagent_depth: 0,
            subagent_max_depth: settings.agent.subagent_max_depth,
            rules_content: combined_rules,
            initial_messages: messages,
            memory_content: memory,
            rules_index,
            pre_activated_rules,
            initial_turn_count,
            subagent_manager,
            compaction_trigger_config: compactor_settings.into(),
            process_manager,
            job_manager,
            output_buffer_registry,
            engine_host: Some(engine_host),
        },
    );

    Ok(BuiltPromptAgent {
        agent,
        provider_type,
    })
}
