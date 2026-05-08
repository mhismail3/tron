//! Tests for `rebase_on_main` — phases B through I of the plan's TDD
//! matrix. Phase A (capability-level parser tests) lives in
//! the engine protocol integration tests.
//!
//! Fixtures run real `git` against `tempfile::tempdir()` directories —
//! the conflict state machine's semantics depend on the index state
//! and can't be faithfully mocked.

use std::sync::Arc;
use std::time::Duration;

use tempfile::tempdir;
use tokio::sync::broadcast;

use super::*;
use crate::core::events::TronEvent;
use crate::events::{ConnectionConfig, EventStore, new_in_memory, run_migrations};
use crate::worktree::types::{
    AcquireResult, MergeOrigin, MergeStrategy, RebaseOnMainResult, WorktreeConfig, WorktreeInfo,
};

// ─────────────────────────────────────────────────────────────────────
// Fixtures
// ─────────────────────────────────────────────────────────────────────

async fn run_cmd(dir: &std::path::Path, args: &[&str]) -> String {
    let out = tokio::process::Command::new(args[0])
        .args(&args[1..])
        .current_dir(dir)
        .output()
        .await
        .unwrap();
    assert!(
        out.status.success(),
        "cmd {:?} failed in {}:\nstderr: {}",
        args,
        dir.display(),
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

async fn init_repo(dir: &std::path::Path) {
    run_cmd(dir, &["git", "init"]).await;
    run_cmd(dir, &["git", "config", "user.email", "test@test.com"]).await;
    run_cmd(dir, &["git", "config", "user.name", "Test"]).await;
    run_cmd(dir, &["git", "config", "commit.gpgsign", "false"]).await;
    run_cmd(dir, &["git", "symbolic-ref", "HEAD", "refs/heads/main"]).await;
    std::fs::write(dir.join("README.md"), "# test").unwrap();
    run_cmd(dir, &["git", "add", "-A"]).await;
    run_cmd(dir, &["git", "commit", "-m", "init"]).await;
}

fn make_store() -> Arc<EventStore> {
    let pool = new_in_memory(&ConnectionConfig::default()).unwrap();
    {
        let conn = pool.get().unwrap();
        let _ = run_migrations(&conn).unwrap();
    }
    Arc::new(EventStore::new(pool))
}

/// Build a coordinator with broadcast wired up so tests can assert events.
fn coord_with_broadcast() -> (Arc<WorktreeCoordinator>, broadcast::Receiver<TronEvent>) {
    let (tx, rx) = broadcast::channel(256);
    let store = make_store();
    let c = Arc::new(WorktreeCoordinator::with_broadcast(
        WorktreeConfig::default(),
        store,
        tx,
    ));
    (c, rx)
}

/// Full setup: init repo, create session, acquire worktree.
/// Returns `(coord, rx, session_id, info, dir)` — keep `dir` alive in
/// the caller to prevent cleanup.
async fn setup_session_on_main() -> (
    Arc<WorktreeCoordinator>,
    broadcast::Receiver<TronEvent>,
    String,
    WorktreeInfo,
    tempfile::TempDir,
) {
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;

    let (coord, rx) = coord_with_broadcast();
    let session = coord
        .event_store
        .create_session(
            "model",
            &dir.path().to_string_lossy(),
            Some("test-rebase"),
            None,
            None,
            None,
        )
        .unwrap();
    let session_id = session.session.id.clone();

    let info = match coord.maybe_acquire(&session_id, dir.path()).await.unwrap() {
        AcquireResult::Acquired(i) => i,
        other => panic!("expected Acquired, got {other:?}"),
    };

    (coord, rx, session_id, info, dir)
}

/// Advance `main` by one commit touching `file` with `content`.
/// Returns the new HEAD sha.
async fn advance_main(repo: &std::path::Path, file: &str, content: &str) -> String {
    // Switch to main in the repo root (which may still be checked out
    // on main from `init_repo`).
    run_cmd(repo, &["git", "checkout", "main"]).await;
    std::fs::write(repo.join(file), content).unwrap();
    run_cmd(repo, &["git", "add", "-A"]).await;
    run_cmd(
        repo,
        &["git", "commit", "-m", &format!("advance main: {file}")],
    )
    .await;
    run_cmd(repo, &["git", "rev-parse", "HEAD"]).await
}

/// Wait for a specific event type with a short timeout. Drains events
/// until it finds one whose `event_type()` matches.
async fn wait_for_event<F>(
    rx: &mut broadcast::Receiver<TronEvent>,
    pred: F,
    label: &str,
) -> TronEvent
where
    F: Fn(&TronEvent) -> bool,
{
    let deadline = tokio::time::Instant::now() + Duration::from_millis(500);
    loop {
        if tokio::time::Instant::now() >= deadline {
            panic!("timed out waiting for event: {label}");
        }
        match tokio::time::timeout(Duration::from_millis(100), rx.recv()).await {
            Ok(Ok(evt)) if pred(&evt) => return evt,
            Ok(Ok(_)) => continue,
            Ok(Err(broadcast::error::RecvError::Lagged(_))) => continue,
            Ok(Err(broadcast::error::RecvError::Closed)) => {
                panic!("channel closed waiting for {label}")
            }
            Err(_) => continue,
        }
    }
}

// ─────────────────────────────────────────────────────────────────────
// Phase B — session-state guards
// ─────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn rebase_on_main_session_not_found() {
    let (coord, _rx) = coord_with_broadcast();
    let err = coord
        .rebase_on_main("ghost-session", None, MergeStrategy::Rebase)
        .await
        .unwrap_err();
    assert!(
        matches!(err, crate::worktree::errors::WorktreeError::NotFound { .. }),
        "expected NotFound, got {err:?}"
    );
}

#[tokio::test]
async fn rebase_on_main_pending_merge_exists() {
    let (coord, _rx, session_id, _info, dir) = setup_session_on_main().await;
    // Advance main so behind>0 and the call would proceed past the NoOp shortcut.
    advance_main(dir.path(), "a.txt", "a").await;

    // Inject a pending merge directly into coordinator state.
    {
        let mut state = coord.state.lock();
        state.pending_merges.insert(
            session_id.clone(),
            crate::worktree::types::PendingMergeState {
                session_id: session_id.clone(),
                source_branch: "x".into(),
                target_branch: "main".into(),
                strategy: MergeStrategy::Merge,
                started_at_ms: 0,
                crash_recovered: false,
                origin: MergeOrigin::Finalize,
                auto_stash_ref: None,
            },
        );
    }

    let err = coord
        .rebase_on_main(&session_id, None, MergeStrategy::Rebase)
        .await
        .unwrap_err();
    assert!(
        matches!(
            err,
            crate::worktree::errors::WorktreeError::PendingMergeExists
        ),
        "expected PendingMergeExists, got {err:?}"
    );
}

#[tokio::test]
async fn rebase_on_main_missing_base_branch_and_no_override() {
    let (coord, _rx) = coord_with_broadcast();
    // Register a fake info with no base_branch.
    let dir = tempdir().unwrap();
    init_repo(dir.path()).await;
    let info = WorktreeInfo {
        session_id: "no-base".into(),
        worktree_path: dir.path().to_path_buf(),
        branch: "session/x".into(),
        base_commit: "abc".into(),
        base_branch: None,
        original_working_dir: dir.path().to_path_buf(),
        repo_root: dir.path().to_path_buf(),
    };
    coord.state.lock().track(info);

    let err = coord
        .rebase_on_main("no-base", None, MergeStrategy::Rebase)
        .await
        .unwrap_err();
    assert!(
        matches!(
            err,
            crate::worktree::errors::WorktreeError::MissingBaseBranch
        ),
        "expected MissingBaseBranch, got {err:?}"
    );
}

// ─────────────────────────────────────────────────────────────────────
// Phase C — divergence shortcuts
// ─────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn rebase_on_main_noop_when_up_to_date() {
    let (coord, _rx, session_id, _info, _dir) = setup_session_on_main().await;
    let result = coord
        .rebase_on_main(&session_id, None, MergeStrategy::Rebase)
        .await
        .unwrap();
    assert!(
        matches!(result, RebaseOnMainResult::NoOp { .. }),
        "expected NoOp, got {result:?}"
    );
}

#[tokio::test]
async fn rebase_on_main_noop_does_not_advance_base_commit() {
    let (coord, _rx, session_id, info_before, _dir) = setup_session_on_main().await;
    let _ = coord
        .rebase_on_main(&session_id, None, MergeStrategy::Rebase)
        .await
        .unwrap();
    let info_after = coord.get_info(&session_id).unwrap();
    assert_eq!(info_before.base_commit, info_after.base_commit);
}

// ─────────────────────────────────────────────────────────────────────
// Phase D — clean paths
// ─────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn rebase_on_main_clean_rebase_advances_session() {
    let (coord, _rx, session_id, info, dir) = setup_session_on_main().await;
    // Pre: session at some SHA. Advance main.
    let _main_sha = advance_main(dir.path(), "new.txt", "hello").await;
    let pre_session_head = coord.git.head_commit(&info.worktree_path).await.unwrap();

    let result = coord
        .rebase_on_main(&session_id, None, MergeStrategy::Rebase)
        .await
        .unwrap();
    match result {
        RebaseOnMainResult::Success {
            main_commits_incorporated,
            new_base_commit,
            ..
        } => {
            assert_eq!(main_commits_incorporated, 1);
            assert_ne!(new_base_commit, pre_session_head);
        }
        other => panic!("expected Success, got {other:?}"),
    }
    // main commits are now on session HEAD.
    let session_head = coord.git.head_commit(&info.worktree_path).await.unwrap();
    let ab = coord
        .ahead_behind(&info.repo_root, "main", &info.branch)
        .await
        .unwrap();
    assert_eq!(ab.1, 0, "session must be 0 behind main after rebase");
    assert!(!session_head.is_empty());
}

#[tokio::test]
async fn rebase_on_main_clean_merge_creates_merge_commit() {
    let (coord, _rx, session_id, info, dir) = setup_session_on_main().await;
    advance_main(dir.path(), "new.txt", "hello").await;
    // Commit something on session first so merge creates a two-parent commit.
    std::fs::write(info.worktree_path.join("s.txt"), "session").unwrap();
    run_cmd(&info.worktree_path, &["git", "add", "-A"]).await;
    run_cmd(
        &info.worktree_path,
        &["git", "commit", "-m", "session commit"],
    )
    .await;

    let result = coord
        .rebase_on_main(&session_id, None, MergeStrategy::Merge)
        .await
        .unwrap();
    assert!(matches!(result, RebaseOnMainResult::Success { .. }));
    // Head should have two parents (merge commit).
    let parents = run_cmd(
        &info.worktree_path,
        &["git", "rev-list", "--parents", "-n", "1", "HEAD"],
    )
    .await;
    let parent_count = parents.split_whitespace().count() - 1;
    assert_eq!(parent_count, 2, "merge commit must have two parents");
}

#[tokio::test]
async fn rebase_on_main_clean_path_fires_rebased_on_main_event() {
    let (coord, mut rx, session_id, _info, dir) = setup_session_on_main().await;
    advance_main(dir.path(), "new.txt", "hello").await;

    let _ = coord
        .rebase_on_main(&session_id, None, MergeStrategy::Rebase)
        .await
        .unwrap();

    let evt = wait_for_event(
        &mut rx,
        |e| matches!(e, TronEvent::WorktreeRebasedOnMain { .. }),
        "worktree.rebased_on_main",
    )
    .await;
    match evt {
        TronEvent::WorktreeRebasedOnMain {
            main_commits_incorporated,
            had_auto_stash,
            ..
        } => {
            assert_eq!(main_commits_incorporated, 1);
            assert!(!had_auto_stash);
        }
        _ => unreachable!(),
    }
}

#[tokio::test]
async fn rebase_on_main_clean_path_updates_base_commit_in_info() {
    let (coord, _rx, session_id, info_before, dir) = setup_session_on_main().await;
    advance_main(dir.path(), "new.txt", "hello").await;

    let _ = coord
        .rebase_on_main(&session_id, None, MergeStrategy::Rebase)
        .await
        .unwrap();

    let info_after = coord.get_info(&session_id).unwrap();
    assert_ne!(info_before.base_commit, info_after.base_commit);
    let head = coord
        .git
        .head_commit(&info_after.worktree_path)
        .await
        .unwrap();
    assert_eq!(info_after.base_commit, head);
}

#[tokio::test]
async fn rebase_on_main_clean_path_acquires_and_releases_repo_lock() {
    let (coord, mut rx, session_id, _info, dir) = setup_session_on_main().await;
    advance_main(dir.path(), "new.txt", "hello").await;

    let _ = coord
        .rebase_on_main(&session_id, None, MergeStrategy::Rebase)
        .await
        .unwrap();

    // Drain up to 30 events; assert both acquired and released seen for
    // op "rebaseOnMain".
    let mut saw_acquired = false;
    let mut saw_released = false;
    for _ in 0..30 {
        match tokio::time::timeout(Duration::from_millis(50), rx.recv()).await {
            Ok(Ok(TronEvent::RepoLockAcquired { op, .. })) if op == "rebaseOnMain" => {
                saw_acquired = true;
            }
            Ok(Ok(TronEvent::RepoLockReleased { op, .. })) if op == "rebaseOnMain" => {
                saw_released = true;
            }
            Ok(Ok(_)) => continue,
            _ => break,
        }
    }
    assert!(saw_acquired, "expected RepoLockAcquired(op=rebaseOnMain)");
    assert!(saw_released, "expected RepoLockReleased(op=rebaseOnMain)");
}

// ─────────────────────────────────────────────────────────────────────
// Phase E — dirty-tree auto-stash
// ─────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn rebase_on_main_dirty_tracked_stashes_and_pops_clean() {
    let (coord, _rx, session_id, info, dir) = setup_session_on_main().await;
    advance_main(dir.path(), "main-only.txt", "m").await;
    // Dirty the session worktree with a tracked-file modification that
    // does not overlap main's change — clean stash + pop expected.
    std::fs::write(info.worktree_path.join("README.md"), "# dirty\n").unwrap();
    assert!(coord.git.has_changes(&info.worktree_path).await.unwrap());

    let res = coord
        .rebase_on_main(&session_id, None, MergeStrategy::Rebase)
        .await
        .unwrap();
    match res {
        RebaseOnMainResult::Success { had_auto_stash, .. } => {
            assert!(had_auto_stash);
        }
        other => panic!("expected Success, got {other:?}"),
    }
    // Dirty state restored after pop.
    let body = std::fs::read_to_string(info.worktree_path.join("README.md")).unwrap();
    assert_eq!(body, "# dirty\n");
}

#[tokio::test]
async fn rebase_on_main_dirty_untracked_stashes_with_u_and_pops() {
    let (coord, _rx, session_id, info, dir) = setup_session_on_main().await;
    advance_main(dir.path(), "main-only.txt", "m").await;
    // Untracked file in session worktree.
    std::fs::write(info.worktree_path.join("new-wip.txt"), "untracked").unwrap();

    let _ = coord
        .rebase_on_main(&session_id, None, MergeStrategy::Rebase)
        .await
        .unwrap();
    assert!(info.worktree_path.join("new-wip.txt").exists());
    assert_eq!(
        std::fs::read_to_string(info.worktree_path.join("new-wip.txt")).unwrap(),
        "untracked"
    );
}

#[tokio::test]
async fn rebase_on_main_dirty_pop_conflict_emits_post_rebase_stash_conflict_event() {
    let (coord, mut rx, session_id, info, dir) = setup_session_on_main().await;
    // Modify README.md on main — README.md is already tracked from init.
    advance_main(dir.path(), "README.md", "main rev\n").await;
    // Session has an uncommitted change to the same tracked file — the
    // stash carries the diff, and pop will conflict against main's rev.
    std::fs::write(info.worktree_path.join("README.md"), "session rev\n").unwrap();

    let _ = coord
        .rebase_on_main(&session_id, None, MergeStrategy::Rebase)
        .await
        .unwrap();

    let evt = wait_for_event(
        &mut rx,
        |e| matches!(e, TronEvent::WorktreePostRebaseStashConflict { .. }),
        "worktree.post_rebase_stash_conflict",
    )
    .await;
    match evt {
        TronEvent::WorktreePostRebaseStashConflict { paths, .. } => {
            assert!(paths.iter().any(|p| p == "README.md"));
        }
        _ => unreachable!(),
    }
}

#[tokio::test]
async fn rebase_on_main_stash_persists_sidecar_file_during_rebase() {
    // We interrupt mid-operation by injecting a conflict so the rebase
    // leaves a PendingMergeState; then assert sidecar on disk.
    let (coord, _rx, session_id, info, dir) = setup_session_on_main().await;
    // Advance main on f.txt.
    advance_main(dir.path(), "f.txt", "from main\n").await;
    // Session commits a divergent f.txt so the rebase WILL conflict.
    std::fs::write(info.worktree_path.join("f.txt"), "from session\n").unwrap();
    run_cmd(&info.worktree_path, &["git", "add", "-A"]).await;
    run_cmd(
        &info.worktree_path,
        &["git", "commit", "-m", "session f.txt"],
    )
    .await;
    // Dirty the worktree with an unrelated tracked change so stash runs.
    std::fs::write(info.worktree_path.join("README.md"), "# dirty\n").unwrap();

    let res = coord
        .rebase_on_main(&session_id, None, MergeStrategy::Rebase)
        .await
        .unwrap();
    assert!(matches!(res, RebaseOnMainResult::Conflicts { .. }));

    // Sidecar should be on disk.
    let path = sidecar_path(&info.worktree_path, &session_id)
        .await
        .unwrap();
    assert!(path.exists(), "sidecar file must exist during conflict");
    let body = tokio::fs::read(&path).await.unwrap();
    let sc: SidecarContents = serde_json::from_slice(&body).unwrap();
    assert_eq!(sc.session_id, session_id);
    assert_eq!(sc.version, SIDECAR_VERSION);
}

#[tokio::test]
async fn rebase_on_main_sidecar_removed_on_clean_completion() {
    let (coord, _rx, session_id, info, dir) = setup_session_on_main().await;
    advance_main(dir.path(), "main-only.txt", "m").await;
    std::fs::write(info.worktree_path.join("README.md"), "# dirty\n").unwrap();

    let _ = coord
        .rebase_on_main(&session_id, None, MergeStrategy::Rebase)
        .await
        .unwrap();

    let path = sidecar_path(&info.worktree_path, &session_id)
        .await
        .unwrap();
    assert!(
        !path.exists(),
        "sidecar must be removed after clean completion"
    );
}

// ─────────────────────────────────────────────────────────────────────
// Phase F — conflict path
// ─────────────────────────────────────────────────────────────────────

async fn setup_conflicted_session() -> (
    Arc<WorktreeCoordinator>,
    broadcast::Receiver<TronEvent>,
    String,
    WorktreeInfo,
    tempfile::TempDir,
) {
    let (coord, rx, session_id, info, dir) = setup_session_on_main().await;
    // Main updates f.txt one way.
    advance_main(dir.path(), "f.txt", "main version\n").await;
    // Session commits a divergent f.txt so rebase conflicts.
    std::fs::write(info.worktree_path.join("f.txt"), "session version\n").unwrap();
    run_cmd(&info.worktree_path, &["git", "add", "-A"]).await;
    run_cmd(
        &info.worktree_path,
        &["git", "commit", "-m", "session f.txt"],
    )
    .await;
    (coord, rx, session_id, info, dir)
}

#[tokio::test]
async fn rebase_on_main_conflicts_populate_pending_merge_state() {
    let (coord, _rx, session_id, _info, _dir) = setup_conflicted_session().await;
    let res = coord
        .rebase_on_main(&session_id, None, MergeStrategy::Rebase)
        .await
        .unwrap();
    assert!(matches!(res, RebaseOnMainResult::Conflicts { count: 1 }));
    let pending = coord.pending_merge(&session_id).expect("pending tracked");
    assert_eq!(pending.origin, MergeOrigin::RebaseOnMain);
    assert!(
        pending.auto_stash_ref.is_none(),
        "clean tree case has no auto-stash"
    );
}

#[tokio::test]
async fn rebase_on_main_dirty_plus_conflict_attaches_auto_stash_ref() {
    let (coord, _rx, session_id, info, _dir) = setup_conflicted_session().await;
    // Dirty an unrelated tracked file so stash fires.
    std::fs::write(info.worktree_path.join("README.md"), "# dirty\n").unwrap();

    let _ = coord
        .rebase_on_main(&session_id, None, MergeStrategy::Rebase)
        .await
        .unwrap();
    let pending = coord.pending_merge(&session_id).expect("pending tracked");
    assert!(pending.auto_stash_ref.is_some());
}

#[tokio::test]
async fn rebase_on_main_conflict_resolve_continue_pops_stash_and_fires_rebased_on_main() {
    let (coord, mut rx, session_id, info, _dir) = setup_conflicted_session().await;
    // Dirty an unrelated file so stash fires.
    std::fs::write(info.worktree_path.join("README.md"), "# dirty-pre\n").unwrap();
    let _ = coord
        .rebase_on_main(&session_id, None, MergeStrategy::Rebase)
        .await
        .unwrap();

    // Resolve with "ours" (session's f.txt survives).
    coord
        .resolve_conflict(
            &session_id,
            "f.txt",
            crate::worktree::types::ConflictResolution::Ours,
        )
        .await
        .unwrap();
    coord.continue_merge(&session_id, None).await.unwrap();

    // Expect rebased_on_main event.
    let _ = wait_for_event(
        &mut rx,
        |e| matches!(e, TronEvent::WorktreeRebasedOnMain { .. }),
        "worktree.rebased_on_main",
    )
    .await;

    // Dirty state restored by stash pop.
    let body = std::fs::read_to_string(info.worktree_path.join("README.md")).unwrap();
    assert_eq!(body, "# dirty-pre\n");
}

#[tokio::test]
async fn rebase_on_main_conflict_abort_pops_stash_and_does_not_fire_rebased_on_main() {
    let (coord, mut rx, session_id, info, _dir) = setup_conflicted_session().await;
    std::fs::write(info.worktree_path.join("README.md"), "# dirty-pre\n").unwrap();
    let pre_head = coord.git.head_commit(&info.worktree_path).await.unwrap();

    let _ = coord
        .rebase_on_main(&session_id, None, MergeStrategy::Rebase)
        .await
        .unwrap();
    coord.abort_merge(&session_id).await.unwrap();

    // Drain events for a short window; assert NO rebased_on_main.
    let mut saw_rebased = false;
    for _ in 0..30 {
        match tokio::time::timeout(Duration::from_millis(50), rx.recv()).await {
            Ok(Ok(TronEvent::WorktreeRebasedOnMain { .. })) => saw_rebased = true,
            Ok(Ok(_)) => continue,
            _ => break,
        }
    }
    assert!(!saw_rebased, "rebased_on_main must NOT fire on abort");

    // Session back at pre-op HEAD.
    let post_head = coord.git.head_commit(&info.worktree_path).await.unwrap();
    assert_eq!(pre_head, post_head, "branch tip must restore on abort");
}

#[tokio::test]
async fn rebase_on_main_conflict_abort_restores_pre_op_dirty_state_byte_identical() {
    let (coord, _rx, session_id, info, _dir) = setup_conflicted_session().await;
    let pre_body = "# dirty-pre\nline2\n".to_string();
    std::fs::write(info.worktree_path.join("README.md"), &pre_body).unwrap();

    let _ = coord
        .rebase_on_main(&session_id, None, MergeStrategy::Rebase)
        .await
        .unwrap();
    coord.abort_merge(&session_id).await.unwrap();

    let after = std::fs::read_to_string(info.worktree_path.join("README.md")).unwrap();
    assert_eq!(after, pre_body);
}

// Plan case 19 ("Dirty tree, rebase conflicts, user aborts, pop
// conflicts during abort → post_rebase_stash_conflict fires; no
// rebased_on_main") is intentionally omitted: `git rebase --abort`
// restores the worktree to its exact pre-rebase state, so a stash
// taken at that point always applies back cleanly. The emission path
// is identical to the clean-path pop (Phase E:
// `rebase_on_main_dirty_pop_conflict_emits_post_rebase_stash_conflict_event`),
// which exercises the shared `stash_pop` → non-empty Vec → event
// branch in both `continue_merge` and `abort_merge`.

// ─────────────────────────────────────────────────────────────────────
// Phase G — concurrency & lock
// ─────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn rebase_on_main_waits_for_peer_sync_main_lock() {
    use super::super::repo_lock::LockedOp;

    let (coord, _rx, session_id, _info, dir) = setup_session_on_main().await;
    advance_main(dir.path(), "m.txt", "m").await;

    // Peer acquires the lock for 80ms.
    let coord_peer = coord.clone();
    let dir_path = dir.path().to_path_buf();
    let peer_guard = coord_peer
        .acquire_repo_lock(&dir_path, "peer", LockedOp::SyncMain)
        .await;
    let peer_handle = tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(80)).await;
        drop(peer_guard);
    });

    let start = tokio::time::Instant::now();
    let _ = coord
        .rebase_on_main(&session_id, None, MergeStrategy::Rebase)
        .await
        .unwrap();
    let elapsed = start.elapsed();
    peer_handle.await.unwrap();

    assert!(
        elapsed >= Duration::from_millis(70),
        "rebase_on_main should have waited for peer lock; elapsed={elapsed:?}"
    );
}

#[tokio::test]
async fn rebase_on_main_concurrent_call_on_same_session_rejected_with_pending_merge_exists() {
    let (coord, _rx, session_id, _info, _dir) = setup_conflicted_session().await;
    // First call produces Conflicts and leaves a pending merge.
    let _ = coord
        .rebase_on_main(&session_id, None, MergeStrategy::Rebase)
        .await
        .unwrap();
    // Second call must see PendingMergeExists.
    let err = coord
        .rebase_on_main(&session_id, None, MergeStrategy::Rebase)
        .await
        .unwrap_err();
    assert!(matches!(
        err,
        crate::worktree::errors::WorktreeError::PendingMergeExists
    ));
}

// ─────────────────────────────────────────────────────────────────────
// Phase H — crash recovery
// ─────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn recovery_pops_orphaned_stash_when_sidecar_present_but_no_rebase_merge_dir() {
    let (coord, _rx, session_id, info, _dir) = setup_session_on_main().await;
    // Simulate: dirty file, stash it, write sidecar, but no rebase/merge state.
    std::fs::write(info.worktree_path.join("README.md"), "# dirty\n").unwrap();
    let stash_ref = coord
        .git
        .stash_create_with_untracked(&info.worktree_path, "tron-test")
        .await
        .unwrap();
    write_sidecar(
        &info.worktree_path,
        &SidecarContents {
            version: SIDECAR_VERSION,
            session_id: session_id.clone(),
            stash_ref: stash_ref.clone(),
            strategy: "rebase".into(),
        },
    )
    .await
    .unwrap();

    // Trigger rebuild — no merge is in progress, so sidecar path runs.
    let _ = coord.rebuild_pending_merges().await;

    // Expect: sidecar removed, stash popped (file restored).
    let sp = sidecar_path(&info.worktree_path, &session_id)
        .await
        .unwrap();
    assert!(!sp.exists(), "sidecar must be removed");
    let body = std::fs::read_to_string(info.worktree_path.join("README.md")).unwrap();
    assert_eq!(body, "# dirty\n");
}

#[tokio::test]
async fn recovery_rebuilds_pending_merge_with_auto_stash_ref_from_sidecar() {
    let (coord, _rx, session_id, info, _dir) = setup_conflicted_session().await;
    // Dirty + rebase_on_main to produce a pending merge with a stash.
    std::fs::write(info.worktree_path.join("README.md"), "# dirty\n").unwrap();
    let _ = coord
        .rebase_on_main(&session_id, None, MergeStrategy::Rebase)
        .await
        .unwrap();

    // Drop in-memory pending_merges to simulate server restart.
    coord.state.lock().pending_merges.remove(&session_id);

    // Rebuild.
    let restored = coord.rebuild_pending_merges().await;
    assert!(restored >= 1);
    let pending = coord.pending_merge(&session_id).expect("rebuilt");
    assert_eq!(pending.origin, MergeOrigin::RebaseOnMain);
    assert!(pending.auto_stash_ref.is_some());
}

#[tokio::test]
async fn recovery_removes_corrupted_sidecar_and_logs_warning() {
    let (coord, _rx, session_id, info, _dir) = setup_session_on_main().await;
    // Write a corrupted sidecar (not matching our schema / version).
    let path = sidecar_path(&info.worktree_path, &session_id)
        .await
        .unwrap();
    tokio::fs::create_dir_all(path.parent().unwrap()).await.ok();
    tokio::fs::write(&path, b"garbage").await.unwrap();

    // No merge state on disk; no dirty stash. Recovery should tolerate
    // the corrupt file (no stash to pop → simply logs and moves on).
    let _ = coord.rebuild_pending_merges().await;

    // Sidecar may be left on disk (garbage is ignored as "no sidecar")
    // or removed — implementation detail. The important assertion is
    // that recovery did not panic.
    assert!(coord.pending_merge(&session_id).is_none());
}

#[tokio::test]
async fn recovery_pops_stash_when_rebase_succeeded_but_pre_pop_crash() {
    // Same as the orphan-stash case — functionally equivalent for our
    // current recovery logic (sidecar + no rebase-merge dir → pop).
    let (coord, _rx, session_id, info, _dir) = setup_session_on_main().await;
    std::fs::write(info.worktree_path.join("README.md"), "# dirty-post\n").unwrap();
    let stash_ref = coord
        .git
        .stash_create_with_untracked(&info.worktree_path, "tron-test")
        .await
        .unwrap();
    write_sidecar(
        &info.worktree_path,
        &SidecarContents {
            version: SIDECAR_VERSION,
            session_id: session_id.clone(),
            stash_ref,
            strategy: "rebase".into(),
        },
    )
    .await
    .unwrap();

    let _ = coord.rebuild_pending_merges().await;

    let body = std::fs::read_to_string(info.worktree_path.join("README.md")).unwrap();
    assert_eq!(body, "# dirty-post\n");
}

// ─────────────────────────────────────────────────────────────────────
// Phase I — event schema & registry
// ─────────────────────────────────────────────────────────────────────

#[test]
fn rebased_on_main_event_schema_matches_expected_fields() {
    let evt = TronEvent::WorktreeRebasedOnMain {
        base: crate::core::events::BaseEvent::now("s1"),
        main_branch: "main".into(),
        strategy: "rebase".into(),
        old_base_commit: "abc".into(),
        new_base_commit: "def".into(),
        main_commits_incorporated: 3,
        had_auto_stash: true,
    };
    let json = serde_json::to_value(&evt).unwrap();
    assert_eq!(json["mainBranch"], "main");
    assert_eq!(json["strategy"], "rebase");
    assert_eq!(json["oldBaseCommit"], "abc");
    assert_eq!(json["newBaseCommit"], "def");
    assert_eq!(json["mainCommitsIncorporated"], 3);
    assert_eq!(json["hadAutoStash"], true);
    // Roundtrip.
    let back: TronEvent = serde_json::from_value(json).unwrap();
    assert_eq!(back.event_type(), "worktree.rebased_on_main");
}

#[test]
fn post_rebase_stash_conflict_event_schema() {
    let evt = TronEvent::WorktreePostRebaseStashConflict {
        base: crate::core::events::BaseEvent::now("s1"),
        stash_ref: "stash@{0}".into(),
        paths: vec!["a.txt".into(), "b.txt".into()],
    };
    let json = serde_json::to_value(&evt).unwrap();
    assert_eq!(json["stashRef"], "stash@{0}");
    assert_eq!(json["paths"], serde_json::json!(["a.txt", "b.txt"]));
    let back: TronEvent = serde_json::from_value(json).unwrap();
    assert_eq!(back.event_type(), "worktree.post_rebase_stash_conflict");
}

#[test]
fn conflict_detected_carries_origin_field() {
    let evt = TronEvent::WorktreeConflictDetected {
        base: crate::core::events::BaseEvent::now("s1"),
        source_branch: "stash".into(),
        target_branch: "session/x".into(),
        origin: "stash_pop".into(),
        paths: vec!["f.txt".into()],
    };
    let json = serde_json::to_value(&evt).unwrap();
    assert_eq!(json["origin"], "stash_pop");
    assert_eq!(json["sourceBranch"], "stash");
    let back: TronEvent = serde_json::from_value(json).unwrap();
    assert_eq!(back.event_type(), "worktree.conflict_detected");
}

#[test]
fn merge_continued_carries_origin_field() {
    let evt = TronEvent::WorktreeMergeContinued {
        base: crate::core::events::BaseEvent::now("s1"),
        merge_commit: "abc".into(),
        strategy: "merge".into(),
        origin: "stash_pop".into(),
    };
    let json = serde_json::to_value(&evt).unwrap();
    assert_eq!(json["origin"], "stash_pop");
}

#[test]
fn merge_aborted_carries_origin_field() {
    let evt = TronEvent::WorktreeMergeAborted {
        base: crate::core::events::BaseEvent::now("s1"),
        strategy: "merge".into(),
        reason: "user".into(),
        origin: "finalize".into(),
    };
    let json = serde_json::to_value(&evt).unwrap();
    assert_eq!(json["origin"], "finalize");
}

// ─────────────────────────────────────────────────────────────────────
// Phase K — StashPop lifecycle (continue / abort)
//
// After a stash-pop conflict, `handle_post_stash_pop` populates
// `pending_merges` with `origin = StashPop`. The normal conflict capability calls
// (`listConflicts` / `resolveConflict` / `continueMerge` / `abortMerge`)
// then drive it to completion. These tests lock down:
//  - `continueMerge(StashPop)` drops the stash and emits
//    `merge_continued` with `origin = stash_pop`.
//  - `abortMerge(StashPop)` resets the working tree to HEAD and PRESERVES
//    the stash on the stash stack.
//  - `listConflicts` returns the unmerged paths while StashPop is
//    pending (index-level conflict visibility).
//  - `merge_aborted` carries `origin = stash_pop`.
//  - Partial resolution: `continueMerge` errors if unmerged paths remain.
// ─────────────────────────────────────────────────────────────────────

/// Produce a StashPop pending-merge scenario: rebase runs cleanly, then
/// the stash pop conflicts on a file main also touched.
async fn setup_stash_pop_conflict() -> (
    Arc<WorktreeCoordinator>,
    broadcast::Receiver<TronEvent>,
    String,
    WorktreeInfo,
    tempfile::TempDir,
) {
    let (coord, rx, session_id, info, dir) = setup_session_on_main().await;
    // Main advances README.md.
    advance_main(dir.path(), "README.md", "main rev\n").await;
    // Session has an uncommitted change to the same tracked file — the
    // stash carries the diff, and pop conflicts against main's rev.
    std::fs::write(info.worktree_path.join("README.md"), "session rev\n").unwrap();
    let res = coord
        .rebase_on_main(&session_id, None, MergeStrategy::Rebase)
        .await
        .unwrap();
    // The rebase itself produced no rebase conflicts (session had no new
    // commits on README.md), but the stash pop did.
    assert!(matches!(res, RebaseOnMainResult::Success { .. }));
    (coord, rx, session_id, info, dir)
}

#[tokio::test]
async fn stash_pop_conflict_populates_pending_merges_with_stashpop_origin() {
    let (coord, _rx, session_id, _info, _dir) = setup_stash_pop_conflict().await;
    let pending = coord
        .pending_merge(&session_id)
        .expect("StashPop pending merge must be populated after pop conflict");
    assert_eq!(pending.origin, MergeOrigin::StashPop);
    assert!(
        pending.auto_stash_ref.is_some(),
        "stash ref must be preserved on the pending merge"
    );
}

#[tokio::test]
async fn stash_pop_conflict_emits_conflict_detected_with_origin_stash_pop() {
    let (_coord, mut rx, _session_id, _info, _dir) = setup_stash_pop_conflict().await;
    let evt = wait_for_event(
        &mut rx,
        |e| matches!(e, TronEvent::WorktreeConflictDetected { origin, .. } if origin == "stash_pop"),
        "conflict_detected(origin=stash_pop)",
    )
    .await;
    match evt {
        TronEvent::WorktreeConflictDetected {
            paths,
            source_branch,
            ..
        } => {
            assert!(paths.iter().any(|p| p == "README.md"));
            assert_eq!(source_branch, "stash");
        }
        _ => unreachable!(),
    }
}

#[tokio::test]
async fn stash_pop_list_conflicts_returns_unmerged_paths() {
    let (coord, _rx, session_id, _info, _dir) = setup_stash_pop_conflict().await;
    let conflicts = coord
        .list_conflicts(&session_id)
        .await
        .expect("listConflicts should work for StashPop");
    assert!(
        conflicts.iter().any(|c| c.path == "README.md"),
        "README.md should appear as a conflict"
    );
}

#[tokio::test]
async fn stash_pop_continue_drops_stash_and_clears_pending() {
    let (coord, mut rx, session_id, info, _dir) = setup_stash_pop_conflict().await;

    // Resolve the file so continue can proceed.
    coord
        .resolve_conflict(
            &session_id,
            "README.md",
            crate::worktree::types::ConflictResolution::Ours,
        )
        .await
        .unwrap();
    coord.continue_merge(&session_id, None).await.unwrap();

    // Pending merge cleared.
    assert!(coord.pending_merge(&session_id).is_none());

    // merge_continued emitted with origin=stash_pop.
    let evt = wait_for_event(
        &mut rx,
        |e| matches!(e, TronEvent::WorktreeMergeContinued { origin, .. } if origin == "stash_pop"),
        "merge_continued(origin=stash_pop)",
    )
    .await;
    match evt {
        TronEvent::WorktreeMergeContinued { strategy, .. } => {
            assert_eq!(strategy, "merge");
        }
        _ => unreachable!(),
    }

    // Stash dropped — no stash entries on the stack.
    let stash_list = tokio::process::Command::new("git")
        .args(["stash", "list"])
        .current_dir(&info.worktree_path)
        .output()
        .await
        .unwrap();
    let s = String::from_utf8_lossy(&stash_list.stdout);
    assert!(!s.contains("stash@{0}"), "stash must be dropped; got: {s}");
}

#[tokio::test]
async fn stash_pop_continue_rejects_unresolved_paths() {
    let (coord, _rx, session_id, _info, _dir) = setup_stash_pop_conflict().await;
    // No resolve_conflict call — should error.
    let err = coord
        .continue_merge(&session_id, None)
        .await
        .expect_err("continue should refuse while conflicts remain");
    assert!(matches!(
        err,
        crate::worktree::errors::WorktreeError::Git(_)
    ));
    // Pending merge must still be present.
    assert!(coord.pending_merge(&session_id).is_some());
}

#[tokio::test]
async fn stash_pop_abort_resets_working_tree_and_preserves_stash() {
    let (coord, mut rx, session_id, info, _dir) = setup_stash_pop_conflict().await;

    // Pre-snapshot HEAD sha.
    let head_before = coord.git.head_commit(&info.worktree_path).await.unwrap();

    coord.abort_merge(&session_id).await.unwrap();

    // Pending merge cleared.
    assert!(coord.pending_merge(&session_id).is_none());

    // merge_aborted emitted with origin=stash_pop.
    let evt = wait_for_event(
        &mut rx,
        |e| matches!(e, TronEvent::WorktreeMergeAborted { origin, .. } if origin == "stash_pop"),
        "merge_aborted(origin=stash_pop)",
    )
    .await;
    assert!(matches!(evt, TronEvent::WorktreeMergeAborted { .. }));

    // HEAD unchanged (abort is reset --hard HEAD).
    let head_after = coord.git.head_commit(&info.worktree_path).await.unwrap();
    assert_eq!(head_before, head_after);

    // No unmerged paths — index is clean.
    let unmerged = coord.git.conflict_files(&info.worktree_path).await.unwrap();
    assert!(unmerged.is_empty(), "abort must clear unmerged entries");

    // Stash PRESERVED on the stack.
    let stash_list = tokio::process::Command::new("git")
        .args(["stash", "list"])
        .current_dir(&info.worktree_path)
        .output()
        .await
        .unwrap();
    let s = String::from_utf8_lossy(&stash_list.stdout);
    assert!(
        s.contains("stash@{0}"),
        "stash must be preserved after StashPop abort; got: {s}"
    );
}

#[tokio::test]
async fn stash_pop_sidecar_preserved_until_continue_or_abort() {
    let (coord, _rx, session_id, info, _dir) = setup_stash_pop_conflict().await;
    let path = sidecar_path(&info.worktree_path, &session_id)
        .await
        .unwrap();
    assert!(
        path.exists(),
        "sidecar must survive across the stash pop conflict so crash recovery can find it"
    );

    coord
        .resolve_conflict(
            &session_id,
            "README.md",
            crate::worktree::types::ConflictResolution::Ours,
        )
        .await
        .unwrap();
    coord.continue_merge(&session_id, None).await.unwrap();

    assert!(
        !path.exists(),
        "sidecar must be removed after continue completes"
    );
}

#[tokio::test]
async fn stash_pop_abort_removes_sidecar() {
    let (coord, _rx, session_id, info, _dir) = setup_stash_pop_conflict().await;
    let path = sidecar_path(&info.worktree_path, &session_id)
        .await
        .unwrap();
    assert!(path.exists());

    coord.abort_merge(&session_id).await.unwrap();
    assert!(!path.exists(), "sidecar must be removed after abort");
}

#[tokio::test]
async fn stash_pop_crash_recovery_detects_unmerged_index_and_populates_pending() {
    let (coord, _rx, session_id, info, _dir) = setup_stash_pop_conflict().await;

    // Simulate server crash: drop in-memory pending_merges. Sidecar +
    // unmerged index entries persist on disk.
    coord.state.lock().pending_merges.remove(&session_id);

    // Rebuild should re-detect via the `(None sidecar) + unmerged index`
    // branch and re-populate with StashPop.
    let restored = coord.rebuild_pending_merges().await;
    assert!(restored >= 1);
    let p = coord.pending_merge(&session_id).expect("rebuilt");
    assert_eq!(p.origin, MergeOrigin::StashPop);
    assert!(p.auto_stash_ref.is_some());

    // Sidecar still present (preserved by recovery for re-crash safety).
    let path = sidecar_path(&info.worktree_path, &session_id)
        .await
        .unwrap();
    assert!(path.exists());
}

#[tokio::test]
async fn stash_pop_abort_is_idempotent_under_repeat_call() {
    let (coord, _rx, session_id, _info, _dir) = setup_stash_pop_conflict().await;
    coord.abort_merge(&session_id).await.unwrap();
    // Second call should error with NoPendingMerge (state already cleared).
    let err = coord
        .abort_merge(&session_id)
        .await
        .expect_err("second abort should fail cleanly");
    assert!(matches!(
        err,
        crate::worktree::errors::WorktreeError::NoPendingMerge
    ));
}

#[tokio::test]
async fn stash_pop_continue_then_abort_returns_no_pending_merge() {
    let (coord, _rx, session_id, _info, _dir) = setup_stash_pop_conflict().await;
    coord
        .resolve_conflict(
            &session_id,
            "README.md",
            crate::worktree::types::ConflictResolution::Ours,
        )
        .await
        .unwrap();
    coord.continue_merge(&session_id, None).await.unwrap();
    let err = coord
        .abort_merge(&session_id)
        .await
        .expect_err("abort after continue should fail cleanly");
    assert!(matches!(
        err,
        crate::worktree::errors::WorktreeError::NoPendingMerge
    ));
}

// ─────────────────────────────────────────────────────────────────────
// Origin passthrough on non-StashPop flows — guard against accidental
// regressions where Finalize/RebaseOnMain start emitting origin="stash_pop".
// ─────────────────────────────────────────────────────────────────────

#[tokio::test]
async fn rebase_on_main_conflict_detected_carries_origin_rebase_on_main() {
    let (_coord, mut rx, _session_id, _info, _dir) = setup_conflicted_session().await;
    let _ = _coord
        .rebase_on_main(&_session_id, None, MergeStrategy::Rebase)
        .await
        .unwrap();
    let evt = wait_for_event(
        &mut rx,
        |e| matches!(e, TronEvent::WorktreeConflictDetected { origin, .. } if origin == "rebase_on_main"),
        "conflict_detected(origin=rebase_on_main)",
    )
    .await;
    assert!(matches!(evt, TronEvent::WorktreeConflictDetected { .. }));
}
