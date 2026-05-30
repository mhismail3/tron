use super::*;
use crate::domains::worktree::test_fixtures::{
    add_commit, checkout_new_branch, init_repo, init_repo_with_origin, make_conflict,
    make_deleted_by_us_conflict, run_cmd, run_cmd_ok,
};
use crate::domains::worktree::types::ConflictKind;
use tempfile::tempdir;

// ── classifier unit tests ──────────────────────────────────────

#[test]
fn classify_push_error_non_fast_forward() {
    let e = classify_push_error(
        "! [rejected] main -> main (non-fast-forward)\nerror: failed to push".to_string(),
    );
    matches!(e, WorktreeError::NonFastForward(_))
        .then_some(())
        .expect("expected NonFastForward");
}

#[test]
fn classify_push_error_stale_lease() {
    let e = classify_push_error(
        "! [rejected] main -> main (stale info)\nhint: force-with-lease".to_string(),
    );
    matches!(e, WorktreeError::NonFastForward(_))
        .then_some(())
        .expect("stale lease should classify as NonFastForward");
}

#[test]
fn classify_remote_error_auth_publickey() {
    let e = classify_remote_error(WorktreeError::Git(
        "Permission denied (publickey). fatal: Could not read from remote repository.".to_string(),
    ));
    matches!(e, WorktreeError::AuthFailure(_))
        .then_some(())
        .expect("expected AuthFailure");
}

#[test]
fn classify_remote_error_network_host() {
    let e = classify_remote_error(WorktreeError::Git(
        "fatal: unable to access 'https://x/': Could not resolve host: x".to_string(),
    ));
    matches!(e, WorktreeError::NetworkTimeout(_))
        .then_some(())
        .expect("expected NetworkTimeout");
}

#[test]
fn classify_remote_error_no_remote() {
    let e = classify_remote_error(WorktreeError::Git(
        "fatal: No configured push destination.".to_string(),
    ));
    matches!(e, WorktreeError::NoRemoteConfigured(_))
        .then_some(())
        .expect("expected NoRemoteConfigured");
}

#[test]
fn classify_remote_error_passthrough_unknown() {
    let e = classify_remote_error(WorktreeError::Git("something else entirely".to_string()));
    assert!(matches!(e, WorktreeError::Git(_)));
}

// ── remote helpers ─────────────────────────────────────────────

#[tokio::test]
async fn remote_list_empty() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    assert!(git.remote_list(dir.path()).await.unwrap().is_empty());
}

#[tokio::test]
async fn remote_list_and_get_url() {
    let work = tempdir().unwrap();
    let origin = tempdir().unwrap();
    let git = init_repo_with_origin(work.path(), origin.path()).await;
    let remotes = git.remote_list(work.path()).await.unwrap();
    assert_eq!(remotes, vec!["origin"]);
    let url = git.remote_get_url(work.path(), "origin").await.unwrap();
    assert!(url.contains(&*origin.path().to_string_lossy()));
}

#[tokio::test]
async fn ls_remote_head_existing_branch() {
    let work = tempdir().unwrap();
    let origin = tempdir().unwrap();
    let git = init_repo_with_origin(work.path(), origin.path()).await;
    let sha = git
        .ls_remote_head(work.path(), "origin", "main")
        .await
        .unwrap();
    assert!(sha.is_some(), "expected sha for origin/main");
    assert_eq!(sha.as_ref().unwrap().len(), 40);
}

#[tokio::test]
async fn ls_remote_head_missing_branch_is_none() {
    let work = tempdir().unwrap();
    let origin = tempdir().unwrap();
    let git = init_repo_with_origin(work.path(), origin.path()).await;
    let sha = git
        .ls_remote_head(work.path(), "origin", "does-not-exist")
        .await
        .unwrap();
    assert!(sha.is_none());
}

// ── push ───────────────────────────────────────────────────────

#[tokio::test]
async fn push_dry_run_no_side_effects() {
    let work = tempdir().unwrap();
    let origin = tempdir().unwrap();
    let git = init_repo_with_origin(work.path(), origin.path()).await;

    // New commit locally, not yet pushed.
    let head_before_remote = git
        .ls_remote_head(work.path(), "origin", "main")
        .await
        .unwrap();

    add_commit(work.path(), "a.txt", "a", "local a").await;

    let out = git
        .push(
            work.path(),
            "origin",
            "main",
            false,
            false,
            true, /* dry_run */
        )
        .await
        .unwrap();
    assert!(out.success);
    assert!(out.dry_run);

    // Remote head is unchanged.
    let head_after = git
        .ls_remote_head(work.path(), "origin", "main")
        .await
        .unwrap();
    assert_eq!(head_before_remote, head_after);
}

#[tokio::test]
async fn push_real_advances_remote() {
    let work = tempdir().unwrap();
    let origin = tempdir().unwrap();
    let git = init_repo_with_origin(work.path(), origin.path()).await;
    let head_before = git
        .ls_remote_head(work.path(), "origin", "main")
        .await
        .unwrap();

    let local_head = add_commit(work.path(), "a.txt", "a", "local a").await;
    let out = git
        .push(work.path(), "origin", "main", false, false, false)
        .await
        .unwrap();
    assert!(out.success);

    let head_after = git
        .ls_remote_head(work.path(), "origin", "main")
        .await
        .unwrap();
    assert_ne!(head_before, head_after);
    assert_eq!(head_after.as_deref(), Some(local_head.as_str()));
}

#[tokio::test]
async fn push_non_ff_rejected() {
    // Two clones of the same origin diverge; the second to push is rejected.
    let base = tempdir().unwrap();
    let origin = base.path().join("origin.git");
    let work_a = base.path().join("a");
    let work_b = base.path().join("b");
    std::fs::create_dir_all(&origin).unwrap();
    run_cmd(&origin, &["git", "init", "--bare"]).await;
    run_cmd(&origin, &["git", "symbolic-ref", "HEAD", "refs/heads/main"]).await;

    // Seed origin via a throwaway clone.
    let seed = base.path().join("seed");
    run_cmd(
        base.path(),
        &[
            "git",
            "clone",
            &origin.to_string_lossy(),
            &seed.to_string_lossy(),
        ],
    )
    .await;
    run_cmd(&seed, &["git", "config", "user.email", "t@t"]).await;
    run_cmd(&seed, &["git", "config", "user.name", "t"]).await;
    run_cmd(&seed, &["git", "config", "commit.gpgsign", "false"]).await;
    std::fs::write(seed.join("README.md"), "init\n").unwrap();
    run_cmd(&seed, &["git", "add", "-A"]).await;
    run_cmd(&seed, &["git", "commit", "-m", "init"]).await;
    run_cmd(&seed, &["git", "push", "origin", "main"]).await;

    // Clone a and b.
    for d in [&work_a, &work_b] {
        run_cmd(
            base.path(),
            &[
                "git",
                "clone",
                &origin.to_string_lossy(),
                &d.to_string_lossy(),
            ],
        )
        .await;
        run_cmd(d, &["git", "config", "user.email", "t@t"]).await;
        run_cmd(d, &["git", "config", "user.name", "t"]).await;
        run_cmd(d, &["git", "config", "commit.gpgsign", "false"]).await;
    }

    // a commits + pushes.
    std::fs::write(work_a.join("a.txt"), "a").unwrap();
    run_cmd(&work_a, &["git", "add", "-A"]).await;
    run_cmd(&work_a, &["git", "commit", "-m", "a"]).await;
    run_cmd(&work_a, &["git", "push", "origin", "main"]).await;

    // b commits but hasn't fetched; push must be rejected.
    std::fs::write(work_b.join("b.txt"), "b").unwrap();
    run_cmd(&work_b, &["git", "add", "-A"]).await;
    run_cmd(&work_b, &["git", "commit", "-m", "b"]).await;

    let git = GitExecutor::new(30_000);
    let err = git
        .push(&work_b, "origin", "main", false, false, false)
        .await
        .expect_err("push should be rejected");
    assert!(
        matches!(err, WorktreeError::NonFastForward(_)),
        "expected NonFastForward, got {err:?}"
    );
}

#[tokio::test]
async fn push_set_upstream_creates_tracking() {
    let work = tempdir().unwrap();
    let origin = tempdir().unwrap();
    let git = init_repo_with_origin(work.path(), origin.path()).await;

    // New branch, no upstream yet.
    checkout_new_branch(work.path(), "feature").await;
    add_commit(work.path(), "f.txt", "f", "feat").await;

    let out = git
        .push(work.path(), "origin", "feature", false, true, false)
        .await
        .unwrap();
    assert!(out.set_upstream);
    assert!(out.success);

    // Confirm tracking exists.
    let upstream = git
        .config_get(work.path(), "branch.feature.merge")
        .await
        .unwrap();
    assert_eq!(upstream.as_deref(), Some("refs/heads/feature"));
}

// ── reset_hard / stash ─────────────────────────────────────────

#[tokio::test]
async fn reset_hard_discards_wip() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    let base = git.head_commit(dir.path()).await.unwrap();
    std::fs::write(dir.path().join("wip.txt"), "wip").unwrap();
    run_cmd(dir.path(), &["git", "add", "-A"]).await;
    run_cmd(dir.path(), &["git", "commit", "-m", "wip"]).await;

    git.reset_hard(dir.path(), &base).await.unwrap();
    let head = git.head_commit(dir.path()).await.unwrap();
    assert_eq!(head, base);
    assert!(!dir.path().join("wip.txt").exists());
}

#[tokio::test]
async fn stash_push_returns_none_when_clean() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    let r = git.stash_push(dir.path(), "nothing").await.unwrap();
    assert!(r.is_none());
}

#[tokio::test]
async fn stash_push_then_pop_restores_files() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    std::fs::write(dir.path().join("wip.txt"), "contents").unwrap();
    let r = git.stash_push(dir.path(), "msg").await.unwrap();
    assert_eq!(r.as_deref(), Some("stash@{0}"));
    assert!(
        !dir.path().join("wip.txt").exists(),
        "stash should remove wip from working tree"
    );

    let conflicts = git.stash_pop(dir.path(), "stash@{0}").await.unwrap();
    assert!(conflicts.is_empty(), "clean pop should report no conflicts");
    assert_eq!(
        std::fs::read_to_string(dir.path().join("wip.txt")).unwrap(),
        "contents"
    );
}

#[tokio::test]
async fn stash_create_with_untracked_captures_and_pops() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    // Write an untracked file — `-u` flag means it must be captured.
    std::fs::write(dir.path().join("untracked.txt"), "new").unwrap();
    std::fs::write(dir.path().join("README.md"), "# modified").unwrap();

    let stash_ref = git
        .stash_create_with_untracked(dir.path(), "tron-rebase-test")
        .await
        .unwrap();
    assert_eq!(stash_ref, "stash@{0}");
    // Working tree clean after stash.
    assert!(!git.has_changes(dir.path()).await.unwrap());
    assert!(!dir.path().join("untracked.txt").exists());

    let conflicts = git.stash_pop(dir.path(), &stash_ref).await.unwrap();
    assert!(conflicts.is_empty());
    assert_eq!(
        std::fs::read_to_string(dir.path().join("untracked.txt")).unwrap(),
        "new"
    );
}

#[tokio::test]
async fn stash_drop_removes_entry_idempotent() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    std::fs::write(dir.path().join("README.md"), "# modified").unwrap();
    let stash_ref = git
        .stash_create_with_untracked(dir.path(), "tron-drop-test")
        .await
        .unwrap();

    // First drop — stash exists, should succeed.
    git.stash_drop(dir.path(), &stash_ref).await.unwrap();

    // Second drop — stash no longer exists; must succeed (idempotent).
    git.stash_drop(dir.path(), &stash_ref).await.unwrap();
}

#[tokio::test]
async fn stash_pop_reports_unmerged_paths_on_conflict() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    // Commit a baseline f.txt so it's tracked.
    std::fs::write(dir.path().join("f.txt"), "base\n").unwrap();
    let _ = git.commit_all(dir.path(), "base f.txt").await.unwrap();
    // Modify in working tree — stash picks up the tracked change.
    std::fs::write(dir.path().join("f.txt"), "line A\n").unwrap();
    let stash_ref = git
        .stash_create_with_untracked(dir.path(), "A")
        .await
        .unwrap();
    // Commit a different change to the same file so popping conflicts.
    std::fs::write(dir.path().join("f.txt"), "line B\n").unwrap();
    let _ = git.commit_all(dir.path(), "line B").await.unwrap();

    let conflicts = git.stash_pop(dir.path(), &stash_ref).await.unwrap();
    assert!(
        !conflicts.is_empty(),
        "conflicting pop must report unmerged paths"
    );
    assert!(conflicts.iter().any(|p| p == "f.txt"));
}

// ── config / refs ──────────────────────────────────────────────

#[tokio::test]
async fn config_get_present_and_missing() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;

    let present = git.config_get(dir.path(), "user.email").await.unwrap();
    assert_eq!(present.as_deref(), Some("test@test.com"));

    let missing = git.config_get(dir.path(), "does.not.exist").await.unwrap();
    assert!(missing.is_none());
}

#[tokio::test]
async fn show_ref_verify_true_false() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    assert!(git.show_ref_verify(dir.path(), "refs/heads/main").await);
    assert!(!git.show_ref_verify(dir.path(), "refs/heads/nope").await);
}

#[tokio::test]
async fn for_each_ref_first_existing_picks_main() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    let r = git
        .for_each_ref_first_existing(dir.path(), &["master", "main"])
        .await;
    assert_eq!(
        r.as_deref(),
        Some("master").or(Some("main")).and(Some("main"))
    );
    let r = git
        .for_each_ref_first_existing(dir.path(), &["main", "master"])
        .await;
    assert_eq!(r.as_deref(), Some("main"));
    let r = git
        .for_each_ref_first_existing(dir.path(), &["nope", "zzz"])
        .await;
    assert!(r.is_none());
}

#[tokio::test]
async fn rev_parse_verify_valid_and_invalid() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    let sha = git.rev_parse_verify(dir.path(), "HEAD").await.unwrap();
    assert_eq!(sha.len(), 40);
    assert!(
        git.rev_parse_verify(dir.path(), "nonexistent")
            .await
            .is_err()
    );
}

#[tokio::test]
async fn merge_ff_only_succeeds() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    let base = git.head_commit(dir.path()).await.unwrap();
    checkout_new_branch(dir.path(), "feature").await;
    add_commit(dir.path(), "f.txt", "f", "feat").await;
    let feature_head = git.head_commit(dir.path()).await.unwrap();

    // Go back to main, FF-merge feature.
    run_cmd(dir.path(), &["git", "checkout", "main"]).await;
    assert_eq!(git.head_commit(dir.path()).await.unwrap(), base);
    let new_head = git.merge_ff_only(dir.path(), "feature").await.unwrap();
    assert_eq!(new_head, feature_head);
}

#[tokio::test]
async fn merge_ff_only_rejects_non_ff() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    // diverge: main has a commit that feature doesn't.
    checkout_new_branch(dir.path(), "feature").await;
    add_commit(dir.path(), "f.txt", "f", "feat").await;
    run_cmd(dir.path(), &["git", "checkout", "main"]).await;
    add_commit(dir.path(), "m.txt", "m", "main advance").await;
    let err = git.merge_ff_only(dir.path(), "feature").await;
    assert!(err.is_err(), "non-ff ff-only merge must fail");
}

// ── branch / worktree ──────────────────────────────────────────

#[tokio::test]
async fn checkout_new_branch_from_success() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    git.checkout_new_branch_from(dir.path(), "feature/new", "HEAD")
        .await
        .unwrap();
    assert_eq!(git.current_branch(dir.path()).await.unwrap(), "feature/new");
}

#[tokio::test]
async fn checkout_new_branch_from_already_exists() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    run_cmd(dir.path(), &["git", "branch", "exists"]).await;
    let err = git
        .checkout_new_branch_from(dir.path(), "exists", "HEAD")
        .await
        .expect_err("should fail");
    assert!(matches!(err, WorktreeError::BranchExists(n) if n == "exists"));
}

#[tokio::test]
async fn force_checkout_drops_wip() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    checkout_new_branch(dir.path(), "other").await;
    run_cmd(dir.path(), &["git", "checkout", "main"]).await;
    std::fs::write(dir.path().join("wip.txt"), "wip").unwrap();
    // checkout would normally refuse with uncommitted wip if conflicting,
    // but untracked files are tolerated — ensure --force path works.
    git.force_checkout(dir.path(), "other").await.unwrap();
    assert_eq!(git.current_branch(dir.path()).await.unwrap(), "other");
}

#[tokio::test]
async fn update_ref_moves_branch() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    let base = git.head_commit(dir.path()).await.unwrap();
    add_commit(dir.path(), "a.txt", "a", "a").await;
    // Move main to the base commit with update-ref. symbolic-ref still points to
    // main, so `rev-parse refs/heads/main` should now return `base`.
    git.update_ref(dir.path(), "refs/heads/main", &base)
        .await
        .unwrap();
    let r = git
        .rev_parse_verify(dir.path(), "refs/heads/main")
        .await
        .unwrap();
    assert_eq!(r, base);
}

// ── conflict helpers ───────────────────────────────────────────

#[tokio::test]
async fn has_merge_in_progress_false_then_true() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    assert!(!git.has_merge_in_progress(dir.path()).await.unwrap());

    make_conflict(dir.path(), "a", "b", "f.txt").await;
    // Attempt the merge — will conflict, not auto-abort here.
    let _ = run_cmd_ok(dir.path(), &["git", "merge", "--no-ff", "b"]).await;
    assert!(git.has_merge_in_progress(dir.path()).await.unwrap());
}

#[tokio::test]
async fn has_rebase_in_progress_false_by_default() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    assert!(!git.has_rebase_in_progress(dir.path()).await.unwrap());
}

#[tokio::test]
async fn staged_files_reports_added() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    assert!(git.staged_files(dir.path()).await.unwrap().is_empty());
    std::fs::write(dir.path().join("a.txt"), "a").unwrap();
    run_cmd(dir.path(), &["git", "add", "a.txt"]).await;
    assert_eq!(git.staged_files(dir.path()).await.unwrap(), vec!["a.txt"]);
}

#[tokio::test]
async fn conflict_sections_both_modified_content() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    make_conflict(dir.path(), "a", "b", "f.txt").await;
    // Trigger the merge so the index holds stages 1/2/3.
    let _ = run_cmd_ok(dir.path(), &["git", "merge", "--no-ff", "b"]).await;

    let cf = git.conflict_sections(dir.path(), "f.txt").await.unwrap();
    assert_eq!(cf.path, "f.txt");
    assert_eq!(cf.kind, ConflictKind::BothModified);
    assert!(!cf.is_binary);
    assert_eq!(cf.base.as_deref(), Some(b"base line\n".as_slice()));
    assert_eq!(cf.ours.as_deref(), Some(b"from A\n".as_slice()));
    assert_eq!(cf.theirs.as_deref(), Some(b"from B\n".as_slice()));
}

#[tokio::test]
async fn conflict_sections_deleted_by_us() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    make_deleted_by_us_conflict(dir.path(), "a", "b", "gone.txt").await;
    let _ = run_cmd_ok(dir.path(), &["git", "merge", "--no-ff", "b"]).await;
    let cf = git.conflict_sections(dir.path(), "gone.txt").await.unwrap();
    assert_eq!(cf.kind, ConflictKind::DeletedByUs);
    assert!(cf.base.is_some());
    assert!(cf.ours.is_none());
    assert!(cf.theirs.is_some());
}

#[tokio::test]
async fn checkout_ours_resolves_content_conflict() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    make_conflict(dir.path(), "a", "b", "f.txt").await;
    let _ = run_cmd_ok(dir.path(), &["git", "merge", "--no-ff", "b"]).await;

    git.checkout_ours(dir.path(), "f.txt").await.unwrap();
    let contents = std::fs::read_to_string(dir.path().join("f.txt")).unwrap();
    assert_eq!(contents, "from A\n");
    // The file is no longer unmerged (conflict_files reports empty).
    // Note: `staged_files` (diff --cached) may be empty because "ours"
    // content already matches HEAD for the current branch — that's
    // correct behaviour.
    let conflicts = git.conflict_files(dir.path()).await.unwrap();
    assert!(
        conflicts.iter().all(|f| f != "f.txt"),
        "f.txt should no longer be unmerged, got {conflicts:?}"
    );
}

#[tokio::test]
async fn checkout_theirs_resolves_content_conflict() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    make_conflict(dir.path(), "a", "b", "f.txt").await;
    let _ = run_cmd_ok(dir.path(), &["git", "merge", "--no-ff", "b"]).await;

    git.checkout_theirs(dir.path(), "f.txt").await.unwrap();
    let contents = std::fs::read_to_string(dir.path().join("f.txt")).unwrap();
    assert_eq!(contents, "from B\n");
}

#[tokio::test]
async fn merge_continue_commits_resolved() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    make_conflict(dir.path(), "a", "b", "f.txt").await;
    let _ = run_cmd_ok(dir.path(), &["git", "merge", "--no-ff", "b"]).await;
    git.checkout_theirs(dir.path(), "f.txt").await.unwrap();

    let sha = git.merge_continue(dir.path(), None).await.unwrap();
    assert_eq!(sha.len(), 40);
    assert!(!git.has_merge_in_progress(dir.path()).await.unwrap());
}
