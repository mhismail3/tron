//! `push_branch` — controlled push of a session branch (or any branch) to
//! a remote.
//!
//! Adds three things on top of `GitExecutor::push`:
//! 1. Pre-flight protected-branch check (force alone is never enough for
//!    `main`/`master`/anything in the user's allow-list — the caller must
//!    also pass `override_protected: true`).
//! 2. Remote-exists check (maps to `NoRemoteConfigured` rather than a
//!    cryptic "No configured push destination").
//! 3. Consistent typed error mapping via `classify_push_error`.
//!
//! This is the only safe way for the coordinator / engine transport to push;
//! the raw `GitExecutor::push` is for the SCM layer's own use.

use std::path::Path;

use tracing::debug;

use crate::domains::worktree::errors::{Result, WorktreeError};
use crate::domains::worktree::git::GitExecutor;
use crate::domains::worktree::types::PushOutput;

/// Arguments to [`push_branch`]. Grouped so signatures stay sane.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PushArgs<'a> {
    /// Branch name to push (short form, e.g. `session/abc`).
    pub branch: &'a str,
    /// Remote name; defaults to `origin` in most callers.
    pub remote: &'a str,
    /// If `true`, use `--force-with-lease`. Still subject to protected-
    /// branch check.
    pub force_with_lease: bool,
    /// If `true`, pass `-u` so tracking gets set.
    pub set_upstream: bool,
    /// `--dry-run` — no side effects.
    pub dry_run: bool,
    /// Caller-maintained list of branches the UI/settings consider
    /// protected (typically `["main","master","develop"]`).
    pub protected_branches: &'a [String],
    /// If `true`, bypass the protected-branch check. Not exposed in v1 UI
    /// — only the agent tool has access via an explicit parameter.
    pub override_protected: bool,
}

/// Push a branch to a remote, observing protected-branch rules.
pub async fn push_branch(
    repo: &Path,
    args: &PushArgs<'_>,
    git: &GitExecutor,
) -> Result<PushOutput> {
    // 1. Protected branch check up-front (even for `--dry-run` — the user
    //    shouldn't be able to even simulate pushing to `main`).
    if !args.override_protected && args.protected_branches.iter().any(|b| b == args.branch) {
        return Err(WorktreeError::ProtectedBranch(format!(
            "refusing to push protected branch '{}' (override not set)",
            args.branch
        )));
    }

    // 2. Remote exists?
    let remotes = git.remote_list(repo).await?;
    if !remotes.iter().any(|r| r == args.remote) {
        return Err(WorktreeError::NoRemoteConfigured(format!(
            "remote '{}' is not configured",
            args.remote
        )));
    }

    // 3. Delegate to GitExecutor::push.
    let out = git
        .push(
            repo,
            args.remote,
            args.branch,
            args.force_with_lease,
            args.set_upstream,
            args.dry_run,
        )
        .await?;
    debug!(
        branch = args.branch,
        remote = args.remote,
        dry_run = args.dry_run,
        "push complete"
    );
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domains::worktree::test_fixtures::{
        add_commit, checkout_new_branch, init_repo_with_origin,
    };
    use tempfile::tempdir;

    fn protected() -> Vec<String> {
        vec!["main".into(), "master".into(), "develop".into()]
    }

    #[tokio::test]
    async fn push_clean_sets_upstream() {
        let work = tempdir().unwrap();
        let origin = tempdir().unwrap();
        let git = init_repo_with_origin(work.path(), origin.path()).await;
        checkout_new_branch(work.path(), "feature/a").await;
        add_commit(work.path(), "a.txt", "a", "a").await;

        let protected = protected();
        let out = push_branch(
            work.path(),
            &PushArgs {
                branch: "feature/a",
                remote: "origin",
                force_with_lease: false,
                set_upstream: true,
                dry_run: false,
                protected_branches: &protected,
                override_protected: false,
            },
            &git,
        )
        .await
        .unwrap();
        assert!(out.success);
        assert!(out.set_upstream);

        // Tracking should exist.
        let upstream = git
            .config_get(work.path(), "branch.feature/a.merge")
            .await
            .unwrap();
        assert_eq!(upstream.as_deref(), Some("refs/heads/feature/a"));
    }

    #[tokio::test]
    async fn push_protected_branch_rejected() {
        let work = tempdir().unwrap();
        let origin = tempdir().unwrap();
        let git = init_repo_with_origin(work.path(), origin.path()).await;
        add_commit(work.path(), "a.txt", "a", "a").await;

        let protected = protected();
        let err = push_branch(
            work.path(),
            &PushArgs {
                branch: "main",
                remote: "origin",
                force_with_lease: false,
                set_upstream: false,
                dry_run: false,
                protected_branches: &protected,
                override_protected: false,
            },
            &git,
        )
        .await
        .expect_err("protected push must fail");
        assert!(matches!(err, WorktreeError::ProtectedBranch(_)));
    }

    #[tokio::test]
    async fn push_override_protected_succeeds() {
        let work = tempdir().unwrap();
        let origin = tempdir().unwrap();
        let git = init_repo_with_origin(work.path(), origin.path()).await;
        add_commit(work.path(), "a.txt", "a", "a").await;

        let protected = protected();
        let out = push_branch(
            work.path(),
            &PushArgs {
                branch: "main",
                remote: "origin",
                force_with_lease: false,
                set_upstream: false,
                dry_run: false,
                protected_branches: &protected,
                override_protected: true,
            },
            &git,
        )
        .await
        .unwrap();
        assert!(out.success);
    }

    #[tokio::test]
    async fn push_no_remote_is_typed_error() {
        let work = tempdir().unwrap();
        let origin = tempdir().unwrap();
        let git = init_repo_with_origin(work.path(), origin.path()).await;
        checkout_new_branch(work.path(), "feature/a").await;
        add_commit(work.path(), "a.txt", "a", "a").await;

        let protected = protected();
        let err = push_branch(
            work.path(),
            &PushArgs {
                branch: "feature/a",
                remote: "upstream", // does not exist
                force_with_lease: false,
                set_upstream: true,
                dry_run: false,
                protected_branches: &protected,
                override_protected: false,
            },
            &git,
        )
        .await
        .expect_err("missing remote should error");
        assert!(matches!(err, WorktreeError::NoRemoteConfigured(_)));
    }

    #[tokio::test]
    async fn push_dry_run_does_not_push() {
        let work = tempdir().unwrap();
        let origin = tempdir().unwrap();
        let git = init_repo_with_origin(work.path(), origin.path()).await;
        checkout_new_branch(work.path(), "feature/a").await;
        add_commit(work.path(), "a.txt", "a", "a").await;

        let protected = protected();
        let out = push_branch(
            work.path(),
            &PushArgs {
                branch: "feature/a",
                remote: "origin",
                force_with_lease: false,
                set_upstream: true,
                dry_run: true,
                protected_branches: &protected,
                override_protected: false,
            },
            &git,
        )
        .await
        .unwrap();
        assert!(out.success);
        assert!(out.dry_run);
        // Remote should not have the branch.
        let sha = git
            .ls_remote_head(work.path(), "origin", "feature/a")
            .await
            .unwrap();
        assert!(sha.is_none(), "dry-run must not push");
    }

    #[tokio::test]
    async fn push_already_tracking() {
        let work = tempdir().unwrap();
        let origin = tempdir().unwrap();
        let git = init_repo_with_origin(work.path(), origin.path()).await;
        checkout_new_branch(work.path(), "feature/a").await;
        add_commit(work.path(), "a.txt", "a", "a").await;

        let protected = protected();
        // First push sets upstream.
        push_branch(
            work.path(),
            &PushArgs {
                branch: "feature/a",
                remote: "origin",
                force_with_lease: false,
                set_upstream: true,
                dry_run: false,
                protected_branches: &protected,
                override_protected: false,
            },
            &git,
        )
        .await
        .unwrap();

        // Add another commit, push again without `-u`; should still succeed
        // against the existing tracking ref.
        add_commit(work.path(), "a.txt", "b", "b").await;
        let out = push_branch(
            work.path(),
            &PushArgs {
                branch: "feature/a",
                remote: "origin",
                force_with_lease: false,
                set_upstream: false,
                dry_run: false,
                protected_branches: &protected,
                override_protected: false,
            },
            &git,
        )
        .await
        .unwrap();
        assert!(out.success);
    }

    #[tokio::test]
    async fn push_non_ff_rejected() {
        // Two clones of the same bare origin, both push conflicting commits
        // on `feature/a`. The second push (without force) must error with
        // NonFastForward.
        let work_a = tempdir().unwrap();
        let work_b = tempdir().unwrap();
        let origin = tempdir().unwrap();
        let git = init_repo_with_origin(work_a.path(), origin.path()).await;

        // Set up work_b as a clone of origin.
        let git_b = GitExecutor::new(30_000);
        crate::domains::worktree::test_fixtures::run_cmd(
            work_b.path().parent().unwrap(),
            &[
                "git",
                "clone",
                &origin.path().to_string_lossy(),
                &work_b.path().to_string_lossy(),
            ],
        )
        .await;
        crate::domains::worktree::test_fixtures::run_cmd(
            work_b.path(),
            &["git", "config", "user.email", "t@t"],
        )
        .await;
        crate::domains::worktree::test_fixtures::run_cmd(
            work_b.path(),
            &["git", "config", "user.name", "t"],
        )
        .await;
        crate::domains::worktree::test_fixtures::run_cmd(
            work_b.path(),
            &["git", "config", "commit.gpgsign", "false"],
        )
        .await;

        // Both create feature/a with divergent commits.
        checkout_new_branch(work_a.path(), "feature/a").await;
        add_commit(work_a.path(), "a.txt", "AAAA", "from A").await;
        checkout_new_branch(work_b.path(), "feature/a").await;
        add_commit(work_b.path(), "a.txt", "BBBB", "from B").await;

        let protected = protected();
        // A pushes first.
        push_branch(
            work_a.path(),
            &PushArgs {
                branch: "feature/a",
                remote: "origin",
                force_with_lease: false,
                set_upstream: true,
                dry_run: false,
                protected_branches: &protected,
                override_protected: false,
            },
            &git,
        )
        .await
        .unwrap();

        // B pushes second — must be rejected as non-FF.
        let err = push_branch(
            work_b.path(),
            &PushArgs {
                branch: "feature/a",
                remote: "origin",
                force_with_lease: false,
                set_upstream: true,
                dry_run: false,
                protected_branches: &protected,
                override_protected: false,
            },
            &git_b,
        )
        .await
        .expect_err("non-FF push must error");
        assert!(
            matches!(err, WorktreeError::NonFastForward(_)),
            "expected NonFastForward, got {err:?}"
        );
    }

    #[tokio::test]
    async fn push_unicode_branch() {
        let work = tempdir().unwrap();
        let origin = tempdir().unwrap();
        let git = init_repo_with_origin(work.path(), origin.path()).await;
        checkout_new_branch(work.path(), "機能/新しい").await;
        add_commit(work.path(), "a.txt", "a", "a").await;

        let protected = protected();
        let out = push_branch(
            work.path(),
            &PushArgs {
                branch: "機能/新しい",
                remote: "origin",
                force_with_lease: false,
                set_upstream: true,
                dry_run: false,
                protected_branches: &protected,
                override_protected: false,
            },
            &git,
        )
        .await
        .unwrap();
        assert!(out.success);
    }

    #[tokio::test]
    async fn push_force_with_lease_with_stale_ref_rejected() {
        // Force-with-lease refuses when the remote advanced since our last
        // fetch. Simulate: A pushes, B pushes via scratch clone, then A tries
        // to force-with-lease without fetching first → git rejects.
        let work_a = tempdir().unwrap();
        let origin = tempdir().unwrap();
        let git = init_repo_with_origin(work_a.path(), origin.path()).await;
        checkout_new_branch(work_a.path(), "feature/a").await;
        add_commit(work_a.path(), "a.txt", "A1", "a1").await;

        let protected = protected();
        push_branch(
            work_a.path(),
            &PushArgs {
                branch: "feature/a",
                remote: "origin",
                force_with_lease: false,
                set_upstream: true,
                dry_run: false,
                protected_branches: &protected,
                override_protected: false,
            },
            &git,
        )
        .await
        .unwrap();

        // Another worker advances the remote.
        let scratch = work_a.path().parent().unwrap().join("scratch-force");
        crate::domains::worktree::test_fixtures::run_cmd(
            scratch.parent().unwrap(),
            &[
                "git",
                "clone",
                &origin.path().to_string_lossy(),
                &scratch.to_string_lossy(),
            ],
        )
        .await;
        crate::domains::worktree::test_fixtures::run_cmd(
            &scratch,
            &["git", "config", "user.email", "t@t"],
        )
        .await;
        crate::domains::worktree::test_fixtures::run_cmd(
            &scratch,
            &["git", "config", "user.name", "t"],
        )
        .await;
        crate::domains::worktree::test_fixtures::run_cmd(
            &scratch,
            &["git", "config", "commit.gpgsign", "false"],
        )
        .await;
        crate::domains::worktree::test_fixtures::run_cmd(
            &scratch,
            &["git", "checkout", "feature/a"],
        )
        .await;
        std::fs::write(scratch.join("a.txt"), "remote-advance").unwrap();
        crate::domains::worktree::test_fixtures::run_cmd(&scratch, &["git", "add", "-A"]).await;
        crate::domains::worktree::test_fixtures::run_cmd(&scratch, &["git", "commit", "-m", "adv"])
            .await;
        crate::domains::worktree::test_fixtures::run_cmd(
            &scratch,
            &["git", "push", "origin", "feature/a"],
        )
        .await;

        // Meanwhile A makes a local commit and tries force-with-lease
        // without fetching — the lease check sees stale remote and rejects.
        std::fs::write(work_a.path().join("a.txt"), "A2").unwrap();
        crate::domains::worktree::test_fixtures::run_cmd(work_a.path(), &["git", "add", "-A"])
            .await;
        crate::domains::worktree::test_fixtures::run_cmd(
            work_a.path(),
            &["git", "commit", "-m", "a2"],
        )
        .await;
        let err = push_branch(
            work_a.path(),
            &PushArgs {
                branch: "feature/a",
                remote: "origin",
                force_with_lease: true,
                set_upstream: false,
                dry_run: false,
                protected_branches: &protected,
                override_protected: false,
            },
            &git,
        )
        .await
        .expect_err("force-with-lease with stale remote must reject");
        // Either NonFastForward or a generic remote error is acceptable —
        // what matters is the push didn't succeed.
        assert!(
            matches!(
                err,
                WorktreeError::NonFastForward(_) | WorktreeError::Git(_)
            ),
            "expected NonFastForward or Git error, got {err:?}"
        );
        let _ = std::fs::remove_dir_all(&scratch);
    }

    #[tokio::test]
    async fn push_dry_run_also_respects_protected() {
        let work = tempdir().unwrap();
        let origin = tempdir().unwrap();
        let git = init_repo_with_origin(work.path(), origin.path()).await;
        let protected = protected();
        let err = push_branch(
            work.path(),
            &PushArgs {
                branch: "main",
                remote: "origin",
                force_with_lease: false,
                set_upstream: false,
                dry_run: true,
                protected_branches: &protected,
                override_protected: false,
            },
            &git,
        )
        .await
        .expect_err("dry-run to protected must still reject");
        assert!(matches!(err, WorktreeError::ProtectedBranch(_)));
    }
}
