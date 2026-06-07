//! Turn context construction and primitive capability resolution.

use crate::domains::agent::runner::agent::primitive_surface::{self, ResolvedPrimitiveSurface};
use crate::domains::agent::runner::context::context_manager::ContextManager;
use crate::domains::agent::runner::types::RunContext;
use crate::shared::messages::Context;
use tracing::debug;

pub(super) fn build_turn_context(
    context_manager: &mut ContextManager,
    run_context: &RunContext,
    server_origin: Option<&str>,
    primitive_surface: Vec<crate::shared::model_capabilities::ModelCapability>,
) -> Context {
    context_manager.set_volatile_tokens(0, 0, 0);
    context_manager.set_server_origin(server_origin.map(String::from));

    let mut context = context_manager.build_base_context();
    context.messages = context_manager.get_messages_arc();
    context.capabilities = Some(primitive_surface);
    context
        .agent_state_context
        .clone_from(&run_context.agent_state_context);
    context.server_origin = server_origin.map(String::from);

    debug!(
        capability_count = context.capabilities.as_ref().map_or(0, Vec::len),
        has_agent_state = context.agent_state_context.is_some(),
        "primitive turn context"
    );

    context
}

pub(super) async fn resolve_provider_primitive_surface(
    engine_host: Option<&crate::engine::EngineHostHandle>,
    session_id: &str,
    workspace_id: Option<&str>,
) -> Result<ResolvedPrimitiveSurface, String> {
    if let Some(host) = engine_host {
        return primitive_surface::resolve_provider_primitive_surface(
            host,
            session_id,
            workspace_id,
        )
        .await;
    }

    #[cfg(test)]
    {
        let _ = (session_id, workspace_id);
        return Ok(ResolvedPrimitiveSurface {
            capabilities: Vec::new(),
            targets_by_name: Default::default(),
            turn_stopping_capabilities: Default::default(),
        });
    }

    #[cfg(not(test))]
    {
        let _ = (session_id, workspace_id);
        Err("engine host is required for provider capability schema resolution".to_owned())
    }
}
