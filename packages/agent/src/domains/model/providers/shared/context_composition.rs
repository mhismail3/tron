//! Provider-independent composition for the primitive agent context.

use crate::shared::protocol::messages::Context;

/// Compose provider prompt text from the primitive context.
pub fn compose_context_parts(context: &Context) -> Vec<String> {
    let mut parts = Vec::new();

    if let Some(ref system_prompt) = context.system_prompt
        && !system_prompt.is_empty()
    {
        parts.push(system_prompt.clone());
    }

    if let Some(ref origin) = context.server_origin
        && !origin.is_empty()
    {
        parts.push(format!("Server: {origin}"));
    }

    if let Some(ref wd) = context.working_directory
        && !wd.is_empty()
    {
        parts.push(format!("Current working directory: {wd}"));
    }

    parts
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_context() -> Context {
        Context {
            system_prompt: Some("Soul seed".into()),
            messages: vec![].into(),
            tools: None,
            working_directory: Some("/Users/test/project".into()),
            server_origin: Some("localhost:9847".into()),
        }
    }

    #[test]
    fn compose_parts_has_primitive_order() {
        let parts = compose_context_parts(&make_context());

        assert_eq!(parts.len(), 3);
        assert_eq!(parts[0], "Soul seed");
        assert_eq!(parts[1], "Server: localhost:9847");
        assert_eq!(parts[2], "Current working directory: /Users/test/project");
    }
}
