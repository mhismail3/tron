//! Built-in hooks registered programmatically.
//!
//! These are platform features that use the hook infrastructure but
//! don't require user-created files. Users can enable/disable them
//! via `settings.hooks.builtinHooks`.

use std::sync::Arc;

use super::engine::HookEngine;
use super::prompt_handler::PromptHookHandler;
use super::types::HookType;

/// Built-in hook ID: auto-generate session titles on session start.
pub const TITLE_GEN_ID: &str = "builtin:title-gen";

const TITLE_GEN_PROMPT: &str =
    "Generate a concise 3-6 word title for this session based on the user's prompt (in the 'prompt' field of the event context). Return ONLY the title text, nothing else.";

/// Register all built-in hooks into the engine.
///
/// Reads enabled state from `builtin_settings`. Hooks that are disabled
/// are still registered (for listing purposes) but their `should_handle()`
/// returns false.
pub fn register_builtins(
    engine: &mut HookEngine,
    llm_model: &str,
    builtin_settings: &[crate::settings::types::BuiltinHookSetting],
    subagent_manager: &Arc<crate::runtime::orchestrator::subagent_manager::SubagentManager>,
    event_emitter: &Arc<crate::runtime::agent::event_emitter::EventEmitter>,
    event_store: Option<&Arc<crate::events::EventStore>>,
) {
    let title_gen_enabled =
        crate::settings::types::BuiltinHookSetting::is_enabled(builtin_settings, TITLE_GEN_ID);

    let mut handler = PromptHookHandler::new(
        TITLE_GEN_ID.to_string(),
        TITLE_GEN_ID.to_string(),
        "Generate session title".to_string(),
        HookType::UserPromptSubmit,
        TITLE_GEN_PROMPT.to_string(),
        title_gen_enabled,
        0,
        llm_model.to_string(),
        subagent_manager.clone(),
        event_emitter.clone(),
    );
    if let Some(store) = event_store {
        handler = handler.with_event_store(store.clone());
    }
    engine.registry_mut().register(Arc::new(handler));
}

/// Metadata about a built-in hook (for iOS settings display).
pub struct BuiltinHookInfo {
    pub id: &'static str,
    pub label: &'static str,
    pub description: &'static str,
    pub hook_type: HookType,
}

/// List all built-in hooks with their metadata.
pub fn list_builtins() -> Vec<BuiltinHookInfo> {
    vec![BuiltinHookInfo {
        id: TITLE_GEN_ID,
        label: "Generate session title",
        description: "Automatically generates a short title from each user prompt",
        hook_type: HookType::UserPromptSubmit,
    }]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runtime::hooks::engine::HookEngine;
    use crate::runtime::hooks::registry::HookRegistry;
    use crate::settings::types::BuiltinHookSetting;

    // We can't create a real SubagentManager in unit tests, but we can
    // test the lookup and metadata logic.

    #[test]
    fn test_list_builtins_returns_title_gen() {
        let builtins = list_builtins();
        assert_eq!(builtins.len(), 1);
        assert_eq!(builtins[0].id, TITLE_GEN_ID);
        assert_eq!(builtins[0].hook_type, HookType::UserPromptSubmit);
    }

    #[test]
    fn test_title_gen_id_constant() {
        assert_eq!(TITLE_GEN_ID, "builtin:title-gen");
    }

    #[test]
    fn test_builtin_enabled_lookup_default() {
        let settings = BuiltinHookSetting::defaults();
        assert!(BuiltinHookSetting::is_enabled(&settings, TITLE_GEN_ID));
    }

    #[test]
    fn test_builtin_enabled_lookup_disabled() {
        let settings = vec![BuiltinHookSetting {
            id: TITLE_GEN_ID.to_string(),
            enabled: false,
        }];
        assert!(!BuiltinHookSetting::is_enabled(&settings, TITLE_GEN_ID));
    }

    #[test]
    fn test_builtin_enabled_lookup_unknown() {
        let settings = BuiltinHookSetting::defaults();
        // Unknown ID → defaults to true
        assert!(BuiltinHookSetting::is_enabled(&settings, "builtin:unknown"));
    }
}
