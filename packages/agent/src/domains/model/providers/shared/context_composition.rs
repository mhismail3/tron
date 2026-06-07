//! Provider-independent composition for the primitive agent context.

use crate::shared::constitution::{
    ContextBlock, ContextCacheClass, ContextSensitivity, ProviderSurface, TronHome,
    context_block_for_text,
};
use crate::shared::messages::Context;

/// Compose provider prompt text from the primitive context.
pub fn compose_context_parts(context: &Context) -> Vec<String> {
    compose_context_blocks(context)
        .into_iter()
        .map(|block| block.text)
        .collect()
}

/// Compile primitive prompt blocks into the Constitution audit shape.
pub fn compose_context_blocks(context: &Context) -> Vec<ContextBlock> {
    let mut blocks = Vec::new();

    if let Some(ref soul) = context.system_prompt
        && !soul.is_empty()
    {
        blocks.push(context_block_for_text(
            "agent.soul",
            "Agent Soul",
            TronHome::Profiles,
            soul.clone(),
            ContextCacheClass::Foundation,
            10,
        ));
    }

    if let Some(ref state) = context.agent_state_context
        && !state.is_empty()
    {
        blocks.push(context_block_for_text(
            "agent.state",
            "Agent State",
            TronHome::Workspace,
            state.clone(),
            ContextCacheClass::Turn,
            20,
        ));
    }

    if let Some(ref origin) = context.server_origin
        && !origin.is_empty()
    {
        blocks.push(context_block_for_text(
            "environment.server",
            "Server Origin",
            TronHome::Internal,
            format!("Server: {origin}"),
            ContextCacheClass::Session,
            30,
        ));
    }

    if let Some(ref wd) = context.working_directory
        && !wd.is_empty()
    {
        blocks.push(context_block_for_text(
            "environment.workingDirectory",
            "Working Directory",
            TronHome::Workspace,
            format!("Current working directory: {wd}"),
            ContextCacheClass::Session,
            40,
        ));
    }

    blocks
}

/// Compile the full provider-independent audit view of an LLM request.
pub fn compose_context_audit_blocks(context: &Context) -> Vec<ContextBlock> {
    let mut blocks = compose_context_blocks(context);

    if let Some(ref capabilities) = context.capabilities
        && !capabilities.is_empty()
        && let Ok(text) = serde_json::to_string(capabilities)
    {
        let mut block = context_block_for_text(
            "capabilities.schemas",
            "ModelCapability Schemas",
            TronHome::Profiles,
            text,
            ContextCacheClass::Session,
            50,
        );
        block.provider_surface = ProviderSurface::ModelCapability;
        block.inclusion_reason = "available capabilities attached to provider request".into();
        blocks.push(block);
    }

    if !context.messages.is_empty()
        && let Ok(text) = serde_json::to_string(&context.messages)
    {
        let mut block = context_block_for_text(
            "conversation.messages",
            "Conversation Messages",
            TronHome::Workspace,
            text,
            ContextCacheClass::Turn,
            60,
        );
        block.provider_surface = ProviderSurface::Message;
        block.sensitivity = ContextSensitivity::Private;
        block.inclusion_reason = "conversation history attached to provider request".into();
        blocks.push(block);
    }

    blocks.sort_by_key(|block| block.precedence);
    blocks
}

/// Provider prompt parts split by cache behavior.
#[derive(Clone, Debug, Default)]
pub struct GroupedContextParts {
    /// Content stable across turns.
    pub stable: Vec<String>,
    /// Content regenerated for the current turn.
    pub volatile: Vec<String>,
}

/// Compose primitive context parts into stable and turn-local groups.
pub fn compose_context_parts_grouped(context: &Context) -> GroupedContextParts {
    let mut stable = Vec::new();
    let mut volatile = Vec::new();
    for block in compose_context_blocks(context) {
        match block.cache_class {
            ContextCacheClass::Foundation
            | ContextCacheClass::Profile
            | ContextCacheClass::Session => stable.push(block.text),
            ContextCacheClass::Turn | ContextCacheClass::None => volatile.push(block.text),
        }
    }

    GroupedContextParts { stable, volatile }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_context() -> Context {
        Context {
            system_prompt: Some("Soul seed".into()),
            messages: vec![].into(),
            capabilities: None,
            working_directory: Some("/Users/test/project".into()),
            agent_state_context: Some("state summary".into()),
            server_origin: Some("localhost:9847".into()),
        }
    }

    #[test]
    fn compose_parts_has_primitive_order() {
        let parts = compose_context_parts(&make_context());

        assert_eq!(parts.len(), 4);
        assert_eq!(parts[0], "Soul seed");
        assert_eq!(parts[1], "state summary");
        assert_eq!(parts[2], "Server: localhost:9847");
        assert_eq!(parts[3], "Current working directory: /Users/test/project");
    }

    #[test]
    fn grouped_parts_keep_state_volatile() {
        let grouped = compose_context_parts_grouped(&make_context());

        assert_eq!(grouped.stable.len(), 3);
        assert_eq!(grouped.volatile, vec!["state summary".to_owned()]);
    }

    #[test]
    fn audit_blocks_include_capabilities_and_messages() {
        let mut ctx = make_context();
        ctx.capabilities = Some(vec![crate::shared::model_capabilities::ModelCapability {
            name: "execute".into(),
            description: "primitive".into(),
            parameters: crate::shared::model_capabilities::CapabilityParameterSchema {
                schema_type: "object".into(),
                properties: None,
                required: None,
                description: None,
                extra: Default::default(),
            },
        }]);
        ctx.messages = vec![crate::shared::messages::Message::User {
            content: crate::shared::messages::UserMessageContent::Text("hello".into()),
            timestamp: None,
        }]
        .into();

        let ids = compose_context_audit_blocks(&ctx)
            .into_iter()
            .map(|block| block.id)
            .collect::<Vec<_>>();
        assert!(ids.contains(&"agent.soul".to_owned()));
        assert!(ids.contains(&"agent.state".to_owned()));
        assert!(ids.contains(&"capabilities.schemas".to_owned()));
        assert!(ids.contains(&"conversation.messages".to_owned()));
    }
}
