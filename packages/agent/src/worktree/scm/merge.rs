//! Merge strategies for integrating session work back into a target branch.

use std::path::Path;

use tracing::{debug, warn};

use crate::worktree::errors::{Result, WorktreeError};
use crate::worktree::git::GitExecutor;
use crate::worktree::types::{FinalizeSessionResult, MergeResult, MergeStrategy};

/// Merge a session's branch into a target branch.
///
/// The operation is performed in the repository root (not a worktree).
/// On conflict, the merge/rebase is aborted and conflict files are returned.
pub async fn merge_session(
    repo_root: &Path,
    source_branch: &str,
    target_branch: &str,
    strategy: MergeStrategy,
    git: &GitExecutor,
) -> Result<MergeResult> {
    // Remember current branch to restore on failure
    let original_branch = git.current_branch(repo_root).await.ok();

    let result = match strategy {
        MergeStrategy::Merge => do_merge(repo_root, source_branch, target_branch, git).await,
        MergeStrategy::Rebase => do_rebase(repo_root, source_branch, target_branch, git).await,
        MergeStrategy::Squash => do_squash(repo_root, source_branch, target_branch, git).await,
    };

    // On failure, try to restore original branch
    if result.as_ref().is_ok_and(|r| !r.success)
        && let Some(ref branch) = original_branch
    {
        let _ = git.checkout(repo_root, branch).await;
    }

    result
}

async fn do_merge(
    repo_root: &Path,
    source_branch: &str,
    target_branch: &str,
    git: &GitExecutor,
) -> Result<MergeResult> {
    git.checkout(repo_root, target_branch).await?;

    match git.merge(repo_root, source_branch).await {
        Ok(commit) => {
            debug!(
                source = source_branch,
                target = target_branch,
                commit,
                "merge complete"
            );
            Ok(MergeResult {
                success: true,
                merge_commit: Some(commit),
                conflicts: vec![],
                strategy: MergeStrategy::Merge,
            })
        }
        Err(WorktreeError::Git(ref msg))
            if msg.contains("CONFLICT") || msg.contains("Merge conflict") =>
        {
            let conflicts = git.conflict_files(repo_root).await.unwrap_or_default();
            warn!(
                source = source_branch,
                target = target_branch,
                ?conflicts,
                "merge conflicts"
            );
            let _ = git.abort_merge(repo_root).await;
            Ok(MergeResult {
                success: false,
                merge_commit: None,
                conflicts,
                strategy: MergeStrategy::Merge,
            })
        }
        Err(e) => Err(e),
    }
}

async fn do_rebase(
    repo_root: &Path,
    source_branch: &str,
    target_branch: &str,
    git: &GitExecutor,
) -> Result<MergeResult> {
    git.checkout(repo_root, source_branch).await?;

    match git.rebase(repo_root, target_branch).await {
        Ok(()) => {
            // Fast-forward target
            git.checkout(repo_root, target_branch).await?;
            let commit = git.merge(repo_root, source_branch).await?;
            debug!(
                source = source_branch,
                target = target_branch,
                commit,
                "rebase complete"
            );
            Ok(MergeResult {
                success: true,
                merge_commit: Some(commit),
                conflicts: vec![],
                strategy: MergeStrategy::Rebase,
            })
        }
        Err(WorktreeError::Git(ref msg))
            if msg.contains("CONFLICT") || msg.contains("could not apply") =>
        {
            let conflicts = git.conflict_files(repo_root).await.unwrap_or_default();
            warn!(
                source = source_branch,
                target = target_branch,
                ?conflicts,
                "rebase conflicts"
            );
            let _ = git.abort_rebase(repo_root).await;
            Ok(MergeResult {
                success: false,
                merge_commit: None,
                conflicts,
                strategy: MergeStrategy::Rebase,
            })
        }
        Err(e) => Err(e),
    }
}

async fn do_squash(
    repo_root: &Path,
    source_branch: &str,
    target_branch: &str,
    git: &GitExecutor,
) -> Result<MergeResult> {
    git.checkout(repo_root, target_branch).await?;

    match git.squash_merge(repo_root, source_branch).await {
        Ok(()) => {
            let commit = git
                .commit_all(
                    repo_root,
                    &format!("squash merge {source_branch} into {target_branch}"),
                )
                .await?;
            debug!(
                source = source_branch,
                target = target_branch,
                commit,
                "squash merge complete"
            );
            Ok(MergeResult {
                success: true,
                merge_commit: Some(commit),
                conflicts: vec![],
                strategy: MergeStrategy::Squash,
            })
        }
        Err(WorktreeError::Git(ref msg)) if msg.contains("CONFLICT") => {
            let conflicts = git.conflict_files(repo_root).await.unwrap_or_default();
            warn!(
                source = source_branch,
                target = target_branch,
                ?conflicts,
                "squash merge conflicts"
            );
            let _ = git.abort_merge(repo_root).await;
            Ok(MergeResult {
                success: false,
                merge_commit: None,
                conflicts,
                strategy: MergeStrategy::Squash,
            })
        }
        Err(e) => Err(e),
    }
}

/// Atomic "merge session branch into target, then optionally rebranch the
/// session" operation. This is the happy-path finalisation flow — conflicts
/// must already have been resolved (via `conflict.rs`) BEFORE calling this.
///
/// Steps:
/// 1. `merge_session(source -> target)` — errors if it would conflict
///    (caller should have run the conflict state machine first).
/// 2. If `rebranch`: create `new_branch_name` from `target`'s new tip and
///    move the worktree onto it.
/// 3. If `rebranch && !preserve_old`: delete the old `source` branch.
///
/// When `rebranch == false`, steps 2 and 3 are skipped entirely: the
/// worktree stays on `source_branch` (which still points at its pre-merge
/// HEAD). The old branch is never deleted in this mode — the worktree is
/// still checked out on it.
///
/// Atomicity: if any step fails, the partial state is rolled back where
/// practical — the new branch is deleted if step 3 fails after step 2
/// succeeded; if step 1 errors, nothing else runs.
#[allow(clippy::too_many_arguments)]
pub async fn finalize_session(
    repo_root: &Path,
    worktree_path: &Path,
    _session_id: &str,
    source_branch: &str,
    target_branch: &str,
    strategy: MergeStrategy,
    new_branch_name: &str,
    preserve_old: bool,
    rebranch: bool,
    git: &GitExecutor,
) -> Result<FinalizeSessionResult> {
    // 1. Merge source into target in the repo root (target is checked out
    //    there, not in the session's worktree).
    let merge = merge_session(
        repo_root,
        source_branch,
        target_branch,
        strategy.clone(),
        git,
    )
    .await?;
    if !merge.success {
        return Err(WorktreeError::MergeConflicts(merge.conflicts.len()));
    }
    let merge_commit = merge.merge_commit.clone().ok_or_else(|| {
        WorktreeError::Git("merge reported success but returned no commit sha".to_string())
    })?;

    // Shortcut: if the caller opted out of rebranching, leave the worktree
    // on `source_branch` post-merge. The source branch itself is unchanged;
    // only `target_branch` advanced in step 1. We never touch the old
    // branch in this mode because the worktree is still checked out on it.
    //
    // Defensive: in the real session case, `merge_session` ran in `repo_root`
    // and left the worktree untouched (it was never on `target_branch`). But
    // when `repo_root == worktree_path` (e.g. a session rooted directly at
    // the main repo, or certain tests) the merge left the worktree on
    // `target_branch`. Force a checkout back to `source_branch` to make the
    // invariant hold in both cases.
    if !rebranch {
        if let Ok(current) = git.current_branch(worktree_path).await
            && current != source_branch
        {
            git.force_checkout(worktree_path, source_branch).await?;
        }
        let head = git.rev_parse_verify(worktree_path, "HEAD").await?;
        debug!(
            source = source_branch,
            target = target_branch,
            merge_commit,
            "finalize_session complete (no rebranch)"
        );
        return Ok(FinalizeSessionResult {
            merge_commit,
            new_branch: source_branch.to_string(),
            new_base_commit: head,
            old_branch_deleted: false,
            old_branch_delete_error: None,
            strategy,
        });
    }

    // 2. Create the new follow-up branch as a ref pointing at target's
    //    new tip, then switch the session's worktree onto it. We do this
    //    in two steps (create ref in repo_root via `git branch`, then
    //    checkout in worktree) so repo_root stays on `target_branch`
    //    (main) — crucial when the user's editor is rooted there.
    //
    //    Satisfies plan invariant 2 (worktree HEAD is a fresh session
    //    branch, not main) and frees `source_branch` for deletion.
    if let Err(e) = git
        .branch_create_from(repo_root, new_branch_name, target_branch)
        .await
    {
        return Err(e);
    }
    if let Err(e) = git.force_checkout(worktree_path, new_branch_name).await {
        // Partial state: new branch ref exists but worktree didn't move.
        // Try to clean up the ref so a retry with the same name works.
        let _ = git.branch_delete(repo_root, new_branch_name, true).await;
        return Err(e);
    }

    let new_base_commit = git.rev_parse_verify(worktree_path, "HEAD").await?;

    // 3. Optionally delete the old source branch. Now safe because the
    //    worktree switched to `new_branch_name` in step 2. Never fatal:
    //    if delete fails (e.g. branch still checked out elsewhere), log
    //    and return the error string so the UI can show it.
    //
    //    Defensive: re-verify the worktree is actually on
    //    `new_branch_name` before deleting. If force_checkout silently
    //    left the worktree on the old branch, deletion would fail with
    //    "branch checked out at <path>". One retry via force_checkout
    //    covers transient index/lock hiccups without masking real bugs.
    let (old_branch_deleted, old_branch_delete_error) = if preserve_old {
        (false, None)
    } else {
        if let Ok(current) = git.current_branch(worktree_path).await
            && current != new_branch_name
        {
            warn!(
                worktree = %worktree_path.display(),
                current,
                expected = new_branch_name,
                "worktree HEAD not on new branch after force_checkout; retrying"
            );
            let _ = git.force_checkout(worktree_path, new_branch_name).await;
        }
        match git.branch_delete(repo_root, source_branch, true).await {
            Ok(()) => (true, None),
            Err(e) => {
                let msg = e.to_string();
                warn!(branch = source_branch, error = %msg, "failed to delete old session branch");
                (false, Some(msg))
            }
        }
    };

    debug!(
        source = source_branch,
        target = target_branch,
        new_branch = new_branch_name,
        merge_commit,
        old_branch_deleted,
        "finalize_session complete"
    );
    Ok(FinalizeSessionResult {
        merge_commit,
        new_branch: new_branch_name.to_string(),
        new_base_commit,
        old_branch_deleted,
        old_branch_delete_error,
        strategy,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    async fn init_repo(dir: &std::path::Path) -> GitExecutor {
        let git = GitExecutor::new(30_000);
        run_cmd(dir, &["git", "init"]).await;
        run_cmd(dir, &["git", "config", "user.email", "test@test.com"]).await;
        run_cmd(dir, &["git", "config", "user.name", "Test"]).await;
        std::fs::write(dir.join("README.md"), "# test").unwrap();
        run_cmd(dir, &["git", "add", "-A"]).await;
        run_cmd(dir, &["git", "commit", "-m", "init"]).await;
        git
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

    async fn make_branch_with_commit(dir: &std::path::Path, branch: &str, file: &str) {
        run_cmd(dir, &["git", "checkout", "-b", branch]).await;
        std::fs::write(dir.join(file), format!("content of {file}")).unwrap();
        run_cmd(dir, &["git", "add", "-A"]).await;
        run_cmd(dir, &["git", "commit", "-m", &format!("add {file}")]).await;
    }

    #[tokio::test]
    async fn merge_clean() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let main = git.current_branch(dir.path()).await.unwrap();

        make_branch_with_commit(dir.path(), "feature", "feature.txt").await;
        run_cmd(dir.path(), &["git", "checkout", &main]).await;

        let result = merge_session(dir.path(), "feature", &main, MergeStrategy::Merge, &git)
            .await
            .unwrap();

        assert!(result.success);
        assert!(result.merge_commit.is_some());
        assert!(result.conflicts.is_empty());
    }

    #[tokio::test]
    async fn squash_clean() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let main = git.current_branch(dir.path()).await.unwrap();

        make_branch_with_commit(dir.path(), "squash-feature", "squash.txt").await;
        run_cmd(dir.path(), &["git", "checkout", &main]).await;

        let result = merge_session(
            dir.path(),
            "squash-feature",
            &main,
            MergeStrategy::Squash,
            &git,
        )
        .await
        .unwrap();

        assert!(result.success);
        assert!(result.merge_commit.is_some());
        assert_eq!(result.strategy, MergeStrategy::Squash);
    }

    // ────────────────────────────────────────────────────────────────
    // finalize_session tests — use the shared test_fixtures for
    // consistent setup with the rest of Phase 2.
    // ────────────────────────────────────────────────────────────────

    use crate::worktree::test_fixtures as tf;

    #[tokio::test]
    async fn finalize_creates_new_branch() {
        let dir = tempdir().unwrap();
        let git = tf::init_repo(dir.path()).await;
        tf::checkout_new_branch(dir.path(), "session/s1").await;
        tf::add_commit(dir.path(), "feat.txt", "feat", "feat").await;

        let out = finalize_session(
            dir.path(),
            dir.path(),
            "s1",
            "session/s1",
            "main",
            MergeStrategy::Merge,
            "session/s1-followup",
            true, // preserve old
            true, // rebranch
            &git,
        )
        .await
        .unwrap();

        assert!(!out.merge_commit.is_empty());
        assert_eq!(out.new_branch, "session/s1-followup");
        assert!(!out.old_branch_deleted);
        // Worktree should now be on the new branch.
        assert_eq!(
            git.current_branch(dir.path()).await.unwrap(),
            "session/s1-followup"
        );
    }

    #[tokio::test]
    async fn finalize_old_branch_preserved() {
        let dir = tempdir().unwrap();
        let git = tf::init_repo(dir.path()).await;
        tf::checkout_new_branch(dir.path(), "session/s1").await;
        tf::add_commit(dir.path(), "feat.txt", "feat", "feat").await;

        let out = finalize_session(
            dir.path(),
            dir.path(),
            "s1",
            "session/s1",
            "main",
            MergeStrategy::Merge,
            "session/s1-followup",
            true,
            true, // rebranch
            &git,
        )
        .await
        .unwrap();
        assert!(!out.old_branch_deleted);
        // Old branch should still exist.
        assert!(
            git.show_ref_verify(dir.path(), "refs/heads/session/s1")
                .await,
            "preserved branch must still exist"
        );
    }

    #[tokio::test]
    async fn finalize_old_branch_deleted() {
        let dir = tempdir().unwrap();
        let git = tf::init_repo(dir.path()).await;
        tf::checkout_new_branch(dir.path(), "session/s1").await;
        tf::add_commit(dir.path(), "feat.txt", "feat", "feat").await;

        let out = finalize_session(
            dir.path(),
            dir.path(),
            "s1",
            "session/s1",
            "main",
            MergeStrategy::Merge,
            "session/s1-followup",
            false, // delete old
            true,  // rebranch
            &git,
        )
        .await
        .unwrap();
        assert!(out.old_branch_deleted);
        assert!(
            !git.show_ref_verify(dir.path(), "refs/heads/session/s1")
                .await,
            "old branch must be deleted"
        );
    }

    #[tokio::test]
    async fn finalize_conflict_errors_without_partial_state() {
        let dir = tempdir().unwrap();
        let git = tf::init_repo(dir.path()).await;
        tf::make_conflict(dir.path(), "session/s1", "main-ish", "f.txt").await;
        // Make `main` conflict with `session/s1` by fast-forwarding main to
        // `main-ish`.
        tf::run_cmd(dir.path(), &["git", "checkout", "main"]).await;
        tf::run_cmd(dir.path(), &["git", "merge", "--ff-only", "main-ish"]).await;

        let err = finalize_session(
            dir.path(),
            dir.path(),
            "s1",
            "session/s1",
            "main",
            MergeStrategy::Merge,
            "session/s1-followup",
            false,
            true, // rebranch
            &git,
        )
        .await
        .expect_err("conflicting merge must error");
        assert!(matches!(err, WorktreeError::Git(_)));

        // New branch must NOT exist.
        assert!(
            !git.show_ref_verify(dir.path(), "refs/heads/session/s1-followup")
                .await,
            "follow-up branch must not be created on conflict"
        );
    }

    #[tokio::test]
    async fn finalize_atomicity_new_branch_exists_iff_merge_succeeded() {
        // Happy path: new branch exists.
        let dir = tempdir().unwrap();
        let git = tf::init_repo(dir.path()).await;
        tf::checkout_new_branch(dir.path(), "session/s1").await;
        tf::add_commit(dir.path(), "feat.txt", "feat", "feat").await;
        finalize_session(
            dir.path(),
            dir.path(),
            "s1",
            "session/s1",
            "main",
            MergeStrategy::Merge,
            "session/s1-followup",
            true,
            true, // rebranch
            &git,
        )
        .await
        .unwrap();
        assert!(
            git.show_ref_verify(dir.path(), "refs/heads/session/s1-followup")
                .await
        );
    }

    /// When `rebranch == false`, the merge still lands on `target_branch`
    /// but the worktree stays on `source_branch` — no follow-up branch is
    /// created, and the old branch is preserved even if delete was
    /// requested (the worktree is still checked out on it).
    #[tokio::test]
    async fn finalize_no_rebranch_stays_on_source() {
        let dir = tempdir().unwrap();
        let git = tf::init_repo(dir.path()).await;
        tf::checkout_new_branch(dir.path(), "session/s1").await;
        tf::add_commit(dir.path(), "feat.txt", "feat", "feat").await;

        let out = finalize_session(
            dir.path(),
            dir.path(),
            "s1",
            "session/s1",
            "main",
            MergeStrategy::Merge,
            "session/s1-followup",
            false, // delete_old requested…
            false, // …but rebranch=false forces preservation
            &git,
        )
        .await
        .unwrap();

        assert!(!out.merge_commit.is_empty());
        // Worktree stays on the original session branch.
        assert_eq!(out.new_branch, "session/s1");
        assert_eq!(git.current_branch(dir.path()).await.unwrap(), "session/s1");
        // No follow-up branch was created.
        assert!(
            !git.show_ref_verify(dir.path(), "refs/heads/session/s1-followup")
                .await,
            "follow-up branch must not exist when rebranch=false"
        );
        // Source branch preserved even though caller passed delete=true.
        assert!(!out.old_branch_deleted);
        assert!(
            git.show_ref_verify(dir.path(), "refs/heads/session/s1")
                .await,
            "source branch must still exist when rebranch=false"
        );
    }
}
