//! Low-level git command execution.
//!
//! Wraps `tokio::process::Command` with configurable timeout.
//! All commands capture stdout/stderr and return structured results.

use std::path::Path;
use std::time::Duration;

use tracing::{debug, warn};

use crate::errors::{Result, WorktreeError};

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
        self.run(path, &["rev-parse", "--git-dir"]).await.is_ok()
    }

    /// Get the root of the repository containing `path`.
    pub async fn repo_root(&self, path: &Path) -> Result<String> {
        self.run(path, &["rev-parse", "--show-toplevel"]).await
    }

    /// Get the HEAD commit hash.
    pub async fn head_commit(&self, dir: &Path) -> Result<String> {
        self.run(dir, &["rev-parse", "HEAD"]).await
    }

    /// Get the current branch name (None-ish error for detached HEAD).
    pub async fn current_branch(&self, dir: &Path) -> Result<String> {
        self.run(dir, &["symbolic-ref", "--short", "HEAD"]).await
    }

    /// Add a new worktree with a new branch.
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
                &["worktree", "add", "-b", branch, &path_str, start_point],
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

    /// Check if there are uncommitted changes.
    pub async fn has_changes(&self, dir: &Path) -> Result<bool> {
        let output = self.run(dir, &["status", "--porcelain"]).await?;
        Ok(!output.is_empty())
    }

    /// Get diff stat.
    pub async fn diff_stat(&self, dir: &Path) -> Result<String> {
        self.run(dir, &["diff", "--stat"]).await
    }

    /// Stage all and commit.
    pub async fn commit_all(&self, dir: &Path, message: &str) -> Result<String> {
        let _ = self.run(dir, &["add", "-A"]).await?;
        let _ = self.run(dir, &["commit", "-m", message]).await?;
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
        Ok(output.lines().map(std::string::ToString::to_string).collect())
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
        let output = self
            .run(dir, &["diff", "--numstat", base, head])
            .await?;
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
        let output = self.run(repo, &["branch", "--list", pattern, "--format=%(refname:short)"]).await?;
        Ok(output
            .lines()
            .filter(|l| !l.is_empty())
            .map(|l| l.trim().to_string())
            .collect())
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
            .run(repo, &["log", &count_str, "--format=%H%x00%s%x00%aI", branch])
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
    pub async fn commit_count_between(
        &self,
        repo: &Path,
        base: &str,
        head: &str,
    ) -> Result<usize> {
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
        self.run_status(repo, &["merge-base", "--is-ancestor", potential_ancestor, branch])
            .await
    }

    /// Run a git command and return whether it succeeded (exit code 0).
    async fn run_status(&self, dir: &Path, args: &[&str]) -> bool {
        debug!(dir = %dir.display(), args = ?args, "git (status check)");
        let result = tokio::time::timeout(
            self.timeout,
            tokio::process::Command::new("git")
                .args(args)
                .current_dir(dir)
                .output(),
        )
        .await;
        matches!(result, Ok(Ok(output)) if output.status.success())
    }

    /// Run a git command with timeout.
    async fn run(&self, dir: &Path, args: &[&str]) -> Result<String> {
        debug!(dir = %dir.display(), args = ?args, "git");

        let output = tokio::time::timeout(
            self.timeout,
            tokio::process::Command::new("git")
                .args(args)
                .current_dir(dir)
                .output(),
        )
        .await
        .map_err(|_| WorktreeError::Timeout(self.timeout.as_millis() as u64))?
        .map_err(|e| WorktreeError::Git(format!("failed to execute git: {e}")))?;

        if output.status.success() {
            Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
        } else {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            warn!(args = ?args, stderr = %stderr, "git command failed");
            Err(WorktreeError::Git(stderr))
        }
    }
}

/// Parse `git worktree list --porcelain` output.
fn parse_worktree_porcelain(output: &str) -> Vec<WorktreeListEntry> {
    let mut entries = Vec::new();
    let mut path = None;
    let mut head = None;
    let mut branch = None;
    let mut bare = false;

    for line in output.lines() {
        if line.starts_with("worktree ") {
            // Save previous entry if complete
            if let (Some(p), Some(h)) = (path.take(), head.take()) {
                entries.push(WorktreeListEntry {
                    path: p,
                    head: h,
                    branch: branch.take(),
                    bare,
                });
                bare = false;
            }
            path = Some(line.strip_prefix("worktree ").unwrap_or("").to_string());
        } else if line.starts_with("HEAD ") {
            head = Some(line.strip_prefix("HEAD ").unwrap_or("").to_string());
        } else if line.starts_with("branch ") {
            let full = line.strip_prefix("branch ").unwrap_or("");
            branch = Some(
                full.strip_prefix("refs/heads/")
                    .unwrap_or(full)
                    .to_string(),
            );
        } else if line == "bare" {
            bare = true;
        }
    }

    // Push last entry
    if let (Some(p), Some(h)) = (path, head) {
        entries.push(WorktreeListEntry {
            path: p,
            head: h,
            branch,
            bare,
        });
    }

    entries
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn parse_worktree_porcelain_single() {
        let output = "worktree /repo\nHEAD abc123\nbranch refs/heads/main\n";
        let entries = parse_worktree_porcelain(output);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].path, "/repo");
        assert_eq!(entries[0].head, "abc123");
        assert_eq!(entries[0].branch.as_deref(), Some("main"));
        assert!(!entries[0].bare);
    }

    #[test]
    fn parse_worktree_porcelain_multiple() {
        let output = "\
worktree /repo
HEAD abc123
branch refs/heads/main

worktree /repo/.worktrees/session/x
HEAD def456
branch refs/heads/session/x
";
        let entries = parse_worktree_porcelain(output);
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[1].branch.as_deref(), Some("session/x"));
    }

    #[test]
    fn parse_worktree_porcelain_bare() {
        let output = "worktree /repo\nHEAD abc123\nbare\n";
        let entries = parse_worktree_porcelain(output);
        assert_eq!(entries.len(), 1);
        assert!(entries[0].bare);
        assert!(entries[0].branch.is_none());
    }

    #[test]
    fn parse_worktree_porcelain_empty() {
        let entries = parse_worktree_porcelain("");
        assert!(entries.is_empty());
    }

    /// Helper: create a git repo with an initial commit.
    async fn init_repo(dir: &Path) -> GitExecutor {
        let git = GitExecutor::new(30_000);
        run_cmd(dir, &["git", "init"]).await;
        run_cmd(dir, &["git", "config", "user.email", "test@test.com"]).await;
        run_cmd(dir, &["git", "config", "user.name", "Test"]).await;
        std::fs::write(dir.join("README.md"), "# test").unwrap();
        run_cmd(dir, &["git", "add", "-A"]).await;
        run_cmd(dir, &["git", "commit", "-m", "init"]).await;
        git
    }

    async fn run_cmd(dir: &Path, args: &[&str]) {
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

    async fn run_cmd_ok(dir: &Path, args: &[&str]) -> bool {
        tokio::process::Command::new(args[0])
            .args(&args[1..])
            .current_dir(dir)
            .output()
            .await
            .map(|o| o.status.success())
            .unwrap_or(false)
    }

    #[tokio::test]
    async fn is_git_repo_true() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        assert!(git.is_git_repo(dir.path()).await);
    }

    #[tokio::test]
    async fn is_git_repo_false() {
        let dir = tempdir().unwrap();
        let git = GitExecutor::new(30_000);
        assert!(!git.is_git_repo(dir.path()).await);
    }

    #[tokio::test]
    async fn repo_root_from_subdir() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let sub = dir.path().join("sub");
        std::fs::create_dir_all(&sub).unwrap();
        let root = git.repo_root(&sub).await.unwrap();
        assert_eq!(
            std::path::Path::new(&root).canonicalize().unwrap(),
            dir.path().canonicalize().unwrap()
        );
    }

    #[tokio::test]
    async fn head_commit_returns_sha() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let sha = git.head_commit(dir.path()).await.unwrap();
        assert_eq!(sha.len(), 40);
        assert!(sha.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[tokio::test]
    async fn current_branch_main() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let branch = git.current_branch(dir.path()).await.unwrap();
        // git init creates "main" or "master" depending on config
        assert!(!branch.is_empty());
    }

    #[tokio::test]
    async fn worktree_lifecycle() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;

        let wt_path = dir.path().join(".worktrees").join("test-wt");

        // Add
        git.worktree_add(dir.path(), &wt_path, "test-branch", "HEAD")
            .await
            .unwrap();
        assert!(wt_path.exists());

        // List
        let entries = git.worktree_list(dir.path()).await.unwrap();
        assert_eq!(entries.len(), 2);
        assert!(entries.iter().any(|e| e.branch.as_deref() == Some("test-branch")));

        // Remove
        git.worktree_remove(dir.path(), &wt_path, false)
            .await
            .unwrap();
        assert!(!wt_path.exists());

        // Branch still exists
        let branch_output = tokio::process::Command::new("git")
            .args(["branch", "--list", "test-branch"])
            .current_dir(dir.path())
            .output()
            .await
            .unwrap();
        assert!(
            !String::from_utf8_lossy(&branch_output.stdout)
                .trim()
                .is_empty()
        );

        // Delete branch
        git.branch_delete(dir.path(), "test-branch", false)
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn has_changes_and_commit() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;

        assert!(!git.has_changes(dir.path()).await.unwrap());

        std::fs::write(dir.path().join("new.txt"), "hello").unwrap();
        assert!(git.has_changes(dir.path()).await.unwrap());

        let sha = git.commit_all(dir.path(), "add file").await.unwrap();
        assert_eq!(sha.len(), 40);
        assert!(!git.has_changes(dir.path()).await.unwrap());
    }

    #[tokio::test]
    async fn commit_count_since_base() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;

        let base = git.head_commit(dir.path()).await.unwrap();

        // No commits since base
        assert_eq!(git.commit_count_since(dir.path(), &base).await.unwrap(), 0);

        // One commit
        std::fs::write(dir.path().join("a.txt"), "a").unwrap();
        git.commit_all(dir.path(), "first").await.unwrap();
        assert_eq!(git.commit_count_since(dir.path(), &base).await.unwrap(), 1);

        // Two commits
        std::fs::write(dir.path().join("b.txt"), "b").unwrap();
        git.commit_all(dir.path(), "second").await.unwrap();
        assert_eq!(git.commit_count_since(dir.path(), &base).await.unwrap(), 2);
    }

    #[tokio::test]
    async fn changed_files_since_base() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let base = git.head_commit(dir.path()).await.unwrap();

        std::fs::write(dir.path().join("new.txt"), "new").unwrap();
        git.commit_all(dir.path(), "add new").await.unwrap();

        let files = git.changed_files_since(dir.path(), &base).await.unwrap();
        assert_eq!(files, vec!["new.txt"]);
    }

    #[tokio::test]
    async fn diff_numstat_total_basic() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let base = git.head_commit(dir.path()).await.unwrap();

        // Write a file with 3 lines
        std::fs::write(dir.path().join("code.txt"), "line1\nline2\nline3\n").unwrap();
        git.commit_all(dir.path(), "add code").await.unwrap();
        let head = git.head_commit(dir.path()).await.unwrap();

        let (ins, del) = git.diff_numstat_total(dir.path(), &base, &head).await.unwrap();
        assert_eq!(ins, 3);
        assert_eq!(del, 0);
    }

    #[tokio::test]
    async fn error_on_non_git_dir() {
        let dir = tempdir().unwrap();
        let git = GitExecutor::new(30_000);
        let result = git.head_commit(dir.path()).await;
        assert!(result.is_err());
    }

    // ── list_branches_matching ──────────────────────────────────────

    #[tokio::test]
    async fn list_branches_no_matches() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let branches = git.list_branches_matching(dir.path(), "session/*").await.unwrap();
        assert!(branches.is_empty());
    }

    #[tokio::test]
    async fn list_branches_single_match() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        run_cmd(dir.path(), &["git", "branch", "session/abc"]).await;
        let branches = git.list_branches_matching(dir.path(), "session/*").await.unwrap();
        assert_eq!(branches, vec!["session/abc"]);
    }

    #[tokio::test]
    async fn list_branches_multiple_matches() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        run_cmd(dir.path(), &["git", "branch", "session/aaa"]).await;
        run_cmd(dir.path(), &["git", "branch", "session/bbb"]).await;
        run_cmd(dir.path(), &["git", "branch", "session/ccc"]).await;
        let branches = git.list_branches_matching(dir.path(), "session/*").await.unwrap();
        assert_eq!(branches.len(), 3);
    }

    #[tokio::test]
    async fn list_branches_ignores_non_matching() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        run_cmd(dir.path(), &["git", "branch", "session/abc"]).await;
        run_cmd(dir.path(), &["git", "branch", "feature/xyz"]).await;
        let branches = git.list_branches_matching(dir.path(), "session/*").await.unwrap();
        assert_eq!(branches.len(), 1);
        assert_eq!(branches[0], "session/abc");
    }

    // ── branch_log ──────────────────────────────────────────────────

    #[tokio::test]
    async fn branch_log_single_commit() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let entries = git.branch_log(dir.path(), "HEAD", 10).await.unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].0.len(), 40); // hash
        assert_eq!(entries[0].1, "init"); // message
        assert!(!entries[0].2.is_empty()); // date
    }

    #[tokio::test]
    async fn branch_log_multiple_commits() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        for i in 1..=5 {
            std::fs::write(dir.path().join(format!("f{i}.txt")), format!("content{i}")).unwrap();
            git.commit_all(dir.path(), &format!("commit {i}")).await.unwrap();
        }
        let entries = git.branch_log(dir.path(), "HEAD", 3).await.unwrap();
        assert_eq!(entries.len(), 3);
    }

    #[tokio::test]
    async fn branch_log_nonexistent_branch() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let result = git.branch_log(dir.path(), "nonexistent", 1).await;
        assert!(result.is_err());
    }

    // ── merge_base ──────────────────────────────────────────────────

    #[tokio::test]
    async fn merge_base_simple() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let base_sha = git.head_commit(dir.path()).await.unwrap();

        // Create a branch and add a commit
        run_cmd(dir.path(), &["git", "checkout", "-b", "feature"]).await;
        std::fs::write(dir.path().join("f.txt"), "feature").unwrap();
        git.commit_all(dir.path(), "feature commit").await.unwrap();

        // Checkout default branch (may be main or master)
        let branch = git.current_branch(dir.path()).await.unwrap_or_default();
        if branch != "feature" {
            // Already on default branch from the checkout -b
        }
        // Go back to the branch we started on
        let default = if run_cmd_ok(dir.path(), &["git", "checkout", "main"]).await {
            "main"
        } else {
            run_cmd(dir.path(), &["git", "checkout", "master"]).await;
            "master"
        };
        let _ = default;

        let mb = git.merge_base(dir.path(), "feature", "HEAD").await.unwrap();
        assert_eq!(mb, base_sha);
    }

    #[tokio::test]
    async fn merge_base_nonexistent_branch() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let result = git.merge_base(dir.path(), "nonexistent", "HEAD").await;
        assert!(result.is_err());
    }

    // ── diff_between ────────────────────────────────────────────────

    #[tokio::test]
    async fn diff_between_no_changes() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let head = git.head_commit(dir.path()).await.unwrap();
        let diff = git.diff_between(dir.path(), &head, &head).await.unwrap();
        assert!(diff.is_empty());
    }

    #[tokio::test]
    async fn diff_between_added_file() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let base = git.head_commit(dir.path()).await.unwrap();

        std::fs::write(dir.path().join("new.txt"), "hello\n").unwrap();
        let head = git.commit_all(dir.path(), "add new").await.unwrap();

        let diff = git.diff_between(dir.path(), &base, &head).await.unwrap();
        assert!(diff.contains("+hello"));
    }

    #[tokio::test]
    async fn diff_between_nonexistent_ref() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let result = git.diff_between(dir.path(), "badref", "HEAD").await;
        assert!(result.is_err());
    }

    // ── commit_count_between ────────────────────────────────────────

    #[tokio::test]
    async fn commit_count_between_zero() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let head = git.head_commit(dir.path()).await.unwrap();
        let count = git.commit_count_between(dir.path(), &head, &head).await.unwrap();
        assert_eq!(count, 0);
    }

    #[tokio::test]
    async fn commit_count_between_multiple() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let base = git.head_commit(dir.path()).await.unwrap();
        for i in 0..3 {
            std::fs::write(dir.path().join(format!("f{i}.txt")), "x").unwrap();
            git.commit_all(dir.path(), &format!("c{i}")).await.unwrap();
        }
        let head = git.head_commit(dir.path()).await.unwrap();
        let count = git.commit_count_between(dir.path(), &base, &head).await.unwrap();
        assert_eq!(count, 3);
    }

    // ── diff_name_status ────────────────────────────────────────────

    #[tokio::test]
    async fn name_status_added() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let base = git.head_commit(dir.path()).await.unwrap();
        std::fs::write(dir.path().join("new.txt"), "new").unwrap();
        let head = git.commit_all(dir.path(), "add").await.unwrap();
        let entries = git.diff_name_status(dir.path(), &base, &head).await.unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].0, "A");
        assert_eq!(entries[0].1, "new.txt");
    }

    #[tokio::test]
    async fn name_status_mixed() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let base = git.head_commit(dir.path()).await.unwrap();

        // Modify existing, add new, delete existing
        std::fs::write(dir.path().join("README.md"), "modified").unwrap();
        std::fs::write(dir.path().join("new.txt"), "new").unwrap();
        let head = git.commit_all(dir.path(), "changes").await.unwrap();

        let entries = git.diff_name_status(dir.path(), &base, &head).await.unwrap();
        assert!(entries.len() >= 2);
    }

    #[tokio::test]
    async fn name_status_empty() {
        let dir = tempdir().unwrap();
        let git = init_repo(dir.path()).await;
        let head = git.head_commit(dir.path()).await.unwrap();
        let entries = git.diff_name_status(dir.path(), &head, &head).await.unwrap();
        assert!(entries.is_empty());
    }
}
