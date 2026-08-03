//! Agent factory for primitive-loop `TronAgent` construction with required runtime owners.

use std::sync::Arc;

use crate::domains::agent::context::context_manager::ContextManager;
use crate::domains::agent::context::message_store::MessageAuditSource;
use crate::domains::agent::context::types::ContextManagerConfig;
use crate::domains::agent::r#loop::orchestrator::invocation_abort_registry::InvocationAbortRegistry;
use crate::domains::agent::r#loop::tron_agent::{AgentDeps, TronAgent};
use crate::domains::agent::r#loop::types::AgentConfig;
use crate::domains::model::responder::ModelResponder;
use crate::shared::protocol::messages::Message;

pub struct CreateAgentOpts {
    pub responder: Arc<dyn ModelResponder>,
    pub initial_messages: Vec<Message>,
    pub initial_message_sources: Vec<MessageAuditSource>,
    pub initial_turn_offset: u32,
    pub compaction_trigger_config: crate::domains::agent::context::types::CompactionTriggerConfig,
    pub invocation_abort_registry: Arc<InvocationAbortRegistry>,
    pub engine_host: crate::engine::EngineHostHandle,
}

impl CreateAgentOpts {
    pub fn primitive(
        responder: Arc<dyn ModelResponder>,
        initial_messages: Vec<Message>,
        initial_message_sources: Vec<MessageAuditSource>,
        initial_turn_offset: u32,
        compaction_trigger_config: crate::domains::agent::context::types::CompactionTriggerConfig,
        invocation_abort_registry: Arc<InvocationAbortRegistry>,
        engine_host: crate::engine::EngineHostHandle,
    ) -> Self {
        Self {
            responder,
            initial_messages,
            initial_message_sources,
            initial_turn_offset,
            compaction_trigger_config,
            invocation_abort_registry,
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
        let initial_turn_offset = opts.initial_turn_offset;
        let mut compaction = config.compaction.clone();
        compaction.context_limit = opts.responder.context_window();
        let mut context_manager = ContextManager::new(ContextManagerConfig {
            system_prompt: config.system_prompt.clone(),
            working_directory: config.working_directory.clone(),
            compaction,
        });
        if !opts.initial_messages.is_empty() {
            context_manager
                .set_messages_with_sources(opts.initial_messages, opts.initial_message_sources);
        }

        let mut agent = TronAgent::new(
            config,
            AgentDeps {
                responder: opts.responder,
                context_manager,
                compaction_trigger_config: opts.compaction_trigger_config,
                invocation_abort_registry: opts.invocation_abort_registry,
                engine_host: opts.engine_host,
            },
            session_id,
        );
        agent.set_turn_offset(initial_turn_offset);
        agent
    }
}
