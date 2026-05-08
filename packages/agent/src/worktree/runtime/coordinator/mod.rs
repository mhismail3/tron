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
//! | `transactions`  | `commit` (accepts `CommitOptions` for amend / signoff / stage-all), `merge` |
//! | `queries`       | `list_active`, `list_for_repo`, `get_info`, `get_status`, `list_session_branches` |
//! | `diff`          | `get_committed_diff`, `committed_diff_for_branch` |
//! | `branch`        | `delete_session_branch`, `prune_session_branches` — both gated by `preflight_delete_branch`, which refuses branches currently checked out in the main worktree so `remove_worktree_if_present` can never fall through to `remove_dir_all(repo_root)` |
//! | `recovery`      | `rebuild_from_events`, `recover_orphans` |
//! | `repo_lock`     | Per-repo async mutex for `sync_main` / `finalize_session` serialization |
//! | `sync`          | `sync_main` — lock-guarded FF of local `main` from its upstream |
//! | `finalize`      | `finalize_session` — lock-guarded merge + rebranch |
//! | `rebase_on_main`| `rebase_on_main` — lock-guarded inverse (pulls main forward into the session branch, with dirty-tree auto-stash carry-over) |
//! | `conflict_ops`  | Conflict state machine (`start_merge_keep_conflicts`, `list_conflicts`, `resolve_conflict`, `continue_merge`, `abort_merge`) with origin-aware stash pop |
//! | `push_ops`      | `push_branch` with protected-branch rules |
//! | `utils`         | `split_diff_by_file`, `count_diff_stats` (free functions) |
//!
//! ## Stash carry-over invariant
//!
//! When `rebase_on_main` is called with a dirty worktree it auto-stashes
//! and writes a sidecar JSON file at `.git/tron-rebase-stash-<sid>.json`.
//! The sidecar exists iff `PendingMergeState.auto_stash_ref.is_some()`
//! for that session. Sidecar is removed on clean completion AND on
//! abort; crash recovery reads it via `recovery::rebuild_pending_merges`
//! to reattach the stash to the reconstructed merge state.
//!
//! ## Pending-merge origin
//!
//! Every `PendingMergeState` carries a `MergeOrigin`:
//!
//! | Origin        | Trigger                              | `continue_merge`                      | `abort_merge`                                |
//! |---------------|--------------------------------------|---------------------------------------|----------------------------------------------|
//! | `Finalize`    | `worktree.startMerge`                | `git merge/rebase/squash --continue`  | `git merge/rebase --abort`                   |
//! | `RebaseOnMain`| `worktree.rebaseOnMain`              | `git rebase --continue` + pop stash   | `git rebase --abort` + pop stash (restores dirty state) |
//! | `StashPop`    | post-rebase `git stash pop` conflict | `git stash drop <ref>`                | `git reset --hard HEAD` (stash kept on stack) |
//!
//! `StashPop` is synthesised by `conflict_ops::handle_post_stash_pop`
//! when a `git stash pop` after a rebase produces unmerged paths.
//! There's no on-disk `.git/MERGE_HEAD` / `.git/rebase-merge` for the
//! `StashPop` origin — conflicts live purely in the index. The shared
//! `listConflicts` / `resolveConflict` / `continueMerge` / `abortMerge`
//! capability surface works uniformly across all three origins; only the
//! continue/abort side effects differ.
//!
//! `merge_context` routes the working directory by origin:
//! - `Finalize` → `info.repo_root`
//! - `RebaseOnMain` / `StashPop` → `info.worktree_path`

mod branch;
mod conflict_ops;
mod diff;
mod finalize;
mod lifecycle;
mod push_ops;
mod queries;
mod rebase_on_main;
mod recovery;
mod repo_lock;
mod sync;
mod transactions;
/// Diff parsing utilities — `split_diff_by_file` and `count_diff_stats`.
pub mod utils;

pub use repo_lock::{LockGuard, LockHolder, LockedOp};
pub use utils::{count_diff_stats, split_diff_by_file};

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Weak};

use parking_lot::Mutex;
use tokio::sync::{Mutex as AsyncMutex, broadcast};

use crate::core::events::TronEvent;
use crate::events::EventStore;

use crate::worktree::git::GitExecutor;
use crate::worktree::types::{PendingMergeState, WorktreeConfig, WorktreeInfo};

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
    /// Per-main-repo async mutex serializing `git worktree add` calls
    /// against the same main repository. Different from `repo_locks`:
    /// this one is held *only* for the duration of the git command, is
    /// never broadcast, and guards against the macOS-specific metadata
    /// race where two concurrent `worktree add` invocations see each
    /// other's in-progress `.git/worktrees/<id>/commondir` as missing.
    /// Keyed by canonical main `repo_root` so parallel creates for the
    /// same repo serialize, while different repos still parallelize.
    pub(super) worktree_add_locks: HashMap<PathBuf, Arc<AsyncMutex<()>>>,
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
///
/// INVARIANT: [`Self::maybe_acquire_with_override`]'s `use_worktree_override`
/// takes precedence over the global [`crate::settings::types::IsolationMode`]
/// when set. `Some(true)` forces isolation in a git repo; `Some(false)` forces
/// passthrough; `None` defers to the global mode (the legacy behavior).
/// The override is read from `sessions.use_worktree` (set at session.create
/// time, immutable afterward).
pub struct WorktreeCoordinator {
    pub(super) config: WorktreeConfig,
    pub(super) git: GitExecutor,
    pub(super) event_store: Arc<EventStore>,
    /// Broadcast sender for real-time WebSocket events.
    pub(super) broadcast_tx: Option<broadcast::Sender<TronEvent>>,
    /// All active worktree state, kept coherent behind a single lock.
    pub(super) state: Mutex<CoordinatorState>,
    /// Per-session async mutexes used to serialize `maybe_acquire_with_override`
    /// calls for the same session. Concurrent prompts on the same session_id
    /// (double-tap, reconnect-mid-send, etc.) would otherwise all pass the
    /// cache check and each try to create a worktree. Weak refs so entries
    /// drop automatically once no call is holding the lock.
    pub(super) session_acquire_locks: Mutex<HashMap<String, Weak<AsyncMutex<()>>>>,
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
            session_acquire_locks: Mutex::new(HashMap::new()),
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
            session_acquire_locks: Mutex::new(HashMap::new()),
        }
    }

    /// Return the per-main-repo async mutex used to serialize `git worktree
    /// add` calls. Creates the entry lazily on first use. Canonicalises the
    /// path so distinct referents to the same repo share the same mutex.
    ///
    /// Held across a single `git worktree add` invocation. Different repos
    /// get different mutexes and never block each other.
    pub(super) fn worktree_add_mutex(&self, repo_root: &std::path::Path) -> Arc<AsyncMutex<()>> {
        let key = std::fs::canonicalize(repo_root).unwrap_or_else(|_| repo_root.to_path_buf());
        let mut state = self.state.lock();
        state
            .worktree_add_locks
            .entry(key)
            .or_insert_with(|| Arc::new(AsyncMutex::new(())))
            .clone()
    }

    /// Return the per-session async mutex for `session_id`, creating it lazily.
    ///
    /// Used by [`Self::maybe_acquire_with_override`] to serialize concurrent
    /// acquire attempts for the same session. Entries are stored as `Weak`,
    /// so they are garbage-collected automatically once no caller is holding
    /// the returned `Arc`.
    pub(super) fn session_acquire_mutex(&self, session_id: &str) -> Arc<AsyncMutex<()>> {
        let mut locks = self.session_acquire_locks.lock();

        // Opportunistic GC: if the map grows past a threshold, drop dead weaks.
        if locks.len() > 128 {
            locks.retain(|_, weak| weak.strong_count() > 0);
        }

        if let Some(existing) = locks.get(session_id).and_then(Weak::upgrade) {
            return existing;
        }

        let lock = Arc::new(AsyncMutex::new(()));
        let _ = locks.insert(session_id.to_string(), Arc::downgrade(&lock));
        lock
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
    pub async fn resolve_repo_root(
        &self,
        path: &std::path::Path,
    ) -> crate::worktree::errors::Result<String> {
        self.git.repo_root(path).await
    }

    /// Quick check: is the given path inside a git repository?
    /// Used by the iOS new-session sheet to decide whether to show the
    /// per-session worktree-isolation toggle.
    pub async fn is_git_repo(&self, path: &std::path::Path) -> bool {
        self.git.is_git_repo(path).await
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
