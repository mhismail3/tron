//! Provider turn-context construction from the already resolved primitive surface.

use crate::domains::agent::context::context_manager::ContextManager;
use crate::domains::agent::r#loop::types::RunContext;
use crate::shared::protocol::messages::Context;
use tracing::debug;

pub(super) fn build_turn_context(
    context_manager: &mut ContextManager,
    run_context: &RunContext,
    server_origin: Option<&str>,
    primitive_surface: Vec<crate::shared::protocol::model_capabilities::ModelCapability>,
) -> Context {
    context_manager.set_volatile_tokens(0, 0, 0);
    context_manager.set_server_origin(server_origin.map(String::from));

    let mut context = context_manager.build_base_context();
    context.messages = context_manager.get_messages_arc();
    context.capabilities = Some(primitive_surface);
    context
        .agent_state_context
        .clone_from(&run_context.agent_state_context);
    context
        .memory_prompt_context
        .clone_from(&run_context.memory_prompt_context);
    context.server_origin = server_origin.map(String::from);

    debug!(
        capability_count = context.capabilities.as_ref().map_or(0, Vec::len),
        has_agent_state = context.agent_state_context.is_some(),
        has_memory_prompt_context = context.memory_prompt_context.is_some(),
        "primitive turn context"
    );

    context
}
