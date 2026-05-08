//! Agent factory — DI-based `TronAgent` construction.

use std::sync::Arc;

use crate::core::messages::Message;
use crate::llm::provider::Provider;
use crate::runtime::context::context_manager::ContextManager;
use crate::runtime::context::local_policy::ContextPolicy;
use crate::runtime::context::rules_index::RulesIndex;
use crate::runtime::context::types::ContextManagerConfig;
use crate::runtime::guardrails::GuardrailEngine;
use crate::runtime::hooks::engine::HookEngine;
use crate::tools::capability_surface::ToolSurfacePolicy;

use crate::runtime::agent::tron_agent::{AgentDeps, TronAgent};
use crate::runtime::types::AgentConfig;

/// Options for creating an agent.
pub struct CreateAgentOpts {
    /// LLM provider.
    pub provider: Arc<dyn Provider>,
    /// Profile-resolved context policy for this agent.
    pub context_policy: ContextPolicy,
    /// Profile-resolved tool policy for this agent.
    pub tool_policy: crate::core::profile::ToolPolicySpec,
    /// Guardrail engine (optional).
    pub guardrails: Option<Arc<parking_lot::Mutex<GuardrailEngine>>>,
    /// Hook engine (optional).
    pub hooks: Option<Arc<HookEngine>>,
    /// Whether this agent runs without direct user oversight.
    /// When true, interactive tools are removed, spawn tools are gated
    /// by `max_depth`, and all `denied_tools` are enforced.
    /// Set to true for: subagents, cron agents, system subsessions.
    pub is_unattended: bool,
    /// Model tool names denied for this agent.
    pub denied_tools: Vec<String>,
    /// Current subagent nesting depth (0 = top-level agent).
    pub subagent_depth: u32,
    /// Maximum nesting depth allowed for spawning children.
    pub subagent_max_depth: u32,
    /// Merged rules content (global + project).
    pub rules_content: Option<String>,
    /// Messages restored from session history.
    pub initial_messages: Vec<Message>,
    /// Workspace memory content.
    pub memory_content: Option<String>,
    /// Scoped rules index for dynamic path-based activation.
    pub rules_index: Option<RulesIndex>,
    /// Rule relative paths to pre-activate (from session reconstruction).
    pub pre_activated_rules: Vec<String>,
    /// Optional subagent manager for LLM-backed compaction summarization.
    pub subagent_manager:
        Option<std::sync::Arc<crate::runtime::orchestrator::subagent_manager::SubagentManager>>,
    /// Compaction trigger configuration (from settings).
    pub compaction_trigger_config: crate::runtime::context::types::CompactionTriggerConfig,
    /// Optional process manager for background process execution.
    pub process_manager: Option<Arc<dyn crate::tools::traits::ProcessManagerOps>>,
    /// Optional unified job manager for process + subagent lifecycle.
    pub job_manager: Option<Arc<dyn crate::tools::traits::JobManagerOps>>,
    /// Optional output buffer registry for process output streaming.
    pub output_buffer_registry:
        Option<Arc<crate::runtime::orchestrator::output_buffer::OutputBufferRegistry>>,
    /// Optional engine host for routing actual tool execution through
    /// canonical `tool::*` functions.
    pub engine_host: Option<crate::engine::EngineHostHandle>,
}

/// Factory for constructing `TronAgent` instances.
pub struct AgentFactory;

impl AgentFactory {
    /// Create a new agent for the given session.
    pub fn create_agent(
        mut config: AgentConfig,
        session_id: String,
        opts: CreateAgentOpts,
    ) -> TronAgent {
        config.subagent_depth = opts.subagent_depth;
        config.subagent_max_depth = opts.subagent_max_depth;

        let tool_surface_policy = ToolSurfacePolicy::from_profile(
            &opts.tool_policy,
            &opts.denied_tools,
            opts.is_unattended,
            opts.subagent_max_depth,
        );

        let context_limit = opts.provider.context_window();
        let mut compaction = config.compaction.clone();
        compaction.context_limit = context_limit;

        let ctx_config = ContextManagerConfig {
            model: config.model.clone(),
            system_prompt: config.system_prompt.clone(),
            context_policy: opts.context_policy,
            working_directory: config.working_directory.clone(),
            tools: Vec::new(),
            rules_content: opts.rules_content,
            compaction,
        };

        let mut context_manager = ContextManager::new(ctx_config);

        if !opts.initial_messages.is_empty() {
            context_manager.set_messages(opts.initial_messages);
        }

        if opts.memory_content.is_some() {
            context_manager.set_memory_content(opts.memory_content);
        }

        // Wire scoped-rules index for dynamic activation
        if let Some(index) = opts.rules_index {
            context_manager.set_rules_index(index);
        }
        for path in &opts.pre_activated_rules {
            let _ = context_manager.pre_activate_rule(path);
        }
        if !opts.pre_activated_rules.is_empty() {
            context_manager.finalize_rule_activations();
        }

        TronAgent::new(
            config,
            AgentDeps {
                provider: opts.provider,
                tool_surface_policy,
                guardrails: opts.guardrails,
                hooks: opts.hooks,
                context_manager,
                subagent_manager: opts.subagent_manager,
                compaction_trigger_config: opts.compaction_trigger_config,
                process_manager: opts.process_manager,
                job_manager: opts.job_manager,
                output_buffer_registry: opts.output_buffer_registry,
                engine_host: opts.engine_host,
            },
            session_id,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::llm::models::types::Provider as ProviderKind;
    use crate::llm::provider::{Provider, ProviderError, ProviderStreamOptions, StreamEventStream};
    use async_trait::async_trait;

    struct MockProvider;
    #[async_trait]
    impl Provider for MockProvider {
        fn provider_type(&self) -> ProviderKind {
            ProviderKind::Anthropic
        }

        fn model(&self) -> &'static str {
            "mock"
        }

        async fn stream(
            &self,
            _c: &crate::core::messages::Context,
            _o: &ProviderStreamOptions,
        ) -> Result<StreamEventStream, ProviderError> {
            Err(ProviderError::Other {
                message: "mock".into(),
            })
        }
    }

    fn default_resolved_profile() -> Arc<crate::core::profile::ResolvedProfile> {
        let tempdir = tempfile::tempdir().expect("profile tempdir");
        let home = tempdir.path().join(".tron");
        crate::core::constitution::ensure_tron_home_at(&home).expect("seed profile home");
        let profile =
            crate::core::profile::resolve_profile_at(&home, crate::core::profile::NORMAL_PROFILE)
                .expect("normal profile");
        std::mem::forget(tempdir);
        Arc::new(profile)
    }

    fn default_opts(provider: Arc<dyn Provider>) -> CreateAgentOpts {
        let profile = default_resolved_profile();
        let spec = &profile.spec;
        CreateAgentOpts {
            provider,
            context_policy:
                crate::runtime::context::local_policy::ContextPolicy::from_provider_with_spec(
                    ProviderKind::Anthropic,
                    spec,
                ),
            tool_policy: spec.tool_policies["default"].clone(),
            guardrails: None,
            hooks: None,
            is_unattended: false,
            denied_tools: vec![],
            subagent_depth: 0,
            subagent_max_depth: 0,
            rules_content: None,
            initial_messages: vec![],
            memory_content: None,
            rules_index: None,
            pre_activated_rules: vec![],
            subagent_manager: None,
            compaction_trigger_config:
                crate::runtime::context::types::CompactionTriggerConfig::default(),
            process_manager: None,
            job_manager: None,
            output_buffer_registry: None,
            engine_host: None,
        }
    }

    fn default_config() -> AgentConfig {
        let profile = default_resolved_profile();
        let spec = &profile.spec;
        AgentConfig {
            system_prompt: spec
                .entrypoint_prompts
                .get("main")
                .map(|prompt| prompt.content.clone()),
            ..AgentConfig::default()
        }
    }

    #[test]
    fn create_agent_stores_live_catalog_tool_policy() {
        let mut opts = default_opts(Arc::new(MockProvider));
        opts.denied_tools = vec!["Bash".into()];
        let agent = AgentFactory::create_agent(default_config(), "s1".into(), opts);
        assert!(agent.context_manager().tool_names().is_empty());
    }

    #[test]
    fn create_agent_initial_context_has_no_frozen_tool_snapshot() {
        let agent = AgentFactory::create_agent(
            default_config(),
            "s1".into(),
            default_opts(Arc::new(MockProvider)),
        );
        assert!(agent.context_manager().tool_names().is_empty());
    }
}
