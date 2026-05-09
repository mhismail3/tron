//! Built-in hooks registered programmatically.
//!
//! These are platform features that use the hook infrastructure but
//! don't require user-created files. Users can enable/disable them
//! via `settings.hooks.builtinHooks`.
//!
//! Current built-ins:
//! - `builtin:title-gen` — auto-generates session titles from user prompts
//! - `builtin:branch-name-gen` — renames worktree branches to memorable 3-word names

use std::sync::Arc;

use super::engine::HookEngine;
use super::prompt_handler::PromptHookHandler;
use super::types::HookType;

/// Built-in hook ID: auto-generate session titles on session start.
pub const TITLE_GEN_ID: &str = "builtin:title-gen";

/// Built-in hook ID: auto-generate memorable branch names on worktree creation.
pub const BRANCH_NAME_GEN_ID: &str = "builtin:branch-name-gen";

/// Built-in hook ID: suggest follow-up prompts when the agent finishes.
pub const SUGGEST_PROMPTS_ID: &str = "builtin:suggest-prompts";

const TITLE_GEN_PROMPT: &str = "Generate a 3-5 word title describing what the agent is doing in this session, from the agent's perspective, in present continuous tense (e.g. \"Looking up gold prices\", \"Fixing login bug\", \"Drafting release notes\"). Prefer short, common words. Base it on the user's prompt (in the 'prompt' field of the event context). Return ONLY the title text, nothing else.";

const BRANCH_NAME_GEN_PROMPT: &str = "Generate a random memorable 3-word branch name in the format word-word-word (lowercase, hyphen-separated). \
     Use the pattern adjective-adjective-noun or adjective-noun-noun. Examples: fuzzy-purple-elephant, \
     quick-silver-falcon, gentle-autumn-river. Return ONLY the 3-word name, nothing else.";

const SUGGEST_PROMPTS_PROMPT: &str = "Based on the conversation context below, generate 3-5 short follow-up prompts the user might send next.\n\n\
     Rules:\n\
     - Each suggestion: 4-8 words, one per line\n\
     - No bullets, numbers, or prefixes — just the raw text\n\
     - Mix actions, questions, and refinements\n\
     - Be specific to the conversation, not generic\n\
     - If stop_reason is \"Interrupted\", the user stopped the response — suggest corrections, redirections, or alternative approaches\n\
     - Output ONLY the suggestions, nothing else";

/// Register all built-in hooks into the engine.
///
/// Reads enabled state from `builtin_settings`. Hooks that are disabled
/// are still registered (for listing purposes) but their `should_handle()`
/// returns false.
pub fn register_builtins(
    engine: &mut HookEngine,
    llm_model: &str,
    builtin_settings: &[crate::domains::settings::types::BuiltinHookSetting],
    subagent_manager: &Arc<
        crate::domains::agent::runner::orchestrator::subagent_manager::SubagentManager,
    >,
    event_emitter: &Arc<crate::domains::agent::runner::agent::event_emitter::EventEmitter>,
    event_store: Option<&Arc<crate::domains::session::event_store::EventStore>>,
    worktree_coordinator: Option<&Arc<crate::domains::worktree::WorktreeCoordinator>>,
    abort_tracker: &Arc<super::abort_tracker::HookAbortTracker>,
) {
    // Title generation hook
    let title_gen_enabled = crate::domains::settings::types::BuiltinHookSetting::is_enabled(
        builtin_settings,
        TITLE_GEN_ID,
    );

    let mut title_handler = PromptHookHandler::new(
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
    title_handler = title_handler.with_abort_tracker(abort_tracker.clone());
    if let Some(store) = event_store {
        title_handler = title_handler.with_event_store(store.clone());
    }
    engine.registry_mut().register(Arc::new(title_handler));

    // Branch name generation hook
    let branch_gen_enabled = crate::domains::settings::types::BuiltinHookSetting::is_enabled(
        builtin_settings,
        BRANCH_NAME_GEN_ID,
    );

    let mut branch_handler = PromptHookHandler::new(
        BRANCH_NAME_GEN_ID.to_string(),
        BRANCH_NAME_GEN_ID.to_string(),
        "Generate branch name".to_string(),
        HookType::WorktreeAcquired,
        BRANCH_NAME_GEN_PROMPT.to_string(),
        branch_gen_enabled,
        0,
        llm_model.to_string(),
        subagent_manager.clone(),
        event_emitter.clone(),
    );
    branch_handler = branch_handler.with_abort_tracker(abort_tracker.clone());
    if let Some(coord) = worktree_coordinator {
        branch_handler = branch_handler.with_worktree_coordinator(coord.clone());
    }
    engine.registry_mut().register(Arc::new(branch_handler));

    // Suggest follow-up prompts hook
    let suggest_enabled = crate::domains::settings::types::BuiltinHookSetting::is_enabled(
        builtin_settings,
        SUGGEST_PROMPTS_ID,
    );

    let mut suggest_handler = PromptHookHandler::new(
        SUGGEST_PROMPTS_ID.to_string(),
        SUGGEST_PROMPTS_ID.to_string(),
        "Suggest follow-up prompts".to_string(),
        HookType::Stop,
        SUGGEST_PROMPTS_PROMPT.to_string(),
        suggest_enabled,
        0,
        llm_model.to_string(),
        subagent_manager.clone(),
        event_emitter.clone(),
    );
    suggest_handler = suggest_handler.with_abort_tracker(abort_tracker.clone());
    if let Some(store) = event_store {
        suggest_handler = suggest_handler.with_event_store(store.clone());
    }
    engine.registry_mut().register(Arc::new(suggest_handler));
}

/// Metadata about a built-in hook (for iOS settings display).
pub struct BuiltinHookInfo {
    /// Stable identifier matching the hook's registration id.
    pub id: &'static str,
    /// Short human-readable name shown in the settings UI.
    pub label: &'static str,
    /// One-sentence explanation of what the hook does.
    pub description: &'static str,
    /// Lifecycle event this hook fires on.
    pub hook_type: HookType,
}

/// List all built-in hooks with their metadata.
pub fn list_builtins() -> Vec<BuiltinHookInfo> {
    vec![
        BuiltinHookInfo {
            id: TITLE_GEN_ID,
            label: "Generate session title",
            description: "Automatically generates a short title from each user prompt",
            hook_type: HookType::UserPromptSubmit,
        },
        BuiltinHookInfo {
            id: BRANCH_NAME_GEN_ID,
            label: "Generate branch name",
            description: "Renames worktree branches to memorable 3-word names",
            hook_type: HookType::WorktreeAcquired,
        },
        BuiltinHookInfo {
            id: SUGGEST_PROMPTS_ID,
            label: "Suggest follow-up prompts",
            description: "Suggests short follow-up prompts when the agent finishes responding",
            hook_type: HookType::Stop,
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::settings::types::BuiltinHookSetting;

    // We can't create a real SubagentManager in unit tests, but we can
    // test the lookup and metadata logic.

    #[test]
    fn test_list_builtins_returns_all_hooks() {
        let builtins = list_builtins();
        assert_eq!(builtins.len(), 3);
        let ids: Vec<&str> = builtins.iter().map(|b| b.id).collect();
        assert!(ids.contains(&TITLE_GEN_ID));
        assert!(ids.contains(&BRANCH_NAME_GEN_ID));
        assert!(ids.contains(&SUGGEST_PROMPTS_ID));
    }

    #[test]
    fn test_title_gen_id_constant() {
        assert_eq!(TITLE_GEN_ID, "builtin:title-gen");
    }

    #[test]
    fn test_branch_name_gen_id_constant() {
        assert_eq!(BRANCH_NAME_GEN_ID, "builtin:branch-name-gen");
    }

    #[test]
    fn test_branch_name_gen_hook_type() {
        let builtins = list_builtins();
        let branch_gen = builtins
            .iter()
            .find(|b| b.id == BRANCH_NAME_GEN_ID)
            .unwrap();
        assert_eq!(branch_gen.hook_type, HookType::WorktreeAcquired);
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
