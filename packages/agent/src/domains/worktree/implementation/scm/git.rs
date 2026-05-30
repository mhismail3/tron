//! Low-level git command execution.
//!
//! Wraps `tokio::process::Command` with configurable timeout.
//! All commands capture stdout/stderr and return structured results.

use std::path::Path;
use std::time::Duration;

use crate::domains::worktree::errors::{Result, WorktreeError};
use crate::domains::worktree::types::CommitOptions;

#[path = "git/command.rs"]
mod command;
#[path = "git/conflicts.rs"]
mod conflicts;
#[path = "git/error_classification.rs"]
mod error_classification;
#[path = "git/parsing.rs"]
mod parsing;
#[path = "git/remote.rs"]
mod remote;
#[path = "git/state.rs"]
mod state;

pub(crate) use error_classification::{classify_push_error, classify_remote_error};
use parsing::{parse_nul_paths, parse_worktree_porcelain};

/// Parsed entry from `git worktree list --porcelain`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WorktreeListEntry {
    /// Absolute path to the worktree.
    pub path: String,
    /// HEAD commit hash.
    pub head: String,
    /// Branch name (None for detached HEAD).
    pub branch: Option<String>,
    /// Whether this is bare.
    pub bare: bool,
}

/// Git command executor with timeout.
#[derive(Clone, Debug)]
pub struct GitExecutor {
    timeout: Duration,
}

impl GitExecutor {
    /// Create a new executor with the given timeout.
    pub fn new(timeout_ms: u64) -> Self {
        Self {
            timeout: Duration::from_millis(timeout_ms),
        }
    }

    /// Check if a path is inside a git repository.
    pub async fn is_git_repo(&self, path: &Path) -> bool {
        self.run_status(path, &["rev-parse", "--git-dir"]).await
    }

    /// Get the root of the repository containing `path`.
    pub async fn repo_root(&self, path: &Path) -> Result<String> {
        self.run(path, &["rev-parse", "--show-toplevel"]).await
    }

    /// Get the HEAD commit hash.
    pub async fn head_commit(&self, dir: &Path) -> Result<String> {
        self.run(dir, &["rev-parse", "HEAD"]).await
    }

    /// Check whether the repository has at least one commit.
    ///
    /// Returns `false` for empty repos (after `git init` with no commits)
    /// and for non-git directories.
    pub async fn has_commits(&self, path: &Path) -> bool {
        self.run_status(path, &["rev-parse", "--verify", "HEAD"])
            .await
    }

    /// Get the current branch name (None-ish error for detached HEAD).
    pub async fn current_branch(&self, dir: &Path) -> Result<String> {
        self.run(dir, &["symbolic-ref", "--short", "HEAD"]).await
    }

    /// Add a new worktree with a new branch.
    ///
    /// Worktree creation is substrate setup, not user code execution. Disable
    /// checkout hooks so repo-local tooling such as Git LFS cannot make
    /// session isolation unavailable on machines without that tooling.
    pub async fn worktree_add(
        &self,
        repo: &Path,
        path: &Path,
        branch: &str,
        start_point: &str,
    ) -> Result<()> {
        let path_str = path.to_string_lossy();
        let _ = self
            .run(
                repo,
                &[
                    "-c",
                    "core.hooksPath=/dev/null",
                    "worktree",
                    "add",
                    "-b",
                    branch,
                    &path_str,
                    start_point,
                ],
            )
            .await?;
        Ok(())
    }

    /// Remove a worktree.
    pub async fn worktree_remove(&self, repo: &Path, path: &Path, force: bool) -> Result<()> {
        let path_str = path.to_string_lossy();
        let args = if force {
            vec!["worktree", "remove", "--force", &path_str]
        } else {
            vec!["worktree", "remove", &path_str]
        };
        let _ = self.run(repo, &args).await?;
        Ok(())
    }

    /// List worktrees in porcelain format.
    pub async fn worktree_list(&self, repo: &Path) -> Result<Vec<WorktreeListEntry>> {
        let output = self.run(repo, &["worktree", "list", "--porcelain"]).await?;
        Ok(parse_worktree_porcelain(&output))
    }

    /// Prune stale worktree references.
    pub async fn worktree_prune(&self, repo: &Path) -> Result<()> {
        let _ = self.run(repo, &["worktree", "prune"]).await?;
        Ok(())
    }

    /// Delete a branch.
    pub async fn branch_delete(&self, repo: &Path, branch: &str, force: bool) -> Result<()> {
        let flag = if force { "-D" } else { "-d" };
        let _ = self.run(repo, &["branch", flag, branch]).await?;
        Ok(())
    }

    /// Rename a branch.
    pub async fn branch_rename(&self, repo: &Path, old_name: &str, new_name: &str) -> Result<()> {
        let _ = self
            .run(repo, &["branch", "-m", old_name, new_name])
            .await?;
        Ok(())
    }

    /// Create a new branch ref pointing at `start_point` WITHOUT checking
    /// it out. Fails with `BranchExists` if the branch already exists.
    pub async fn branch_create_from(
        &self,
        repo: &Path,
        new_branch: &str,
        start_point: &str,
    ) -> Result<()> {
        let (_stdout, stderr, ok) = self
            .run_capture(repo, &["branch", new_branch, start_point])
            .await?;
        if ok {
            Ok(())
        } else if stderr.contains("already exists") {
            Err(WorktreeError::BranchExists(new_branch.to_string()))
        } else {
            Err(WorktreeError::Git(stderr))
        }
    }

    /// Check if there are uncommitted changes.
    pub async fn has_changes(&self, dir: &Path) -> Result<bool> {
        let output = self.run(dir, &["status", "--porcelain"]).await?;
        Ok(!output.is_empty())
    }

    /// Paths whose working-copy state differs from `HEAD`.
    ///
    /// Includes tracked modifications/deletions plus untracked, non-ignored
    /// files. Callers use this to seed a newly isolated session worktree with
    /// the operator-visible workspace state instead of bare `HEAD` alone.
    pub async fn working_copy_overlay_paths(&self, dir: &Path) -> Result<Vec<String>> {
        let mut paths = Vec::new();
        let tracked = self
            .run_stdout_bytes(dir, &["diff", "--name-only", "-z", "HEAD", "--"])
            .await?;
        paths.extend(parse_nul_paths(&tracked));

        let untracked = self
            .run_stdout_bytes(dir, &["ls-files", "--others", "--exclude-standard", "-z"])
            .await?;
        paths.extend(parse_nul_paths(&untracked));

        paths.sort();
        paths.dedup();
        Ok(paths)
    }

    /// Get diff stat.
    pub async fn diff_stat(&self, dir: &Path) -> Result<String> {
        self.run(dir, &["diff", "--stat"]).await
    }

    /// Stage all and commit.
    ///
    /// Thin wrapper over [`commit_with_options`] that preserves the original
    /// "stage everything, no amend, no signoff" behavior relied on by
    /// lifecycle/recovery paths. New callers should prefer
    /// [`commit_with_options`] and pass flags explicitly.
    pub async fn commit_all(&self, dir: &Path, message: &str) -> Result<String> {
        self.commit_with_options(dir, message, &CommitOptions::default_stage_all())
            .await
    }

    /// Commit with caller-chosen flags.
    ///
    /// Behavior:
    /// - `opts.stage_all`: run `git add -A` before commit. Omit to commit only
    ///   the existing index.
    /// - `opts.amend`: append `--amend` so the previous HEAD commit is
    ///   rewritten in place.
    /// - `opts.signoff`: append `--signoff` so a `Signed-off-by:` trailer is
    ///   added by git.
    ///
    /// Returns the new HEAD SHA. Errors propagate `WorktreeError::Git` with
    /// the raw git stderr so the caller (and ultimately the UI) can surface
    /// it. The `message` is passed via `-m`, so leading dashes and embedded
    /// newlines are preserved as-is.
    pub async fn commit_with_options(
        &self,
        dir: &Path,
        message: &str,
        opts: &CommitOptions,
    ) -> Result<String> {
        if opts.stage_all {
            let _ = self.run(dir, &["add", "-A"]).await?;
        }
        let mut args: Vec<&str> = vec!["commit", "-m", message];
        if opts.amend {
            args.push("--amend");
        }
        if opts.signoff {
            args.push("--signoff");
        }
        let _ = self.run(dir, &args).await?;
        self.run(dir, &["rev-parse", "HEAD"]).await
    }

    /// Merge a branch (--no-ff).
    pub async fn merge(&self, dir: &Path, branch: &str) -> Result<String> {
        let _ = self.run(dir, &["merge", "--no-ff", branch]).await?;
        self.run(dir, &["rev-parse", "HEAD"]).await
    }

    /// Rebase onto a branch.
    pub async fn rebase(&self, dir: &Path, onto: &str) -> Result<()> {
        let _ = self.run(dir, &["rebase", onto]).await?;
        Ok(())
    }

    /// Squash merge a branch.
    pub async fn squash_merge(&self, dir: &Path, branch: &str) -> Result<()> {
        let _ = self.run(dir, &["merge", "--squash", branch]).await?;
        Ok(())
    }

    /// Abort an in-progress merge.
    pub async fn abort_merge(&self, dir: &Path) -> Result<()> {
        let _ = self.run(dir, &["merge", "--abort"]).await?;
        Ok(())
    }

    /// Abort an in-progress rebase.
    pub async fn abort_rebase(&self, dir: &Path) -> Result<()> {
        let _ = self.run(dir, &["rebase", "--abort"]).await?;
        Ok(())
    }

    /// Checkout a branch.
    pub async fn checkout(&self, dir: &Path, branch: &str) -> Result<()> {
        let _ = self.run(dir, &["checkout", branch]).await?;
        Ok(())
    }

    /// Get list of conflicting files during a merge.
    pub async fn conflict_files(&self, dir: &Path) -> Result<Vec<String>> {
        let output = self
            .run(dir, &["diff", "--name-only", "--diff-filter=U"])
            .await?;
        Ok(output
            .lines()
            .map(std::string::ToString::to_string)
            .collect())
    }

    /// Count commits since a base commit (inclusive of commits after base, exclusive of base).
    pub async fn commit_count_since(&self, dir: &Path, base_commit: &str) -> Result<usize> {
        let range = format!("{base_commit}..HEAD");
        let output = self.run(dir, &["rev-list", "--count", &range]).await?;
        output.parse::<usize>().map_err(|e| {
            WorktreeError::Git(format!("failed to parse commit count '{output}': {e}"))
        })
    }

    /// Get list of files changed since a commit (compared to HEAD).
    pub async fn changed_files_since(&self, dir: &Path, base_commit: &str) -> Result<Vec<String>> {
        let output = self
            .run(dir, &["diff", "--name-only", base_commit, "HEAD"])
            .await?;
        Ok(output
            .lines()
            .filter(|l| !l.is_empty())
            .map(std::string::ToString::to_string)
            .collect())
    }

    /// Get diff stat summary (insertions, deletions) between two refs.
    pub async fn diff_numstat_total(
        &self,
        dir: &Path,
        base: &str,
        head: &str,
    ) -> Result<(usize, usize)> {
        let output = self.run(dir, &["diff", "--numstat", base, head]).await?;
        let mut insertions = 0usize;
        let mut deletions = 0usize;
        for line in output.lines() {
            let parts: Vec<&str> = line.split('\t').collect();
            if parts.len() >= 2 {
                // Binary files show "-" for insertions/deletions
                insertions += parts[0].parse::<usize>().unwrap_or(0);
                deletions += parts[1].parse::<usize>().unwrap_or(0);
            }
        }
        Ok((insertions, deletions))
    }

    /// List branches matching a glob pattern.
    pub async fn list_branches_matching(&self, repo: &Path, pattern: &str) -> Result<Vec<String>> {
        let output = self
            .run(
                repo,
                &["branch", "--list", pattern, "--format=%(refname:short)"],
            )
            .await?;
        Ok(output
            .lines()
            .filter(|l| !l.is_empty())
            .map(|l| l.trim().to_string())
            .collect())
    }

    /// List branches on a remote. Returns the branch name with the remote
    /// prefix stripped (e.g. `origin/main` → `main`) and filters the
    /// pseudo-ref `HEAD`. Used for the Merge Changes target picker so only
    /// published/shared branches are offered as merge targets.
    pub async fn list_remote_branches(&self, repo: &Path, remote: &str) -> Result<Vec<String>> {
        let pattern = format!("refs/remotes/{remote}/");
        let output = self
            .run(
                repo,
                &["for-each-ref", "--format=%(refname:short)", &pattern],
            )
            .await?;
        let prefix = format!("{remote}/");
        let mut names: Vec<String> = output
            .lines()
            .filter(|l| !l.is_empty())
            .map(|l| l.trim())
            .filter_map(|l| l.strip_prefix(&prefix).map(str::to_string))
            .filter(|name| name != "HEAD")
            .collect();
        names.sort();
        names.dedup();
        Ok(names)
    }

    /// Get log entries for a branch: (hash, message, date).
    pub async fn branch_log(
        &self,
        repo: &Path,
        branch: &str,
        count: usize,
    ) -> Result<Vec<(String, String, String)>> {
        let count_str = format!("-{count}");
        let output = self
            .run(
                repo,
                &["log", &count_str, "--format=%H%x00%s%x00%aI", branch],
            )
            .await?;
        Ok(output
            .lines()
            .filter(|l| !l.is_empty())
            .filter_map(|line| {
                let mut parts = line.splitn(3, '\0');
                let hash = parts.next()?.to_string();
                let message = parts.next()?.to_string();
                let date = parts.next()?.to_string();
                Some((hash, message, date))
            })
            .collect())
    }

    /// Find the merge base of two refs.
    pub async fn merge_base(&self, repo: &Path, a: &str, b: &str) -> Result<String> {
        self.run(repo, &["merge-base", a, b]).await
    }

    /// Get unified diff between two refs.
    pub async fn diff_between(&self, repo: &Path, base: &str, head: &str) -> Result<String> {
        let range = format!("{base}..{head}");
        self.run(repo, &["diff", &range]).await
    }

    /// Count commits between base (exclusive) and head (inclusive).
    pub async fn commit_count_between(&self, repo: &Path, base: &str, head: &str) -> Result<usize> {
        let range = format!("{base}..{head}");
        let output = self.run(repo, &["rev-list", "--count", &range]).await?;
        output.parse::<usize>().map_err(|e| {
            WorktreeError::Git(format!("failed to parse commit count '{output}': {e}"))
        })
    }

    /// Get (status, path) pairs between two refs via `git diff --name-status`.
    pub async fn diff_name_status(
        &self,
        repo: &Path,
        base: &str,
        head: &str,
    ) -> Result<Vec<(String, String)>> {
        let range = format!("{base}..{head}");
        let output = self.run(repo, &["diff", "--name-status", &range]).await?;
        Ok(output
            .lines()
            .filter(|l| !l.is_empty())
            .filter_map(|line| {
                let mut parts = line.splitn(2, '\t');
                let status = parts.next()?.trim().to_string();
                let path = parts.next()?.trim().to_string();
                Some((status, path))
            })
            .collect())
    }

    /// Check if `potential_ancestor` is an ancestor of `branch`.
    ///
    /// Uses `git merge-base --is-ancestor` which returns exit 0 if true, 1 if not.
    pub async fn is_ancestor(&self, repo: &Path, potential_ancestor: &str, branch: &str) -> bool {
        self.run_status(
            repo,
            &["merge-base", "--is-ancestor", potential_ancestor, branch],
        )
        .await
    }
}

#[cfg(test)]
#[path = "git/tests.rs"]
mod tests;

#[cfg(test)]
#[path = "git/phase1_tests.rs"]
mod phase1_tests;
