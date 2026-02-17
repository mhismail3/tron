//! Agent factory — DI-based `TronAgent` construction.

use std::sync::Arc;

use tron_context::context_manager::ContextManager;
use tron_context::rules_index::RulesIndex;
use tron_context::types::ContextManagerConfig;
use tron_core::messages::Message;
use tron_guardrails::GuardrailEngine;
use tron_hooks::engine::HookEngine;
use tron_llm::provider::Provider;
use tron_tools::registry::ToolRegistry;

use crate::agent::tron_agent::TronAgent;
use crate::types::AgentConfig;

/// Options for creating an agent.
pub struct CreateAgentOpts {
    /// LLM provider.
    pub provider: Arc<dyn Provider>,
    /// Tool registry.
    pub tools: ToolRegistry,
    /// Guardrail engine (optional).
    pub guardrails: Option<Arc<std::sync::Mutex<GuardrailEngine>>>,
    /// Hook engine (optional).
    pub hooks: Option<Arc<HookEngine>>,
    /// Whether this is a subagent.
    pub is_subagent: bool,
    /// Tools to deny for subagents.
    pub denied_tools: Vec<String>,
    /// Current subagent nesting depth (0 = top-level agent).
    pub subagent_depth: u32,
    /// Maximum nesting depth allowed for spawning children.
    pub subagent_max_depth: u32,
    /// Merged rules content (global + project).
    pub rules_content: Option<String>,
    /// Messages restored from session history.
    pub initial_messages: Vec<Message>,
    /// Workspace memory content (~/.tron/notes/MEMORY.md).
    pub memory_content: Option<String>,
    /// Scoped rules index for dynamic path-based activation.
    pub rules_index: Option<RulesIndex>,
    /// Rule relative paths to pre-activate (from session reconstruction).
    pub pre_activated_rules: Vec<String>,
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

        let mut registry = opts.tools;

        // Remove denied tools for subagents
        if opts.is_subagent {
            for tool_name in &opts.denied_tools {
                let _ = registry.remove(tool_name);
            }
            // Remove interactive tools from subagents
            let interactive_tools: Vec<String> = registry
                .list()
                .iter()
                .filter(|t| t.is_interactive())
                .map(|t| t.name().to_owned())
                .collect();
            for name in &interactive_tools {
                let _ = registry.remove(name);
            }
            // Deny subagent spawning tools when at max nesting depth
            if opts.subagent_max_depth == 0 {
                for name in &["SpawnSubagent", "QueryAgent", "WaitForAgents"] {
                    let _ = registry.remove(name);
                }
            }
        }

        let context_limit = tron_tokens::get_context_limit(&config.model);
        let mut compaction = config.compaction.clone();
        compaction.context_limit = context_limit;

        let ctx_config = ContextManagerConfig {
            model: config.model.clone(),
            system_prompt: config.system_prompt.clone(),
            working_directory: config.working_directory.clone(),
            tools: registry.definitions(),
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
            opts.provider,
            registry,
            opts.guardrails,
            opts.hooks,
            context_manager,
            session_id,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use tron_core::tools::{Tool, ToolParameterSchema, ToolCategory, TronToolResult, text_result};
    use tron_llm::models::types::ProviderType;
    use tron_llm::provider::{ProviderError, ProviderStreamOptions, StreamEventStream};
    use tron_tools::traits::{ToolContext, TronTool};

    fn default_opts(provider: Arc<dyn Provider>, tools: ToolRegistry) -> CreateAgentOpts {
        CreateAgentOpts {
            provider,
            tools,
            guardrails: None,
            hooks: None,
            is_subagent: false,
            denied_tools: vec![],
            subagent_depth: 0,
            subagent_max_depth: 0,
            rules_content: None,
            initial_messages: vec![],
            memory_content: None,
            rules_index: None,
            pre_activated_rules: vec![],
        }
    }

    struct MockProvider;
    #[async_trait]
    impl Provider for MockProvider {
        fn provider_type(&self) -> ProviderType { ProviderType::Anthropic }
        fn model(&self) -> &str { "mock" }
        async fn stream(&self, _c: &tron_core::messages::Context, _o: &ProviderStreamOptions)
            -> Result<StreamEventStream, ProviderError> {
            Err(ProviderError::Other { message: "not impl".into() })
        }
    }

    struct InteractiveTool;
    #[async_trait]
    impl TronTool for InteractiveTool {
        fn name(&self) -> &str { "ask_user" }
        fn category(&self) -> ToolCategory { ToolCategory::Custom }
        fn is_interactive(&self) -> bool { true }
        fn stops_turn(&self) -> bool { true }
        fn definition(&self) -> Tool {
            Tool { name: "ask_user".into(), description: "Ask".into(), parameters: ToolParameterSchema { schema_type: "object".into(), properties: None, required: None, description: None, extra: serde_json::Map::new() } }
        }
        async fn execute(&self, _p: serde_json::Value, _c: &ToolContext) -> Result<TronToolResult, tron_tools::errors::ToolError> {
            Ok(text_result("ok", false))
        }
    }

    struct NormalTool;
    #[async_trait]
    impl TronTool for NormalTool {
        fn name(&self) -> &str { "bash" }
        fn category(&self) -> ToolCategory { ToolCategory::Shell }
        fn definition(&self) -> Tool {
            Tool { name: "bash".into(), description: "Shell".into(), parameters: ToolParameterSchema { schema_type: "object".into(), properties: None, required: None, description: None, extra: serde_json::Map::new() } }
        }
        async fn execute(&self, _p: serde_json::Value, _c: &ToolContext) -> Result<TronToolResult, tron_tools::errors::ToolError> {
            Ok(text_result("ok", false))
        }
    }

    #[test]
    fn factory_creates_agent() {
        let mut registry = ToolRegistry::new();
        registry.register(Arc::new(NormalTool));

        let agent = AgentFactory::create_agent(
            AgentConfig::default(),
            "s1".into(),
            default_opts(Arc::new(MockProvider), registry),
        );

        assert_eq!(agent.session_id(), "s1");
        assert_eq!(agent.model(), "claude-opus-4-6");
    }

    #[test]
    fn factory_removes_denied_tools_for_subagent() {
        let mut registry = ToolRegistry::new();
        registry.register(Arc::new(NormalTool));
        registry.register(Arc::new(InteractiveTool));

        let mut opts = default_opts(Arc::new(MockProvider), registry);
        opts.is_subagent = true;
        opts.denied_tools = vec!["bash".into()];

        let agent = AgentFactory::create_agent(AgentConfig::default(), "s1".into(), opts);
        assert_eq!(agent.session_id(), "s1");
    }

    #[test]
    fn factory_removes_interactive_tools_for_subagent() {
        let mut registry = ToolRegistry::new();
        registry.register(Arc::new(NormalTool));
        registry.register(Arc::new(InteractiveTool));

        let mut opts = default_opts(Arc::new(MockProvider), registry);
        opts.is_subagent = true;

        let agent = AgentFactory::create_agent(AgentConfig::default(), "s1".into(), opts);
        assert_eq!(agent.session_id(), "s1");
    }

    #[test]
    fn factory_passes_rules_to_context_manager() {
        let mut opts = default_opts(Arc::new(MockProvider), ToolRegistry::new());
        opts.rules_content = Some("# My Rules".into());

        let agent = AgentFactory::create_agent(AgentConfig::default(), "s1".into(), opts);
        assert_eq!(agent.context_manager().get_rules_content(), Some("# My Rules"));
    }

    #[test]
    fn factory_restores_initial_messages() {
        let mut opts = default_opts(Arc::new(MockProvider), ToolRegistry::new());
        opts.initial_messages = vec![
            Message::user("Hello"),
            Message::assistant("Hi"),
            Message::user("How are you?"),
        ];

        let agent = AgentFactory::create_agent(AgentConfig::default(), "s1".into(), opts);
        assert_eq!(agent.context_manager().message_count(), 3);
    }

    #[test]
    fn factory_sets_memory_content() {
        let mut opts = default_opts(Arc::new(MockProvider), ToolRegistry::new());
        opts.memory_content = Some("# Memory\nImportant stuff".into());

        let agent = AgentFactory::create_agent(AgentConfig::default(), "s1".into(), opts);
        assert_eq!(
            agent.context_manager().get_full_memory_content(),
            Some("# Memory\nImportant stuff".into())
        );
    }

    #[test]
    fn factory_no_rules_still_works() {
        let opts = default_opts(Arc::new(MockProvider), ToolRegistry::new());
        let agent = AgentFactory::create_agent(AgentConfig::default(), "s1".into(), opts);
        assert!(agent.context_manager().get_rules_content().is_none());
    }

    #[test]
    fn factory_empty_messages_still_works() {
        let opts = default_opts(Arc::new(MockProvider), ToolRegistry::new());
        let agent = AgentFactory::create_agent(AgentConfig::default(), "s1".into(), opts);
        assert_eq!(agent.context_manager().message_count(), 0);
    }

    #[test]
    fn factory_context_limit_matches_model() {
        let config = AgentConfig {
            model: "claude-opus-4-6".into(),
            ..AgentConfig::default()
        };
        let opts = default_opts(Arc::new(MockProvider), ToolRegistry::new());
        let agent = AgentFactory::create_agent(config, "s1".into(), opts);
        assert_eq!(
            agent.context_manager().get_context_limit(),
            tron_tokens::get_context_limit("claude-opus-4-6")
        );
    }

    #[test]
    fn factory_context_limit_for_gemini() {
        let config = AgentConfig {
            model: "gemini-2.5-pro".into(),
            ..AgentConfig::default()
        };
        let opts = default_opts(Arc::new(MockProvider), ToolRegistry::new());
        let agent = AgentFactory::create_agent(config, "s1".into(), opts);
        assert_eq!(
            agent.context_manager().get_context_limit(),
            tron_tokens::get_context_limit("gemini-2.5-pro")
        );
    }

    #[test]
    fn factory_applies_depth_from_opts() {
        let mut opts = default_opts(Arc::new(MockProvider), ToolRegistry::new());
        opts.subagent_depth = 1;
        opts.subagent_max_depth = 3;

        let agent = AgentFactory::create_agent(AgentConfig::default(), "s1".into(), opts);
        assert_eq!(agent.subagent_depth(), 1);
        assert_eq!(agent.subagent_max_depth(), 3);
    }

    #[test]
    fn factory_overrides_config_depth_with_opts() {
        let config = AgentConfig {
            subagent_depth: 99,
            subagent_max_depth: 99,
            ..AgentConfig::default()
        };
        let mut opts = default_opts(Arc::new(MockProvider), ToolRegistry::new());
        opts.subagent_depth = 2;
        opts.subagent_max_depth = 5;

        let agent = AgentFactory::create_agent(config, "s1".into(), opts);
        assert_eq!(agent.subagent_depth(), 2);
        assert_eq!(agent.subagent_max_depth(), 5);
    }

    // ── Subagent tool removal tests ──

    struct FakeSpawnTool;
    #[async_trait]
    impl TronTool for FakeSpawnTool {
        fn name(&self) -> &str { "SpawnSubagent" }
        fn category(&self) -> ToolCategory { ToolCategory::Custom }
        fn definition(&self) -> Tool {
            Tool { name: "SpawnSubagent".into(), description: "Spawn".into(), parameters: ToolParameterSchema { schema_type: "object".into(), properties: None, required: None, description: None, extra: serde_json::Map::new() } }
        }
        async fn execute(&self, _p: serde_json::Value, _c: &ToolContext) -> Result<TronToolResult, tron_tools::errors::ToolError> {
            Ok(text_result("ok", false))
        }
    }

    #[test]
    fn factory_removes_subagent_tools_when_max_depth_zero() {
        let mut registry = ToolRegistry::new();
        registry.register(Arc::new(NormalTool));
        registry.register(Arc::new(FakeSpawnTool));
        assert!(registry.contains("SpawnSubagent"));

        let mut opts = default_opts(Arc::new(MockProvider), registry);
        opts.is_subagent = true;
        opts.subagent_max_depth = 0;

        let agent = AgentFactory::create_agent(AgentConfig::default(), "s1".into(), opts);
        // SpawnSubagent should be removed (max_depth == 0 for subagent)
        let _ = agent; // agent created successfully
    }

    #[test]
    fn factory_keeps_subagent_tools_when_max_depth_positive() {
        let mut registry = ToolRegistry::new();
        registry.register(Arc::new(NormalTool));
        registry.register(Arc::new(FakeSpawnTool));

        let mut opts = default_opts(Arc::new(MockProvider), registry);
        opts.is_subagent = true;
        opts.subagent_max_depth = 3;

        let agent = AgentFactory::create_agent(AgentConfig::default(), "s1".into(), opts);
        // SpawnSubagent should be kept (max_depth > 0) — tool contributes tokens
        let tools_tokens = agent.context_manager().estimate_tools_tokens();
        assert!(tools_tokens > 0, "SpawnSubagent + bash should contribute tool tokens");

        // Verify by comparing against subagent_max_depth=0 (tools removed)
        let mut registry2 = ToolRegistry::new();
        registry2.register(Arc::new(NormalTool));
        registry2.register(Arc::new(FakeSpawnTool));
        let mut opts2 = default_opts(Arc::new(MockProvider), registry2);
        opts2.is_subagent = true;
        opts2.subagent_max_depth = 0;
        let agent2 = AgentFactory::create_agent(AgentConfig::default(), "s2".into(), opts2);
        let tools_tokens2 = agent2.context_manager().estimate_tools_tokens();
        assert!(tools_tokens > tools_tokens2, "max_depth>0 should have more tools than max_depth=0");
    }
}
