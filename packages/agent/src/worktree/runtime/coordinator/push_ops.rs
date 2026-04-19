//! Coordinator-level `push_branch`: no repo lock unless the branch is
//! protected (rare — pushing main usually happens via a CI job, not an
//! agent). Delegates to `scm::push::push_branch` and emits
//! `WorktreePushed` on success.

use std::path::{Path, PathBuf};

use serde_json::json;

use crate::core::events::{BaseEvent, TronEvent};
use crate::events::{AppendOptions, EventType};
use crate::worktree::errors::{Result, WorktreeError};
use crate::worktree::push::{self as scm_push, PushArgs};
use crate::worktree::types::PushOutput;

use super::WorktreeCoordinator;

impl WorktreeCoordinator {
    /// Push a session-owned branch to its remote.
    ///
    /// If `branch` is `None`, uses the session's current branch (resolved
    /// from the active worktree or, for passthrough sessions, from
    /// `fallback_dir` via `git symbolic-ref HEAD`).
    #[allow(clippy::too_many_arguments)]
    pub async fn push_branch(
        &self,
        session_id: &str,
        branch: Option<&str>,
        remote: &str,
        force_with_lease: bool,
        set_upstream: bool,
        dry_run: bool,
        protected_branches: &[String],
        override_protected: bool,
        fallback_dir: Option<&Path>,
    ) -> Result<PushOutput> {
        // Try the active worktree first; otherwise fall back to the
        // session's working_dir (passthrough mode). Either way we need
        // a (repo_root, current_branch) pair before calling scm::push.
        let active = self.state.lock().active_info(session_id);
        let (repo_root, current_branch): (PathBuf, String) = if let Some(info) = active {
            (info.repo_root, info.branch)
        } else if let Some(dir) = fallback_dir {
            let root_str = self
                .git
                .repo_root(dir)
                .await
                .map_err(|_| WorktreeError::NotFound { session_id: session_id.to_string() })?;
            let root = PathBuf::from(root_str);
            let cur = self
                .git
                .current_branch(&root)
                .await
                .map_err(|_| WorktreeError::NotFound { session_id: session_id.to_string() })?;
            (root, cur)
        } else {
            return Err(WorktreeError::NotFound { session_id: session_id.to_string() });
        };

        let branch_owned = branch
            .map(String::from)
            .unwrap_or_else(|| current_branch.clone());
        let args = PushArgs {
            branch: &branch_owned,
            remote,
            force_with_lease,
            set_upstream,
            dry_run,
            protected_branches,
            override_protected,
        };
        let out = scm_push::push_branch(&repo_root, &args, &self.git).await?;

        if out.success {
            let _ = self.event_store.append(&AppendOptions {
                session_id,
                event_type: EventType::WorktreePushed,
                payload: json!({
                    "branch": branch_owned,
                    "remote": remote,
                    "setUpstream": out.set_upstream,
                    "dryRun": out.dry_run,
                    "forceWithLease": force_with_lease,
                }),
                parent_id: None,
                sequence: None,
            });
            self.broadcast(TronEvent::WorktreePushed {
                base: BaseEvent::now(session_id),
                branch: branch_owned,
                remote: remote.to_string(),
                set_upstream: out.set_upstream,
                dry_run: out.dry_run,
                force_with_lease,
            });
        }
        Ok(out)
    }
}
