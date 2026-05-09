//! Git workflow settings — user-tunable knobs for the per-session git
//! workflow suite (sync, finalize, switch, push, conflict resolution).
//!
//! Persisted under `profiles/user/profile.toml > [settings.git]`. Every field has a 1:1 iOS
//! settings control (see `GitWorkflowSettingsPage.swift` in the iOS app).

use serde::{Deserialize, Serialize};

/// Default branches that require `override_protected` to push to.
fn default_protected_branches() -> Vec<String> {
    vec!["main".into(), "master".into(), "develop".into()]
}

const fn default_op_timeout_network_ms() -> u64 {
    60_000
}
const fn default_op_timeout_local_ms() -> u64 {
    30_000
}
const fn default_crash_recovery_abort_timeout_ms() -> u64 {
    30 * 60 * 1_000
}
const fn default_true() -> bool {
    true
}

/// Policy for what happens to the old session branch on `finalize_session`.
///
/// Default: `Keep` — users rarely want their branch history vaporised even
/// after a successful merge.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SessionBranchPolicy {
    /// Keep the source branch after finalize (default).
    #[default]
    Keep,
    /// Delete the source branch after a successful finalize.
    DeleteOnFinalize,
}

/// Preferred merge strategy for finalize/merge operations.
///
/// Mirrors `crate::domains::worktree::types::MergeStrategy` but lives here so the
/// iOS UI can bind directly to the user-facing setting without pulling
/// the worktree crate.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum MergeStrategyPref {
    /// `git merge --no-ff` (default).
    #[default]
    Merge,
    /// `git rebase` + FF.
    Rebase,
    /// `git merge --squash` + commit.
    Squash,
}

/// Git workflow settings.
///
/// Settings parity: every field here has a matching control in the iOS
/// app's `GitWorkflowSettingsPage`. When changing defaults here, update
/// the iOS side in the same commit.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct GitWorkflowSettings {
    /// Override the auto-detected target branch for sync/finalize. `None`
    /// falls back to `init.defaultBranch` → `main` → `master` probing.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target_branch: Option<String>,

    /// Branches that require `override_protected` for push.
    pub protected_branches: Vec<String>,

    /// Keep or delete the source branch on finalize.
    pub session_branch_policy: SessionBranchPolicy,

    /// Default merge strategy when the user doesn't specify one.
    pub merge_strategy: MergeStrategyPref,

    /// Pass `-u` on first push automatically.
    pub auto_set_upstream: bool,

    /// How long (ms) a pending merge can sit after a crash before the
    /// coordinator auto-aborts it. 30min by default.
    pub crash_recovery_abort_timeout_ms: u64,

    /// Per-op timeout for network operations (fetch, push).
    pub op_timeout_network_ms: u64,

    /// Per-op timeout for local operations (merge, switch, finalize).
    pub op_timeout_local_ms: u64,

    /// Whether to spawn the conflict-resolver subagent automatically on
    /// merge conflicts. Only affects the "tap to start resolver" flow —
    /// the user still has to explicitly authorise it.
    pub subagent_conflict_resolution_enabled: bool,
}

impl Default for GitWorkflowSettings {
    fn default() -> Self {
        Self {
            target_branch: None,
            protected_branches: default_protected_branches(),
            session_branch_policy: SessionBranchPolicy::Keep,
            merge_strategy: MergeStrategyPref::Merge,
            auto_set_upstream: default_true(),
            crash_recovery_abort_timeout_ms: default_crash_recovery_abort_timeout_ms(),
            op_timeout_network_ms: default_op_timeout_network_ms(),
            op_timeout_local_ms: default_op_timeout_local_ms(),
            subagent_conflict_resolution_enabled: default_true(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_safe() {
        let g = GitWorkflowSettings::default();
        assert!(g.target_branch.is_none());
        assert!(g.protected_branches.contains(&"main".to_string()));
        assert!(g.protected_branches.contains(&"master".to_string()));
        assert!(g.protected_branches.contains(&"develop".to_string()));
        assert_eq!(g.session_branch_policy, SessionBranchPolicy::Keep);
        assert_eq!(g.merge_strategy, MergeStrategyPref::Merge);
        assert!(g.auto_set_upstream);
        assert_eq!(g.crash_recovery_abort_timeout_ms, 30 * 60 * 1000);
        assert_eq!(g.op_timeout_network_ms, 60_000);
        assert_eq!(g.op_timeout_local_ms, 30_000);
        assert!(g.subagent_conflict_resolution_enabled);
    }

    #[test]
    fn serde_camel_case_roundtrip() {
        let g = GitWorkflowSettings::default();
        let v = serde_json::to_value(&g).unwrap();
        assert!(v.get("protectedBranches").is_some());
        assert!(v.get("sessionBranchPolicy").is_some());
        assert!(v.get("mergeStrategy").is_some());
        assert!(v.get("autoSetUpstream").is_some());
        assert!(v.get("crashRecoveryAbortTimeoutMs").is_some());
        assert!(v.get("opTimeoutNetworkMs").is_some());
        assert!(v.get("opTimeoutLocalMs").is_some());
        assert!(v.get("subagentConflictResolutionEnabled").is_some());

        let back: GitWorkflowSettings = serde_json::from_value(v).unwrap();
        assert_eq!(back.session_branch_policy, g.session_branch_policy);
        assert_eq!(back.merge_strategy, g.merge_strategy);
    }

    #[test]
    fn session_branch_policy_serializes_camel_case() {
        let v = serde_json::to_value(SessionBranchPolicy::DeleteOnFinalize).unwrap();
        assert_eq!(v, serde_json::json!("deleteOnFinalize"));
        let v = serde_json::to_value(SessionBranchPolicy::Keep).unwrap();
        assert_eq!(v, serde_json::json!("keep"));
    }

    #[test]
    fn merge_strategy_pref_serializes_camel_case() {
        assert_eq!(
            serde_json::to_value(MergeStrategyPref::Merge).unwrap(),
            serde_json::json!("merge")
        );
        assert_eq!(
            serde_json::to_value(MergeStrategyPref::Rebase).unwrap(),
            serde_json::json!("rebase")
        );
        assert_eq!(
            serde_json::to_value(MergeStrategyPref::Squash).unwrap(),
            serde_json::json!("squash")
        );
    }

    #[test]
    fn partial_json_keeps_other_defaults() {
        let json = serde_json::json!({
            "autoSetUpstream": false,
            "opTimeoutNetworkMs": 120_000u64
        });
        let g: GitWorkflowSettings = serde_json::from_value(json).unwrap();
        assert!(!g.auto_set_upstream);
        assert_eq!(g.op_timeout_network_ms, 120_000);
        // Everything else falls back to default.
        assert_eq!(g.op_timeout_local_ms, 30_000);
        assert_eq!(g.session_branch_policy, SessionBranchPolicy::Keep);
    }
}
