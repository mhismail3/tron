//! Agent factory — DI-based `TronAgent` construction.

use std::sync::Arc;

use crate::context::context_manager::ContextManager;
use crate::context::rules_index::RulesIndex;
use crate::context::types::ContextManagerConfig;
use crate::guardrails::GuardrailEngine;
use crate::hooks::engine::HookEngine;
use tron_core::messages::Message;
use tron_llm::provider::Provider;
use tron_tools::registry::ToolRegistry;

use crate::agent::tron_agent::{AgentDeps, TronAgent};
use crate::types::AgentConfig;

/// Options for creating an agent.
pub struct CreateAgentOpts {
    /// LLM provider.
    pub provider: Arc<dyn Provider>,
    /// Tool registry.
    pub tools: ToolRegistry,
    /// Guardrail engine (optional).
    pub guardrails: Option<Arc<parking_lot::Mutex<GuardrailEngine>>>,
    /// Hook engine (optional).
    pub hooks: Option<Arc<HookEngine>>,
    /// Whether this agent runs without direct user oversight.
    /// When true, interactive tools are removed, spawn tools are gated
    /// by `max_depth`, and all `denied_tools` are enforced.
    /// Set to true for: subagents, cron agents, system subsessions.
    pub is_unattended: bool,
    /// Tools to remove from the registry before agent creation.
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

        // Remove denied tools (applies to both cron agent turns and subagents)
        for tool_name in &opts.denied_tools {
            let _ = registry.remove(tool_name);
        }

        // Unattended agent restrictions (subagents, cron, system subsessions)
        if opts.is_unattended {
            // Remove interactive tools (no user to interact with)
            let interactive_tools: Vec<String> = registry
                .list()
                .iter()
                .filter(|t| t.is_interactive())
                .map(|t| t.name().to_owned())
                .collect();
            for name in &interactive_tools {
                let _ = registry.remove(name);
            }
            // Remove spawn tools when at max nesting depth
            if opts.subagent_max_depth == 0 {
                for name in &["SpawnSubagent", "WaitForAgents"] {
                    let _ = registry.remove(name);
                }
            }
        }

        let context_limit = tron_llm::model_context_window(&config.model);
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
            AgentDeps {
                provider: opts.provider,
                registry,
                guardrails: opts.guardrails,
                hooks: opts.hooks,
                context_manager,
            },
            session_id,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use tron_core::tools::{Tool, ToolCategory, ToolParameterSchema, TronToolResult, text_result};
    use tron_llm::models::types::Provider as ProviderKind;
    use tron_llm::provider::{Provider, ProviderError, ProviderStreamOptions, StreamEventStream};
    use tron_tools::traits::{ToolContext, TronTool};

    fn default_opts(provider: Arc<dyn Provider>, tools: ToolRegistry) -> CreateAgentOpts {
        CreateAgentOpts {
            provider,
            tools,
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
        }
    }

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
            _c: &tron_core::messages::Context,
            _o: &ProviderStreamOptions,
        ) -> Result<StreamEventStream, ProviderError> {
            Err(ProviderError::Other {
                message: "not impl".into(),
            })
        }
    }

    struct InteractiveTool;
    #[async_trait]
    impl TronTool for InteractiveTool {
        fn name(&self) -> &'static str {
            "ask_user"
        }
        fn category(&self) -> ToolCategory {
            ToolCategory::Custom
        }
        fn is_interactive(&self) -> bool {
            true
        }
        fn stops_turn(&self) -> bool {
            true
        }
        fn definition(&self) -> Tool {
            Tool {
                name: "ask_user".into(),
                description: "Ask".into(),
                parameters: ToolParameterSchema {
                    schema_type: "object".into(),
                    properties: None,
                    required: None,
                    description: None,
                    extra: serde_json::Map::new(),
                },
            }
        }
        async fn execute(
            &self,
            _p: serde_json::Value,
            _c: &ToolContext,
        ) -> Result<TronToolResult, tron_tools::errors::ToolError> {
            Ok(text_result("ok", false))
        }
    }

    struct NormalTool;
    #[async_trait]
    impl TronTool for NormalTool {
        fn name(&self) -> &'static str {
            "bash"
        }
        fn category(&self) -> ToolCategory {
            ToolCategory::Shell
        }
        fn definition(&self) -> Tool {
            Tool {
                name: "bash".into(),
                description: "Shell".into(),
                parameters: ToolParameterSchema {
                    schema_type: "object".into(),
                    properties: None,
                    required: None,
                    description: None,
                    extra: serde_json::Map::new(),
                },
            }
        }
        async fn execute(
            &self,
            _p: serde_json::Value,
            _c: &ToolContext,
        ) -> Result<TronToolResult, tron_tools::errors::ToolError> {
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
    fn factory_removes_denied_tools_for_unattended_agent() {
        let mut registry = ToolRegistry::new();
        registry.register(Arc::new(NormalTool));
        registry.register(Arc::new(InteractiveTool));

        let mut opts = default_opts(Arc::new(MockProvider), registry);
        opts.is_unattended = true;
        opts.denied_tools = vec!["bash".into()];

        let agent = AgentFactory::create_agent(AgentConfig::default(), "s1".into(), opts);
        let names = agent.context_manager().tool_names();
        assert!(!names.contains(&"bash".into()));
        assert!(!names.contains(&"ask_user".into())); // interactive also removed
    }

    #[test]
    fn factory_removes_interactive_tools_for_unattended_agent() {
        let mut registry = ToolRegistry::new();
        registry.register(Arc::new(NormalTool));
        registry.register(Arc::new(InteractiveTool));

        let mut opts = default_opts(Arc::new(MockProvider), registry);
        opts.is_unattended = true;

        let agent = AgentFactory::create_agent(AgentConfig::default(), "s1".into(), opts);
        let names = agent.context_manager().tool_names();
        assert!(!names.contains(&"ask_user".into()));
        assert!(names.contains(&"bash".into()));
    }

    #[test]
    fn factory_passes_rules_to_context_manager() {
        let mut opts = default_opts(Arc::new(MockProvider), ToolRegistry::new());
        opts.rules_content = Some("# My Rules".into());

        let agent = AgentFactory::create_agent(AgentConfig::default(), "s1".into(), opts);
        assert_eq!(
            agent.context_manager().get_rules_content(),
            Some("# My Rules")
        );
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
            tron_llm::model_context_window("claude-opus-4-6")
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
            tron_llm::model_context_window("gemini-2.5-pro")
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

    // ── Spawn tool gating tests ──

    struct FakeSpawnTool;
    #[async_trait]
    impl TronTool for FakeSpawnTool {
        fn name(&self) -> &'static str {
            "SpawnSubagent"
        }
        fn category(&self) -> ToolCategory {
            ToolCategory::Custom
        }
        fn definition(&self) -> Tool {
            Tool {
                name: "SpawnSubagent".into(),
                description: "Spawn".into(),
                parameters: ToolParameterSchema {
                    schema_type: "object".into(),
                    properties: None,
                    required: None,
                    description: None,
                    extra: serde_json::Map::new(),
                },
            }
        }
        async fn execute(
            &self,
            _p: serde_json::Value,
            _c: &ToolContext,
        ) -> Result<TronToolResult, tron_tools::errors::ToolError> {
            Ok(text_result("ok", false))
        }
    }

    struct FakeWaitTool;
    #[async_trait]
    impl TronTool for FakeWaitTool {
        fn name(&self) -> &'static str {
            "WaitForAgents"
        }
        fn category(&self) -> ToolCategory {
            ToolCategory::Custom
        }
        fn definition(&self) -> Tool {
            Tool {
                name: "WaitForAgents".into(),
                description: "Wait".into(),
                parameters: ToolParameterSchema {
                    schema_type: "object".into(),
                    properties: None,
                    required: None,
                    description: None,
                    extra: serde_json::Map::new(),
                },
            }
        }
        async fn execute(
            &self,
            _p: serde_json::Value,
            _c: &ToolContext,
        ) -> Result<TronToolResult, tron_tools::errors::ToolError> {
            Ok(text_result("ok", false))
        }
    }

    /// Second interactive tool for multi-interactive tests.
    struct InteractiveTool2;
    #[async_trait]
    impl TronTool for InteractiveTool2 {
        fn name(&self) -> &'static str {
            "open_url"
        }
        fn category(&self) -> ToolCategory {
            ToolCategory::Custom
        }
        fn is_interactive(&self) -> bool {
            true
        }
        fn definition(&self) -> Tool {
            Tool {
                name: "open_url".into(),
                description: "Open".into(),
                parameters: ToolParameterSchema {
                    schema_type: "object".into(),
                    properties: None,
                    required: None,
                    description: None,
                    extra: serde_json::Map::new(),
                },
            }
        }
        async fn execute(
            &self,
            _p: serde_json::Value,
            _c: &ToolContext,
        ) -> Result<TronToolResult, tron_tools::errors::ToolError> {
            Ok(text_result("ok", false))
        }
    }

    /// Helper: build a registry with all fake tools registered.
    fn full_registry() -> ToolRegistry {
        let mut r = ToolRegistry::new();
        r.register(Arc::new(NormalTool));
        r.register(Arc::new(InteractiveTool));
        r.register(Arc::new(InteractiveTool2));
        r.register(Arc::new(FakeSpawnTool));
        r.register(Arc::new(FakeWaitTool));
        r
    }

    #[test]
    fn factory_removes_spawn_tools_when_unattended_max_depth_zero() {
        let mut registry = ToolRegistry::new();
        registry.register(Arc::new(NormalTool));
        registry.register(Arc::new(FakeSpawnTool));
        registry.register(Arc::new(FakeWaitTool));

        let mut opts = default_opts(Arc::new(MockProvider), registry);
        opts.is_unattended = true;
        opts.subagent_max_depth = 0;

        let agent = AgentFactory::create_agent(AgentConfig::default(), "s1".into(), opts);
        let names = agent.context_manager().tool_names();
        assert!(!names.contains(&"SpawnSubagent".into()));
        assert!(!names.contains(&"WaitForAgents".into()));
        assert!(names.contains(&"bash".into()));
    }

    #[test]
    fn factory_keeps_spawn_tools_when_unattended_max_depth_positive() {
        let mut registry = ToolRegistry::new();
        registry.register(Arc::new(NormalTool));
        registry.register(Arc::new(FakeSpawnTool));
        registry.register(Arc::new(FakeWaitTool));

        let mut opts = default_opts(Arc::new(MockProvider), registry);
        opts.is_unattended = true;
        opts.subagent_max_depth = 3;

        let agent = AgentFactory::create_agent(AgentConfig::default(), "s1".into(), opts);
        let names = agent.context_manager().tool_names();
        assert!(names.contains(&"SpawnSubagent".into()));
        assert!(names.contains(&"WaitForAgents".into()));
    }

    // ── Attended (user) agent tests ──

    #[test]
    fn factory_attended_agent_keeps_interactive_tools() {
        let mut opts = default_opts(Arc::new(MockProvider), full_registry());
        opts.is_unattended = false;

        let agent = AgentFactory::create_agent(AgentConfig::default(), "s1".into(), opts);
        let names = agent.context_manager().tool_names();
        assert!(names.contains(&"ask_user".into()));
        assert!(names.contains(&"open_url".into()));
    }

    #[test]
    fn factory_attended_agent_keeps_spawn_tools_at_max_depth_zero() {
        let mut opts = default_opts(Arc::new(MockProvider), full_registry());
        opts.is_unattended = false;
        opts.subagent_max_depth = 0;

        let agent = AgentFactory::create_agent(AgentConfig::default(), "s1".into(), opts);
        let names = agent.context_manager().tool_names();
        assert!(names.contains(&"SpawnSubagent".into()));
        assert!(names.contains(&"WaitForAgents".into()));
    }

    #[test]
    fn factory_attended_agent_applies_denied_tools() {
        let mut opts = default_opts(Arc::new(MockProvider), full_registry());
        opts.is_unattended = false;
        opts.denied_tools = vec!["bash".into()];

        let agent = AgentFactory::create_agent(AgentConfig::default(), "s1".into(), opts);
        let names = agent.context_manager().tool_names();
        assert!(!names.contains(&"bash".into()));
        // Other tools still present
        assert!(names.contains(&"ask_user".into()));
        assert!(names.contains(&"SpawnSubagent".into()));
    }

    // ── Comprehensive unattended agent tests ──

    #[test]
    fn factory_unattended_removes_all_interactive_tools() {
        let mut opts = default_opts(Arc::new(MockProvider), full_registry());
        opts.is_unattended = true;
        opts.subagent_max_depth = 3; // keep spawn tools to isolate interactive removal

        let agent = AgentFactory::create_agent(AgentConfig::default(), "s1".into(), opts);
        let names = agent.context_manager().tool_names();
        assert!(!names.contains(&"ask_user".into()));
        assert!(!names.contains(&"open_url".into()));
        assert!(names.contains(&"bash".into()));
        assert!(names.contains(&"SpawnSubagent".into()));
    }

    #[test]
    fn factory_unattended_with_denied_and_interactive_overlap() {
        let mut opts = default_opts(Arc::new(MockProvider), full_registry());
        opts.is_unattended = true;
        opts.denied_tools = vec!["ask_user".into()]; // also interactive
        opts.subagent_max_depth = 3;

        // Should not panic from double-remove
        let agent = AgentFactory::create_agent(AgentConfig::default(), "s1".into(), opts);
        let names = agent.context_manager().tool_names();
        assert!(!names.contains(&"ask_user".into()));
        assert!(!names.contains(&"open_url".into())); // still removed as interactive
    }

    #[test]
    fn factory_unattended_with_empty_denied_tools() {
        let mut opts = default_opts(Arc::new(MockProvider), full_registry());
        opts.is_unattended = true;
        opts.denied_tools = vec![];
        opts.subagent_max_depth = 0;

        let agent = AgentFactory::create_agent(AgentConfig::default(), "s1".into(), opts);
        let names = agent.context_manager().tool_names();
        // Interactive tools removed
        assert!(!names.contains(&"ask_user".into()));
        assert!(!names.contains(&"open_url".into()));
        // Spawn tools removed at depth 0
        assert!(!names.contains(&"SpawnSubagent".into()));
        assert!(!names.contains(&"WaitForAgents".into()));
        // Core tools preserved
        assert!(names.contains(&"bash".into()));
    }

    #[test]
    fn factory_unattended_preserves_non_interactive_tools() {
        let mut opts = default_opts(Arc::new(MockProvider), full_registry());
        opts.is_unattended = true;
        opts.subagent_max_depth = 3;

        let agent = AgentFactory::create_agent(AgentConfig::default(), "s1".into(), opts);
        let names = agent.context_manager().tool_names();
        assert!(names.contains(&"bash".into()));
        assert!(names.contains(&"SpawnSubagent".into()));
        assert!(names.contains(&"WaitForAgents".into()));
    }

    #[test]
    fn factory_denied_tools_applied_before_interactive_removal() {
        // Verify ordering independence: denied removal + interactive removal are separate passes
        let mut opts = default_opts(Arc::new(MockProvider), full_registry());
        opts.is_unattended = true;
        opts.denied_tools = vec!["bash".into(), "open_url".into()];
        opts.subagent_max_depth = 3;

        let agent = AgentFactory::create_agent(AgentConfig::default(), "s1".into(), opts);
        let names = agent.context_manager().tool_names();
        assert!(!names.contains(&"bash".into())); // denied
        assert!(!names.contains(&"open_url".into())); // denied + interactive
        assert!(!names.contains(&"ask_user".into())); // interactive
        assert!(names.contains(&"SpawnSubagent".into())); // kept (depth > 0)
    }

    // ── Cron scenario test ──

    #[test]
    fn factory_cron_agent_scenario() {
        // Simulate cron: is_unattended=true, denied_tools from user restrictions, max_depth=0
        let mut opts = default_opts(Arc::new(MockProvider), full_registry());
        opts.is_unattended = true;
        opts.denied_tools = vec!["WaitForAgents".into()]; // simulate user restriction
        opts.subagent_max_depth = 0;

        let agent = AgentFactory::create_agent(AgentConfig::default(), "s1".into(), opts);
        let names = agent.context_manager().tool_names();

        // All interactive tools removed (the key fix — cron was missing these)
        assert!(!names.contains(&"ask_user".into()));
        assert!(!names.contains(&"open_url".into()));

        // Spawn tools removed at depth 0
        assert!(!names.contains(&"SpawnSubagent".into()));
        assert!(!names.contains(&"WaitForAgents".into()));

        // Core tools preserved
        assert!(names.contains(&"bash".into()));
    }
}
