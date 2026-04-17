//! Per-repo async mutex for main-branch-mutating operations.
//!
//! Only `sync_main` and `finalize_session` take the lock. All other
//! per-session operations (commit, push session branch, switch) run
//! freely in parallel across sessions.
//!
//! Held as an `Arc<tokio::sync::Mutex<()>>` keyed by canonical repo_root
//! inside `CoordinatorState.repo_locks`. Two sessions against the same
//! repo share the same `Arc` → they serialize. Different repos get
//! different `Arc`s → they don't.
//!
//! Emits `repo.lock_acquired` on acquire and `repo.lock_released` on
//! guard drop so other sessions' UIs can render "Waiting for session X…"
//! and auto-proceed when the lock releases.

use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

use serde_json::json;
use tokio::sync::broadcast;
use tokio::sync::{Mutex as AsyncMutex, OwnedMutexGuard};

use crate::core::events::{BaseEvent, TronEvent};
use crate::events::{AppendOptions, EventStore, EventType};

use super::WorktreeCoordinator;

/// Which lock-worthy op is being performed. Informational.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LockedOp {
    /// `sync_main` — pulling `origin/main` into local `main`.
    SyncMain,
    /// `finalize_session` — merging session branch into `main` + rebranch.
    FinalizeSession,
}

/// Wire-label for `LockedOp` (matches `RepoLockOp` payload variants).
fn lock_op_label(op: LockedOp) -> &'static str {
    match op {
        LockedOp::SyncMain => "syncMain",
        LockedOp::FinalizeSession => "finalizeSession",
    }
}

/// Metadata bundled with the owned guard so observers can see who holds
/// the lock and for how long (useful for "Waiting for session X…" UI).
#[derive(Clone, Debug)]
pub struct LockHolder {
    /// Session that acquired the lock.
    pub session_id: String,
    /// What operation is holding it.
    pub op: LockedOp,
    /// When it was acquired.
    pub acquired_at: Instant,
}

/// Owned guard returned by `acquire_repo_lock`. Releases on drop and
/// broadcasts `RepoLockReleased` so waiting sessions auto-proceed.
pub struct LockGuard {
    _guard: OwnedMutexGuard<()>,
    /// Holder metadata — preserved for introspection / logging.
    pub holder: LockHolder,
    /// Canonicalised repo root (so the Drop emitter carries it).
    repo_root: PathBuf,
    /// Broadcast handle for `repo.lock_released` on drop.
    broadcast_tx: Option<broadcast::Sender<TronEvent>>,
    /// Event store for the persistent release record.
    event_store: Option<Arc<EventStore>>,
}

impl Drop for LockGuard {
    fn drop(&mut self) {
        let op_label = lock_op_label(self.holder.op);
        let repo_root_str = self.repo_root.to_string_lossy().to_string();

        if let Some(ref store) = self.event_store {
            let _ = store.append(&AppendOptions {
                session_id: &self.holder.session_id,
                event_type: EventType::RepoLockReleased,
                payload: json!({
                    "repoRoot": repo_root_str,
                    "sessionId": self.holder.session_id,
                    "op": op_label,
                }),
                parent_id: None,
                sequence: None,
            });
        }
        if let Some(ref tx) = self.broadcast_tx {
            let _ = tx.send(TronEvent::RepoLockReleased {
                base: BaseEvent::now(&self.holder.session_id),
                repo_root: repo_root_str,
                session_id: self.holder.session_id.clone(),
                op: op_label.to_string(),
            });
        }
    }
}

impl WorktreeCoordinator {
    /// Acquire the per-repo lock for `repo_root`, waiting if another
    /// session holds it. Returns a guard that releases on drop and
    /// broadcasts `repo.lock_released`.
    ///
    /// On acquire, broadcasts `repo.lock_acquired` so other sessions'
    /// UIs can render "Waiting for session X…".
    pub async fn acquire_repo_lock(
        &self,
        repo_root: &Path,
        session_id: &str,
        op: LockedOp,
    ) -> LockGuard {
        let mutex = self.repo_mutex(repo_root);
        let guard = mutex.lock_owned().await;
        let canonical = canonical_or_owned(repo_root);
        let op_label = lock_op_label(op);
        let repo_root_str = canonical.to_string_lossy().to_string();

        // Persist + broadcast acquisition.
        let _ = self.event_store.append(&AppendOptions {
            session_id,
            event_type: EventType::RepoLockAcquired,
            payload: json!({
                "repoRoot": repo_root_str,
                "sessionId": session_id,
                "op": op_label,
            }),
            parent_id: None,
            sequence: None,
        });
        self.broadcast(TronEvent::RepoLockAcquired {
            base: BaseEvent::now(session_id),
            repo_root: repo_root_str,
            session_id: session_id.to_string(),
            op: op_label.to_string(),
        });

        LockGuard {
            _guard: guard,
            holder: LockHolder {
                session_id: session_id.to_string(),
                op,
                acquired_at: Instant::now(),
            },
            repo_root: canonical,
            broadcast_tx: self.broadcast_tx.clone(),
            event_store: Some(self.event_store.clone()),
        }
    }

    /// Return the Arc'd mutex for `repo_root`, creating it lazily on
    /// first use. Canonicalises the path so distinct referents to the
    /// same repo serialize correctly.
    fn repo_mutex(&self, repo_root: &Path) -> Arc<AsyncMutex<()>> {
        let key = canonical_or_owned(repo_root);
        let mut state = self.state.lock();
        state
            .repo_locks
            .entry(key)
            .or_insert_with(|| Arc::new(AsyncMutex::new(())))
            .clone()
    }
}

fn canonical_or_owned(p: &Path) -> PathBuf {
    std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::events::{ConnectionConfig, EventStore, new_in_memory, run_migrations};
    use crate::worktree::types::WorktreeConfig;
    use std::sync::Arc;
    use std::time::Duration;
    use tempfile::tempdir;

    fn coord(_hint: &str) -> WorktreeCoordinator {
        let pool = new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = run_migrations(&conn).unwrap();
        }
        WorktreeCoordinator::new(WorktreeConfig::default(), Arc::new(EventStore::new(pool)))
    }

    fn coord_with_broadcast(
        _hint: &str,
    ) -> (WorktreeCoordinator, broadcast::Receiver<TronEvent>) {
        let pool = new_in_memory(&ConnectionConfig::default()).unwrap();
        {
            let conn = pool.get().unwrap();
            let _ = run_migrations(&conn).unwrap();
        }
        let (tx, rx) = broadcast::channel(64);
        let c = WorktreeCoordinator::with_broadcast(
            WorktreeConfig::default(),
            Arc::new(EventStore::new(pool)),
            tx,
        );
        (c, rx)
    }

    #[tokio::test]
    async fn lock_serializes_same_repo() {
        let coord = Arc::new(coord("same"));
        let dir = tempdir().unwrap();
        let dir_path: PathBuf = dir.path().to_path_buf();

        // Session A holds the lock for ~80ms, then drops it.
        let a_guard = coord
            .acquire_repo_lock(&dir_path, "a", LockedOp::SyncMain)
            .await;
        let a_handle = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(80)).await;
            drop(a_guard);
        });

        let start = Instant::now();
        let _b_guard = coord
            .acquire_repo_lock(&dir_path, "b", LockedOp::FinalizeSession)
            .await;
        let elapsed = start.elapsed();
        a_handle.await.unwrap();
        assert!(
            elapsed >= Duration::from_millis(70),
            "B should have waited ~80ms; elapsed={elapsed:?}"
        );
    }

    #[tokio::test]
    async fn lock_does_not_block_different_repo() {
        let coord = coord("diff");
        let dir_a = tempdir().unwrap();
        let dir_b = tempdir().unwrap();

        let _a = coord
            .acquire_repo_lock(dir_a.path(), "a", LockedOp::SyncMain)
            .await;

        // Different repo → must return immediately.
        let start = Instant::now();
        let _b = coord
            .acquire_repo_lock(dir_b.path(), "b", LockedOp::SyncMain)
            .await;
        assert!(start.elapsed() < Duration::from_millis(50));
    }

    #[tokio::test]
    async fn lock_guard_drop_releases() {
        let coord = coord("drop");
        let dir = tempdir().unwrap();

        {
            let _g = coord
                .acquire_repo_lock(dir.path(), "s", LockedOp::SyncMain)
                .await;
        } // guard dropped here

        // Immediate re-acquire must succeed.
        let start = Instant::now();
        let _g2 = coord
            .acquire_repo_lock(dir.path(), "s", LockedOp::SyncMain)
            .await;
        assert!(start.elapsed() < Duration::from_millis(20));
    }

    #[tokio::test]
    async fn lock_holder_records_metadata() {
        let coord = coord("meta");
        let dir = tempdir().unwrap();
        let g = coord
            .acquire_repo_lock(dir.path(), "sess-x", LockedOp::FinalizeSession)
            .await;
        assert_eq!(g.holder.session_id, "sess-x");
        assert_eq!(g.holder.op, LockedOp::FinalizeSession);
    }

    #[tokio::test]
    async fn lock_emits_acquired_and_released_events() {
        let (c, mut rx) = coord_with_broadcast("events");
        let dir = tempdir().unwrap();

        {
            let _g = c
                .acquire_repo_lock(dir.path(), "s1", LockedOp::SyncMain)
                .await;
            // One acquired event should be queued.
            let evt = rx.try_recv().expect("acquired event");
            match evt {
                TronEvent::RepoLockAcquired {
                    session_id, op, ..
                } => {
                    assert_eq!(session_id, "s1");
                    assert_eq!(op, "syncMain");
                }
                other => panic!("unexpected event: {other:?}"),
            }
        } // guard dropped → release event

        let evt = rx.try_recv().expect("released event");
        match evt {
            TronEvent::RepoLockReleased {
                session_id, op, ..
            } => {
                assert_eq!(session_id, "s1");
                assert_eq!(op, "syncMain");
            }
            other => panic!("unexpected event: {other:?}"),
        }
    }
}
