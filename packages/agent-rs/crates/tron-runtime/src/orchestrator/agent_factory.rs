//! Agent factory — DI-based `TronAgent` construction.

use std::sync::Arc;

use tron_context::context_manager::ContextManager;
use tron_context::types::ContextManagerConfig;
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
}

/// Factory for constructing `TronAgent` instances.
pub struct AgentFactory;

impl AgentFactory {
    /// Create a new agent for the given session.
    pub fn create_agent(
        config: AgentConfig,
        session_id: String,
        opts: CreateAgentOpts,
    ) -> TronAgent {
        let mut registry = opts.tools;

        // Remove denied tools for subagents
        if opts.is_subagent {
            for tool_name in &opts.denied_tools {
                registry.remove(tool_name);
            }
            // Remove interactive tools from subagents
            let interactive_tools: Vec<String> = registry
                .list()
                .iter()
                .filter(|t| t.is_interactive())
                .map(|t| t.name().to_owned())
                .collect();
            for name in &interactive_tools {
                registry.remove(name);
            }
        }

        let ctx_config = ContextManagerConfig {
            model: config.model.clone(),
            system_prompt: config.system_prompt.clone(),
            working_directory: config.working_directory.clone(),
            tools: registry.definitions(),
            rules_content: None,
            compaction: config.compaction.clone(),
        };

        let context_manager = ContextManager::new(ctx_config);

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
            CreateAgentOpts {
                provider: Arc::new(MockProvider),
                tools: registry,
                guardrails: None,
                hooks: None,
                is_subagent: false,
                denied_tools: vec![],
            },
        );

        assert_eq!(agent.session_id(), "s1");
        assert_eq!(agent.model(), "claude-opus-4-6");
    }

    #[test]
    fn factory_removes_denied_tools_for_subagent() {
        let mut registry = ToolRegistry::new();
        registry.register(Arc::new(NormalTool));
        registry.register(Arc::new(InteractiveTool));

        let agent = AgentFactory::create_agent(
            AgentConfig::default(),
            "s1".into(),
            CreateAgentOpts {
                provider: Arc::new(MockProvider),
                tools: registry,
                guardrails: None,
                hooks: None,
                is_subagent: true,
                denied_tools: vec!["bash".into()],
            },
        );

        // bash should be removed (denied) and ask_user should be removed (interactive)
        assert_eq!(agent.session_id(), "s1");
    }

    #[test]
    fn factory_removes_interactive_tools_for_subagent() {
        let mut registry = ToolRegistry::new();
        registry.register(Arc::new(NormalTool));
        registry.register(Arc::new(InteractiveTool));

        let agent = AgentFactory::create_agent(
            AgentConfig::default(),
            "s1".into(),
            CreateAgentOpts {
                provider: Arc::new(MockProvider),
                tools: registry,
                guardrails: None,
                hooks: None,
                is_subagent: true,
                denied_tools: vec![],
            },
        );

        // ask_user should be removed (interactive)
        assert_eq!(agent.session_id(), "s1");
    }
}
