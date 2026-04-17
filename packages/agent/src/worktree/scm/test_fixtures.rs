//! Shared test fixtures for worktree SCM tests.
//!
//! Consolidates the helpers that previously lived (duplicated) inside each
//! `scm/*.rs`'s `#[cfg(test)] mod tests`, and adds higher-level fixtures used
//! by Phase 2 onwards (sync, push, switch, conflict).
//!
//! All fixtures run real `git` against `tempfile::tempdir()` directories —
//! mocks would be unfaithful to git's semantics (especially conflict
//! resolution, which depends on index state).
//!
//! Naming conventions:
//! - `init_repo*` — creates a repo with an initial commit.
//! - `init_repo_with_origin` — creates a non-bare working repo AND a bare
//!   "origin" repo it pushes to, so remote-round-trip tests are realistic.
//! - `make_*_conflict` — sets up a specific kind of conflict (content,
//!   binary, rename, delete) between two branches and returns the names.
//! - `diverge` — makes local and its remote have unique commits so fetch
//!   reports non-zero ahead/behind counts.

#![cfg(test)]

use std::path::Path;

use crate::worktree::git::GitExecutor;

/// Run a command in `dir`, panicking if it fails. Returns stdout trimmed.
pub async fn run_cmd(dir: &Path, args: &[&str]) -> String {
    let output = tokio::process::Command::new(args[0])
        .args(&args[1..])
        .current_dir(dir)
        .output()
        .await
        .unwrap_or_else(|e| panic!("failed to spawn {args:?}: {e}"));
    assert!(
        output.status.success(),
        "cmd {:?} failed in {}:\nstderr: {}",
        args,
        dir.display(),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

/// Run a command and return whether it succeeded.
pub async fn run_cmd_ok(dir: &Path, args: &[&str]) -> bool {
    tokio::process::Command::new(args[0])
        .args(&args[1..])
        .current_dir(dir)
        .output()
        .await
        .map(|o| o.status.success())
        .unwrap_or(false)
}

/// Initialise a repo with an initial commit and return a `GitExecutor` bound
/// to a generous timeout (30s).
///
/// The default branch is whatever the local `git` chooses (`main` or
/// `master`) — query it via `GitExecutor::current_branch` in the caller if
/// you need the name.
pub async fn init_repo(dir: &Path) -> GitExecutor {
    let git = GitExecutor::new(30_000);
    run_cmd(dir, &["git", "init"]).await;
    run_cmd(dir, &["git", "config", "user.email", "test@test.com"]).await;
    run_cmd(dir, &["git", "config", "user.name", "Test"]).await;
    run_cmd(dir, &["git", "config", "commit.gpgsign", "false"]).await;
    // Make sure every test sees a deterministic default branch so assertions
    // on "main" vs "master" don't depend on the developer's global config.
    run_cmd(dir, &["git", "symbolic-ref", "HEAD", "refs/heads/main"]).await;
    std::fs::write(dir.join("README.md"), "# test").unwrap();
    run_cmd(dir, &["git", "add", "-A"]).await;
    run_cmd(dir, &["git", "commit", "-m", "init"]).await;
    git
}

/// Initialise a repo and a bare "origin" remote, wire them together, and push
/// the initial commit.
///
/// Returns `(work, origin_bare)`:
/// - `work` is the non-bare working repo (what tests operate on).
/// - `origin_bare` is the bare remote (mirrors real-world `origin`).
///
/// Both paths are owned by the caller's `tempdir()` — they share no filesystem
/// state with other tests.
pub async fn init_repo_with_origin(
    work: &Path,
    origin_bare: &Path,
) -> GitExecutor {
    // Bare remote first.
    std::fs::create_dir_all(origin_bare).unwrap();
    run_cmd(origin_bare, &["git", "init", "--bare"]).await;
    // Ensure bare default branch matches working repo.
    run_cmd(origin_bare, &["git", "symbolic-ref", "HEAD", "refs/heads/main"]).await;

    let git = init_repo(work).await;
    run_cmd(
        work,
        &["git", "remote", "add", "origin", &origin_bare.to_string_lossy()],
    )
    .await;
    run_cmd(work, &["git", "push", "-u", "origin", "main"]).await;
    git
}

/// Create and switch to a new branch off HEAD, returning the branch name.
///
/// Tests call this when they need a second branch to merge from.
pub async fn checkout_new_branch(dir: &Path, branch: &str) {
    run_cmd(dir, &["git", "checkout", "-b", branch]).await;
}

/// Add a commit to the current branch that touches `file` with `content`.
///
/// Returns the new HEAD sha.
pub async fn add_commit(dir: &Path, file: &str, content: &str, msg: &str) -> String {
    std::fs::write(dir.join(file), content).unwrap();
    run_cmd(dir, &["git", "add", "-A"]).await;
    run_cmd(dir, &["git", "commit", "-m", msg]).await;
    run_cmd(dir, &["git", "rev-parse", "HEAD"]).await
}

/// Set up a content conflict: `branch_a` and `branch_b` each rewrite `file`'s
/// single line to different content off a common base.
///
/// Caller must be on the base branch when invoked; leaves the repo on
/// `branch_a` with the conflict unmerged if the caller attempts a merge.
pub async fn make_conflict(dir: &Path, branch_a: &str, branch_b: &str, file: &str) {
    // Base commit with the file.
    std::fs::write(dir.join(file), "base line\n").unwrap();
    run_cmd(dir, &["git", "add", "-A"]).await;
    run_cmd(dir, &["git", "commit", "-m", "conflict base"]).await;

    // Branch A edits the line one way.
    run_cmd(dir, &["git", "checkout", "-b", branch_a]).await;
    std::fs::write(dir.join(file), "from A\n").unwrap();
    run_cmd(dir, &["git", "add", "-A"]).await;
    run_cmd(dir, &["git", "commit", "-m", "A change"]).await;

    // Back to base for branch B.
    run_cmd(dir, &["git", "checkout", "HEAD~1", "--detach"]).await;
    // Find the base commit hash and create branch B from it.
    let base_sha = run_cmd(dir, &["git", "rev-parse", "HEAD"]).await;
    run_cmd(dir, &["git", "checkout", "-b", branch_b, &base_sha]).await;
    std::fs::write(dir.join(file), "from B\n").unwrap();
    run_cmd(dir, &["git", "add", "-A"]).await;
    run_cmd(dir, &["git", "commit", "-m", "B change"]).await;

    // Leave repo checked out on branch_a for caller convenience.
    run_cmd(dir, &["git", "checkout", branch_a]).await;
}

/// Set up a binary conflict: both branches rewrite `file` with different
/// binary content. git's merge will flag this as a binary conflict that
/// must be resolved with `checkout --ours|--theirs`.
pub async fn make_binary_conflict(dir: &Path, branch_a: &str, branch_b: &str, file: &str) {
    // Base commit with initial binary content.
    std::fs::write(dir.join(file), [0u8, 1, 2, 3, 4]).unwrap();
    run_cmd(dir, &["git", "add", "-A"]).await;
    run_cmd(dir, &["git", "commit", "-m", "binary base"]).await;

    run_cmd(dir, &["git", "checkout", "-b", branch_a]).await;
    std::fs::write(dir.join(file), [0u8, 1, 2, 3, 4, 0xAA, 0xBB]).unwrap();
    run_cmd(dir, &["git", "add", "-A"]).await;
    run_cmd(dir, &["git", "commit", "-m", "A binary change"]).await;

    let base_sha = run_cmd(dir, &["git", "rev-parse", "HEAD~1"]).await;
    run_cmd(dir, &["git", "checkout", "-b", branch_b, &base_sha]).await;
    std::fs::write(dir.join(file), [0u8, 1, 2, 3, 4, 0xCC, 0xDD, 0xEE]).unwrap();
    run_cmd(dir, &["git", "add", "-A"]).await;
    run_cmd(dir, &["git", "commit", "-m", "B binary change"]).await;

    run_cmd(dir, &["git", "checkout", branch_a]).await;
}

/// Set up a rename conflict: both branches rename the same base file to
/// different names (git reports the conflict as two renames on merge).
pub async fn make_rename_conflict(
    dir: &Path,
    branch_a: &str,
    branch_b: &str,
    original: &str,
    renamed_a: &str,
    renamed_b: &str,
) {
    std::fs::write(dir.join(original), "content to be renamed\n").unwrap();
    run_cmd(dir, &["git", "add", "-A"]).await;
    run_cmd(dir, &["git", "commit", "-m", "rename base"]).await;

    run_cmd(dir, &["git", "checkout", "-b", branch_a]).await;
    run_cmd(dir, &["git", "mv", original, renamed_a]).await;
    run_cmd(dir, &["git", "commit", "-m", "rename to A"]).await;

    let base_sha = run_cmd(dir, &["git", "rev-parse", "HEAD~1"]).await;
    run_cmd(dir, &["git", "checkout", "-b", branch_b, &base_sha]).await;
    run_cmd(dir, &["git", "mv", original, renamed_b]).await;
    run_cmd(dir, &["git", "commit", "-m", "rename to B"]).await;

    run_cmd(dir, &["git", "checkout", branch_a]).await;
}

/// Set up a "deleted by us" / "deleted by them" conflict: `branch_a` deletes
/// the file; `branch_b` modifies it. Merging produces a delete/modify
/// conflict.
pub async fn make_deleted_by_us_conflict(
    dir: &Path,
    branch_a: &str,
    branch_b: &str,
    file: &str,
) {
    std::fs::write(dir.join(file), "original content\n").unwrap();
    run_cmd(dir, &["git", "add", "-A"]).await;
    run_cmd(dir, &["git", "commit", "-m", "delete conflict base"]).await;

    run_cmd(dir, &["git", "checkout", "-b", branch_a]).await;
    run_cmd(dir, &["git", "rm", file]).await;
    run_cmd(dir, &["git", "commit", "-m", "delete in A"]).await;

    let base_sha = run_cmd(dir, &["git", "rev-parse", "HEAD~1"]).await;
    run_cmd(dir, &["git", "checkout", "-b", branch_b, &base_sha]).await;
    std::fs::write(dir.join(file), "modified content\n").unwrap();
    run_cmd(dir, &["git", "add", "-A"]).await;
    run_cmd(dir, &["git", "commit", "-m", "modify in B"]).await;

    run_cmd(dir, &["git", "checkout", branch_a]).await;
}

/// Make local and its remote have different, non-overlapping commits on the
/// same branch so that a fetch reports non-zero ahead AND behind counts.
///
/// Assumes the repo at `work` has an `origin` remote with matching branch
/// (use `init_repo_with_origin` first). Pushes one commit directly into the
/// bare remote via a scratch clone, while committing a different change
/// locally. The caller is left with `work` ahead by 1 and behind by 1.
pub async fn diverge(work: &Path, origin_bare: &Path) {
    // 1. Local: add a commit not yet pushed.
    std::fs::write(work.join("local-only.txt"), "local\n").unwrap();
    run_cmd(work, &["git", "add", "-A"]).await;
    run_cmd(work, &["git", "commit", "-m", "local-only commit"]).await;

    // 2. Remote: clone it briefly, push a commit, discard the clone.
    let scratch = work
        .parent()
        .expect("work dir must have a parent")
        .join(format!("scratch-{}", uuid_like()));
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
    run_cmd(&scratch, &["git", "config", "user.email", "test@test.com"]).await;
    run_cmd(&scratch, &["git", "config", "user.name", "Test"]).await;
    run_cmd(&scratch, &["git", "config", "commit.gpgsign", "false"]).await;
    std::fs::write(scratch.join("remote-only.txt"), "remote\n").unwrap();
    run_cmd(&scratch, &["git", "add", "-A"]).await;
    run_cmd(&scratch, &["git", "commit", "-m", "remote-only commit"]).await;
    run_cmd(&scratch, &["git", "push", "origin", "main"]).await;

    // 3. Have the local repo see the new remote head (fetch updates refs
    //    without touching the working tree).
    run_cmd(work, &["git", "fetch", "origin"]).await;

    // best-effort scratch cleanup (ignore failures)
    let _ = std::fs::remove_dir_all(&scratch);
}

/// Helper to build a unique-ish suffix without pulling in the `uuid` crate.
fn uuid_like() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{nanos:x}")
}

