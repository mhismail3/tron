#![allow(unused_results)]
//! Top-level orchestrator — main public API for worktree isolation.
//!
//! The coordinator manages the lifecycle of worktrees across all sessions,
//! tracks active worktrees, and delegates to specialized modules.
//!
//! Key operations: `maybe_acquire`, `release`, `rename_branch`, `commit`,
//! `merge`, `get_status`, `rebuild_from_events`, `recover_orphans`.
//!
//! ## Submodules
//!
//! | Module          | Contents |
//! |-----------------|----------|
//! | `lifecycle`     | `maybe_acquire`, `release`, `effective_working_dir`, `rename_branch` |
//! | `transactions`  | `commit`, `merge` |
//! | `queries`       | `list_active`, `list_for_repo`, `get_info`, `get_status`, `list_session_branches` |
//! | `diff`          | `get_committed_diff`, `committed_diff_for_branch` |
//! | `branch`        | `delete_session_branch`, `prune_session_branches` |
//! | `recovery`      | `rebuild_from_events`, `recover_orphans` |
//! | `repo_lock`     | Per-repo async mutex for `sync_main` / `finalize_session` serialization |
//! | `sync`          | `sync_main` — lock-guarded FF of local `main` from its upstream |
//! | `finalize`      | `finalize_session` — lock-guarded merge + rebranch |
//! | `conflict_ops`  | Conflict state machine (`start_merge_keep_conflicts`, `list_conflicts`, `resolve_conflict`, `continue_merge`, `abort_merge`) |
//! | `push_ops`      | `push_branch` with protected-branch rules |
//! | `utils`         | `split_diff_by_file`, `count_diff_stats` (free functions) |

mod branch;
mod conflict_ops;
mod diff;
mod finalize;
mod lifecycle;
mod push_ops;
mod queries;
mod recovery;
mod repo_lock;
mod sync;
mod transactions;
/// Diff parsing utilities — `split_diff_by_file` and `count_diff_stats`.
pub mod utils;

pub use repo_lock::{LockGuard, LockHolder, LockedOp};
pub use utils::{split_diff_by_file, count_diff_stats};

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;

use parking_lot::Mutex;
use tokio::sync::{broadcast, Mutex as AsyncMutex};

use crate::core::events::TronEvent;
use crate::events::EventStore;

use crate::worktree::git::GitExecutor;
use crate::worktree::types::{
    PendingMergeState, WorktreeConfig, WorktreeInfo,
};

/// All active worktree state, kept coherent behind a single lock.
#[derive(Default)]
pub(super) struct CoordinatorState {
    pub(super) active_by_session: HashMap<String, WorktreeInfo>,
    pub(super) sessions_by_repo: HashMap<PathBuf, HashSet<String>>,
    /// In-flight merges/rebases keyed by `session_id`. Populated by
    /// `conflict_ops::start_merge_keep_conflicts` and cleared on
    /// `continue_merge` / `abort_merge`. Reconstructed from
    /// `.git/MERGE_HEAD` at coordinator startup (crash recovery).
    pub(super) pending_merges: HashMap<String, PendingMergeState>,
    /// Per-repo async mutex held only while `sync_main` or
    /// `finalize_session` is running in that repo. Keyed by canonical
    /// `repo_root`. All other per-session ops run freely in parallel.
    pub(super) repo_locks: HashMap<PathBuf, Arc<AsyncMutex<()>>>,
}

impl CoordinatorState {
    pub(super) fn active_info(&self, session_id: &str) -> Option<WorktreeInfo> {
        self.active_by_session.get(session_id).cloned()
    }

    pub(super) fn repo_session_count(&self, repo_root: &std::path::Path) -> usize {
        self.sessions_by_repo.get(repo_root).map_or(0, HashSet::len)
    }

    pub(super) fn track(&mut self, info: WorktreeInfo) {
        let session_id = info.session_id.clone();
        let repo_root = info.repo_root.clone();
        self.active_by_session.insert(session_id.clone(), info);
        self.sessions_by_repo
            .entry(repo_root)
            .or_default()
            .insert(session_id);
    }

    pub(super) fn untrack(&mut self, session_id: &str) -> Option<WorktreeInfo> {
        let info = self.active_by_session.remove(session_id)?;
        if let Some(sessions) = self.sessions_by_repo.get_mut(&info.repo_root) {
            sessions.remove(session_id);
            if sessions.is_empty() {
                self.sessions_by_repo.remove(&info.repo_root);
            }
        }
        Some(info)
    }

    pub(super) fn replace_active(&mut self, infos: impl IntoIterator<Item = WorktreeInfo>) {
        self.active_by_session.clear();
        self.sessions_by_repo.clear();
        for info in infos {
            self.track(info);
        }
    }

    pub(super) fn list_active(&self) -> Vec<WorktreeInfo> {
        self.active_by_session.values().cloned().collect()
    }

    pub(super) fn active_branch_snapshot(&self) -> HashMap<String, (String, Option<String>)> {
        self.active_by_session
            .iter()
            .map(|(session_id, info)| {
                (
                    info.branch.clone(),
                    (session_id.clone(), info.base_branch.clone()),
                )
            })
            .collect()
    }

    #[cfg(test)]
    fn repo_count(&self) -> usize {
        self.sessions_by_repo.len()
    }

    #[cfg(test)]
    fn repo_root_for_session(&self, session_id: &str) -> Option<PathBuf> {
        self.active_by_session
            .get(session_id)
            .map(|info| info.repo_root.clone())
    }

    #[cfg(test)]
    fn is_session_tracked_for_repo(&self, repo_root: &std::path::Path, session_id: &str) -> bool {
        self.sessions_by_repo
            .get(repo_root)
            .is_some_and(|sessions| sessions.contains(session_id))
    }
}

/// Worktree coordinator — manages worktree lifecycle across sessions.
pub struct WorktreeCoordinator {
    pub(super) config: WorktreeConfig,
    pub(super) git: GitExecutor,
    pub(super) event_store: Arc<EventStore>,
    /// Broadcast sender for real-time WebSocket events.
    pub(super) broadcast_tx: Option<broadcast::Sender<TronEvent>>,
    /// All active worktree state, kept coherent behind a single lock.
    pub(super) state: Mutex<CoordinatorState>,
}

impl WorktreeCoordinator {
    /// Create a new coordinator.
    pub fn new(config: WorktreeConfig, event_store: Arc<EventStore>) -> Self {
        let git = GitExecutor::new(config.timeout_ms);
        Self {
            config,
            git,
            event_store,
            broadcast_tx: None,
            state: Mutex::new(CoordinatorState::default()),
        }
    }

    /// Create a coordinator with WebSocket broadcast support.
    pub fn with_broadcast(
        config: WorktreeConfig,
        event_store: Arc<EventStore>,
        tx: broadcast::Sender<TronEvent>,
    ) -> Self {
        let git = GitExecutor::new(config.timeout_ms);
        Self {
            config,
            git,
            event_store,
            broadcast_tx: Some(tx),
            state: Mutex::new(CoordinatorState::default()),
        }
    }

    /// Broadcast a `TronEvent` to WebSocket clients (non-blocking, best-effort).
    pub(super) fn broadcast(&self, event: TronEvent) {
        if let Some(ref tx) = self.broadcast_tx {
            let _ = tx.send(event);
        }
    }

    /// Get the configuration.
    pub fn config(&self) -> &WorktreeConfig {
        &self.config
    }

    /// Resolve the git repository root for a given path.
    pub async fn resolve_repo_root(&self, path: &std::path::Path) -> crate::worktree::errors::Result<String> {
        self.git.repo_root(path).await
    }

    #[cfg(test)]
    fn tracked_repo_count(&self) -> usize {
        self.state.lock().repo_count()
    }

    #[cfg(test)]
    fn tracked_repo_root_for_session(&self, session_id: &str) -> Option<PathBuf> {
        self.state.lock().repo_root_for_session(session_id)
    }

    #[cfg(test)]
    fn tracked_session_count_for_repo(&self, repo_root: &std::path::Path) -> usize {
        self.state.lock().repo_session_count(repo_root)
    }

    #[cfg(test)]
    fn is_session_tracked_for_repo(&self, repo_root: &std::path::Path, session_id: &str) -> bool {
        self.state
            .lock()
            .is_session_tracked_for_repo(repo_root, session_id)
    }
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;
