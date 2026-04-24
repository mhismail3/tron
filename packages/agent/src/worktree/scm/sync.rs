//! `sync_main` — fast-forward the local main branch from its remote.
//!
//! Preconditions (all checked up-front; any failure returns a typed
//! `SyncBlockReason`):
//! 1. Repo has a remote (usually `origin`).
//! 2. Repo has at least one commit (not an empty `git init`).
//! 3. HEAD is not detached — we need a branch to fast-forward.
//! 4. The main branch exists locally.
//! 5. The repo-root working tree is clean. `sync_main` runs in the
//!    user's actual checkout (not a session worktree); dirtying that tree
//!    would stomp on the user's VS Code state.
//!
//! Then: fetch → compare local vs `<remote>/<main>` → either do nothing,
//! fast-forward, or surface `LocalAhead` / `Diverged` for the caller to
//! handle.
//!
//! Atomicity: if the FF step itself fails after fetch, HEAD is reset back
//! to its old value so the on-disk branch ref is unchanged.

use std::path::Path;

use tracing::{debug, warn};

use crate::worktree::errors::Result;
use crate::worktree::git::GitExecutor;
use crate::worktree::types::{SyncBlockReason, SyncOutcome};

/// Default branch candidates, in order: the caller may override.
pub const DEFAULT_MAIN_CANDIDATES: &[&str] = &["main", "master"];

/// Sync `main_branch` of `repo_root` from `<remote>/<main_branch>`.
///
/// `timeout_ms` is forwarded to `fetch_timeout`; everything else uses
/// `git`'s configured executor timeout.
///
/// `main_branch` is the locally-known name; pass `None` to auto-detect
/// via `init.defaultBranch` / `refs/heads/{main,master}`.
///
/// `prune` maps to `git fetch --prune`, removing local remote-tracking refs
/// for branches deleted upstream. `dry_run`, when true, still runs the
/// fetch (so remote-tracking refs become fresh and `--prune` is honored)
/// but skips the final fast-forward; the caller gets a `DryRunPreview`.
pub async fn sync_main(
    repo_root: &Path,
    main_branch: Option<&str>,
    remote: &str,
    git: &GitExecutor,
    fetch_timeout_ms: u64,
    prune: bool,
    dry_run: bool,
) -> Result<SyncOutcome> {
    // 1. Remote configured?
    let remotes = git.remote_list(repo_root).await?;
    if !remotes.iter().any(|r| r == remote) {
        return Ok(SyncOutcome::Blocked(SyncBlockReason::NoRemote));
    }

    // 2. Any commits at all?
    if !git.has_commits(repo_root).await {
        return Ok(SyncOutcome::Blocked(SyncBlockReason::EmptyRepository));
    }

    // 3. Resolve main branch (caller override wins).
    let main = match main_branch {
        Some(m) => m.to_string(),
        None => match resolve_default_branch(git, repo_root).await? {
            Some(b) => b,
            None => return Ok(SyncOutcome::Blocked(SyncBlockReason::NoDefaultBranch)),
        },
    };
    if !git
        .show_ref_verify(repo_root, &format!("refs/heads/{main}"))
        .await
    {
        return Ok(SyncOutcome::Blocked(SyncBlockReason::NoDefaultBranch));
    }

    // 4. HEAD must be on `main` (or at least on some branch). This function
    //    operates in-place on the repo root; if the user has it checked out
    //    on something else we block rather than surprise them. Detached
    //    HEAD is also blocked.
    let current = match git.current_branch(repo_root).await {
        Ok(b) => b,
        Err(_) => return Ok(SyncOutcome::Blocked(SyncBlockReason::DetachedHead)),
    };

    // 5. Working tree clean?
    if git.has_changes(repo_root).await.unwrap_or(true) {
        return Ok(SyncOutcome::Blocked(SyncBlockReason::DirtyWorkingTree));
    }

    // 6. Make sure HEAD is on main — otherwise refuse rather than silently
    //    switch branches.
    if current != main {
        return Ok(SyncOutcome::Blocked(SyncBlockReason::NotOnDefaultBranch {
            current,
            expected: main,
        }));
    }

    // 7. Fetch with the caller-supplied timeout. Remote errors get typed
    //    variants from `fetch_timeout`; we surface them via `RemoteError`.
    if let Err(e) = git
        .fetch_timeout(repo_root, remote, fetch_timeout_ms, prune)
        .await
    {
        warn!(error = %e, "fetch failed during sync_main");
        return Ok(SyncOutcome::Blocked(SyncBlockReason::RemoteError(
            e.to_string(),
        )));
    }

    let old_head = git.rev_parse_verify(repo_root, "HEAD").await?;
    let remote_ref = format!("{remote}/{main}");
    let remote_head = match git.rev_parse_verify(repo_root, &remote_ref).await {
        Ok(h) => h,
        Err(e) => {
            // Remote ref disappeared or never existed.
            return Ok(SyncOutcome::Blocked(SyncBlockReason::RemoteError(
                e.to_string(),
            )));
        }
    };

    if old_head == remote_head {
        return Ok(SyncOutcome::UpToDate { head: old_head });
    }

    // 8. Divergence analysis.
    //    ahead  = commits local has that remote doesn't
    //    behind = commits remote has that local doesn't
    let ahead = git
        .commit_count_between(repo_root, &remote_head, &old_head)
        .await
        .unwrap_or(0);
    let behind = git
        .commit_count_between(repo_root, &old_head, &remote_head)
        .await
        .unwrap_or(0);

    if ahead > 0 && behind > 0 {
        return Ok(SyncOutcome::Blocked(SyncBlockReason::Diverged {
            ahead,
            behind,
        }));
    }
    if ahead > 0 && behind == 0 {
        return Ok(SyncOutcome::Blocked(SyncBlockReason::LocalAhead { ahead }));
    }
    // behind > 0, ahead == 0 → fast-forward.

    // 8.5. Dry-run short-circuit: report what would happen without touching
    //      local `main`. Fetch already ran (and honored --prune) so the
    //      remote-tracking refs are fresh, but HEAD is left alone.
    if dry_run {
        return Ok(SyncOutcome::DryRunPreview {
            head: old_head,
            remote_head,
            would_advance_by: behind,
        });
    }

    // 9. Fast-forward. On failure, restore old HEAD.
    match git.merge_ff_only(repo_root, &remote_ref).await {
        Ok(new_head) => {
            debug!(%old_head, %new_head, advanced_by = behind, "sync_main fast-forwarded");
            Ok(SyncOutcome::FastForwarded {
                old_head,
                new_head,
                advanced_by: behind,
            })
        }
        Err(e) => {
            warn!(error = %e, "ff failed unexpectedly; rolling back");
            // Best-effort rollback; if this itself fails the repo is in a
            // slightly awkward state but HEAD ref didn't move.
            let _ = git.reset_hard(repo_root, &old_head).await;
            Ok(SyncOutcome::Blocked(SyncBlockReason::RemoteError(
                e.to_string(),
            )))
        }
    }
}

/// Resolve the repo's default branch: `init.defaultBranch` config first,
/// then a probe for `main` / `master`. Returns `Ok(None)` if nothing fits.
pub async fn resolve_default_branch(git: &GitExecutor, repo_root: &Path) -> Result<Option<String>> {
    if let Some(v) = git.config_get(repo_root, "init.defaultBranch").await?
        && git
            .show_ref_verify(repo_root, &format!("refs/heads/{v}"))
            .await
    {
        return Ok(Some(v));
    }
    Ok(git
        .for_each_ref_first_existing(repo_root, DEFAULT_MAIN_CANDIDATES)
        .await)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::worktree::test_fixtures::{
        add_commit, diverge, init_repo, init_repo_with_origin, run_cmd,
    };
    use tempfile::tempdir;

    #[tokio::test]
    async fn sync_already_up_to_date() {
        let work = tempdir().unwrap();
        let origin = tempdir().unwrap();
        let git = init_repo_with_origin(work.path(), origin.path()).await;
        let out = sync_main(
            work.path(),
            Some("main"),
            "origin",
            &git,
            30_000,
            false,
            false,
        )
        .await
        .unwrap();
        matches!(out, SyncOutcome::UpToDate { .. })
            .then_some(())
            .expect("expected UpToDate");
    }

    #[tokio::test]
    async fn sync_fast_forward() {
        let work = tempdir().unwrap();
        let origin = tempdir().unwrap();
        let git = init_repo_with_origin(work.path(), origin.path()).await;

        // Make the remote advance (via a scratch clone).
        diverge_remote_only(work.path(), origin.path()).await;

        let out = sync_main(
            work.path(),
            Some("main"),
            "origin",
            &git,
            30_000,
            false,
            false,
        )
        .await
        .unwrap();
        match out {
            SyncOutcome::FastForwarded { advanced_by, .. } => assert_eq!(advanced_by, 1),
            other => panic!("expected FastForwarded, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn sync_local_ahead_blocked() {
        let work = tempdir().unwrap();
        let origin = tempdir().unwrap();
        let git = init_repo_with_origin(work.path(), origin.path()).await;
        add_commit(work.path(), "a.txt", "a", "local a").await;

        let out = sync_main(
            work.path(),
            Some("main"),
            "origin",
            &git,
            30_000,
            false,
            false,
        )
        .await
        .unwrap();
        match out {
            SyncOutcome::Blocked(SyncBlockReason::LocalAhead { ahead }) => {
                assert_eq!(ahead, 1)
            }
            other => panic!("expected Blocked::LocalAhead, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn sync_diverged_blocked() {
        let work = tempdir().unwrap();
        let origin = tempdir().unwrap();
        let git = init_repo_with_origin(work.path(), origin.path()).await;
        diverge(work.path(), origin.path()).await;

        let out = sync_main(
            work.path(),
            Some("main"),
            "origin",
            &git,
            30_000,
            false,
            false,
        )
        .await
        .unwrap();
        matches!(out, SyncOutcome::Blocked(SyncBlockReason::Diverged { .. }))
            .then_some(())
            .expect("expected Diverged");
    }

    #[tokio::test]
    async fn sync_no_remote() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let out = sync_main(
            dir.path(),
            Some("main"),
            "origin",
            &git,
            30_000,
            false,
            false,
        )
        .await
        .unwrap();
        assert_eq!(out, SyncOutcome::Blocked(SyncBlockReason::NoRemote));
    }

    #[tokio::test]
    async fn sync_empty_repo() {
        let dir = tempdir().unwrap();
        run_cmd(dir.path(), &["git", "init"]).await;
        // Add an origin stub so the NoRemote check passes and we hit
        // empty-repo.
        let origin_bare = dir.path().parent().unwrap().join(format!(
            "{}-origin.git",
            dir.path().file_name().unwrap().to_string_lossy()
        ));
        std::fs::create_dir_all(&origin_bare).unwrap();
        run_cmd(&origin_bare, &["git", "init", "--bare"]).await;
        run_cmd(
            dir.path(),
            &[
                "git",
                "remote",
                "add",
                "origin",
                &origin_bare.to_string_lossy(),
            ],
        )
        .await;
        let git = GitExecutor::new(30_000);

        let out = sync_main(
            dir.path(),
            Some("main"),
            "origin",
            &git,
            30_000,
            false,
            false,
        )
        .await
        .unwrap();
        assert_eq!(out, SyncOutcome::Blocked(SyncBlockReason::EmptyRepository));
        let _ = std::fs::remove_dir_all(&origin_bare);
    }

    #[tokio::test]
    async fn sync_dirty_working_tree_blocked() {
        let work = tempdir().unwrap();
        let origin = tempdir().unwrap();
        let git = init_repo_with_origin(work.path(), origin.path()).await;
        std::fs::write(work.path().join("dirty.txt"), "dirty").unwrap();
        let out = sync_main(
            work.path(),
            Some("main"),
            "origin",
            &git,
            30_000,
            false,
            false,
        )
        .await
        .unwrap();
        assert_eq!(out, SyncOutcome::Blocked(SyncBlockReason::DirtyWorkingTree));
    }

    #[tokio::test]
    async fn sync_detached_head_blocked() {
        let work = tempdir().unwrap();
        let origin = tempdir().unwrap();
        let git = init_repo_with_origin(work.path(), origin.path()).await;
        let head = git.head_commit(work.path()).await.unwrap();
        run_cmd(work.path(), &["git", "checkout", "--detach", &head]).await;

        let out = sync_main(
            work.path(),
            Some("main"),
            "origin",
            &git,
            30_000,
            false,
            false,
        )
        .await
        .unwrap();
        assert_eq!(out, SyncOutcome::Blocked(SyncBlockReason::DetachedHead));
    }

    #[tokio::test]
    async fn sync_non_default_main_branch() {
        let work = tempdir().unwrap();
        let origin = tempdir().unwrap();
        let git = init_repo_with_origin(work.path(), origin.path()).await;
        // Rename main → trunk everywhere. Bare repos refuse to delete the
        // branch they have HEAD pointed at, so repoint the bare origin's
        // HEAD at `trunk` first.
        run_cmd(work.path(), &["git", "branch", "-m", "main", "trunk"]).await;
        run_cmd(work.path(), &["git", "push", "-u", "origin", "trunk"]).await;
        run_cmd(
            origin.path(),
            &["git", "symbolic-ref", "HEAD", "refs/heads/trunk"],
        )
        .await;
        run_cmd(work.path(), &["git", "push", "origin", "--delete", "main"]).await;

        let out = sync_main(
            work.path(),
            Some("trunk"),
            "origin",
            &git,
            30_000,
            false,
            false,
        )
        .await
        .unwrap();
        matches!(out, SyncOutcome::UpToDate { .. })
            .then_some(())
            .expect("expected UpToDate for trunk");
    }

    #[tokio::test]
    async fn sync_auto_detects_default_branch() {
        let work = tempdir().unwrap();
        let origin = tempdir().unwrap();
        let git = init_repo_with_origin(work.path(), origin.path()).await;
        let out = sync_main(work.path(), None, "origin", &git, 30_000, false, false)
            .await
            .unwrap();
        matches!(out, SyncOutcome::UpToDate { .. })
            .then_some(())
            .expect("auto-detection should resolve `main`");
    }

    // Internal helper: push a commit to origin via a scratch clone without
    // creating a local divergence. The local repo is left behind-by-1.
    async fn diverge_remote_only(work: &std::path::Path, origin_bare: &std::path::Path) {
        let scratch = work.parent().unwrap().join(format!(
            "scratch-{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        run_cmd(
            scratch.parent().unwrap(),
            &[
                "git",
                "clone",
                &origin_bare.to_string_lossy(),
                &scratch.to_string_lossy(),
            ],
        )
        .await;
        run_cmd(&scratch, &["git", "config", "user.email", "t@t"]).await;
        run_cmd(&scratch, &["git", "config", "user.name", "t"]).await;
        run_cmd(&scratch, &["git", "config", "commit.gpgsign", "false"]).await;
        std::fs::write(scratch.join("remote-only.txt"), "r").unwrap();
        run_cmd(&scratch, &["git", "add", "-A"]).await;
        run_cmd(&scratch, &["git", "commit", "-m", "r"]).await;
        run_cmd(&scratch, &["git", "push", "origin", "main"]).await;
        run_cmd(work, &["git", "fetch", "origin"]).await;
        let _ = std::fs::remove_dir_all(&scratch);
    }

    #[tokio::test]
    async fn resolve_default_branch_picks_main() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let r = resolve_default_branch(&git, dir.path()).await.unwrap();
        assert_eq!(r.as_deref(), Some("main"));
    }

    #[tokio::test]
    async fn sync_unicode_branch_name() {
        let work = tempdir().unwrap();
        let origin = tempdir().unwrap();
        let git = init_repo_with_origin(work.path(), origin.path()).await;
        run_cmd(work.path(), &["git", "branch", "-m", "main", "メイン"]).await;
        run_cmd(work.path(), &["git", "push", "-u", "origin", "メイン"]).await;
        run_cmd(
            origin.path(),
            &["git", "symbolic-ref", "HEAD", "refs/heads/メイン"],
        )
        .await;
        run_cmd(work.path(), &["git", "push", "origin", "--delete", "main"]).await;

        let out = sync_main(
            work.path(),
            Some("メイン"),
            "origin",
            &git,
            30_000,
            false,
            false,
        )
        .await
        .unwrap();
        matches!(out, SyncOutcome::UpToDate { .. })
            .then_some(())
            .expect("expected UpToDate for unicode branch");
    }

    #[tokio::test]
    async fn sync_multiple_remotes() {
        // Sync against `origin` works even when another remote is present.
        let work = tempdir().unwrap();
        let origin = tempdir().unwrap();
        let other_bare = tempdir().unwrap();
        let git = init_repo_with_origin(work.path(), origin.path()).await;
        run_cmd(other_bare.path(), &["git", "init", "--bare"]).await;
        run_cmd(
            work.path(),
            &[
                "git",
                "remote",
                "add",
                "upstream",
                &other_bare.path().to_string_lossy(),
            ],
        )
        .await;
        let out = sync_main(
            work.path(),
            Some("main"),
            "origin",
            &git,
            30_000,
            false,
            false,
        )
        .await
        .unwrap();
        matches!(out, SyncOutcome::UpToDate { .. })
            .then_some(())
            .expect("expected UpToDate with multiple remotes");
    }

    #[tokio::test]
    async fn sync_network_timeout_surfaced() {
        // Point origin at an unresolvable URL and use a 1ms timeout — fetch
        // must surface as a typed `Blocked::RemoteError` rather than panic.
        let work = tempdir().unwrap();
        let origin = tempdir().unwrap();
        let git = init_repo_with_origin(work.path(), origin.path()).await;
        // Rewrite origin URL to a bogus destination so fetch fails fast.
        run_cmd(
            work.path(),
            &[
                "git",
                "remote",
                "set-url",
                "origin",
                "https://127.0.0.1:1/bogus.git",
            ],
        )
        .await;
        let out = sync_main(
            work.path(),
            Some("main"),
            "origin",
            &git,
            1_500,
            false,
            false,
        )
        .await
        .unwrap();
        assert!(matches!(
            out,
            SyncOutcome::Blocked(SyncBlockReason::RemoteError(_))
        ));
    }

    #[tokio::test]
    async fn sync_auth_failure_surfaced() {
        // A file path that doesn't exist triggers the git transport's
        // "does not appear to be a git repository" error, which the
        // executor classifies as a remote error.
        let work = tempdir().unwrap();
        let origin = tempdir().unwrap();
        let git = init_repo_with_origin(work.path(), origin.path()).await;
        let bogus = work.path().parent().unwrap().join("nonexistent-origin.git");
        run_cmd(
            work.path(),
            &[
                "git",
                "remote",
                "set-url",
                "origin",
                &bogus.to_string_lossy(),
            ],
        )
        .await;
        let out = sync_main(
            work.path(),
            Some("main"),
            "origin",
            &git,
            5_000,
            false,
            false,
        )
        .await
        .unwrap();
        assert!(matches!(
            out,
            SyncOutcome::Blocked(SyncBlockReason::RemoteError(_))
        ));
    }

    #[tokio::test]
    async fn sync_rolls_back_on_ff_failure() {
        // Simulate a rollback path: force-merging into a locked index
        // should fail gracefully and leave HEAD at its prior sha.
        let work = tempdir().unwrap();
        let origin = tempdir().unwrap();
        let git = init_repo_with_origin(work.path(), origin.path()).await;
        diverge_remote_only(work.path(), origin.path()).await;
        let pre_head = git.rev_parse_verify(work.path(), "HEAD").await.unwrap();

        // Hold a stale index.lock to make merge_ff_only fail; sync_main's
        // rollback branch should still leave HEAD on the original commit.
        let git_dir = work.path().join(".git");
        let lock = git_dir.join("index.lock");
        std::fs::write(&lock, "").unwrap();

        let out = sync_main(
            work.path(),
            Some("main"),
            "origin",
            &git,
            30_000,
            false,
            false,
        )
        .await
        .unwrap();

        // Clean up the lock so the next tempdir teardown doesn't race.
        let _ = std::fs::remove_file(&lock);

        // Must not be FastForwarded; either blocked (RemoteError / DirtyWorkingTree)
        // or UpToDate would be acceptable — the key invariant is HEAD unchanged.
        assert!(!matches!(out, SyncOutcome::FastForwarded { .. }));
        let post_head = git.rev_parse_verify(work.path(), "HEAD").await.unwrap();
        assert_eq!(pre_head, post_head, "HEAD must not move on FF failure");
    }
}
