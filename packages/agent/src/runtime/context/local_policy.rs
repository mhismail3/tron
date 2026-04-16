//! Single source of truth for local-model (Ollama) context policy.
//!
//! Local models run with a smaller context window and a stripped-down system
//! prompt to minimize time-to-first-token. This module centralizes every
//! decision that differs from cloud behavior:
//!
//! - Which tools are exposed (and executable) on local models
//! - How much of the rules content is included before truncation
//! - Which provider types are considered "local"
//!
//! All three call sites that previously hardcoded these values
//! (`turn_runner::build_turn_context`, `ContextManager::new`, and the prompt
//! handler) consume this module so that adding/removing a local tool or
//! changing the truncation budget is a single-line edit.
//!
//! ## Invariant
//!
//! If `is_local_provider(p)` is true, the model must only see and be able to
//! execute tools in [`LOCAL_MODEL_TOOLS`]. Schema filtering alone is
//! insufficient — the executor must also refuse off-list calls to close the
//! gap where a model hallucinates a tool name from training data or memory.

use crate::core::messages::Provider;

/// Tool names exposed to local models.
///
/// Schema filtering happens in `build_turn_context`; execution-layer
/// enforcement happens in the tool executor. Both consult this list.
pub const LOCAL_MODEL_TOOLS: &[&str] =
    &["Read", "Write", "Edit", "Bash", "Search", "Find", "WebFetch"];

/// Maximum chars of `rules_content` included in the local context.
pub const LOCAL_RULES_TRUNCATION_CHARS: usize = 500;

/// Suffix appended after truncation so the model knows content was cut.
pub const LOCAL_RULES_TRUNCATION_SUFFIX: &str =
    "\n\n[Truncated — full rules available via Read tool]";

/// Char budget for token estimation (truncation + suffix length).
///
/// The token estimator uses this to match what
/// [`truncate_rules_for_local`] actually emits, so compaction triggers
/// align with what the model receives.
pub const LOCAL_RULES_ESTIMATION_CHARS: usize =
    LOCAL_RULES_TRUNCATION_CHARS + LOCAL_RULES_TRUNCATION_SUFFIX.len();

/// Is this provider a local model (stripped context, small window)?
#[must_use]
pub fn is_local_provider(p: Provider) -> bool {
    matches!(p, Provider::Ollama)
}

/// Is this tool permitted for local models?
#[must_use]
pub fn is_local_tool(name: &str) -> bool {
    LOCAL_MODEL_TOOLS.contains(&name)
}

/// Which context-assembly policy applies to a turn.
///
/// A thin, self-documenting replacement for scattered `if is_local` branches.
/// Prefer passing [`ContextPolicy`] into helpers over a raw `bool` so the
/// semantic decision ("strip memory? include all tools?") is visible at the
/// call site.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ContextPolicy {
    /// Full context: all tools, memory, skills, jobs, rules.
    Cloud,
    /// Stripped context: tool allow-list, no memory, no job results, truncated rules.
    Local,
}

impl ContextPolicy {
    /// Derive the policy from a provider type.
    #[must_use]
    pub fn from_provider(p: Provider) -> Self {
        if is_local_provider(p) { Self::Local } else { Self::Cloud }
    }

    /// Does this policy strip `memory_content`?
    #[must_use]
    pub fn strip_memory(self) -> bool {
        matches!(self, Self::Local)
    }

    /// Does this policy strip the skill index block?
    #[must_use]
    pub fn strip_skill_index(self) -> bool {
        matches!(self, Self::Local)
    }

    /// Does this policy strip the job-results block?
    #[must_use]
    pub fn strip_job_results(self) -> bool {
        matches!(self, Self::Local)
    }

    /// Does this policy skip upstream DB queries for pending subagent/process
    /// /user-job results during prompt bootstrap?
    #[must_use]
    pub fn skip_pending_jobs_bootstrap(self) -> bool {
        matches!(self, Self::Local)
    }

    /// The allow-list of tool names, or `None` if all registered tools apply.
    #[must_use]
    pub fn tool_filter(self) -> Option<&'static [&'static str]> {
        match self {
            Self::Cloud => None,
            Self::Local => Some(LOCAL_MODEL_TOOLS),
        }
    }

    /// The rules truncation budget (chars), or `None` for no truncation.
    #[must_use]
    pub fn rules_truncation(self) -> Option<usize> {
        match self {
            Self::Cloud => None,
            Self::Local => Some(LOCAL_RULES_TRUNCATION_CHARS),
        }
    }
}

/// Truncate `rules` for local display.
///
/// Safe at multi-byte char boundaries. Returns the original string unchanged
/// if it already fits within [`LOCAL_RULES_TRUNCATION_CHARS`].
#[must_use]
pub fn truncate_rules_for_local(rules: &str) -> String {
    if rules.len() <= LOCAL_RULES_TRUNCATION_CHARS {
        return rules.to_string();
    }
    let cut = rules
        .char_indices()
        .take_while(|&(i, _)| i <= LOCAL_RULES_TRUNCATION_CHARS)
        .last()
        .map_or(0, |(i, _)| i);
    format!("{}{}", &rules[..cut], LOCAL_RULES_TRUNCATION_SUFFIX)
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    // ── is_local_provider ────────────────────────────────────────────────

    #[test]
    fn ollama_is_local() {
        assert!(is_local_provider(Provider::Ollama));
    }

    #[test]
    fn cloud_providers_are_not_local() {
        assert!(!is_local_provider(Provider::Anthropic));
        assert!(!is_local_provider(Provider::OpenAi));
        assert!(!is_local_provider(Provider::OpenAiCodex));
        assert!(!is_local_provider(Provider::Google));
        assert!(!is_local_provider(Provider::MiniMax));
        assert!(!is_local_provider(Provider::Kimi));
    }

    #[test]
    fn unknown_provider_is_not_local() {
        // Defensive: unrecognized providers default to cloud policy so they
        // get full tool access and unrestricted context. Forcing them into
        // the local allow-list would silently break any new provider added.
        assert!(!is_local_provider(Provider::Unknown));
    }

    // ── is_local_tool ────────────────────────────────────────────────────

    #[test]
    fn all_seven_local_tools_allowed() {
        for name in ["Read", "Write", "Edit", "Bash", "Search", "Find", "WebFetch"] {
            assert!(is_local_tool(name), "{name} should be local-allowed");
        }
    }

    #[test]
    fn cloud_only_tool_rejected() {
        assert!(!is_local_tool("SpawnSubagent"));
        assert!(!is_local_tool("AskUserQuestion"));
        assert!(!is_local_tool("UnknownTool"));
    }

    #[test]
    fn local_tool_check_is_case_sensitive() {
        assert!(!is_local_tool("read"));
        assert!(!is_local_tool("BASH"));
    }

    // ── truncate_rules_for_local ─────────────────────────────────────────

    #[test]
    fn truncate_empty_returns_empty() {
        assert_eq!(truncate_rules_for_local(""), "");
    }

    #[test]
    fn truncate_shorter_than_budget_unchanged() {
        let s = "short rules";
        assert_eq!(truncate_rules_for_local(s), s);
    }

    #[test]
    fn truncate_exactly_at_budget_unchanged() {
        let s = "a".repeat(LOCAL_RULES_TRUNCATION_CHARS);
        assert_eq!(truncate_rules_for_local(&s), s);
    }

    #[test]
    fn truncate_over_budget_adds_suffix() {
        let s = "a".repeat(LOCAL_RULES_TRUNCATION_CHARS + 100);
        let out = truncate_rules_for_local(&s);
        assert!(out.ends_with(LOCAL_RULES_TRUNCATION_SUFFIX));
        assert!(out.len() < s.len());
    }

    #[test]
    fn truncate_multibyte_boundary_safe() {
        // Each 'é' is 2 bytes. Build a string that forces truncation mid-codepoint
        // if we weren't being careful.
        let s = "é".repeat(LOCAL_RULES_TRUNCATION_CHARS);
        let out = truncate_rules_for_local(&s);
        // Must be valid UTF-8 (trivially true for String, but must not have
        // split a codepoint mid-byte — verify by successful construction and
        // sensible length).
        assert!(out.ends_with(LOCAL_RULES_TRUNCATION_SUFFIX));
    }

    // ── ContextPolicy ────────────────────────────────────────────────────

    #[test]
    fn policy_from_ollama_is_local() {
        assert_eq!(ContextPolicy::from_provider(Provider::Ollama), ContextPolicy::Local);
    }

    #[test]
    fn policy_from_cloud_providers_is_cloud() {
        for p in [
            Provider::Anthropic,
            Provider::OpenAi,
            Provider::OpenAiCodex,
            Provider::Google,
            Provider::MiniMax,
            Provider::Kimi,
            Provider::Unknown,
        ] {
            assert_eq!(ContextPolicy::from_provider(p), ContextPolicy::Cloud);
        }
    }

    #[test]
    fn local_policy_strips_everything() {
        let p = ContextPolicy::Local;
        assert!(p.strip_memory());
        assert!(p.strip_skill_index());
        assert!(p.strip_job_results());
        assert!(p.skip_pending_jobs_bootstrap());
        assert_eq!(p.tool_filter(), Some(LOCAL_MODEL_TOOLS));
        assert_eq!(p.rules_truncation(), Some(LOCAL_RULES_TRUNCATION_CHARS));
    }

    #[test]
    fn cloud_policy_strips_nothing() {
        let p = ContextPolicy::Cloud;
        assert!(!p.strip_memory());
        assert!(!p.strip_skill_index());
        assert!(!p.strip_job_results());
        assert!(!p.skip_pending_jobs_bootstrap());
        assert_eq!(p.tool_filter(), None);
        assert_eq!(p.rules_truncation(), None);
    }

    #[test]
    fn estimation_chars_matches_truncation_output() {
        let s = "a".repeat(LOCAL_RULES_TRUNCATION_CHARS + 1000);
        let out = truncate_rules_for_local(&s);
        // The actual output length should be <= LOCAL_RULES_ESTIMATION_CHARS,
        // so the estimator's budget is a safe upper bound.
        assert!(out.len() <= LOCAL_RULES_ESTIMATION_CHARS);
    }
}
