//! Provider-independent composition for the primitive agent context.

use crate::shared::protocol::messages::Context;

#[derive(Clone, Copy)]
enum CacheStability {
    Stable,
    Volatile,
}

struct ContextPart {
    text: String,
    stability: CacheStability,
}

/// Compose provider prompt text from the primitive context.
pub fn compose_context_parts(context: &Context) -> Vec<String> {
    context_parts(context)
        .into_iter()
        .map(|part| part.text)
        .collect()
}

fn context_parts(context: &Context) -> Vec<ContextPart> {
    let mut parts = Vec::new();

    if let Some(ref soul) = context.system_prompt
        && !soul.is_empty()
    {
        parts.push(ContextPart {
            text: soul.clone(),
            stability: CacheStability::Stable,
        });
    }

    if let Some(ref state) = context.agent_state_context
        && !state.is_empty()
    {
        parts.push(ContextPart {
            text: state.clone(),
            stability: CacheStability::Volatile,
        });
    }

    if let Some(ref origin) = context.server_origin
        && !origin.is_empty()
    {
        parts.push(ContextPart {
            text: format!("Server: {origin}"),
            stability: CacheStability::Stable,
        });
    }

    if let Some(ref wd) = context.working_directory
        && !wd.is_empty()
    {
        parts.push(ContextPart {
            text: format!("Current working directory: {wd}"),
            stability: CacheStability::Stable,
        });
    }

    parts
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
    for part in context_parts(context) {
        match part.stability {
            CacheStability::Stable => stable.push(part.text),
            CacheStability::Volatile => volatile.push(part.text),
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
}
