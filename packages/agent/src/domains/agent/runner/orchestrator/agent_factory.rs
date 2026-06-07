//! Agent factory for primitive-loop `TronAgent` construction.

use std::sync::Arc;

use crate::domains::agent::runner::agent::tron_agent::{AgentDeps, TronAgent};
use crate::domains::agent::runner::context::context_manager::ContextManager;
use crate::domains::agent::runner::context::types::ContextManagerConfig;
use crate::domains::agent::runner::types::AgentConfig;
use crate::domains::model::providers::provider::Provider;
use crate::shared::messages::Message;

pub struct CreateAgentOpts {
    pub provider: Arc<dyn Provider>,
    pub initial_messages: Vec<Message>,
    pub initial_turn_count: u32,
    pub compaction_trigger_config:
        crate::domains::agent::runner::context::types::CompactionTriggerConfig,
    pub engine_host: Option<crate::engine::EngineHostHandle>,
}

impl CreateAgentOpts {
    pub fn primitive(
        provider: Arc<dyn Provider>,
        initial_messages: Vec<Message>,
        initial_turn_count: u32,
        compaction_trigger_config: crate::domains::agent::runner::context::types::CompactionTriggerConfig,
        engine_host: Option<crate::engine::EngineHostHandle>,
    ) -> Self {
        Self {
            provider,
            initial_messages,
            initial_turn_count,
            compaction_trigger_config,
            engine_host,
        }
    }
}

pub struct AgentFactory;

impl AgentFactory {
    pub fn create_agent(
        config: AgentConfig,
        session_id: String,
        opts: CreateAgentOpts,
    ) -> TronAgent {
        let initial_turn_count = opts.initial_turn_count;
        let mut compaction = config.compaction.clone();
        compaction.context_limit = opts.provider.context_window();
        let mut context_manager = ContextManager::new(ContextManagerConfig {
            model: config.model.clone(),
            system_prompt: config.system_prompt.clone(),
            working_directory: config.working_directory.clone(),
            capabilities: Vec::new(),
            compaction,
        });
        if !opts.initial_messages.is_empty() {
            context_manager.set_messages(opts.initial_messages);
        }

        let mut agent = TronAgent::new(
            config,
            AgentDeps {
                provider: opts.provider,
                context_manager,
                compaction_trigger_config: opts.compaction_trigger_config,
                engine_host: opts.engine_host,
            },
            session_id,
        );
        agent.set_completed_turn_offset(initial_turn_count);
        agent
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::model::providers::models::types::Provider as ProviderKind;
    use crate::domains::model::providers::provider::{
        Provider, ProviderError, ProviderStreamOptions, StreamEventStream,
    };
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
            _context: &crate::shared::messages::Context,
            _options: &ProviderStreamOptions,
        ) -> Result<StreamEventStream, ProviderError> {
            Err(ProviderError::Other {
                message: "mock".into(),
            })
        }
    }

    fn default_opts(provider: Arc<dyn Provider>) -> CreateAgentOpts {
        CreateAgentOpts::primitive(
            provider,
            vec![],
            0,
            crate::domains::agent::runner::context::types::CompactionTriggerConfig::default(),
            None,
        )
    }

    #[test]
    fn create_agent_initial_context_has_no_frozen_capability_snapshot() {
        let agent = AgentFactory::create_agent(
            AgentConfig {
                system_prompt: Some("soul".into()),
                ..AgentConfig::default()
            },
            "s1".into(),
            default_opts(Arc::new(MockProvider)),
        );
        assert!(agent.context_manager().model_capability_names().is_empty());
    }
}
