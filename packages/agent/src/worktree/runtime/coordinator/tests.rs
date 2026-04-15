use super::*;
use tempfile::tempdir;
use crate::events::{ConnectionConfig, new_in_memory, run_migrations};
use crate::worktree::git::GitExecutor;
use crate::worktree::types::{
    AcquireResult, DeferralReason, WorktreeConfig,
};

fn make_store() -> Arc<EventStore> {
    let pool = new_in_memory(&ConnectionConfig::default()).unwrap();
    {
        let conn = pool.get().unwrap();
        let _ = run_migrations(&conn).unwrap();
    }
    Arc::new(EventStore::new(pool))
}

async fn init_repo(dir: &std::path::Path) {
    run_cmd(dir, &["git", "init"]).await;
    run_cmd(dir, &["git", "config", "user.email", "test@test.com"]).await;
    run_cmd(dir, &["git", "config", "user.name", "Test"]).await;
    std::fs::write(dir.join("README.md"), "# test").unwrap();
    run_cmd(dir, &["git", "add", "-A"]).await;
    run_cmd(dir, &["git", "commit", "-m", "init"]).await;
}

async fn run_cmd(dir: &std::path::Path, args: &[&str]) {
    let status = tokio::process::Command::new(args[0])
        .args(&args[1..])
        .current_dir(dir)
        .output()
        .await
        .unwrap();
    assert!(
        status.status.success(),
        "cmd {:?} failed: {}",
        args,
        String::from_utf8_lossy(&status.stderr)
    );
}

#[tokio::test]
async fn acquire_in_git_repo() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let _ = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("test"),
            None,
            None,
            None,
        )
        .unwrap();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let result = coord.maybe_acquire("test-sess", dir.path()).await.unwrap();
    assert!(matches!(result, AcquireResult::Acquired(_)));

    if let AcquireResult::Acquired(info) = result {
        assert!(info.worktree_path.exists());
        assert!(info.branch.starts_with("session/"));
    }
}

#[tokio::test]
async fn acquire_non_git_passthrough() {
    let dir = tempdir().unwrap();
    let store = make_store();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let result = coord.maybe_acquire("test-sess", dir.path()).await.unwrap();
    assert!(matches!(result, AcquireResult::Passthrough));
}

#[tokio::test]
async fn acquire_idempotent() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let _ = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("test"),
            None,
            None,
            None,
        )
        .unwrap();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let r1 = coord.maybe_acquire("test-idem", dir.path()).await.unwrap();
    let r2 = coord.maybe_acquire("test-idem", dir.path()).await.unwrap();

    if let (AcquireResult::Acquired(i1), AcquireResult::Acquired(i2)) = (&r1, &r2) {
        assert_eq!(i1.worktree_path, i2.worktree_path);
    } else {
        panic!("expected both to be Acquired");
    }
}

#[tokio::test]
async fn acquire_mode_never() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let config = WorktreeConfig {
        mode: crate::settings::types::IsolationMode::Never,
        ..WorktreeConfig::default()
    };
    let coord = WorktreeCoordinator::new(config, store);

    let result = coord.maybe_acquire("test-never", dir.path()).await.unwrap();
    assert!(matches!(result, AcquireResult::Passthrough));
}

#[tokio::test]
async fn release_unknown_session() {
    let store = make_store();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);
    coord.release("nonexistent").await.unwrap(); // Should not error
}

#[tokio::test]
async fn full_lifecycle() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let session = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("test"),
            None,
            None,
            None,
        )
        .unwrap();
    let sid = &session.session.id;
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    // Acquire
    let result = coord.maybe_acquire(sid, dir.path()).await.unwrap();
    let info = match result {
        AcquireResult::Acquired(i) => i,
        other => panic!("expected Acquired, got {other:?}"),
    };

    assert!(coord.effective_working_dir(sid).is_some());
    assert_eq!(coord.list_active().len(), 1);

    // Write a file in worktree
    std::fs::write(info.worktree_path.join("work.txt"), "progress").unwrap();

    // Commit
    let commit_result = coord.commit(sid, "wip").await.unwrap();
    assert!(commit_result.is_some());
    let cr = commit_result.unwrap();
    assert_eq!(cr.commit_hash.len(), 40);
    assert!(!cr.files_changed.is_empty());

    // Release
    coord.release(sid).await.unwrap();
    assert!(coord.effective_working_dir(sid).is_none());
    assert!(coord.list_active().is_empty());
}

#[tokio::test]
async fn get_status_returns_enriched_info() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let session = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("test"),
            None,
            None,
            None,
        )
        .unwrap();
    let sid = &session.session.id;
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    // Acquire
    let result = coord.maybe_acquire(sid, dir.path()).await.unwrap();
    let info = match result {
        AcquireResult::Acquired(i) => i,
        other => panic!("expected Acquired, got {other:?}"),
    };

    // Initially: no changes, no commits
    let status = coord.get_status(sid).await.unwrap().unwrap();
    assert!(status.isolated);
    assert!(!status.has_uncommitted_changes);
    assert_eq!(status.commit_count, 0);
    assert_eq!(status.branch, info.branch);

    // Write a file → uncommitted changes
    std::fs::write(info.worktree_path.join("work.txt"), "wip").unwrap();
    let status = coord.get_status(sid).await.unwrap().unwrap();
    assert!(status.has_uncommitted_changes);
    assert_eq!(status.commit_count, 0);

    // Commit → committed, no uncommitted
    coord.commit(sid, "first commit").await.unwrap();
    let status = coord.get_status(sid).await.unwrap().unwrap();
    assert!(!status.has_uncommitted_changes);
    assert_eq!(status.commit_count, 1);

    // Second commit
    std::fs::write(info.worktree_path.join("more.txt"), "more").unwrap();
    coord.commit(sid, "second commit").await.unwrap();
    let status = coord.get_status(sid).await.unwrap().unwrap();
    assert_eq!(status.commit_count, 2);
}

#[tokio::test]
async fn get_status_none_for_unknown_session() {
    let store = make_store();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);
    assert!(coord.get_status("nonexistent").await.unwrap().is_none());
}

#[tokio::test]
async fn commit_populates_files_and_stats() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let session = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("test"),
            None,
            None,
            None,
        )
        .unwrap();
    let sid = &session.session.id;
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store.clone());

    let result = coord.maybe_acquire(sid, dir.path()).await.unwrap();
    let info = match result {
        AcquireResult::Acquired(i) => i,
        other => panic!("expected Acquired, got {other:?}"),
    };

    // Create files and commit
    std::fs::write(info.worktree_path.join("new.txt"), "hello\nworld\n").unwrap();
    std::fs::write(info.worktree_path.join("other.txt"), "line1\n").unwrap();
    coord.commit(sid, "add files").await.unwrap();

    // Check the persisted event
    let events = store.get_events_since(sid, 0).unwrap();
    let commit_event = events
        .iter()
        .find(|e| e.event_type == "worktree.commit")
        .expect("commit event should exist");

    let payload: serde_json::Value = serde_json::from_str(&commit_event.payload).unwrap();
    let files = payload["filesChanged"].as_array().unwrap();
    assert!(files.len() >= 2);
    assert!(payload["insertions"].as_u64().unwrap() >= 3);
    assert_eq!(payload["deletions"].as_u64().unwrap(), 0);
}

#[tokio::test]
async fn concurrent_sessions_same_repo() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let r1 = coord
        .maybe_acquire("aaaa-session-a1", dir.path())
        .await
        .unwrap();
    let r2 = coord
        .maybe_acquire("bbbb-session-b2", dir.path())
        .await
        .unwrap();

    if let (AcquireResult::Acquired(i1), AcquireResult::Acquired(i2)) = (&r1, &r2) {
        assert_ne!(i1.worktree_path, i2.worktree_path);
        assert_ne!(i1.branch, i2.branch);
    } else {
        panic!("expected both Acquired");
    }

    assert_eq!(coord.list_active().len(), 2);
}

#[tokio::test]
async fn rebuild_from_events_restores_repo_tracking_for_lazy_mode() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let first = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("first"),
            None,
            None,
            None,
        )
        .unwrap();
    let second = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("second"),
            None,
            None,
            None,
        )
        .unwrap();

    let seed_coord = WorktreeCoordinator::new(WorktreeConfig::default(), store.clone());
    let acquired = seed_coord
        .maybe_acquire(&first.session.id, dir.path())
        .await
        .unwrap();
    assert!(matches!(acquired, AcquireResult::Acquired(_)));

    let lazy_coord = WorktreeCoordinator::new(
        WorktreeConfig {
            mode: crate::settings::types::IsolationMode::Lazy,
            ..WorktreeConfig::default()
        },
        store,
    );
    lazy_coord.rebuild_from_events();

    let rebuilt = lazy_coord
        .maybe_acquire(&second.session.id, dir.path())
        .await
        .unwrap();
    assert!(
        matches!(rebuilt, AcquireResult::Acquired(_)),
        "lazy mode should isolate when an active worktree was rebuilt"
    );
}

// ── list_session_branches tests ────────────────────────────────

#[tokio::test]
async fn list_branches_empty_repo() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);
    let branches = coord.list_session_branches(dir.path()).await.unwrap();
    assert!(branches.is_empty());
}

#[tokio::test]
async fn list_branches_with_active_worktree() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let _ = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("test"),
            None,
            None,
            None,
        )
        .unwrap();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let result = coord.maybe_acquire("sess-1", dir.path()).await.unwrap();
    assert!(matches!(result, AcquireResult::Acquired(_)));

    let branches = coord.list_session_branches(dir.path()).await.unwrap();
    assert_eq!(branches.len(), 1);
    assert!(branches[0].is_active);
    assert_eq!(branches[0].session_id.as_deref(), Some("sess-1"));
    assert!(branches[0].branch.starts_with("session/"));
}

#[tokio::test]
async fn list_branches_with_preserved_branch() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let _ = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("test"),
            None,
            None,
            None,
        )
        .unwrap();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    // Acquire then release (branch preserved by default)
    let result = coord.maybe_acquire("sess-2", dir.path()).await.unwrap();
    let AcquireResult::Acquired(info) = result else {
        panic!("expected Acquired");
    };
    // Write something so there's a commit
    std::fs::write(info.worktree_path.join("work.txt"), "data").unwrap();
    coord.commit("sess-2", "wip").await.unwrap();
    coord.release("sess-2").await.unwrap();

    let branches = coord.list_session_branches(dir.path()).await.unwrap();
    assert_eq!(branches.len(), 1);
    assert!(!branches[0].is_active);
    assert!(branches[0].session_id.is_none());
    assert!(branches[0].commit_count > 0);
}

#[tokio::test]
async fn list_branches_ignores_non_session_branches() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;
    run_cmd(dir.path(), &["git", "branch", "feature/xyz"]).await;
    run_cmd(dir.path(), &["git", "branch", "session/abc"]).await;

    let store = make_store();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let branches = coord.list_session_branches(dir.path()).await.unwrap();
    assert_eq!(branches.len(), 1);
    assert_eq!(branches[0].branch, "session/abc");
}

// ── get_committed_diff tests ────────────────────────────────────

#[tokio::test]
async fn committed_diff_no_commits() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let _ = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("test"),
            None,
            None,
            None,
        )
        .unwrap();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    coord.maybe_acquire("sess-cd1", dir.path()).await.unwrap();

    let result = coord.get_committed_diff("sess-cd1").await.unwrap();
    assert!(result.is_some());
    let diff = result.unwrap();
    assert!(diff.commits.is_empty());
    assert!(diff.files.is_empty());
    assert_eq!(diff.summary.total_files, 0);
}

#[tokio::test]
async fn committed_diff_single_commit() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let _ = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("test"),
            None,
            None,
            None,
        )
        .unwrap();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let result = coord.maybe_acquire("sess-cd2", dir.path()).await.unwrap();
    let AcquireResult::Acquired(info) = result else {
        panic!("expected Acquired");
    };

    std::fs::write(info.worktree_path.join("new.txt"), "hello\nworld\n").unwrap();
    coord.commit("sess-cd2", "add file").await.unwrap();

    let diff = coord.get_committed_diff("sess-cd2").await.unwrap().unwrap();
    assert_eq!(diff.commits.len(), 1);
    assert_eq!(diff.commits[0].message, "add file");
    assert!(!diff.files.is_empty());
    assert!(diff.summary.total_additions > 0);
}

#[tokio::test]
async fn committed_diff_no_active_worktree() {
    let store = make_store();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let result = coord.get_committed_diff("nonexistent").await.unwrap();
    assert!(result.is_none());
}

#[tokio::test]
async fn release_cleans_empty_repo_sessions() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let _ = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("test"),
            None,
            None,
            None,
        )
        .unwrap();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    // Acquire and release a single session
    let result = coord.maybe_acquire("sess-clean", dir.path()).await.unwrap();
    assert!(matches!(result, AcquireResult::Acquired(_)));

    coord.release("sess-clean").await.unwrap();

    assert_eq!(
        coord.tracked_repo_count(),
        0,
        "repo tracking should be empty after last session released"
    );
}

#[tokio::test]
async fn acquire_idempotent_no_duplicate_tracking() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let _ = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("test"),
            None,
            None,
            None,
        )
        .unwrap();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    // Acquire same session twice (idempotent)
    coord.maybe_acquire("sess-dup", dir.path()).await.unwrap();
    coord.maybe_acquire("sess-dup", dir.path()).await.unwrap();

    let repo_root = coord.tracked_repo_root_for_session("sess-dup").unwrap();
    assert_eq!(
        coord.tracked_session_count_for_repo(&repo_root),
        1,
        "duplicate acquire should not create duplicate tracking entries"
    );
}

#[tokio::test]
async fn release_partial_leaves_other_sessions() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    // Use distinct session IDs (different prefixes → different branch names)
    let sid1 = "aaaa-partial-s1";
    let sid2 = "bbbb-partial-s2";

    // Acquire 2 sessions in the same repo
    let r1 = coord.maybe_acquire(sid1, dir.path()).await.unwrap();
    let r2 = coord.maybe_acquire(sid2, dir.path()).await.unwrap();
    assert!(matches!(r1, AcquireResult::Acquired(_)));
    assert!(matches!(r2, AcquireResult::Acquired(_)));

    let repo_root = coord.tracked_repo_root_for_session(sid1).unwrap();
    assert_eq!(coord.tracked_session_count_for_repo(&repo_root), 2);

    // Release one session
    coord.release(sid1).await.unwrap();

    assert_eq!(coord.tracked_session_count_for_repo(&repo_root), 1);
    assert!(coord.is_session_tracked_for_repo(&repo_root, sid2));

    // Release second session — entry should be fully removed
    coord.release(sid2).await.unwrap();
    assert_eq!(coord.tracked_repo_count(), 0);
}

#[tokio::test]
async fn broadcasts_worktree_events() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let session = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("test"),
            None,
            None,
            None,
        )
        .unwrap();
    let sid = &session.session.id;

    // Create coordinator with broadcast channel
    let (tx, _) = tokio::sync::broadcast::channel(16);
    let mut rx = tx.subscribe();
    let coord = WorktreeCoordinator::with_broadcast(WorktreeConfig::default(), store, tx);

    // Acquire — should broadcast WorktreeAcquired
    let result = coord.maybe_acquire(sid, dir.path()).await.unwrap();
    let info = match result {
        AcquireResult::Acquired(i) => i,
        other => panic!("expected Acquired, got {other:?}"),
    };
    let event = rx.try_recv().unwrap();
    assert_eq!(event.event_type(), "worktree.acquired");
    assert_eq!(event.session_id(), sid.as_str());

    // Commit — should broadcast WorktreeCommit
    std::fs::write(info.worktree_path.join("work.txt"), "data").unwrap();
    coord.commit(sid, "wip").await.unwrap();
    let event = rx.try_recv().unwrap();
    assert_eq!(event.event_type(), "worktree.commit");

    // Release — should broadcast WorktreeReleased
    coord.release(sid).await.unwrap();
    let event = rx.try_recv().unwrap();
    assert_eq!(event.event_type(), "worktree.released");
}

// --- Empty repo deferral tests ---

#[tokio::test]
async fn acquire_empty_repo_returns_deferred() {
    let dir = tempdir().unwrap();
    run_cmd(dir.path(), &["git", "init"]).await;

    let store = make_store();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let result = coord.maybe_acquire("test-empty", dir.path()).await.unwrap();
    assert!(
        matches!(result, AcquireResult::Deferred(DeferralReason::EmptyRepository)),
        "expected Deferred(EmptyRepository), got {result:?}"
    );
}

#[tokio::test]
async fn acquire_empty_repo_then_commit_then_acquire() {
    let dir = tempdir().unwrap();
    run_cmd(dir.path(), &["git", "init"]).await;
    run_cmd(dir.path(), &["git", "config", "user.email", "test@test.com"]).await;
    run_cmd(dir.path(), &["git", "config", "user.name", "Test"]).await;

    let store = make_store();
    let _ = store
        .create_session("model", &dir.path().to_string_lossy(), Some("test"), None, None, None)
        .unwrap();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    // First attempt: deferred (no commits)
    let result = coord.maybe_acquire("test-defer", dir.path()).await.unwrap();
    assert!(matches!(result, AcquireResult::Deferred(_)));

    // Make first commit
    std::fs::write(dir.path().join("README.md"), "# test").unwrap();
    run_cmd(dir.path(), &["git", "add", "-A"]).await;
    run_cmd(dir.path(), &["git", "commit", "-m", "init"]).await;

    // Second attempt: acquired
    let result = coord.maybe_acquire("test-defer", dir.path()).await.unwrap();
    assert!(
        matches!(result, AcquireResult::Acquired(_)),
        "expected Acquired after first commit, got {result:?}"
    );
}

#[tokio::test]
async fn deferred_not_tracked_in_state() {
    let dir = tempdir().unwrap();
    run_cmd(dir.path(), &["git", "init"]).await;

    let store = make_store();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let result = coord.maybe_acquire("test-untracked", dir.path()).await.unwrap();
    assert!(matches!(result, AcquireResult::Deferred(_)));

    assert!(coord.get_info("test-untracked").is_none());
    assert!(coord.list_active().is_empty());
}

// --- Reverse case: staleness tests ---

#[tokio::test]
async fn acquire_then_delete_git_dir_returns_passthrough() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let _ = store
        .create_session("model", &dir.path().to_string_lossy(), Some("test"), None, None, None)
        .unwrap();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let result = coord.maybe_acquire("test-stale", dir.path()).await.unwrap();
    assert!(matches!(result, AcquireResult::Acquired(_)));

    // Delete .git directory
    std::fs::remove_dir_all(dir.path().join(".git")).unwrap();

    // Next acquire should detect staleness and return Passthrough
    let result = coord.maybe_acquire("test-stale", dir.path()).await.unwrap();
    assert!(
        matches!(result, AcquireResult::Passthrough),
        "expected Passthrough after .git deletion, got {result:?}"
    );
    assert!(coord.list_active().is_empty());
}

#[tokio::test]
async fn get_status_after_git_dir_deleted_returns_none() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let _ = store
        .create_session("model", &dir.path().to_string_lossy(), Some("test"), None, None, None)
        .unwrap();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let result = coord.maybe_acquire("test-status", dir.path()).await.unwrap();
    assert!(matches!(result, AcquireResult::Acquired(_)));

    // Delete .git directory
    std::fs::remove_dir_all(dir.path().join(".git")).unwrap();

    // get_status should detect and clean up
    let status = coord.get_status("test-status").await.unwrap();
    assert!(status.is_none());
    assert!(coord.get_info("test-status").is_none());
}

#[tokio::test]
async fn acquire_then_delete_worktree_dir_detects_staleness() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let _ = store
        .create_session("model", &dir.path().to_string_lossy(), Some("test"), None, None, None)
        .unwrap();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let result = coord.maybe_acquire("test-wt-gone", dir.path()).await.unwrap();
    let wt_path = match &result {
        AcquireResult::Acquired(info) => info.worktree_path.clone(),
        other => panic!("expected Acquired, got {other:?}"),
    };

    // Delete worktree directory
    std::fs::remove_dir_all(&wt_path).unwrap();

    // Next acquire detects staleness and untracks, then falls through.
    // Re-creation fails because the branch still exists in git — this is
    // expected; the stale worktree left behind an orphan branch that
    // recover_orphans() would clean up on server restart.
    let result = coord.maybe_acquire("test-wt-gone", dir.path()).await;
    // Staleness was detected: session was untracked
    assert!(coord.get_info("test-wt-gone").is_none());
    // The re-create attempt returns BranchExists error (orphan branch)
    assert!(result.is_err());
}

#[tokio::test]
async fn get_status_after_worktree_dir_deleted_returns_none() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let _ = store
        .create_session("model", &dir.path().to_string_lossy(), Some("test"), None, None, None)
        .unwrap();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let result = coord.maybe_acquire("test-wt-status", dir.path()).await.unwrap();
    let wt_path = match &result {
        AcquireResult::Acquired(info) => info.worktree_path.clone(),
        other => panic!("expected Acquired, got {other:?}"),
    };

    // Delete worktree directory
    std::fs::remove_dir_all(&wt_path).unwrap();

    // get_status should detect and clean up
    let status = coord.get_status("test-wt-status").await.unwrap();
    assert!(status.is_none());
    assert!(coord.get_info("test-wt-status").is_none());
}

// --- Isolation mode coverage ---

#[tokio::test]
async fn acquire_empty_repo_lazy_mode_deferred() {
    let dir = tempdir().unwrap();
    run_cmd(dir.path(), &["git", "init"]).await;

    let store = make_store();
    let config = WorktreeConfig {
        mode: crate::settings::types::IsolationMode::Lazy,
        ..WorktreeConfig::default()
    };
    let coord = WorktreeCoordinator::new(config, store);

    // Lazy mode with no other sessions → Passthrough (isolation not triggered)
    let result = coord.maybe_acquire("test-lazy-empty", dir.path()).await.unwrap();
    assert!(matches!(result, AcquireResult::Passthrough));
}

// --- Full lifecycle integration ---

#[tokio::test]
async fn full_lifecycle_git_init_midsession() {
    let dir = tempdir().unwrap();

    let store = make_store();
    let _ = store
        .create_session("model", &dir.path().to_string_lossy(), Some("test"), None, None, None)
        .unwrap();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    // 1. Non-git directory → Passthrough
    let result = coord.maybe_acquire("test-mid", dir.path()).await.unwrap();
    assert!(
        matches!(result, AcquireResult::Passthrough),
        "expected Passthrough for non-git dir, got {result:?}"
    );

    // 2. git init (no commits) → Deferred
    run_cmd(dir.path(), &["git", "init"]).await;
    run_cmd(dir.path(), &["git", "config", "user.email", "test@test.com"]).await;
    run_cmd(dir.path(), &["git", "config", "user.name", "Test"]).await;
    let result = coord.maybe_acquire("test-mid", dir.path()).await.unwrap();
    assert!(
        matches!(result, AcquireResult::Deferred(DeferralReason::EmptyRepository)),
        "expected Deferred for empty repo, got {result:?}"
    );

    // 3. First commit → Acquired
    std::fs::write(dir.path().join("README.md"), "# test").unwrap();
    run_cmd(dir.path(), &["git", "add", "-A"]).await;
    run_cmd(dir.path(), &["git", "commit", "-m", "init"]).await;
    let result = coord.maybe_acquire("test-mid", dir.path()).await.unwrap();
    assert!(
        matches!(result, AcquireResult::Acquired(_)),
        "expected Acquired after first commit, got {result:?}"
    );

    // Verify tracked
    assert!(coord.get_info("test-mid").is_some());
    assert_eq!(coord.list_active().len(), 1);
}

// ── rename_branch tests ────────────────────────────────────────

#[tokio::test]
async fn rename_branch_updates_state_and_git() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let sess = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("test"),
            None,
            None,
            None,
        )
        .unwrap();
    let sid = &sess.session.id;
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store.clone());

    let result = coord.maybe_acquire(sid, dir.path()).await.unwrap();
    let AcquireResult::Acquired(info) = result else {
        panic!("expected Acquired");
    };
    let old_branch = info.branch.clone();

    coord
        .rename_branch(sid, "session/fuzzy-purple-elephant")
        .await
        .unwrap();

    // State updated
    let new_info = coord.get_info(sid).unwrap();
    assert_eq!(new_info.branch, "session/fuzzy-purple-elephant");

    // Git branch renamed
    let git = GitExecutor::new(30_000);
    let branches = git
        .list_branches_matching(dir.path(), "session/*")
        .await
        .unwrap();
    assert!(branches.contains(&"session/fuzzy-purple-elephant".to_string()));
    assert!(!branches.contains(&old_branch));

    // Event emitted
    let events = store
        .get_events_by_type(sid, &["worktree.renamed"], None)
        .unwrap();
    assert_eq!(events.len(), 1);
    let payload: serde_json::Value =
        serde_json::from_str(&events[0].payload).unwrap();
    assert_eq!(payload["oldBranch"], old_branch);
    assert_eq!(payload["newBranch"], "session/fuzzy-purple-elephant");
}

#[tokio::test]
async fn rename_branch_not_tracked_returns_error() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let result = coord.rename_branch("nonexistent", "session/new-name").await;
    assert!(result.is_err());
}

#[tokio::test]
async fn rename_branch_collision_returns_error() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let sess = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("test"),
            None,
            None,
            None,
        )
        .unwrap();
    let sid = &sess.session.id;
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let result = coord.maybe_acquire(sid, dir.path()).await.unwrap();
    let AcquireResult::Acquired(info) = result else {
        panic!("expected Acquired");
    };

    // Create a branch that will collide
    run_cmd(dir.path(), &["git", "branch", "session/taken-name"]).await;

    let result = coord
        .rename_branch(sid, "session/taken-name")
        .await;
    assert!(result.is_err());

    // Original state preserved on failure
    let check = coord.get_info(sid).unwrap();
    assert_eq!(check.branch, info.branch);
}

#[tokio::test]
async fn rename_branch_then_release_preserves_new_name() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let sess = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("test"),
            None,
            None,
            None,
        )
        .unwrap();
    let sid = &sess.session.id;
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let result = coord.maybe_acquire(sid, dir.path()).await.unwrap();
    let AcquireResult::Acquired(info) = result else {
        panic!("expected Acquired");
    };

    std::fs::write(info.worktree_path.join("work.txt"), "data").unwrap();
    coord.commit(sid, "wip").await.unwrap();

    coord
        .rename_branch(sid, "session/cool-branch-name")
        .await
        .unwrap();
    coord.release(sid).await.unwrap();

    let git = GitExecutor::new(30_000);
    let branches = git
        .list_branches_matching(dir.path(), "session/*")
        .await
        .unwrap();
    assert!(branches.contains(&"session/cool-branch-name".to_string()));
}

#[tokio::test]
async fn rename_branch_idempotent_same_name() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let sess = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("test"),
            None,
            None,
            None,
        )
        .unwrap();
    let sid = &sess.session.id;
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let result = coord.maybe_acquire(sid, dir.path()).await.unwrap();
    let AcquireResult::Acquired(info) = result else {
        panic!("expected Acquired");
    };

    coord.rename_branch(sid, &info.branch).await.unwrap();
    let new_info = coord.get_info(sid).unwrap();
    assert_eq!(new_info.branch, info.branch);
}

// ── rebuild_from_events with renames ───────────────────────────

#[tokio::test]
async fn rebuild_from_events_applies_renames() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let sess = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("test"),
            None,
            None,
            None,
        )
        .unwrap();
    let sid = &sess.session.id;

    let seed_coord = WorktreeCoordinator::new(WorktreeConfig::default(), store.clone());
    let result = seed_coord.maybe_acquire(sid, dir.path()).await.unwrap();
    let AcquireResult::Acquired(info) = result else {
        panic!("expected Acquired");
    };
    let old_branch = info.branch.clone();

    seed_coord
        .rename_branch(sid, "session/fuzzy-purple-elephant")
        .await
        .unwrap();

    let new_coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);
    new_coord.rebuild_from_events();

    let rebuilt_info = new_coord.get_info(sid).unwrap();
    assert_eq!(
        rebuilt_info.branch, "session/fuzzy-purple-elephant",
        "rebuild should apply rename"
    );
    assert_ne!(rebuilt_info.branch, old_branch);
}

#[tokio::test]
async fn rebuild_from_events_multiple_renames_uses_latest() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let sess = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("test"),
            None,
            None,
            None,
        )
        .unwrap();
    let sid = &sess.session.id;

    let seed_coord = WorktreeCoordinator::new(WorktreeConfig::default(), store.clone());
    seed_coord.maybe_acquire(sid, dir.path()).await.unwrap();

    seed_coord
        .rename_branch(sid, "session/first-rename-attempt")
        .await
        .unwrap();
    seed_coord
        .rename_branch(sid, "session/final-branch-name")
        .await
        .unwrap();

    let new_coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);
    new_coord.rebuild_from_events();

    let info = new_coord.get_info(sid).unwrap();
    assert_eq!(info.branch, "session/final-branch-name");
}

// ── list_session_branches with renames ─────────────────────────

#[tokio::test]
async fn list_branches_after_rename_shows_correct_base_branch() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let sess = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("test"),
            None,
            None,
            None,
        )
        .unwrap();
    let sid = &sess.session.id;
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let result = coord.maybe_acquire(sid, dir.path()).await.unwrap();
    let AcquireResult::Acquired(info) = result else {
        panic!("expected Acquired");
    };

    std::fs::write(info.worktree_path.join("work.txt"), "data").unwrap();
    coord.commit(sid, "wip").await.unwrap();

    coord
        .rename_branch(sid, "session/pretty-new-name")
        .await
        .unwrap();

    let branches = coord.list_session_branches(dir.path()).await.unwrap();
    assert_eq!(branches.len(), 1);
    assert_eq!(branches[0].branch, "session/pretty-new-name");
    assert!(branches[0].is_active);
    assert!(branches[0].base_branch.is_some());
}

#[tokio::test]
async fn list_branches_after_rename_and_release_shows_base_branch() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let sess = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("test"),
            None,
            None,
            None,
        )
        .unwrap();
    let sid = &sess.session.id;
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let result = coord.maybe_acquire(sid, dir.path()).await.unwrap();
    let AcquireResult::Acquired(info) = result else {
        panic!("expected Acquired");
    };

    std::fs::write(info.worktree_path.join("work.txt"), "data").unwrap();
    coord.commit(sid, "wip").await.unwrap();

    coord
        .rename_branch(sid, "session/released-rename")
        .await
        .unwrap();
    coord.release(sid).await.unwrap();

    let branches = coord.list_session_branches(dir.path()).await.unwrap();
    assert_eq!(branches.len(), 1);
    assert_eq!(branches[0].branch, "session/released-rename");
    assert!(!branches[0].is_active);
    assert!(
        branches[0].base_branch.is_some(),
        "load_base_branches_from_events should rekey renamed branches"
    );
}

// ── delete_session_branch / prune_session_branches tests ───────

#[tokio::test]
async fn delete_branch_with_linked_worktree() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let git = GitExecutor::new(30_000);
    let wt_path = dir
        .path()
        .join(".worktrees")
        .join("session")
        .join("orphan1");
    git.worktree_add(dir.path(), &wt_path, "session/orphan1", "HEAD")
        .await
        .unwrap();
    assert!(wt_path.exists());

    let store = make_store();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let result = coord
        .delete_session_branch(dir.path(), "session/orphan1")
        .await;
    assert!(result.is_ok(), "delete should succeed: {result:?}");
    assert!(!wt_path.exists(), "worktree directory should be removed");

    let branches = git
        .list_branches_matching(dir.path(), "session/*")
        .await
        .unwrap();
    assert!(
        !branches.contains(&"session/orphan1".to_string()),
        "branch should be deleted"
    );
}

#[tokio::test]
async fn delete_branch_with_dirty_worktree_auto_commits() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let git = GitExecutor::new(30_000);
    let wt_path = dir
        .path()
        .join(".worktrees")
        .join("session")
        .join("dirty1");
    git.worktree_add(dir.path(), &wt_path, "session/dirty1", "HEAD")
        .await
        .unwrap();

    // Write dirty changes
    std::fs::write(wt_path.join("unsaved.txt"), "uncommitted work").unwrap();

    let store = make_store();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let result = coord
        .delete_session_branch(dir.path(), "session/dirty1")
        .await;
    assert!(
        result.is_ok(),
        "delete should succeed even with dirty worktree: {result:?}"
    );
    assert!(!wt_path.exists(), "worktree directory should be removed");
}

#[tokio::test]
async fn delete_branch_rejects_active_branch() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let _ = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("test"),
            None,
            None,
            None,
        )
        .unwrap();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let result = coord.maybe_acquire("sess-del", dir.path()).await.unwrap();
    let AcquireResult::Acquired(info) = result else {
        panic!("expected Acquired");
    };

    let err = coord
        .delete_session_branch(dir.path(), &info.branch)
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::worktree::WorktreeError::BranchActive(_)),
        "should reject active branch: {err:?}"
    );
}

#[tokio::test]
async fn delete_branch_rejects_wrong_prefix() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;
    run_cmd(dir.path(), &["git", "branch", "feature/xyz"]).await;

    let store = make_store();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let err = coord
        .delete_session_branch(dir.path(), "feature/xyz")
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::worktree::WorktreeError::Git(_)),
        "should reject non-session prefix: {err:?}"
    );
}

#[tokio::test]
async fn prune_removes_worktree_linked_branches() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let git = GitExecutor::new(30_000);

    // Create two orphan worktrees
    let wt1 = dir.path().join(".worktrees/session/orphan-a");
    let wt2 = dir.path().join(".worktrees/session/orphan-b");
    git.worktree_add(dir.path(), &wt1, "session/orphan-a", "HEAD")
        .await
        .unwrap();
    git.worktree_add(dir.path(), &wt2, "session/orphan-b", "HEAD")
        .await
        .unwrap();

    // Also acquire one via coordinator (active — should be skipped)
    let store = make_store();
    let _ = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("test"),
            None,
            None,
            None,
        )
        .unwrap();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);
    let result = coord.maybe_acquire("sess-active", dir.path()).await.unwrap();
    let AcquireResult::Acquired(active_info) = result else {
        panic!("expected Acquired");
    };

    let prune_result = coord.prune_session_branches(dir.path()).await.unwrap();
    assert!(
        prune_result.deleted.contains(&"session/orphan-a".to_string()),
        "orphan-a should be deleted: {:?}",
        prune_result.deleted
    );
    assert!(
        prune_result.deleted.contains(&"session/orphan-b".to_string()),
        "orphan-b should be deleted: {:?}",
        prune_result.deleted
    );
    assert!(
        prune_result.failed.is_empty(),
        "no failures expected: {:?}",
        prune_result.failed
    );

    // Active branch should still exist
    let remaining = git
        .list_branches_matching(dir.path(), "session/*")
        .await
        .unwrap();
    assert!(
        remaining.contains(&active_info.branch),
        "active branch should be preserved: {remaining:?}"
    );
    assert!(!wt1.exists(), "orphan-a worktree should be removed");
    assert!(!wt2.exists(), "orphan-b worktree should be removed");
}

#[tokio::test]
async fn prune_empty_repo() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let result = coord.prune_session_branches(dir.path()).await.unwrap();
    assert!(result.deleted.is_empty());
    assert!(result.failed.is_empty());
}

#[tokio::test]
async fn delete_branch_with_stale_worktree_ref() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let git = GitExecutor::new(30_000);
    let wt_path = dir
        .path()
        .join(".worktrees")
        .join("session")
        .join("stale1");
    git.worktree_add(dir.path(), &wt_path, "session/stale1", "HEAD")
        .await
        .unwrap();

    // Manually delete the worktree directory to simulate a stale ref
    tokio::fs::remove_dir_all(&wt_path).await.unwrap();
    assert!(!wt_path.exists());

    let store = make_store();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let result = coord
        .delete_session_branch(dir.path(), "session/stale1")
        .await;
    assert!(
        result.is_ok(),
        "delete should succeed with stale worktree ref: {result:?}"
    );

    let branches = git
        .list_branches_matching(dir.path(), "session/*")
        .await
        .unwrap();
    assert!(
        !branches.contains(&"session/stale1".to_string()),
        "branch should be deleted"
    );
}
