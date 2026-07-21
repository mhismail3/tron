//! Provider turn-context construction from the already resolved primitive surface.

use crate::domains::agent::context::context_manager::ContextManager;
use crate::shared::protocol::messages::Context;
use tracing::debug;

pub(super) fn build_turn_context(
    context_manager: &mut ContextManager,
    server_origin: Option<&str>,
    primitive_surface: Vec<crate::shared::protocol::model_capabilities::ModelCapability>,
) -> Context {
    context_manager.set_server_origin(server_origin.map(String::from));
    context_manager.set_capabilities(primitive_surface.clone());

    let mut context = context_manager.build_base_context();
    context.messages = context_manager.get_messages_arc();
    context.capabilities = Some(primitive_surface);
    context.server_origin = server_origin.map(String::from);

    debug!(
        capability_count = context.capabilities.as_ref().map_or(0, Vec::len),
        "primitive turn context"
    );

    context
}
