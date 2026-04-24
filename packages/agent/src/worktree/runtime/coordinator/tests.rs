use super::*;
use crate::events::{ConnectionConfig, new_in_memory, run_migrations};
use crate::worktree::git::GitExecutor;
use crate::worktree::types::{AcquireResult, CommitOptions, DeferralReason, WorktreeConfig};
use tempfile::tempdir;

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

// ── Per-session worktree override ────────────────────────────────────────

/// `Some(true)` overrides global `Never` and acquires a worktree in a git repo.
#[tokio::test]
async fn override_true_overrides_global_never() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let config = WorktreeConfig {
        mode: crate::settings::types::IsolationMode::Never,
        ..WorktreeConfig::default()
    };
    let coord = WorktreeCoordinator::new(config, store);

    let result = coord
        .maybe_acquire_with_override("override-true", dir.path(), Some(true))
        .await
        .unwrap();
    assert!(matches!(result, AcquireResult::Acquired(_)));
}

/// `Some(false)` overrides global `Always` and returns Passthrough.
#[tokio::test]
async fn override_false_overrides_global_always() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    // Default WorktreeConfig is Always.
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let result = coord
        .maybe_acquire_with_override("override-false", dir.path(), Some(false))
        .await
        .unwrap();
    assert!(matches!(result, AcquireResult::Passthrough));
}

/// `None` falls through to the global mode (Always → Acquired in git repo).
#[tokio::test]
async fn override_none_defers_to_global_always() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let result = coord
        .maybe_acquire_with_override("override-none", dir.path(), None)
        .await
        .unwrap();
    assert!(matches!(result, AcquireResult::Acquired(_)));
}

/// `Some(true)` on a non-git directory still passthroughs (worktrees require git).
#[tokio::test]
async fn override_true_on_non_git_passthroughs() {
    let dir = tempdir().unwrap();
    let store = make_store();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let result = coord
        .maybe_acquire_with_override("override-true-non-git", dir.path(), Some(true))
        .await
        .unwrap();
    assert!(matches!(result, AcquireResult::Passthrough));
}

/// `Some(true)` on an empty git repo (no commits) defers — same as Always-mode.
#[tokio::test]
async fn override_true_on_empty_git_repo_defers() {
    let dir = tempdir().unwrap();
    // Init repo without making any commits.
    run_cmd(dir.path(), &["git", "init"]).await;

    let store = make_store();
    let config = WorktreeConfig {
        mode: crate::settings::types::IsolationMode::Never,
        ..WorktreeConfig::default()
    };
    let coord = WorktreeCoordinator::new(config, store);

    let result = coord
        .maybe_acquire_with_override("override-true-empty", dir.path(), Some(true))
        .await
        .unwrap();
    assert!(matches!(
        result,
        AcquireResult::Deferred(DeferralReason::EmptyRepository)
    ));
}

/// Cached worktree wins over a Some(false) override (cache check happens first).
/// In practice this can't happen because overrides are immutable post-create —
/// but we verify the behavior is safe if it ever did.
#[tokio::test]
async fn cached_worktree_returned_regardless_of_override() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let first = coord
        .maybe_acquire_with_override("cached-sess", dir.path(), None)
        .await
        .unwrap();
    assert!(matches!(first, AcquireResult::Acquired(_)));

    // Even with Some(false), the cached worktree is returned.
    let second = coord
        .maybe_acquire_with_override("cached-sess", dir.path(), Some(false))
        .await
        .unwrap();
    assert!(matches!(second, AcquireResult::Acquired(_)));
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
    let commit_result = coord
        .commit(sid, "wip", CommitOptions::default_stage_all())
        .await
        .unwrap();
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
    coord
        .commit(sid, "first commit", CommitOptions::default_stage_all())
        .await
        .unwrap();
    let status = coord.get_status(sid).await.unwrap().unwrap();
    assert!(!status.has_uncommitted_changes);
    assert_eq!(status.commit_count, 1);

    // Second commit
    std::fs::write(info.worktree_path.join("more.txt"), "more").unwrap();
    coord
        .commit(sid, "second commit", CommitOptions::default_stage_all())
        .await
        .unwrap();
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
    coord
        .commit(sid, "add files", CommitOptions::default_stage_all())
        .await
        .unwrap();

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
    coord
        .commit("sess-2", "wip", CommitOptions::default_stage_all())
        .await
        .unwrap();
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
    coord
        .commit("sess-cd2", "add file", CommitOptions::default_stage_all())
        .await
        .unwrap();

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
    coord
        .commit(sid, "wip", CommitOptions::default_stage_all())
        .await
        .unwrap();
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
        matches!(
            result,
            AcquireResult::Deferred(DeferralReason::EmptyRepository)
        ),
        "expected Deferred(EmptyRepository), got {result:?}"
    );
}

#[tokio::test]
async fn acquire_empty_repo_then_commit_then_acquire() {
    let dir = tempdir().unwrap();
    run_cmd(dir.path(), &["git", "init"]).await;
    run_cmd(
        dir.path(),
        &["git", "config", "user.email", "test@test.com"],
    )
    .await;
    run_cmd(dir.path(), &["git", "config", "user.name", "Test"]).await;

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

    let result = coord
        .maybe_acquire("test-untracked", dir.path())
        .await
        .unwrap();
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

    let result = coord
        .maybe_acquire("test-status", dir.path())
        .await
        .unwrap();
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

    let result = coord
        .maybe_acquire("test-wt-gone", dir.path())
        .await
        .unwrap();
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

    let result = coord
        .maybe_acquire("test-wt-status", dir.path())
        .await
        .unwrap();
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
    let result = coord
        .maybe_acquire("test-lazy-empty", dir.path())
        .await
        .unwrap();
    assert!(matches!(result, AcquireResult::Passthrough));
}

// --- Full lifecycle integration ---

#[tokio::test]
async fn full_lifecycle_git_init_midsession() {
    let dir = tempdir().unwrap();

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

    // 1. Non-git directory → Passthrough
    let result = coord.maybe_acquire("test-mid", dir.path()).await.unwrap();
    assert!(
        matches!(result, AcquireResult::Passthrough),
        "expected Passthrough for non-git dir, got {result:?}"
    );

    // 2. git init (no commits) → Deferred
    run_cmd(dir.path(), &["git", "init"]).await;
    run_cmd(
        dir.path(),
        &["git", "config", "user.email", "test@test.com"],
    )
    .await;
    run_cmd(dir.path(), &["git", "config", "user.name", "Test"]).await;
    let result = coord.maybe_acquire("test-mid", dir.path()).await.unwrap();
    assert!(
        matches!(
            result,
            AcquireResult::Deferred(DeferralReason::EmptyRepository)
        ),
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
    let payload: serde_json::Value = serde_json::from_str(&events[0].payload).unwrap();
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

    let result = coord.rename_branch(sid, "session/taken-name").await;
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
    coord
        .commit(sid, "wip", CommitOptions::default_stage_all())
        .await
        .unwrap();

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
    coord
        .commit(sid, "wip", CommitOptions::default_stage_all())
        .await
        .unwrap();

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
    coord
        .commit(sid, "wip", CommitOptions::default_stage_all())
        .await
        .unwrap();

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
    let wt_path = dir.path().join(".worktrees").join("session").join("dirty1");
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
async fn delete_refuses_main_worktree_branch() {
    // *** Regression test for H20. ***
    //
    // Pathology: a session/* branch is checked out in the MAIN worktree
    // (e.g. user ran `git checkout session/x` by hand in their repo).
    // It isn't in `active_by_session` because no session ever acquired
    // it, so the prior `delete_session_branch` passed the active check,
    // then called `remove_worktree_if_present`, which asked git to
    // remove the MAIN worktree. Git refuses ("fatal: … is a main
    // working tree"), so the code fell through to
    // `remove_dir_all(&wt_path)` — which is `repo_root` in this case,
    // nuking the entire repository.
    //
    // Preflight must refuse before any destructive step runs, and the
    // safety guard in `remove_worktree_if_present` must refuse to
    // `remove_dir_all` a path equal to `repo_root`.
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;
    run_cmd(dir.path(), &["git", "branch", "session/pathological"]).await;
    run_cmd(dir.path(), &["git", "checkout", "session/pathological"]).await;

    let store = make_store();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let err = coord
        .delete_session_branch(dir.path(), "session/pathological")
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::worktree::WorktreeError::BranchActive(_)),
        "expected BranchActive, got {err:?}"
    );

    // Main repo must survive — this is the catastrophic-failure check.
    assert!(dir.path().exists(), "repo dir was wiped");
    assert!(dir.path().join(".git").exists(), ".git was wiped");
    assert!(
        dir.path().join("README.md").exists(),
        "working-tree file was wiped",
    );

    // Branch must still exist since delete was refused.
    let git = GitExecutor::new(30_000);
    let branches = git
        .list_branches_matching(dir.path(), "session/*")
        .await
        .unwrap();
    assert!(
        branches.contains(&"session/pathological".to_string()),
        "branch must still exist after refused delete: {branches:?}",
    );
}

#[tokio::test]
async fn prune_refuses_main_worktree_branch() {
    // Same pathology as `delete_refuses_main_worktree_branch`, reached
    // via `prune_session_branches`. Without the preflight, prune would
    // iterate over the inactive session/* branch and call
    // remove_worktree_if_present on the main worktree — same
    // remove_dir_all disaster.
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;
    run_cmd(dir.path(), &["git", "branch", "session/main-head"]).await;
    run_cmd(dir.path(), &["git", "checkout", "session/main-head"]).await;

    let store = make_store();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let result = coord.prune_session_branches(dir.path()).await.unwrap();

    // Main repo must survive.
    assert!(dir.path().exists(), "repo dir wiped by prune");
    assert!(dir.path().join(".git").exists(), ".git wiped by prune");
    assert!(
        dir.path().join("README.md").exists(),
        "working-tree file wiped by prune",
    );

    // The main-HEAD branch must not be in deleted, must be in failed.
    assert!(
        !result.deleted.contains(&"session/main-head".to_string()),
        "prune must not delete main-worktree branch: {:?}",
        result.deleted,
    );
    assert!(
        result
            .failed
            .iter()
            .any(|f| f.branch == "session/main-head"),
        "prune must record main-worktree branch as a failure: {:?}",
        result.failed,
    );

    let git = GitExecutor::new(30_000);
    let branches = git
        .list_branches_matching(dir.path(), "session/*")
        .await
        .unwrap();
    assert!(
        branches.contains(&"session/main-head".to_string()),
        "branch must still exist after refused prune: {branches:?}",
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
    let result = coord
        .maybe_acquire("sess-active", dir.path())
        .await
        .unwrap();
    let AcquireResult::Acquired(active_info) = result else {
        panic!("expected Acquired");
    };

    let prune_result = coord.prune_session_branches(dir.path()).await.unwrap();
    assert!(
        prune_result
            .deleted
            .contains(&"session/orphan-a".to_string()),
        "orphan-a should be deleted: {:?}",
        prune_result.deleted
    );
    assert!(
        prune_result
            .deleted
            .contains(&"session/orphan-b".to_string()),
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
    let wt_path = dir.path().join(".worktrees").join("session").join("stale1");
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

// ── Passthrough-mode queries ────────────────────────────────────────
//
// These cover the "session running directly on main" case: maybe_acquire
// returns Passthrough, nothing is inserted into active_by_session, but
// git-workflow RPCs (status, list_local_branches, list_remote_branches,
// sync_main, push_branch) must still work against the session's
// original working directory.

#[tokio::test]
async fn passthrough_status_resolves_on_main_session() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let status = coord.passthrough_status(dir.path()).await.unwrap();
    let status = status.expect("passthrough repo should yield status");
    assert!(
        !status.isolated,
        "passthrough status must flag isolated=false"
    );
    // Fresh `git init` default branch name varies by host config; accept
    // the two values we see in CI.
    assert!(
        status.branch == "main" || status.branch == "master",
        "unexpected branch: {}",
        status.branch
    );
    assert!(
        status
            .repo_root
            .ends_with(dir.path().to_string_lossy().as_ref())
            || status
                .repo_root
                .contains(dir.path().to_string_lossy().as_ref())
    );
    assert_eq!(status.commit_count, 0);
}

#[tokio::test]
async fn passthrough_status_returns_none_for_non_repo() {
    let dir = tempdir().unwrap();
    let store = make_store();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let status = coord.passthrough_status(dir.path()).await.unwrap();
    assert!(status.is_none());
}

#[tokio::test]
async fn list_local_branches_falls_back_to_cwd_when_session_untracked() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    // No `maybe_acquire` → session never tracked, simulating passthrough.
    let branches = coord
        .list_local_branches("untracked-sess", Some(dir.path()))
        .await
        .unwrap();
    assert!(!branches.is_empty(), "expected at least the default branch");
}

#[tokio::test]
async fn list_local_branches_errors_without_fallback_for_untracked_session() {
    let store = make_store();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    let err = coord.list_local_branches("ghost", None).await.unwrap_err();
    assert!(
        matches!(err, crate::worktree::WorktreeError::NotFound { .. }),
        "expected NotFound, got {err:?}"
    );
}

#[tokio::test]
async fn list_remote_branches_falls_back_to_cwd_when_session_untracked() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    // No remote configured → list is empty but the call must still
    // resolve a repo root instead of erroring with NotFound.
    let branches = coord
        .list_remote_branches("untracked-sess", Some("origin"), Some(dir.path()))
        .await
        .unwrap();
    assert!(branches.is_empty());
}

// ── commit options: amend / stage_all / guards ─────────────────────

/// Helper: acquire a worktree on a freshly-initialized repo.
async fn acquire_for_commit_tests() -> (
    tempfile::TempDir,
    Arc<WorktreeCoordinator>,
    String,
    std::path::PathBuf,
    Arc<crate::events::EventStore>,
) {
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
    let sid = session.session.id.clone();
    let coord = Arc::new(WorktreeCoordinator::new(
        WorktreeConfig::default(),
        store.clone(),
    ));

    let result = coord.maybe_acquire(&sid, dir.path()).await.unwrap();
    let info = match result {
        AcquireResult::Acquired(i) => i,
        other => panic!("expected Acquired, got {other:?}"),
    };
    let wt = info.worktree_path.clone();
    (dir, coord, sid, wt, store)
}

#[tokio::test]
async fn coordinator_commit_no_changes_returns_none() {
    let (_dir, coord, sid, _wt, _store) = acquire_for_commit_tests().await;

    // Clean tree, no amend → None.
    let r = coord
        .commit(&sid, "nothing", CommitOptions::default_stage_all())
        .await
        .unwrap();
    assert!(r.is_none(), "expected None on clean tree without amend");
}

#[tokio::test]
async fn coordinator_commit_amend_with_no_changes_still_commits() {
    let (_dir, coord, sid, wt, _store) = acquire_for_commit_tests().await;

    // First, make a commit to amend.
    std::fs::write(wt.join("a.txt"), "a").unwrap();
    let first = coord
        .commit(&sid, "first", CommitOptions::default_stage_all())
        .await
        .unwrap()
        .expect("first commit should succeed");

    // Now amend with no working-tree changes — should still produce a new SHA
    // (amend rewrites HEAD so SHA changes even with same tree).
    let amended = coord
        .commit(
            &sid,
            "first (amended)",
            CommitOptions {
                amend: true,
                stage_all: true,
                ..Default::default()
            },
        )
        .await
        .unwrap()
        .expect("amend on clean tree must not return None");

    assert_ne!(
        first.commit_hash, amended.commit_hash,
        "amend must produce a new SHA"
    );
}

#[tokio::test]
async fn coordinator_commit_amend_on_empty_repo_returns_err() {
    // Verify the coordinator's amend-on-unborn-HEAD guard by:
    //   1. Acquiring a normal worktree.
    //   2. Erasing HEAD on that worktree to simulate an unborn state.
    //   3. Calling commit(amend=true) and asserting the guard fires.
    //
    // This exercises the actual `!has_commits → Err` branch rather than
    // the acquire-refuses path that an unborn root repo would take.
    let (_dir, coord, sid, wt, _store) = acquire_for_commit_tests().await;

    // Delete HEAD so the worktree has no commits. A worktree's HEAD lives
    // under <repo>/.git/worktrees/<name>/HEAD. Simplest: point it at a
    // non-existent ref so `git rev-parse --verify HEAD` fails.
    run_cmd(
        &wt,
        &["git", "symbolic-ref", "HEAD", "refs/heads/nonexistent"],
    )
    .await;

    let err = coord
        .commit(
            &sid,
            "amend on empty",
            CommitOptions {
                amend: true,
                ..Default::default()
            },
        )
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::worktree::WorktreeError::Git(ref m) if m.contains("amend")),
        "expected Git(\"Cannot amend: no previous commit exists\"), got {err:?}"
    );
}

#[tokio::test]
async fn coordinator_commit_records_compaction_signal() {
    // The handler records the signal, not the coordinator — so this is really
    // a regression check that the event payload and path remain unchanged.
    // Asserting the `worktree.commit` event is appended covers the compaction
    // handler's detection surface; the handler matches on `event_type`.
    use crate::events::EventType;
    use crate::events::sqlite::repositories::event::ListEventsOptions;

    let (_dir, coord, sid, wt, store) = acquire_for_commit_tests().await;
    std::fs::write(wt.join("signal.txt"), "x").unwrap();
    let _ = coord
        .commit(&sid, "signal", CommitOptions::default_stage_all())
        .await
        .unwrap();

    let events = store
        .get_events_by_session(&sid, &ListEventsOptions::default())
        .unwrap_or_default();
    assert!(
        events
            .iter()
            .any(|e| e.event_type == EventType::WorktreeCommit.as_str()),
        "expected a WorktreeCommit event to be recorded"
    );
}

#[tokio::test]
async fn coordinator_commit_emits_event_with_stats() {
    use crate::events::EventType;
    use crate::events::sqlite::repositories::event::ListEventsOptions;
    let (_dir, coord, sid, wt, store) = acquire_for_commit_tests().await;

    std::fs::write(wt.join("code.rs"), "line1\nline2\nline3\n").unwrap();
    let r = coord
        .commit(&sid, "add code", CommitOptions::default_stage_all())
        .await
        .unwrap()
        .expect("commit should succeed");

    assert_eq!(r.insertions, 3, "insertions should be 3");
    assert_eq!(r.deletions, 0);
    assert!(r.files_changed.contains(&"code.rs".to_string()));

    // Locate the emitted event and confirm the payload matches the returned
    // CommitResult — regression guard for the compaction progress signal,
    // totalCommitCount, and hasUncommittedChanges fields.
    let events = store
        .get_events_by_session(&sid, &ListEventsOptions::default())
        .unwrap_or_default();
    let last = events
        .iter()
        .rev()
        .find(|e| e.event_type == EventType::WorktreeCommit.as_str())
        .expect("WorktreeCommit event must be emitted");
    let payload: serde_json::Value =
        serde_json::from_str(&last.payload).expect("payload must be valid json");
    assert_eq!(payload["commitHash"].as_str().unwrap(), r.commit_hash);
    assert_eq!(payload["insertions"].as_u64().unwrap(), 3);
    assert_eq!(payload["deletions"].as_u64().unwrap(), 0);
    assert_eq!(payload["totalCommitCount"].as_u64().unwrap(), 1);
    assert_eq!(payload["hasUncommittedChanges"].as_bool().unwrap(), false);
}

#[tokio::test]
async fn coordinator_commit_stage_all_false_only_commits_index() {
    let (_dir, coord, sid, wt, _store) = acquire_for_commit_tests().await;

    std::fs::write(wt.join("indexed.txt"), "one").unwrap();
    std::fs::write(wt.join("untracked.txt"), "two").unwrap();
    run_cmd(&wt, &["git", "add", "indexed.txt"]).await;

    let r = coord
        .commit(
            &sid,
            "partial",
            CommitOptions {
                stage_all: false,
                ..Default::default()
            },
        )
        .await
        .unwrap()
        .expect("partial commit should succeed");

    assert!(r.files_changed.contains(&"indexed.txt".to_string()));
    assert!(
        !r.files_changed.contains(&"untracked.txt".to_string()),
        "untracked file must not land in the commit: {:?}",
        r.files_changed
    );
}

// ── Concurrent acquire for the same session is serialized ────────────────

/// Fire N concurrent `maybe_acquire_with_override` calls for the SAME session
/// and assert exactly one worktree gets created. Without the per-session lock
/// these would race on the cache check → create → track window and produce
/// multiple `WorktreeAcquired` events.
#[tokio::test]
async fn concurrent_acquire_same_session_creates_exactly_one_worktree() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let session = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("race-sess"),
            None,
            None,
            None,
        )
        .unwrap();
    let sid = session.session.id.clone();
    let coord = Arc::new(WorktreeCoordinator::new(
        WorktreeConfig::default(),
        store.clone(),
    ));

    // Launch 10 concurrent acquire attempts for the same session.
    let mut handles = Vec::new();
    for _ in 0..10 {
        let coord = coord.clone();
        let path = dir.path().to_path_buf();
        let sid = sid.clone();
        handles.push(tokio::spawn(async move {
            coord.maybe_acquire_with_override(&sid, &path, None).await
        }));
    }

    let results: Vec<_> = futures::future::join_all(handles).await;
    // All must succeed...
    let acquires: Vec<_> = results.into_iter().map(|r| r.unwrap().unwrap()).collect();
    assert_eq!(acquires.len(), 10);
    for r in &acquires {
        assert!(matches!(r, AcquireResult::Acquired(_)));
    }

    // ...and all must reference the SAME worktree path + branch.
    let paths: std::collections::HashSet<_> = acquires
        .iter()
        .filter_map(|r| match r {
            AcquireResult::Acquired(info) => Some(info.worktree_path.clone()),
            _ => None,
        })
        .collect();
    assert_eq!(
        paths.len(),
        1,
        "concurrent acquires must converge on a single worktree; got {paths:?}"
    );

    // Only one persistent `worktree.acquired` event should exist.
    let opts = crate::events::sqlite::repositories::event::ListEventsOptions::default();
    let events = store.get_events_by_session(&sid, &opts).unwrap();
    let acquired_count = events
        .iter()
        .filter(|e| e.event_type == crate::events::EventType::WorktreeAcquired.as_str())
        .count();
    assert_eq!(
        acquired_count, 1,
        "exactly one worktree.acquired event expected; got {acquired_count}"
    );
}

/// Different sessions must still acquire in parallel; the per-session lock
/// scopes by session_id and must not serialize across sessions.
#[tokio::test]
async fn concurrent_acquire_different_sessions_not_serialized() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let mut sids: Vec<String> = Vec::new();
    for title in ["s1", "s2", "s3"] {
        let r = store
            .create_session(
                "model",
                &dir.path().to_string_lossy(),
                Some(title),
                None,
                None,
                None,
            )
            .unwrap();
        sids.push(r.session.id);
    }
    let coord = Arc::new(WorktreeCoordinator::new(WorktreeConfig::default(), store));

    let start = std::time::Instant::now();
    let mut handles = Vec::new();
    for sid in sids {
        let coord = coord.clone();
        let path = dir.path().to_path_buf();
        handles.push(tokio::spawn(async move {
            coord.maybe_acquire_with_override(&sid, &path, None).await
        }));
    }
    for h in handles {
        let _ = h.await.unwrap().unwrap();
    }
    let elapsed = start.elapsed();

    // Three sessions creating worktrees on one repo. Even sequentially
    // this completes in well under a minute; we just want to confirm the
    // per-session lock doesn't pathologically serialize them.
    assert!(
        elapsed < std::time::Duration::from_secs(60),
        "three-session acquire took {elapsed:?}"
    );
    assert_eq!(coord.list_active().len(), 3);
}

/// `git worktree add` writes metadata files under
/// `.git/worktrees/<name>/` (HEAD, commondir, gitdir, etc.) and, while
/// doing so, reads the same metadata files belonging to every OTHER
/// worktree on that main repo (git internally calls `get_worktrees()`
/// to validate the new addition). Two concurrent `git worktree add`
/// invocations against the same main repo therefore race on the
/// commondir file of each other's in-progress worktree:
///   "fatal: failed to read .git/worktrees/<other>/commondir: Undefined error: 0"
///
/// The coordinator's per-session lock (H4) does NOT prevent this
/// because the race is across different sessions, and the heavy
/// `repo_locks` ("syncMain" / "finalizeSession" / "rebaseOnMain") are
/// only held during those named ops — they are NOT held during
/// `maybe_acquire_with_override`.
///
/// This regression test runs 12 concurrent acquires against a single
/// main repo. With the main-repo-scoped `worktree_add_locks` guard in
/// place every call succeeds; without it, the test reliably hits the
/// commondir race on macOS. The test's shape (cross-session, same
/// repo, high fan-out) mirrors the original failure observed during
/// Sprint 2 audit.
#[tokio::test]
async fn parallel_acquire_different_sessions_same_repo_no_git_race() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    // Fan-out large enough to reliably trigger the git metadata race
    // in the absence of main-repo serialization.
    const FANOUT: usize = 24;
    let mut sids: Vec<String> = Vec::with_capacity(FANOUT);
    for i in 0..FANOUT {
        let r = store
            .create_session(
                "model",
                &dir.path().to_string_lossy(),
                Some(&format!("s{i}")),
                None,
                None,
                None,
            )
            .unwrap();
        sids.push(r.session.id);
    }
    let coord = Arc::new(WorktreeCoordinator::new(WorktreeConfig::default(), store));

    let mut handles = Vec::new();
    for sid in sids {
        let coord = coord.clone();
        let path = dir.path().to_path_buf();
        handles.push(tokio::spawn(async move {
            coord.maybe_acquire_with_override(&sid, &path, None).await
        }));
    }

    // Every acquire must succeed — no Git metadata errors.
    for h in handles {
        let result = h.await.unwrap();
        result.expect("acquire must not fail due to git metadata race");
    }

    // Every session's worktree must be tracked.
    assert_eq!(coord.list_active().len(), FANOUT);
}

/// After an acquire that RETURNS AN ERROR, the per-session lock must
/// still be released (RAII on `_guard`). Otherwise one failed acquire
/// would stall every subsequent prompt for that session.
///
/// We can't easily inject a failure into the real flow, but we can
/// verify the lock-release invariant at the primitive level: acquire
/// the same mutex twice back-to-back and confirm it returns fast.
#[tokio::test]
async fn session_acquire_mutex_releases_on_scope_exit() {
    let store = make_store();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    // Simulate an "acquire attempt" that early-returns (e.g. error path):
    // take the lock inside a scope and drop it, then confirm a second
    // acquire for the same session proceeds immediately.
    {
        let lock = coord.session_acquire_mutex("stuck-sess");
        let _guard = lock.lock().await;
        // guard dropped at end of scope
    }

    let start = std::time::Instant::now();
    let lock2 = coord.session_acquire_mutex("stuck-sess");
    let _guard2 = lock2.lock().await;
    assert!(
        start.elapsed() < std::time::Duration::from_millis(100),
        "second acquire must not wait — prior lock RAII-released; elapsed={:?}",
        start.elapsed()
    );
}

/// After an acquire that RETURNED EmptyRepository (a real error path
/// through the function), the lock must be available for the next
/// caller. This exercises the full `maybe_acquire_with_override` flow.
#[tokio::test]
async fn error_path_does_not_leak_session_lock() {
    let dir = tempdir().unwrap();
    // git init with no commits → EmptyRepository deferral.
    run_cmd(dir.path(), &["git", "init"]).await;

    let store = make_store();
    let session = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("err-sess"),
            None,
            None,
            None,
        )
        .unwrap();
    let sid = session.session.id;
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    // First call: returns Deferred(EmptyRepository). We care about the
    // lock being released afterward, not the result itself.
    let _ = coord
        .maybe_acquire_with_override(&sid, dir.path(), Some(true))
        .await
        .unwrap();

    // Second call for the same session must not block on a stuck lock.
    let start = std::time::Instant::now();
    let _ = coord
        .maybe_acquire_with_override(&sid, dir.path(), Some(true))
        .await
        .unwrap();
    assert!(
        start.elapsed() < std::time::Duration::from_millis(500),
        "error-path must release the per-session lock; elapsed={:?}",
        start.elapsed()
    );
}

/// After acquire returns, the per-session lock must be released so a
/// subsequent acquire for the same session can proceed. (The lock is a
/// short-lived coordination primitive, NOT a long-held resource.)
#[tokio::test]
async fn acquire_releases_lock_after_return() {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let session = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("release-sess"),
            None,
            None,
            None,
        )
        .unwrap();
    let sid = session.session.id;
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store);

    // First acquire creates.
    let first = coord
        .maybe_acquire_with_override(&sid, dir.path(), None)
        .await
        .unwrap();
    assert!(matches!(first, AcquireResult::Acquired(_)));

    // Second acquire (idempotent) must not block — proves the lock dropped.
    let start = std::time::Instant::now();
    let _second = coord
        .maybe_acquire_with_override(&sid, dir.path(), None)
        .await
        .unwrap();
    assert!(
        start.elapsed() < std::time::Duration::from_secs(1),
        "second acquire must not have waited on a stuck lock"
    );
}

// ── worktree.auto_recovered_commits emission (M24) ────────────────

/// Helper: fetch every persisted `worktree.auto_recovered_commits`
/// event for a session, decoded as JSON. Using the event log directly
/// (not broadcast) makes the assertion equivalent to what iOS sees on
/// reconstruction — the whole point of M24.
fn fetch_auto_recovered_events(store: &EventStore, session_id: &str) -> Vec<serde_json::Value> {
    store
        .get_events_by_type(session_id, &["worktree.auto_recovered_commits"], None)
        .unwrap()
        .into_iter()
        .map(|e| serde_json::from_str(&e.payload).unwrap())
        .collect()
}

#[tokio::test]
async fn auto_recovered_commits_emit_event_on_delete_branch() {
    // Full regression test for M24: `delete_session_branch` on a
    // dirty worktree must persist a `worktree.auto_recovered_commits`
    // event carrying the auto-commit SHA so iOS can surface a notice.
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let store = make_store();
    let session = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("recov-1"),
            None,
            None,
            None,
        )
        .unwrap();
    let session_id = session.session.id.clone();
    let branch = format!("session/{session_id}");

    // Create the worktree at a session-id-aligned path and branch so
    // `emit_auto_recovered` can strip the prefix and find the row.
    let git = GitExecutor::new(30_000);
    let wt_path = dir
        .path()
        .join(".worktrees")
        .join("session")
        .join(&session_id);
    git.worktree_add(dir.path(), &wt_path, &branch, "HEAD")
        .await
        .unwrap();
    std::fs::write(wt_path.join("unsaved.txt"), "uncommitted work").unwrap();

    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store.clone());
    coord
        .delete_session_branch(dir.path(), &branch)
        .await
        .expect("delete should succeed");

    let events = fetch_auto_recovered_events(&store, &session_id);
    assert_eq!(events.len(), 1, "exactly one event expected: {events:?}");
    let payload = &events[0];
    assert_eq!(payload["branch"], branch);
    assert_eq!(
        payload["branchRemoved"], true,
        "delete path destroys the branch after commit"
    );
    let sha = payload["commitHash"].as_str().expect("commitHash present");
    assert_eq!(
        sha.len(),
        40,
        "commitHash must be full-length git sha: {sha:?}"
    );
    assert!(
        sha.chars().all(|c| c.is_ascii_hexdigit()),
        "sha must be hex: {sha:?}"
    );
    // The SHA must exist in reflog even after branch delete.
    let cat = tokio::process::Command::new("git")
        .args(["cat-file", "-e", sha])
        .current_dir(dir.path())
        .output()
        .await
        .unwrap();
    assert!(
        cat.status.success(),
        "auto-commit SHA must be reachable via reflog after branch delete"
    );
    // Event carries the worktree path exactly as reported by
    // `git worktree list`, which canonicalises symlinks (e.g.
    // /var → /private/var on macOS). Assert by suffix so the test is
    // portable.
    let event_path = payload["path"].as_str().unwrap();
    assert!(
        event_path.ends_with(&format!(".worktrees/session/{session_id}",)),
        "unexpected event path {event_path:?}"
    );
    assert!(
        !wt_path.exists(),
        "worktree dir must be removed after delete"
    );
}

#[tokio::test]
async fn auto_recovered_commits_skips_clean_delete() {
    // Clean worktree → no auto-commit → no event. Regression guard
    // against a callsite emitting a bogus event with an empty SHA.
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;
    let git = GitExecutor::new(30_000);

    let store = make_store();
    let session = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("clean-del"),
            None,
            None,
            None,
        )
        .unwrap();
    let session_id = session.session.id.clone();
    let branch = format!("session/{session_id}");
    let wt_path = dir
        .path()
        .join(".worktrees")
        .join("session")
        .join(&session_id);
    git.worktree_add(dir.path(), &wt_path, &branch, "HEAD")
        .await
        .unwrap();
    // No dirty changes written — worktree is clean.

    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store.clone());
    coord
        .delete_session_branch(dir.path(), &branch)
        .await
        .unwrap();

    let events = fetch_auto_recovered_events(&store, &session_id);
    assert!(
        events.is_empty(),
        "clean worktree must not emit auto-recovered event: {events:?}"
    );
}

#[tokio::test]
async fn auto_recovered_commits_skips_when_session_missing() {
    // If the session row is gone, we have no timeline to attach to —
    // the emit helper must short-circuit instead of producing an
    // orphan event. Exercised via delete_session_branch with a
    // synthetic dirty orphan whose session_id matches NO session row.
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;
    let git = GitExecutor::new(30_000);

    let branch = "session/ghost-1234";
    let wt_path = dir
        .path()
        .join(".worktrees")
        .join("session")
        .join("ghost-1234");
    git.worktree_add(dir.path(), &wt_path, branch, "HEAD")
        .await
        .unwrap();
    std::fs::write(wt_path.join("x.txt"), "dirt").unwrap();

    let store = make_store();
    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store.clone());

    // Delete succeeds — the auto-commit + branch destruction still
    // runs, we just don't emit an event because there's no session
    // row to hang it off of.
    coord
        .delete_session_branch(dir.path(), branch)
        .await
        .unwrap();

    let events = fetch_auto_recovered_events(&store, "ghost-1234");
    assert!(
        events.is_empty(),
        "missing session row must not produce a ghost event: {events:?}"
    );
}

#[tokio::test]
async fn auto_recovered_commits_from_prune() {
    // Prune path also emits per dirty orphan. Attributes one event
    // per sessionful branch that had dirty changes.
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;
    let git = GitExecutor::new(30_000);

    let store = make_store();
    // Two sessions, each with a dirty worktree.
    let ses1 = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("prune-1"),
            None,
            None,
            None,
        )
        .unwrap()
        .session
        .id;
    let ses2 = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("prune-2"),
            None,
            None,
            None,
        )
        .unwrap()
        .session
        .id;
    let b1 = format!("session/{ses1}");
    let b2 = format!("session/{ses2}");
    let wt1 = dir.path().join(".worktrees/session").join(&ses1);
    let wt2 = dir.path().join(".worktrees/session").join(&ses2);
    git.worktree_add(dir.path(), &wt1, &b1, "HEAD")
        .await
        .unwrap();
    git.worktree_add(dir.path(), &wt2, &b2, "HEAD")
        .await
        .unwrap();
    std::fs::write(wt1.join("a.txt"), "dirt-1").unwrap();
    std::fs::write(wt2.join("b.txt"), "dirt-2").unwrap();

    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store.clone());
    let result = coord.prune_session_branches(dir.path()).await.unwrap();
    assert_eq!(result.deleted.len(), 2, "both should prune: {result:?}");
    assert!(result.failed.is_empty());

    for sid in [&ses1, &ses2] {
        let events = fetch_auto_recovered_events(&store, sid);
        assert_eq!(events.len(), 1, "one event per session: {events:?}");
        assert_eq!(events[0]["branchRemoved"], true);
        let sha = events[0]["commitHash"].as_str().unwrap();
        assert_eq!(sha.len(), 40);
    }
}

#[tokio::test]
async fn auto_recovered_commits_from_startup_sweep() {
    // Startup orphan sweep: the branch is preserved when it has
    // commits, so `branchRemoved = false`. iOS uses this flag to tell
    // the user whether the SHA is reachable directly (false) or only
    // via reflog (true).
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;
    let git = GitExecutor::new(30_000);

    let store = make_store();
    let sid = store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("sweep-1"),
            None,
            None,
            None,
        )
        .unwrap()
        .session
        .id;
    store
        .get_or_create_workspace(&dir.path().to_string_lossy(), Some("sweep"))
        .unwrap();
    let branch = format!("session/{sid}");
    let wt_path = dir.path().join(".worktrees/session").join(&sid);
    git.worktree_add(dir.path(), &wt_path, &branch, "HEAD")
        .await
        .unwrap();
    std::fs::write(wt_path.join("work.txt"), "orphan").unwrap();

    let coord = WorktreeCoordinator::new(WorktreeConfig::default(), store.clone());
    // active_branches is empty — coordinator has no in-memory state
    // for this branch, so the sweep treats it as an orphan.
    let total = coord.recover_orphans().await;
    assert!(
        total >= 1,
        "expected at least one recovered worktree, got {total}"
    );

    let events = fetch_auto_recovered_events(&store, &sid);
    assert_eq!(
        events.len(),
        1,
        "sweep should emit exactly one event: {events:?}"
    );
    assert_eq!(
        events[0]["branchRemoved"], false,
        "branch preserved for recoverability"
    );
    let sha = events[0]["commitHash"].as_str().unwrap();
    assert_eq!(sha.len(), 40);
    // Since the branch is preserved, cat-file should resolve the SHA.
    let cat = tokio::process::Command::new("git")
        .args(["cat-file", "-e", sha])
        .current_dir(dir.path())
        .output()
        .await
        .unwrap();
    assert!(cat.status.success(), "SHA must be reachable post-sweep");
}
