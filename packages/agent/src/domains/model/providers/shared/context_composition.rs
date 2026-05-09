//! # Context Composition
//!
//! Composes [`Context`] fields into ordered text parts for system prompt assembly.
//! All providers use this to build their system prompt from the same context object,
//! ensuring consistent ordering across Anthropic, `OpenAI`, and Google.
//!
//! Two modes:
//! - [`compose_context_parts`] — flat list in canonical order
//! - [`compose_context_parts_grouped`] — split into stable (1h cache TTL) and
//!   volatile (5m cache TTL) groups for Anthropic prompt caching

use crate::shared::constitution::{
    ContextBlock, ContextCacheClass, ContextSensitivity, ProviderSurface, TronHome,
    context_block_for_text,
};
use crate::shared::messages::Context;

/// Compose context fields into an ordered array of text parts.
///
/// Canonical ordering:
/// 1. `system_prompt`
/// 2. `rules_content` (with `"# Project Rules\n\n"` header)
/// 3. `memory_content`
/// 4. `dynamic_rules_context` (with `"# Active Rules\n\n"` header)
/// 5. `skill_index_context` (lightweight index of all available skills)
/// 6. `skill_context` (full content of explicitly invoked skills)
/// 7. `skill_removal_context` (one-turn deactivation notice)
/// 8. `job_results_context` (completed background processes + subagents)
/// 9. `working_directory` (appended as `"Current working directory: <path>"`)
pub fn compose_context_parts(context: &Context) -> Vec<String> {
    compose_context_blocks(context)
        .into_iter()
        .map(|block| block.text)
        .collect()
}

/// Compile context fields into typed Constitution context blocks.
///
/// This is the provider-independent audit shape. Provider payload builders may flatten
/// the text, split by cache class, or apply provider-specific cache controls,
/// but the compiled block identities and ordering stay stable.
pub fn compose_context_blocks(context: &Context) -> Vec<ContextBlock> {
    let mut blocks = Vec::new();

    if let Some(ref sp) = context.system_prompt
        && !sp.is_empty()
    {
        blocks.push(context_block_for_text(
            "system.prompt",
            "System Prompt",
            TronHome::Profiles,
            sp.clone(),
            ContextCacheClass::Foundation,
            10,
        ));
    }

    if let Some(ref rules) = context.rules_content
        && !rules.is_empty()
    {
        blocks.push(context_block_for_text(
            "project.rules",
            "Project Rules",
            TronHome::Workspace,
            format!("# Project Rules\n\n{rules}"),
            ContextCacheClass::Session,
            20,
        ));
    }

    if let Some(ref memory) = context.memory_content
        && !memory.is_empty()
    {
        blocks.push(context_block_for_text(
            "memory.root",
            "Memory",
            TronHome::Memory,
            memory.clone(),
            ContextCacheClass::Session,
            30,
        ));
    }

    if let Some(ref dynamic) = context.dynamic_rules_context
        && !dynamic.is_empty()
    {
        blocks.push(context_block_for_text(
            "dynamic.rules",
            "Active Rules",
            TronHome::Profiles,
            format!("# Active Rules\n\n{dynamic}"),
            ContextCacheClass::Turn,
            40,
        ));
    }

    if let Some(ref skill_index) = context.skill_index_context
        && !skill_index.is_empty()
    {
        blocks.push(context_block_for_text(
            "skills.index",
            "Skill Index",
            TronHome::Skills,
            skill_index.clone(),
            ContextCacheClass::Session,
            50,
        ));
    }

    if let Some(ref activation) = context.skill_activation_context
        && !activation.is_empty()
    {
        blocks.push(context_block_for_text(
            "skills.activation",
            "Skill Activation",
            TronHome::Skills,
            activation.clone(),
            ContextCacheClass::Turn,
            60,
        ));
    }

    if let Some(ref skills) = context.skill_context
        && !skills.is_empty()
    {
        blocks.push(context_block_for_text(
            "skills.active",
            "Active Skill Context",
            TronHome::Skills,
            skills.clone(),
            ContextCacheClass::Turn,
            70,
        ));
    }

    if let Some(ref removal) = context.skill_removal_context
        && !removal.is_empty()
    {
        blocks.push(context_block_for_text(
            "skills.removal",
            "Skill Removal",
            TronHome::Skills,
            removal.clone(),
            ContextCacheClass::Turn,
            80,
        ));
    }

    if let Some(ref jobs) = context.job_results_context
        && !jobs.is_empty()
    {
        blocks.push(context_block_for_text(
            "jobs.results",
            "Job Results",
            TronHome::Workspace,
            jobs.clone(),
            ContextCacheClass::Turn,
            90,
        ));
    }

    // Environment details: server origin + working directory
    if let Some(ref origin) = context.server_origin
        && !origin.is_empty()
    {
        blocks.push(context_block_for_text(
            "environment.server",
            "Server Origin",
            TronHome::Internal,
            format!("Server: {origin}"),
            ContextCacheClass::Session,
            100,
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
            110,
        ));
    }

    blocks
}

/// Compile the complete provider-independent audit view of an LLM request.
///
/// Unlike [`compose_context_parts`], this includes non-instruction provider
/// surfaces such as tool schemas and conversation messages. It is used only for
/// Constitution audit/replay and must not feed back into prompt text assembly.
pub fn compose_context_audit_blocks(context: &Context) -> Vec<ContextBlock> {
    let mut blocks = compose_context_blocks(context);

    if let Some(ref hook_context) = context.hook_context
        && !hook_context.is_empty()
    {
        let mut block = context_block_for_text(
            "hooks.addContext",
            "Hook Context",
            TronHome::Workspace,
            hook_context.clone(),
            ContextCacheClass::Turn,
            95,
        );
        block.inclusion_reason = "hook AddContext attached to user turn".into();
        blocks.push(block);
    }

    if let Some(ref tools) = context.tools
        && !tools.is_empty()
    {
        if let Ok(text) = serde_json::to_string(tools) {
            let mut block = context_block_for_text(
                "tools.schemas",
                "Tool Schemas",
                TronHome::Profiles,
                text,
                ContextCacheClass::Session,
                120,
            );
            block.provider_surface = ProviderSurface::Tool;
            block.inclusion_reason = "available tools attached to provider request".into();
            blocks.push(block);
        }
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
            130,
        );
        block.provider_surface = ProviderSurface::Message;
        block.sensitivity = ContextSensitivity::Private;
        block.inclusion_reason = "conversation history attached to provider request".into();
        blocks.push(block);
    }

    blocks.sort_by_key(|block| block.precedence);
    blocks
}

/// Context parts split by cache stability.
///
/// Used by Anthropic OAuth to assign different cache TTLs:
/// - Stable parts change rarely → 1h TTL
/// - Volatile parts change per turn → 5m TTL (default ephemeral)
#[derive(Clone, Debug, Default)]
pub struct GroupedContextParts {
    /// Parts that change rarely (system prompt, rules, memory).
    pub stable: Vec<String>,
    /// Parts that change frequently (dynamic rules, skills, subagent results, tasks).
    pub volatile: Vec<String>,
}

/// Compose context fields split into stable and volatile groups.
///
/// **Stable** (1h cache TTL): `system_prompt`, `rules_content`, `memory_content`,
/// `skill_index_context`
/// **Volatile** (5m cache TTL): `dynamic_rules_context`, `skill_context`,
/// `skill_removal_context`, `job_results_context`
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

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn make_context() -> Context {
        Context {
            system_prompt: Some("You are a helpful assistant.".into()),
            messages: vec![].into(),
            tools: None,
            working_directory: Some("/Users/test/project".into()),
            rules_content: Some("Always use Rust.".into()),
            memory_content: Some("User prefers concise responses.".into()),
            skill_index_context: Some("# Available Skills\n\n- @sandbox".into()),
            skill_activation_context: None,
            skill_context: Some("Available skill: /commit".into()),
            skill_removal_context: None,
            job_results_context: None,
            dynamic_rules_context: Some("Rule: no console.log".into()),
            hook_context: None,
            server_origin: None,
        }
    }

    // ── compose_context_parts ────────────────────────────────────────────

    #[test]
    fn compose_parts_canonical_order() {
        let ctx = make_context();
        let parts = compose_context_parts(&ctx);

        assert_eq!(parts.len(), 7);
        assert_eq!(parts[0], "You are a helpful assistant.");
        assert!(parts[1].starts_with("# Project Rules"));
        assert!(parts[1].contains("Always use Rust."));
        assert_eq!(parts[2], "User prefers concise responses.");
        assert!(parts[3].starts_with("# Active Rules"));
        assert!(parts[3].contains("no console.log"));
        assert!(parts[4].contains("# Available Skills"));
        assert_eq!(parts[5], "Available skill: /commit");
        assert_eq!(parts[6], "Current working directory: /Users/test/project");
    }

    #[test]
    fn compose_parts_empty_context() {
        let ctx = Context {
            system_prompt: None,
            messages: vec![].into(),
            tools: None,
            working_directory: None,
            rules_content: None,
            memory_content: None,
            skill_index_context: None,
            skill_activation_context: None,
            skill_context: None,
            skill_removal_context: None,
            job_results_context: None,
            dynamic_rules_context: None,
            hook_context: None,
            server_origin: None,
        };
        let parts = compose_context_parts(&ctx);
        assert!(parts.is_empty());
    }

    #[test]
    fn compose_parts_skips_empty_strings() {
        let ctx = Context {
            system_prompt: Some(String::new()),
            messages: vec![].into(),
            tools: None,
            working_directory: None,
            rules_content: Some(String::new()),
            memory_content: Some("memory".into()),
            skill_index_context: None,
            skill_activation_context: None,
            skill_context: None,
            skill_removal_context: None,
            job_results_context: None,
            dynamic_rules_context: None,
            hook_context: None,
            server_origin: None,
        };
        let parts = compose_context_parts(&ctx);
        assert_eq!(parts.len(), 1);
        assert_eq!(parts[0], "memory");
    }

    #[test]
    fn compose_parts_only_system_prompt() {
        let ctx = Context {
            system_prompt: Some("Hello".into()),
            messages: vec![].into(),
            tools: None,
            working_directory: None,
            rules_content: None,
            memory_content: None,
            skill_index_context: None,
            skill_activation_context: None,
            skill_context: None,
            skill_removal_context: None,
            job_results_context: None,
            dynamic_rules_context: None,
            hook_context: None,
            server_origin: None,
        };
        let parts = compose_context_parts(&ctx);
        assert_eq!(parts.len(), 1);
        assert_eq!(parts[0], "Hello");
    }

    #[test]
    fn audit_blocks_include_tools_and_messages_without_flattening() {
        let ctx = Context {
            messages: vec![crate::shared::messages::Message::user("hello")].into(),
            tools: Some(vec![crate::shared::tools::Tool {
                name: "read".into(),
                description: "Read a file".into(),
                parameters: crate::shared::tools::ToolParameterSchema {
                    schema_type: "object".into(),
                    properties: None,
                    required: None,
                    description: None,
                    extra: serde_json::Map::new(),
                },
            }]),
            system_prompt: Some("System".into()),
            ..Default::default()
        };

        let flat = compose_context_parts(&ctx);
        assert_eq!(flat, vec!["System"]);

        let blocks = compose_context_audit_blocks(&ctx);
        assert!(
            blocks.iter().any(|block| block.id == "tools.schemas"
                && block.provider_surface == ProviderSurface::Tool)
        );
        assert!(
            blocks
                .iter()
                .any(|block| block.id == "conversation.messages"
                    && block.provider_surface == ProviderSurface::Message
                    && block.sensitivity == ContextSensitivity::Private)
        );
    }

    // ── compose_context_parts_grouped ────────────────────────────────────

    #[test]
    fn grouped_stable_and_volatile() {
        let ctx = make_context();
        let grouped = compose_context_parts_grouped(&ctx);

        // Stable: system_prompt, rules_content, memory_content, skill_index, working_directory
        assert_eq!(grouped.stable.len(), 5);
        assert_eq!(grouped.stable[0], "You are a helpful assistant.");
        assert!(grouped.stable[1].contains("Always use Rust."));
        assert_eq!(grouped.stable[2], "User prefers concise responses.");
        assert!(grouped.stable[3].contains("# Available Skills"));
        assert_eq!(
            grouped.stable[4],
            "Current working directory: /Users/test/project"
        );

        // Volatile: dynamic_rules, skill (subagent/process results are None)
        assert_eq!(grouped.volatile.len(), 2);
        assert!(grouped.volatile[0].contains("no console.log"));
        assert_eq!(grouped.volatile[1], "Available skill: /commit");
    }

    #[test]
    fn grouped_empty_context() {
        let ctx = Context {
            system_prompt: None,
            messages: vec![].into(),
            tools: None,
            working_directory: None,
            rules_content: None,
            memory_content: None,
            skill_index_context: None,
            skill_activation_context: None,
            skill_context: None,
            skill_removal_context: None,
            job_results_context: None,
            dynamic_rules_context: None,
            hook_context: None,
            server_origin: None,
        };
        let grouped = compose_context_parts_grouped(&ctx);
        assert!(grouped.stable.is_empty());
        assert!(grouped.volatile.is_empty());
    }

    #[test]
    fn grouped_only_stable() {
        let ctx = Context {
            system_prompt: Some("System".into()),
            messages: vec![].into(),
            tools: None,
            working_directory: None,
            rules_content: Some("Rules".into()),
            memory_content: None,
            skill_index_context: None,
            skill_activation_context: None,
            skill_context: None,
            skill_removal_context: None,
            job_results_context: None,
            dynamic_rules_context: None,
            hook_context: None,
            server_origin: None,
        };
        let grouped = compose_context_parts_grouped(&ctx);
        assert_eq!(grouped.stable.len(), 2);
        assert!(grouped.volatile.is_empty());
    }

    #[test]
    fn compose_parts_with_server_origin() {
        let ctx = Context {
            server_origin: Some("localhost:9847".into()),
            working_directory: Some("/Users/test/project".into()),
            ..Default::default()
        };
        let parts = compose_context_parts(&ctx);
        assert_eq!(parts.len(), 2);
        assert_eq!(parts[0], "Server: localhost:9847");
        assert_eq!(parts[1], "Current working directory: /Users/test/project");
    }

    #[test]
    fn grouped_server_origin_is_stable() {
        let ctx = Context {
            server_origin: Some("localhost:9846".into()),
            working_directory: Some("/tmp".into()),
            ..Default::default()
        };
        let grouped = compose_context_parts_grouped(&ctx);
        assert_eq!(grouped.stable.len(), 2);
        assert_eq!(grouped.stable[0], "Server: localhost:9846");
        assert_eq!(grouped.stable[1], "Current working directory: /tmp");
        assert!(grouped.volatile.is_empty());
    }

    #[test]
    fn skill_index_in_stable_group() {
        let ctx = Context {
            skill_index_context: Some("# Available Skills\n\n- @sandbox".into()),
            ..Default::default()
        };
        let grouped = compose_context_parts_grouped(&ctx);
        assert_eq!(grouped.stable.len(), 1);
        assert!(grouped.stable[0].contains("Available Skills"));
        assert!(grouped.volatile.is_empty());
    }

    #[test]
    fn skill_index_before_skill_context_in_flat() {
        let ctx = Context {
            skill_index_context: Some("# Available Skills\n\n- @sandbox".into()),
            skill_activation_context: None,
            skill_context: Some("<skills>full content</skills>".into()),
            ..Default::default()
        };
        let parts = compose_context_parts(&ctx);
        assert_eq!(parts.len(), 2);
        assert!(parts[0].contains("Available Skills"));
        assert!(parts[1].contains("full content"));
    }

    #[test]
    fn skill_index_empty_string_skipped() {
        let ctx = Context {
            skill_index_context: Some(String::new()),
            ..Default::default()
        };
        let parts = compose_context_parts(&ctx);
        assert!(parts.is_empty());

        let grouped = compose_context_parts_grouped(&ctx);
        assert!(grouped.stable.is_empty());
    }

    #[test]
    fn grouped_only_volatile() {
        let ctx = Context {
            system_prompt: None,
            messages: vec![].into(),
            tools: None,
            working_directory: None,
            rules_content: None,
            memory_content: None,
            skill_index_context: None,
            skill_activation_context: None,
            skill_context: Some("Skill".into()),
            skill_removal_context: None,
            job_results_context: None,
            dynamic_rules_context: None,
            hook_context: None,
            server_origin: None,
        };
        let grouped = compose_context_parts_grouped(&ctx);
        assert!(grouped.stable.is_empty());
        assert_eq!(grouped.volatile.len(), 1);
    }

    // ── skill_removal_context ───────────────────────────────────────

    #[test]
    fn skill_removal_context_in_flat_ordering() {
        let ctx = Context {
            skill_activation_context: None,
            skill_context: Some("<skills>browser</skills>".into()),
            skill_removal_context: Some(
                "The following skills have been deactivated: @old-skill".into(),
            ),
            job_results_context: Some("Job done".into()),
            ..Default::default()
        };
        let parts = compose_context_parts(&ctx);
        assert_eq!(parts.len(), 3);
        // Order: skill_context, skill_removal_context, job_results_context
        assert!(parts[0].contains("browser"));
        assert!(parts[1].contains("deactivated"));
        assert!(parts[2].contains("Job done"));
    }

    #[test]
    fn skill_removal_context_in_volatile_group() {
        let ctx = Context {
            system_prompt: Some("System".into()),
            skill_removal_context: Some("Stop following @browser".into()),
            ..Default::default()
        };
        let grouped = compose_context_parts_grouped(&ctx);
        assert_eq!(grouped.stable.len(), 1); // system_prompt
        assert_eq!(grouped.volatile.len(), 1); // skill_removal_context
        assert!(grouped.volatile[0].contains("Stop following"));
    }

    #[test]
    fn skill_removal_context_empty_skipped() {
        let ctx = Context {
            skill_removal_context: None,
            ..Default::default()
        };
        let parts = compose_context_parts(&ctx);
        assert!(parts.is_empty());

        let ctx2 = Context {
            skill_removal_context: Some(String::new()),
            ..Default::default()
        };
        let parts2 = compose_context_parts(&ctx2);
        assert!(parts2.is_empty());
    }

    // ── skill_activation_context ───────────────────────────────────

    #[test]
    fn activation_context_before_skill_context_in_flat() {
        let ctx = Context {
            skill_activation_context: Some("Follow @browser".into()),
            skill_context: Some("<skills>browser content</skills>".into()),
            ..Default::default()
        };
        let parts = compose_context_parts(&ctx);
        assert_eq!(parts.len(), 2);
        let activation_idx = parts
            .iter()
            .position(|p| p.contains("Follow @browser"))
            .unwrap();
        let skill_idx = parts.iter().position(|p| p.contains("<skills>")).unwrap();
        assert!(activation_idx < skill_idx);
    }

    #[test]
    fn activation_context_in_volatile_group() {
        let ctx = Context {
            skill_activation_context: Some("Follow @browser".into()),
            system_prompt: Some("System".into()),
            ..Default::default()
        };
        let grouped = compose_context_parts_grouped(&ctx);
        assert!(
            grouped
                .volatile
                .iter()
                .any(|p| p.contains("Follow @browser"))
        );
        assert!(!grouped.stable.iter().any(|p| p.contains("Follow @browser")));
    }

    #[test]
    fn activation_context_none_skipped() {
        let ctx = Context {
            skill_activation_context: None,
            ..Default::default()
        };
        let parts = compose_context_parts(&ctx);
        assert!(parts.is_empty());
    }

    #[test]
    fn activation_context_empty_string_skipped() {
        let ctx = Context {
            skill_activation_context: Some(String::new()),
            ..Default::default()
        };
        let parts = compose_context_parts(&ctx);
        assert!(parts.is_empty());
    }
}
