//! Repo-wide event payloads.
//!
//! Per-repo (not per-session) events that broadcast to every session
//! sharing a repo. Used to surface lock contention, main-branch motion,
//! and cross-session coordination in the UI.

use serde::{Deserialize, Serialize};

/// Operation that is holding the per-repo mutex.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RepoLockOp {
    /// `sync_main` — fast-forwarding local main from remote.
    SyncMain,
    /// `finalize_session` — merge + rebranch a session.
    FinalizeSession,
}

/// Emitted when a session acquires the per-repo lock. Other sessions'
/// UIs render a "Waiting for session X…" indicator.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RepoLockAcquiredPayload {
    /// Absolute path of the repo root (canonicalized).
    pub repo_root: String,
    /// Session that took the lock.
    pub session_id: String,
    /// Operation the lock is serialising.
    pub op: RepoLockOp,
}

/// Emitted when the lock is released. Listeners auto-proceed.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RepoLockReleasedPayload {
    /// Absolute path of the repo root.
    pub repo_root: String,
    /// Session that released the lock.
    pub session_id: String,
    /// Operation that completed.
    pub op: RepoLockOp,
}

/// Emitted when the main branch advances (from `sync_main` or
/// `finalize_session`). Other sessions use this to refresh divergence chips.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RepoMainAdvancedPayload {
    /// Absolute path of the repo root.
    pub repo_root: String,
    /// Previous main HEAD sha.
    pub old_head: String,
    /// New main HEAD sha.
    pub new_head: String,
    /// Session that advanced main.
    pub source_session_id: String,
    /// Cause: `"sync"` or `"finalize"`.
    pub cause: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn repo_lock_op_serde_camel_case() {
        assert_eq!(
            serde_json::to_value(RepoLockOp::SyncMain).unwrap(),
            serde_json::json!("syncMain")
        );
        assert_eq!(
            serde_json::to_value(RepoLockOp::FinalizeSession).unwrap(),
            serde_json::json!("finalizeSession")
        );
    }

    #[test]
    fn lock_acquired_camel_case_fields() {
        let p = RepoLockAcquiredPayload {
            repo_root: "/repo".into(),
            session_id: "s1".into(),
            op: RepoLockOp::SyncMain,
        };
        let v = serde_json::to_value(&p).unwrap();
        assert!(v.get("repoRoot").is_some());
        assert!(v.get("sessionId").is_some());
        assert!(v.get("op").is_some());
    }

    #[test]
    fn main_advanced_roundtrip() {
        let p = RepoMainAdvancedPayload {
            repo_root: "/repo".into(),
            old_head: "a".into(),
            new_head: "b".into(),
            source_session_id: "s1".into(),
            cause: "sync".into(),
        };
        let v = serde_json::to_value(&p).unwrap();
        let back: RepoMainAdvancedPayload = serde_json::from_value(v).unwrap();
        assert_eq!(back, p);
    }
}
