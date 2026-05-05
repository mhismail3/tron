//! Profile-backed local-model context policy.
//!
//! Local models run with a smaller context window and a stripped-down system
//! prompt to minimize time-to-first-token. The active profile owns every
//! decision that differs from cloud behavior:
//!
//! - Which tools are exposed (and executable) on local models
//! - How much of the rules content is included before truncation
//! - Which provider types are considered "local"
//!
//! This module is a small runtime adapter over [`AgentExecutionSpec`], keeping
//! the existing call sites simple while avoiding scattered policy literals.
//!
//! ## Invariant
//!
//! If `is_local_provider(p)` is true, the model must only see and be able to
//! execute tools in the active profile's local tool policy. Schema filtering
//! alone is insufficient — the executor must also refuse off-list calls to
//! close the gap where a model hallucinates a tool name from training data or
//! memory.

use crate::core::messages::Provider;

const FALLBACK_LOCAL_TOOLS: &[&str] = &[
    "Read",
    "Write",
    "Edit",
    "Bash",
    "Search",
    "Find",
    "WebFetch",
    "AskUserQuestion",
];
const FALLBACK_RULES_TRUNCATION_CHARS: usize = 500;
const FALLBACK_RULES_TRUNCATION_SUFFIX: &str =
    "\n\n[Truncated - full rules available via Read tool]";

/// Tool names exposed to local models.
#[must_use]
pub fn local_model_tools() -> Vec<String> {
    ContextPolicy::local_default()
        .tool_filter()
        .unwrap_or_else(|| {
            FALLBACK_LOCAL_TOOLS
                .iter()
                .map(|tool| (*tool).to_string())
                .collect()
        })
}

/// Rules truncation budget.
#[must_use]
pub fn rules_truncation_chars() -> usize {
    ContextPolicy::local_default()
        .rules_truncation()
        .unwrap_or(FALLBACK_RULES_TRUNCATION_CHARS)
}

/// Rules truncation suffix.
#[must_use]
pub fn rules_truncation_suffix() -> String {
    ContextPolicy::local_default()
        .spec
        .rules_truncation_suffix
        .unwrap_or_else(|| FALLBACK_RULES_TRUNCATION_SUFFIX.to_string())
}

/// Char budget for token estimation.
#[must_use]
pub fn rules_estimation_chars() -> usize {
    rules_truncation_chars() + rules_truncation_suffix().len()
}

/// Which context-assembly policy applies to a turn.
///
/// A thin, self-documenting replacement for scattered `if is_local` branches.
/// Prefer passing [`ContextPolicy`] into helpers over a raw `bool` so the
/// semantic decision ("strip memory? include all tools?") is visible at the
/// call site.
#[derive(Clone, Debug, PartialEq)]
pub struct ContextPolicy {
    id: String,
    spec: crate::core::profile::ContextPolicySpec,
    tool_policy: Option<crate::core::profile::ToolPolicySpec>,
    is_local: bool,
}

impl ContextPolicy {
    /// Derive the policy from a provider type.
    #[must_use]
    pub fn from_provider(p: Provider) -> Self {
        let spec = crate::core::profile::active_execution_spec_or_default();
        Self::from_provider_with_spec(p, &spec)
    }

    /// Derive the policy from an explicit execution spec.
    #[must_use]
    pub fn from_provider_with_spec(
        p: Provider,
        spec: &crate::core::profile::AgentExecutionSpec,
    ) -> Self {
        Self::from_entrypoint_with_spec(p, spec, "main")
    }

    /// Derive the policy from a provider type and explicit entrypoint.
    #[must_use]
    pub fn from_entrypoint_with_spec(
        p: Provider,
        spec: &crate::core::profile::AgentExecutionSpec,
        entrypoint_id: &str,
    ) -> Self {
        let provider_id = p.as_str();
        let provider_is_local = spec.context_policies.iter().any(|(_, policy)| {
            policy
                .local_providers
                .iter()
                .any(|candidate| candidate == provider_id)
        });

        let entrypoint = spec
            .entrypoints
            .get(entrypoint_id)
            .or_else(|| spec.entrypoints.get("main"))
            .or_else(|| spec.entrypoints.get("chat"));
        let context_id = if provider_is_local {
            entrypoint
                .and_then(|entrypoint| entrypoint.local_context_policy.as_deref())
                .or_else(|| entrypoint.map(|entrypoint| entrypoint.context_policy.as_str()))
        } else {
            entrypoint.map(|entrypoint| entrypoint.context_policy.as_str())
        }
        .or_else(|| spec.context_policies.keys().next().map(String::as_str))
        .expect("bundled default profile must define a context policy");
        let selected_is_local = provider_is_local
            || spec
                .context_policy(context_id)
                .is_some_and(|policy| !policy.local_providers.is_empty());
        Self::from_context_id_with_spec(spec, context_id, selected_is_local)
    }

    /// The default local context policy from the active profile.
    #[must_use]
    pub fn local_default() -> Self {
        let spec = crate::core::profile::active_execution_spec_or_default();
        let (id, _) = spec
            .context_policies
            .iter()
            .find(|(_, policy)| !policy.local_providers.is_empty())
            .expect("bundled default profile must define a local context policy");
        Self::from_context_id_with_spec(&spec, id, true)
    }

    /// The default cloud/chat context policy from the active profile.
    #[must_use]
    pub fn cloud_default() -> Self {
        let spec = crate::core::profile::active_execution_spec_or_default();
        let entrypoint = spec
            .entrypoints
            .get("main")
            .or_else(|| spec.entrypoints.get("chat"));
        let context_id = entrypoint
            .map(|entrypoint| entrypoint.context_policy.as_str())
            .or_else(|| spec.context_policies.keys().next().map(String::as_str))
            .expect("bundled default profile must define a context policy");
        Self::from_context_id_with_spec(&spec, context_id, false)
    }

    fn from_context_id_with_spec(
        spec: &crate::core::profile::AgentExecutionSpec,
        context_id: &str,
        is_local: bool,
    ) -> Self {
        let context_spec = spec
            .context_policy(context_id)
            .cloned()
            .expect("validated profile must define referenced context policy");
        let entrypoint = spec
            .entrypoints
            .get("main")
            .or_else(|| spec.entrypoints.get("chat"));
        let tool_policy_id = context_spec
            .tool_policy
            .as_deref()
            .or_else(|| entrypoint.map(|entrypoint| entrypoint.tool_policy.as_str()));
        let tool_policy = tool_policy_id.and_then(|id| spec.tool_policy(id).cloned());
        Self {
            id: context_id.to_string(),
            spec: context_spec,
            tool_policy,
            is_local,
        }
    }

    /// Context policy id from the active profile.
    #[must_use]
    pub fn id(&self) -> &str {
        &self.id
    }

    /// Whether this policy is selected because the provider matched
    /// `localProviders`.
    #[must_use]
    pub fn is_local(&self) -> bool {
        self.is_local
    }

    /// Tool policy id for this context policy.
    #[must_use]
    pub fn tool_policy_id(&self) -> Option<&str> {
        self.spec.tool_policy.as_deref()
    }

    /// Cache-agnostic context policy spec.
    #[must_use]
    pub fn spec(&self) -> &crate::core::profile::ContextPolicySpec {
        &self.spec
    }

    /// Tool presentation policy spec, if one is attached.
    #[must_use]
    pub fn tool_policy(&self) -> Option<&crate::core::profile::ToolPolicySpec> {
        self.tool_policy.as_ref()
    }

    /// Does this policy strip `memory_content`?
    #[must_use]
    pub fn strip_memory(&self) -> bool {
        self.spec.strip_memory
    }

    /// Does this policy strip the skill index block?
    #[must_use]
    pub fn strip_skill_index(&self) -> bool {
        self.spec.strip_skill_index
    }

    /// Does this policy strip the job-results block?
    #[must_use]
    pub fn strip_job_results(&self) -> bool {
        self.spec.strip_job_results
    }

    /// Does this policy skip upstream DB queries for pending subagent/process
    /// /user-job results during prompt bootstrap?
    #[must_use]
    pub fn skip_pending_jobs_bootstrap(&self) -> bool {
        self.spec.skip_pending_jobs_bootstrap
    }

    /// The allow-list of tool names, or `None` if all registered tools apply.
    #[must_use]
    pub fn tool_filter(&self) -> Option<Vec<String>> {
        self.tool_policy
            .as_ref()
            .and_then(|policy| policy.allowed_tools.clone())
    }

    /// The rules truncation budget (chars), or `None` for no truncation.
    #[must_use]
    pub fn rules_truncation(&self) -> Option<usize> {
        self.spec.rules_truncation_chars
    }

    /// Truncate rules according to this policy.
    #[must_use]
    pub fn truncate_rules(&self, rules: &str) -> String {
        let Some(budget) = self.rules_truncation() else {
            return rules.to_string();
        };
        if rules.len() <= budget {
            return rules.to_string();
        }
        let suffix = self
            .spec
            .rules_truncation_suffix
            .clone()
            .unwrap_or_else(|| FALLBACK_RULES_TRUNCATION_SUFFIX.to_string());
        let cut = rules
            .char_indices()
            .take_while(|&(i, _)| i <= budget)
            .last()
            .map_or(0, |(i, _)| i);
        format!("{}{}", &rules[..cut], suffix)
    }
}

/// Is this provider a local model (stripped context, small window)?
#[must_use]
pub fn is_local_provider(p: Provider) -> bool {
    ContextPolicy::from_provider(p).is_local()
}

/// Is this tool permitted for local models?
#[must_use]
pub fn is_local_tool(name: &str) -> bool {
    local_model_tools().iter().any(|tool| tool == name)
}

/// Truncate `rules` for local display.
///
/// Safe at multi-byte char boundaries. Returns the original string unchanged if
/// it already fits within the active profile's local truncation budget.
#[must_use]
pub fn truncate_rules_for_local(rules: &str) -> String {
    let budget = rules_truncation_chars();
    if rules.len() <= budget {
        return rules.to_string();
    }
    let cut = rules
        .char_indices()
        .take_while(|&(i, _)| i <= budget)
        .last()
        .map_or(0, |(i, _)| i);
    format!("{}{}", &rules[..cut], rules_truncation_suffix())
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
    fn local_tools_allow_file_search_web_and_questions() {
        for name in [
            "Read",
            "Write",
            "Edit",
            "Bash",
            "Search",
            "Find",
            "WebFetch",
            "AskUserQuestion",
        ] {
            assert!(is_local_tool(name), "{name} should be local-allowed");
        }
    }

    #[test]
    fn cloud_only_tool_rejected() {
        assert!(!is_local_tool("SpawnSubagent"));
        assert!(!is_local_tool("GetConfirmation"));
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
        let s = "a".repeat(rules_truncation_chars());
        assert_eq!(truncate_rules_for_local(&s), s);
    }

    #[test]
    fn truncate_over_budget_adds_suffix() {
        let s = "a".repeat(rules_truncation_chars() + 100);
        let out = truncate_rules_for_local(&s);
        assert!(out.ends_with(&rules_truncation_suffix()));
        assert!(out.len() < s.len());
    }

    #[test]
    fn truncate_multibyte_boundary_safe() {
        // Each 'é' is 2 bytes. Build a string that forces truncation mid-codepoint
        // if we weren't being careful.
        let s = "é".repeat(rules_truncation_chars());
        let out = truncate_rules_for_local(&s);
        // Must be valid UTF-8 (trivially true for String, but must not have
        // split a codepoint mid-byte - verify by successful construction and
        // sensible length).
        assert!(out.ends_with(&rules_truncation_suffix()));
    }

    // ── ContextPolicy ────────────────────────────────────────────────────

    #[test]
    fn policy_from_ollama_is_local() {
        let policy = ContextPolicy::from_provider(Provider::Ollama);
        assert!(policy.is_local());
        assert_eq!(policy.id(), "localDefault");
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
            let policy = ContextPolicy::from_provider(p);
            assert!(!policy.is_local(), "{p:?} should use cloud policy");
            assert_eq!(policy.id(), "cloudDefault");
        }
    }

    #[test]
    fn local_policy_strips_everything() {
        let p = ContextPolicy::local_default();
        assert!(p.strip_memory());
        assert!(p.strip_skill_index());
        assert!(p.strip_job_results());
        assert!(p.skip_pending_jobs_bootstrap());
        assert_eq!(p.tool_filter(), Some(local_model_tools()));
        assert_eq!(p.rules_truncation(), Some(rules_truncation_chars()));
    }

    #[test]
    fn cloud_policy_strips_nothing() {
        let p = ContextPolicy::cloud_default();
        assert!(!p.strip_memory());
        assert!(!p.strip_skill_index());
        assert!(!p.strip_job_results());
        assert!(!p.skip_pending_jobs_bootstrap());
        assert_eq!(p.tool_filter(), None);
        assert_eq!(p.rules_truncation(), None);
    }

    #[test]
    fn estimation_chars_matches_truncation_output() {
        let s = "a".repeat(rules_truncation_chars() + 1000);
        let out = truncate_rules_for_local(&s);
        // The actual output length should be <= rules_estimation_chars(),
        // so the estimator's budget is a safe upper bound.
        assert!(out.len() <= rules_estimation_chars());
    }
}
