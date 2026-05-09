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
//! This module is a small runtime view over [`AgentExecutionSpec`], keeping
//! the existing call sites simple while avoiding scattered policy literals.
//!
//! ## Invariant
//!
//! If a session plan selects a local provider policy, the model must only see
//! and be able to execute tools in that profile's local tool policy. Schema filtering
//! alone is insufficient — the executor must also refuse off-list calls to
//! close the gap where a model hallucinates a tool name from training data or
//! memory.

use crate::shared::messages::Provider;

/// Which context-assembly policy applies to a turn.
///
/// A thin, self-documenting replacement for scattered `if is_local` branches.
/// Prefer passing [`ContextPolicy`] into helpers over a raw `bool` so the
/// semantic decision ("strip memory? include all tools?") is visible at the
/// call site.
#[derive(Clone, Debug, PartialEq)]
pub struct ContextPolicy {
    id: String,
    spec: crate::shared::profile::ContextPolicySpec,
    tool_policy: Option<crate::shared::profile::ToolPolicySpec>,
    is_local: bool,
}

impl ContextPolicy {
    /// Derive the policy from an explicit execution spec.
    #[must_use]
    pub fn from_provider_with_spec(
        p: Provider,
        spec: &crate::shared::profile::AgentExecutionSpec,
    ) -> Self {
        Self::from_entrypoint_with_spec(p, spec, "main")
    }

    /// Derive the policy from a provider type and explicit entrypoint.
    #[must_use]
    pub fn from_entrypoint_with_spec(
        p: Provider,
        spec: &crate::shared::profile::AgentExecutionSpec,
        entrypoint_id: &str,
    ) -> Self {
        let provider_is_local = provider_is_local_for_spec(p, spec);

        let entrypoint = spec
            .entrypoints
            .get(entrypoint_id)
            .expect("validated profile must define the requested entrypoint");
        let context_id = if provider_is_local {
            entrypoint
                .local_context_policy
                .as_deref()
                .unwrap_or(entrypoint.context_policy.as_str())
        } else {
            entrypoint.context_policy.as_str()
        };
        let selected_is_local = provider_is_local
            || spec
                .context_policy(context_id)
                .is_some_and(|policy| !policy.local_providers.is_empty());
        Self::from_context_id_with_spec(spec, context_id, selected_is_local)
    }

    fn from_context_id_with_spec(
        spec: &crate::shared::profile::AgentExecutionSpec,
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
            .expect("validated profile must define entrypoints.main");
        let tool_policy_id = context_spec
            .tool_policy
            .as_deref()
            .unwrap_or(entrypoint.tool_policy.as_str());
        let tool_policy = spec.tool_policy(tool_policy_id).cloned();
        Self::from_resolved_parts(context_id, context_spec, tool_policy, is_local)
    }

    /// Build a context policy from already-resolved profile policy tables.
    #[must_use]
    pub fn from_resolved_parts(
        id: impl Into<String>,
        spec: crate::shared::profile::ContextPolicySpec,
        tool_policy: Option<crate::shared::profile::ToolPolicySpec>,
        is_local: bool,
    ) -> Self {
        Self {
            id: id.into(),
            spec,
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
    pub fn spec(&self) -> &crate::shared::profile::ContextPolicySpec {
        &self.spec
    }

    /// Tool presentation policy spec, if one is attached.
    #[must_use]
    pub fn tool_policy(&self) -> Option<&crate::shared::profile::ToolPolicySpec> {
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

    /// Char budget for token estimation, including the truncation suffix.
    #[must_use]
    pub fn rules_estimation_chars(&self) -> Option<usize> {
        Some(self.rules_truncation()? + self.spec.rules_truncation_suffix.as_ref()?.len())
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
        let suffix = self.spec.rules_truncation_suffix.clone().expect(
            "profile context policy must define rulesTruncationSuffix when truncation is enabled",
        );
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
pub fn provider_is_local_for_spec(
    p: Provider,
    spec: &crate::shared::profile::AgentExecutionSpec,
) -> bool {
    let provider_id = p.as_str();
    spec.context_policies.iter().any(|(_, policy)| {
        policy
            .local_providers
            .iter()
            .any(|candidate| candidate == provider_id)
    })
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn spec() -> crate::shared::profile::AgentExecutionSpec {
        crate::shared::profile::bundled_default_execution_spec()
    }

    fn policy(provider: Provider) -> ContextPolicy {
        ContextPolicy::from_provider_with_spec(provider, &spec())
    }

    fn local_policy() -> ContextPolicy {
        policy(Provider::Ollama)
    }

    // ── provider_is_local_for_spec ──────────────────────────────────────

    #[test]
    fn ollama_is_local() {
        assert!(provider_is_local_for_spec(Provider::Ollama, &spec()));
    }

    #[test]
    fn cloud_providers_are_not_local() {
        assert!(!provider_is_local_for_spec(Provider::Anthropic, &spec()));
        assert!(!provider_is_local_for_spec(Provider::OpenAi, &spec()));
        assert!(!provider_is_local_for_spec(Provider::OpenAiCodex, &spec()));
        assert!(!provider_is_local_for_spec(Provider::Google, &spec()));
        assert!(!provider_is_local_for_spec(Provider::MiniMax, &spec()));
        assert!(!provider_is_local_for_spec(Provider::Kimi, &spec()));
    }

    #[test]
    fn unknown_provider_is_not_local() {
        // Defensive: unrecognized providers default to cloud policy so they
        // get full tool access and unrestricted context. Forcing them into
        // the local allow-list would silently break any new provider added.
        assert!(!provider_is_local_for_spec(Provider::Unknown, &spec()));
    }

    // ── local tool filter ────────────────────────────────────────────────

    #[test]
    fn local_tools_allow_file_search_web_and_questions() {
        let allowed = local_policy().tool_filter().unwrap();
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
            assert!(
                allowed.iter().any(|tool| tool == name),
                "{name} should be local-allowed"
            );
        }
    }

    #[test]
    fn cloud_only_tool_rejected() {
        let allowed = local_policy().tool_filter().unwrap();
        assert!(!allowed.iter().any(|tool| tool == "SpawnSubagent"));
        assert!(!allowed.iter().any(|tool| tool == "GetConfirmation"));
        assert!(!allowed.iter().any(|tool| tool == "UnknownTool"));
    }

    #[test]
    fn local_tool_check_is_case_sensitive() {
        let allowed = local_policy().tool_filter().unwrap();
        assert!(!allowed.iter().any(|tool| tool == "read"));
        assert!(!allowed.iter().any(|tool| tool == "BASH"));
    }

    // ── truncate_rules ──────────────────────────────────────────────────

    #[test]
    fn truncate_empty_returns_empty() {
        assert_eq!(local_policy().truncate_rules(""), "");
    }

    #[test]
    fn truncate_shorter_than_budget_unchanged() {
        let s = "short rules";
        assert_eq!(local_policy().truncate_rules(s), s);
    }

    #[test]
    fn truncate_exactly_at_budget_unchanged() {
        let p = local_policy();
        let s = "a".repeat(p.rules_truncation().unwrap());
        assert_eq!(p.truncate_rules(&s), s);
    }

    #[test]
    fn truncate_over_budget_adds_suffix() {
        let p = local_policy();
        let suffix = p.spec.rules_truncation_suffix.clone().unwrap();
        let s = "a".repeat(p.rules_truncation().unwrap() + 100);
        let out = p.truncate_rules(&s);
        assert!(out.ends_with(&suffix));
        assert!(out.len() < s.len());
    }

    #[test]
    fn truncate_multibyte_boundary_safe() {
        // Each 'é' is 2 bytes. Build a string that forces truncation mid-codepoint
        // if we weren't being careful.
        let p = local_policy();
        let suffix = p.spec.rules_truncation_suffix.clone().unwrap();
        let s = "é".repeat(p.rules_truncation().unwrap());
        let out = p.truncate_rules(&s);
        // Must be valid UTF-8 (trivially true for String, but must not have
        // split a codepoint mid-byte - verify by successful construction and
        // sensible length).
        assert!(out.ends_with(&suffix));
    }

    // ── ContextPolicy ────────────────────────────────────────────────────

    #[test]
    fn policy_from_ollama_is_local() {
        let policy = policy(Provider::Ollama);
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
            let policy = policy(p);
            assert!(!policy.is_local(), "{p:?} should use cloud policy");
            assert_eq!(policy.id(), "cloudDefault");
        }
    }

    #[test]
    fn local_policy_strips_everything() {
        let p = local_policy();
        assert!(p.strip_memory());
        assert!(p.strip_skill_index());
        assert!(p.strip_job_results());
        assert!(p.skip_pending_jobs_bootstrap());
        assert!(p.tool_filter().is_some());
        assert!(p.rules_truncation().is_some());
    }

    #[test]
    fn cloud_policy_strips_nothing() {
        let p = policy(Provider::Anthropic);
        assert!(!p.strip_memory());
        assert!(!p.strip_skill_index());
        assert!(!p.strip_job_results());
        assert!(!p.skip_pending_jobs_bootstrap());
        assert_eq!(p.tool_filter(), None);
        assert_eq!(p.rules_truncation(), None);
    }

    #[test]
    fn estimation_chars_matches_truncation_output() {
        let p = local_policy();
        let s = "a".repeat(p.rules_truncation().unwrap() + 1000);
        let out = p.truncate_rules(&s);
        // The actual output length should be <= rules_estimation_chars(),
        // so the estimator's budget is a safe upper bound.
        assert!(out.len() <= p.rules_estimation_chars().unwrap());
    }
}
