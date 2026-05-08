//! Provider and agent construction for a prompt run.

use std::sync::Arc;

use tracing::warn;

use super::{AgentConfig, AgentFactory, CreateAgentOpts};

pub(super) struct BuiltPromptAgent {
    pub(super) agent: crate::runtime::agent::tron_agent::TronAgent,
    pub(super) provider_type: String,
}

#[allow(clippy::too_many_arguments)]
pub(super) async fn build_prompt_agent(
    provider_factory: Arc<dyn crate::llm::provider::ProviderFactory>,
    tool_factory: &Arc<dyn Fn() -> crate::tools::registry::ToolRegistry + Send + Sync>,
    guardrails: Option<Arc<parking_lot::Mutex<crate::runtime::guardrails::GuardrailEngine>>>,
    health_tracker: Arc<crate::llm::ProviderHealthTracker>,
    process_manager: Option<Arc<dyn crate::tools::traits::ProcessManagerOps>>,
    job_manager: Option<Arc<dyn crate::tools::traits::JobManagerOps>>,
    output_buffer_registry: Option<
        Arc<crate::runtime::orchestrator::output_buffer::OutputBufferRegistry>,
    >,
    subagent_manager: Option<Arc<crate::runtime::orchestrator::subagent_manager::SubagentManager>>,
    hooks: Option<Arc<crate::runtime::hooks::engine::HookEngine>>,
    engine_host: crate::engine::EngineHostHandle,
    broadcast: &Arc<crate::runtime::EventEmitter>,
    settings: &crate::settings::TronSettings,
    session_plan: &crate::runtime::profile_runtime::SessionExecutionPlan,
    session_id: &str,
    profile: &str,
    model: &str,
    working_dir: &str,
    server_origin: String,
    combined_rules: Option<String>,
    messages: Vec<crate::core::messages::Message>,
    memory: Option<String>,
    rules_index: Option<crate::runtime::context::rules_index::RulesIndex>,
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
            let _ = broadcast.emit(crate::core::events::TronEvent::Error {
                base: crate::core::events::BaseEvent::now(session_id),
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
    let system_prompt = if profile == crate::core::profile::NORMAL_PROFILE {
        crate::runtime::context::instruction_prompts::load_system_prompt_from_file(working_dir)
            .or_else(crate::runtime::context::instruction_prompts::load_global_system_prompt)
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
        compaction: crate::runtime::context::types::CompactionConfig {
            threshold: compactor_settings.compaction_threshold,
            preserve_recent_turns: compactor_settings.preserve_recent_count,
            context_limit,
        },
        retry: Some(crate::core::retry::RetryConfig {
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
    let tools = tool_factory();
    let agent = AgentFactory::create_agent(
        config,
        session_id.to_owned(),
        CreateAgentOpts {
            provider,
            tools,
            context_policy: session_plan.runtime_context_policy(),
            tool_policy: session_plan.tool_policy.clone(),
            guardrails,
            hooks,
            is_unattended: false,
            denied_tools: vec![],
            subagent_depth: 0,
            subagent_max_depth: settings.agent.subagent_max_depth,
            rules_content: combined_rules,
            initial_messages: messages,
            memory_content: memory,
            rules_index,
            pre_activated_rules,
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
