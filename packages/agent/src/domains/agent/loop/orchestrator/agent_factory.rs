//! Agent factory for primitive-loop `TronAgent` construction.

use std::sync::Arc;

use crate::domains::agent::context::context_manager::ContextManager;
use crate::domains::agent::context::types::ContextManagerConfig;
use crate::domains::agent::r#loop::tron_agent::{AgentDeps, TronAgent};
use crate::domains::agent::r#loop::types::AgentConfig;
use crate::domains::model::responder::ModelResponder;
use crate::shared::protocol::messages::Message;

pub struct CreateAgentOpts {
    pub responder: Arc<dyn ModelResponder>,
    pub initial_messages: Vec<Message>,
    pub initial_turn_count: u32,
    pub compaction_trigger_config: crate::domains::agent::context::types::CompactionTriggerConfig,
    pub engine_host: Option<crate::engine::EngineHostHandle>,
}

impl CreateAgentOpts {
    pub fn primitive(
        responder: Arc<dyn ModelResponder>,
        initial_messages: Vec<Message>,
        initial_turn_count: u32,
        compaction_trigger_config: crate::domains::agent::context::types::CompactionTriggerConfig,
        engine_host: Option<crate::engine::EngineHostHandle>,
    ) -> Self {
        Self {
            responder,
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
        compaction.context_limit = opts.responder.context_window();
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
                responder: opts.responder,
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
    use crate::domains::model::responder::{
        ModelResponder, ModelResponderInfo, ModelResponse, ModelResponseError, ModelResponseRequest,
    };
    use async_trait::async_trait;

    struct MockResponder;

    #[async_trait]
    impl ModelResponder for MockResponder {
        fn info(&self) -> ModelResponderInfo {
            ModelResponderInfo {
                provider_type: crate::shared::protocol::messages::Provider::Anthropic,
                provider_name: "anthropic",
                model: "mock".to_owned(),
                context_window: 200_000,
            }
        }

        async fn respond(
            &self,
            _request: ModelResponseRequest,
        ) -> Result<ModelResponse, ModelResponseError> {
            Err(ModelResponseError::other("mock"))
        }
    }

    fn default_opts(responder: Arc<dyn ModelResponder>) -> CreateAgentOpts {
        CreateAgentOpts::primitive(
            responder,
            vec![],
            0,
            crate::domains::agent::context::types::CompactionTriggerConfig::default(),
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
            default_opts(Arc::new(MockResponder)),
        );
        assert!(agent.context_manager().model_capability_names().is_empty());
    }
}
