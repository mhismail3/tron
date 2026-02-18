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

use tron_core::messages::Context;

/// Compose context fields into an ordered array of text parts.
///
/// Canonical ordering:
/// 1. `system_prompt`
/// 2. `rules_content` (with `"# Project Rules\n\n"` header)
/// 3. `memory_content`
/// 4. `dynamic_rules_context` (with `"# Active Rules\n\n"` header)
/// 5. `skill_context`
/// 6. `subagent_results_context`
/// 7. `task_context` (wrapped in `<task-context>` tags)
/// 8. `working_directory` (appended as `"Current working directory: <path>"`)
pub fn compose_context_parts(context: &Context) -> Vec<String> {
    let mut parts = Vec::new();

    if let Some(ref sp) = context.system_prompt {
        if !sp.is_empty() {
            parts.push(sp.clone());
        }
    }

    if let Some(ref rules) = context.rules_content {
        if !rules.is_empty() {
            parts.push(format!("# Project Rules\n\n{rules}"));
        }
    }

    if let Some(ref memory) = context.memory_content {
        if !memory.is_empty() {
            parts.push(memory.clone());
        }
    }

    if let Some(ref dynamic) = context.dynamic_rules_context {
        if !dynamic.is_empty() {
            parts.push(format!("# Active Rules\n\n{dynamic}"));
        }
    }

    if let Some(ref skills) = context.skill_context {
        if !skills.is_empty() {
            parts.push(skills.clone());
        }
    }

    if let Some(ref subagent) = context.subagent_results_context {
        if !subagent.is_empty() {
            parts.push(subagent.clone());
        }
    }

    if let Some(ref tasks) = context.task_context {
        if !tasks.is_empty() {
            parts.push(format!("<task-context>\n{tasks}\n</task-context>"));
        }
    }

    if let Some(ref wd) = context.working_directory {
        if !wd.is_empty() {
            parts.push(format!("Current working directory: {wd}"));
        }
    }

    parts
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
/// **Stable** (1h cache TTL): `system_prompt`, `rules_content`, `memory_content`
/// **Volatile** (5m cache TTL): `dynamic_rules_context`, `skill_context`,
/// `subagent_results_context`, `task_context`
pub fn compose_context_parts_grouped(context: &Context) -> GroupedContextParts {
    let mut stable = Vec::new();
    let mut volatile = Vec::new();

    // Stable parts
    if let Some(ref sp) = context.system_prompt {
        if !sp.is_empty() {
            stable.push(sp.clone());
        }
    }

    if let Some(ref rules) = context.rules_content {
        if !rules.is_empty() {
            stable.push(format!("# Project Rules\n\n{rules}"));
        }
    }

    if let Some(ref memory) = context.memory_content {
        if !memory.is_empty() {
            stable.push(memory.clone());
        }
    }

    if let Some(ref wd) = context.working_directory {
        if !wd.is_empty() {
            stable.push(format!("Current working directory: {wd}"));
        }
    }

    // Volatile parts
    if let Some(ref dynamic) = context.dynamic_rules_context {
        if !dynamic.is_empty() {
            volatile.push(format!("# Active Rules\n\n{dynamic}"));
        }
    }

    if let Some(ref skills) = context.skill_context {
        if !skills.is_empty() {
            volatile.push(skills.clone());
        }
    }

    if let Some(ref subagent) = context.subagent_results_context {
        if !subagent.is_empty() {
            volatile.push(subagent.clone());
        }
    }

    if let Some(ref tasks) = context.task_context {
        if !tasks.is_empty() {
            volatile.push(format!("<task-context>\n{tasks}\n</task-context>"));
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
            messages: vec![],
            tools: None,
            working_directory: Some("/Users/test/project".into()),
            rules_content: Some("Always use Rust.".into()),
            memory_content: Some("User prefers concise responses.".into()),
            skill_context: Some("Available skill: /commit".into()),
            subagent_results_context: None,
            task_context: Some("Task #1: Fix the bug".into()),
            dynamic_rules_context: Some("Rule: no console.log".into()),
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
        assert_eq!(parts[4], "Available skill: /commit");
        assert!(parts[5].starts_with("<task-context>"));
        assert!(parts[5].contains("Fix the bug"));
        assert!(parts[5].ends_with("</task-context>"));
        assert_eq!(parts[6], "Current working directory: /Users/test/project");
    }

    #[test]
    fn compose_parts_empty_context() {
        let ctx = Context {
            system_prompt: None,
            messages: vec![],
            tools: None,
            working_directory: None,
            rules_content: None,
            memory_content: None,
            skill_context: None,
            subagent_results_context: None,
            task_context: None,
            dynamic_rules_context: None,
        };
        let parts = compose_context_parts(&ctx);
        assert!(parts.is_empty());
    }

    #[test]
    fn compose_parts_skips_empty_strings() {
        let ctx = Context {
            system_prompt: Some(String::new()),
            messages: vec![],
            tools: None,
            working_directory: None,
            rules_content: Some(String::new()),
            memory_content: Some("memory".into()),
            skill_context: None,
            subagent_results_context: None,
            task_context: None,
            dynamic_rules_context: None,
        };
        let parts = compose_context_parts(&ctx);
        assert_eq!(parts.len(), 1);
        assert_eq!(parts[0], "memory");
    }

    #[test]
    fn compose_parts_only_system_prompt() {
        let ctx = Context {
            system_prompt: Some("Hello".into()),
            messages: vec![],
            tools: None,
            working_directory: None,
            rules_content: None,
            memory_content: None,
            skill_context: None,
            subagent_results_context: None,
            task_context: None,
            dynamic_rules_context: None,
        };
        let parts = compose_context_parts(&ctx);
        assert_eq!(parts.len(), 1);
        assert_eq!(parts[0], "Hello");
    }

    // ── compose_context_parts_grouped ────────────────────────────────────

    #[test]
    fn grouped_stable_and_volatile() {
        let ctx = make_context();
        let grouped = compose_context_parts_grouped(&ctx);

        // Stable: system_prompt, rules_content, memory_content, working_directory
        assert_eq!(grouped.stable.len(), 4);
        assert_eq!(grouped.stable[0], "You are a helpful assistant.");
        assert!(grouped.stable[1].contains("Always use Rust."));
        assert_eq!(grouped.stable[2], "User prefers concise responses.");
        assert_eq!(
            grouped.stable[3],
            "Current working directory: /Users/test/project"
        );

        // Volatile: dynamic_rules, skill, task (subagent_results is None)
        assert_eq!(grouped.volatile.len(), 3);
        assert!(grouped.volatile[0].contains("no console.log"));
        assert_eq!(grouped.volatile[1], "Available skill: /commit");
        assert!(grouped.volatile[2].contains("Fix the bug"));
    }

    #[test]
    fn grouped_empty_context() {
        let ctx = Context {
            system_prompt: None,
            messages: vec![],
            tools: None,
            working_directory: None,
            rules_content: None,
            memory_content: None,
            skill_context: None,
            subagent_results_context: None,
            task_context: None,
            dynamic_rules_context: None,
        };
        let grouped = compose_context_parts_grouped(&ctx);
        assert!(grouped.stable.is_empty());
        assert!(grouped.volatile.is_empty());
    }

    #[test]
    fn grouped_only_stable() {
        let ctx = Context {
            system_prompt: Some("System".into()),
            messages: vec![],
            tools: None,
            working_directory: None,
            rules_content: Some("Rules".into()),
            memory_content: None,
            skill_context: None,
            subagent_results_context: None,
            task_context: None,
            dynamic_rules_context: None,
        };
        let grouped = compose_context_parts_grouped(&ctx);
        assert_eq!(grouped.stable.len(), 2);
        assert!(grouped.volatile.is_empty());
    }

    #[test]
    fn grouped_only_volatile() {
        let ctx = Context {
            system_prompt: None,
            messages: vec![],
            tools: None,
            working_directory: None,
            rules_content: None,
            memory_content: None,
            skill_context: Some("Skill".into()),
            subagent_results_context: None,
            task_context: None,
            dynamic_rules_context: None,
        };
        let grouped = compose_context_parts_grouped(&ctx);
        assert!(grouped.stable.is_empty());
        assert_eq!(grouped.volatile.len(), 1);
    }
}
