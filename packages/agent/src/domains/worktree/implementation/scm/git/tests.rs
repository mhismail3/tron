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
async fn has_commits_true_with_commits() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    assert!(git.has_commits(dir.path()).await);
}

#[tokio::test]
async fn has_commits_false_empty_repo() {
    let dir = tempdir().unwrap();
    run_cmd(dir.path(), &["git", "init"]).await;
    let git = GitExecutor::new(30_000);
    assert!(!git.has_commits(dir.path()).await);
}

#[tokio::test]
async fn has_commits_false_non_git() {
    let dir = tempdir().unwrap();
    let git = GitExecutor::new(30_000);
    assert!(!git.has_commits(dir.path()).await);
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
    assert!(
        entries
            .iter()
            .any(|e| e.branch.as_deref() == Some("test-branch"))
    );

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

// ── commit_with_options ────────────────────────────────────────────

/// Read the full commit message (body + trailers) of HEAD.
async fn head_message(dir: &Path) -> String {
    let out = tokio::process::Command::new("git")
        .args(["log", "-1", "--format=%B"])
        .current_dir(dir)
        .output()
        .await
        .unwrap();
    assert!(out.status.success(), "git log failed");
    String::from_utf8(out.stdout).unwrap()
}

async fn head_subject(dir: &Path) -> String {
    let out = tokio::process::Command::new("git")
        .args(["log", "-1", "--format=%s"])
        .current_dir(dir)
        .output()
        .await
        .unwrap();
    assert!(out.status.success());
    String::from_utf8(out.stdout)
        .unwrap()
        .trim_end()
        .to_string()
}

async fn rev_list_count(dir: &Path) -> u64 {
    let out = tokio::process::Command::new("git")
        .args(["rev-list", "--count", "HEAD"])
        .current_dir(dir)
        .output()
        .await
        .unwrap();
    assert!(out.status.success());
    String::from_utf8(out.stdout)
        .unwrap()
        .trim()
        .parse()
        .unwrap()
}

async fn files_at_head(dir: &Path) -> Vec<String> {
    let out = tokio::process::Command::new("git")
        .args(["log", "-1", "--name-only", "--format="])
        .current_dir(dir)
        .output()
        .await
        .unwrap();
    assert!(out.status.success());
    String::from_utf8(out.stdout)
        .unwrap()
        .lines()
        .filter(|l| !l.is_empty())
        .map(|l| l.to_string())
        .collect()
}

#[tokio::test]
async fn commit_with_options_stage_all_adds_and_commits() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;

    std::fs::write(dir.path().join("new.txt"), "hello").unwrap();
    let opts = CommitOptions {
        stage_all: true,
        ..Default::default()
    };
    let sha = git
        .commit_with_options(dir.path(), "add new", &opts)
        .await
        .unwrap();

    assert_eq!(sha.len(), 40, "sha must be a 40-char hex");
    let files = files_at_head(dir.path()).await;
    assert!(
        files.iter().any(|f| f == "new.txt"),
        "expected new.txt in HEAD, got {files:?}"
    );
    assert!(
        !git.has_changes(dir.path()).await.unwrap(),
        "tree should be clean after commit"
    );
}

#[tokio::test]
async fn commit_with_options_stage_all_false_commits_only_index() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;

    // Two new files. Stage only the first via raw git; leave the second
    // untracked. With stage_all=false, the commit must include only
    // staged.txt — NOT unstaged.txt.
    std::fs::write(dir.path().join("staged.txt"), "one").unwrap();
    std::fs::write(dir.path().join("unstaged.txt"), "two").unwrap();
    run_cmd(dir.path(), &["git", "add", "staged.txt"]).await;

    let opts = CommitOptions {
        stage_all: false,
        ..Default::default()
    };
    let sha = git
        .commit_with_options(dir.path(), "partial", &opts)
        .await
        .unwrap();
    assert_eq!(sha.len(), 40);

    let files = files_at_head(dir.path()).await;
    assert!(
        files.contains(&"staged.txt".to_string()),
        "staged.txt must be in commit: {files:?}"
    );
    assert!(
        !files.contains(&"unstaged.txt".to_string()),
        "unstaged.txt MUST NOT be in commit: {files:?}"
    );

    // Untracked file still present after commit
    assert!(
        git.has_changes(dir.path()).await.unwrap(),
        "untracked unstaged.txt should keep tree dirty"
    );
}

#[tokio::test]
async fn commit_with_options_amend_rewrites_head() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;

    // init_repo already produced one commit. Make one more to amend.
    std::fs::write(dir.path().join("a.txt"), "a").unwrap();
    let _ = git.commit_all(dir.path(), "first add").await.unwrap();
    let count_before = rev_list_count(dir.path()).await;

    // Modify and amend with a new message
    std::fs::write(dir.path().join("a.txt"), "a-edited").unwrap();
    let opts = CommitOptions {
        stage_all: true,
        amend: true,
        ..Default::default()
    };
    let sha = git
        .commit_with_options(dir.path(), "first add (amended)", &opts)
        .await
        .unwrap();
    assert_eq!(sha.len(), 40);

    assert_eq!(
        rev_list_count(dir.path()).await,
        count_before,
        "amend must not add a commit"
    );
    assert_eq!(head_subject(dir.path()).await, "first add (amended)");
}

#[tokio::test]
async fn commit_with_options_signoff_adds_trailer() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;

    std::fs::write(dir.path().join("s.txt"), "s").unwrap();
    let opts = CommitOptions {
        stage_all: true,
        signoff: true,
        ..Default::default()
    };
    let _ = git
        .commit_with_options(dir.path(), "signed change", &opts)
        .await
        .unwrap();

    let body = head_message(dir.path()).await;
    assert!(
        body.lines().any(|l| l.starts_with("Signed-off-by:")),
        "expected Signed-off-by: trailer, got {body:?}"
    );
}

#[tokio::test]
async fn commit_with_options_amend_and_signoff_compose() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;

    // First commit to amend
    std::fs::write(dir.path().join("x.txt"), "x").unwrap();
    let _ = git.commit_all(dir.path(), "x").await.unwrap();
    let count_before = rev_list_count(dir.path()).await;

    // Amend with signoff
    std::fs::write(dir.path().join("x.txt"), "x2").unwrap();
    let opts = CommitOptions {
        stage_all: true,
        amend: true,
        signoff: true,
    };
    let _ = git
        .commit_with_options(dir.path(), "x (amended)", &opts)
        .await
        .unwrap();

    assert_eq!(rev_list_count(dir.path()).await, count_before);
    let body = head_message(dir.path()).await;
    assert!(body.starts_with("x (amended)"));
    assert!(body.lines().any(|l| l.starts_with("Signed-off-by:")));
}

#[tokio::test]
async fn commit_with_options_no_changes_without_amend_returns_err() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;

    // git commit exits non-zero when the index is clean; the "nothing to
    // commit" text lands on stdout, not stderr, so we just assert Err
    // rather than probing the message.
    let opts = CommitOptions {
        stage_all: false,
        ..Default::default()
    };
    let result = git.commit_with_options(dir.path(), "empty", &opts).await;
    assert!(
        result.is_err(),
        "expected Err on clean index without --allow-empty"
    );
}

#[tokio::test]
async fn commit_with_options_message_with_newlines_preserved() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;

    std::fs::write(dir.path().join("m.txt"), "m").unwrap();
    let message = "subject line\n\nbody paragraph\nsecond body line";
    let opts = CommitOptions {
        stage_all: true,
        ..Default::default()
    };
    let _ = git
        .commit_with_options(dir.path(), message, &opts)
        .await
        .unwrap();

    let body = head_message(dir.path()).await;
    // git may append a trailing newline; compare trimmed.
    assert_eq!(body.trim_end(), message);
}

#[tokio::test]
async fn commit_with_options_message_starting_with_dash_not_treated_as_flag() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;

    std::fs::write(dir.path().join("d.txt"), "d").unwrap();
    let message = "-x do thing";
    let opts = CommitOptions {
        stage_all: true,
        ..Default::default()
    };
    let sha = git
        .commit_with_options(dir.path(), message, &opts)
        .await
        .unwrap();
    assert_eq!(sha.len(), 40);
    assert_eq!(head_subject(dir.path()).await, "-x do thing");
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
    let _ = git.commit_all(dir.path(), "first").await.unwrap();
    assert_eq!(git.commit_count_since(dir.path(), &base).await.unwrap(), 1);

    // Two commits
    std::fs::write(dir.path().join("b.txt"), "b").unwrap();
    let _ = git.commit_all(dir.path(), "second").await.unwrap();
    assert_eq!(git.commit_count_since(dir.path(), &base).await.unwrap(), 2);
}

#[tokio::test]
async fn changed_files_since_base() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    let base = git.head_commit(dir.path()).await.unwrap();

    std::fs::write(dir.path().join("new.txt"), "new").unwrap();
    let _ = git.commit_all(dir.path(), "add new").await.unwrap();

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
    let _ = git.commit_all(dir.path(), "add code").await.unwrap();
    let head = git.head_commit(dir.path()).await.unwrap();

    let (ins, del) = git
        .diff_numstat_total(dir.path(), &base, &head)
        .await
        .unwrap();
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
    let branches = git
        .list_branches_matching(dir.path(), "session/*")
        .await
        .unwrap();
    assert!(branches.is_empty());
}

#[tokio::test]
async fn list_branches_single_match() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    run_cmd(dir.path(), &["git", "branch", "session/abc"]).await;
    let branches = git
        .list_branches_matching(dir.path(), "session/*")
        .await
        .unwrap();
    assert_eq!(branches, vec!["session/abc"]);
}

#[tokio::test]
async fn list_branches_multiple_matches() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    run_cmd(dir.path(), &["git", "branch", "session/aaa"]).await;
    run_cmd(dir.path(), &["git", "branch", "session/bbb"]).await;
    run_cmd(dir.path(), &["git", "branch", "session/ccc"]).await;
    let branches = git
        .list_branches_matching(dir.path(), "session/*")
        .await
        .unwrap();
    assert_eq!(branches.len(), 3);
}

#[tokio::test]
async fn list_branches_ignores_non_matching() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    run_cmd(dir.path(), &["git", "branch", "session/abc"]).await;
    run_cmd(dir.path(), &["git", "branch", "feature/xyz"]).await;
    let branches = git
        .list_branches_matching(dir.path(), "session/*")
        .await
        .unwrap();
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
        let _ = git
            .commit_all(dir.path(), &format!("commit {i}"))
            .await
            .unwrap();
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
    let _ = git.commit_all(dir.path(), "feature commit").await.unwrap();

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
    let count = git
        .commit_count_between(dir.path(), &head, &head)
        .await
        .unwrap();
    assert_eq!(count, 0);
}

#[tokio::test]
async fn commit_count_between_multiple() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    let base = git.head_commit(dir.path()).await.unwrap();
    for i in 0..3 {
        std::fs::write(dir.path().join(format!("f{i}.txt")), "x").unwrap();
        let _ = git.commit_all(dir.path(), &format!("c{i}")).await.unwrap();
    }
    let head = git.head_commit(dir.path()).await.unwrap();
    let count = git
        .commit_count_between(dir.path(), &base, &head)
        .await
        .unwrap();
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
    let entries = git
        .diff_name_status(dir.path(), &base, &head)
        .await
        .unwrap();
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

    let entries = git
        .diff_name_status(dir.path(), &base, &head)
        .await
        .unwrap();
    assert!(entries.len() >= 2);
}

#[tokio::test]
async fn name_status_empty() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    let head = git.head_commit(dir.path()).await.unwrap();
    let entries = git
        .diff_name_status(dir.path(), &head, &head)
        .await
        .unwrap();
    assert!(entries.is_empty());
}

// ── branch_rename tests ────────────────────────────────────────

#[tokio::test]
async fn branch_rename_success() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    run_cmd(dir.path(), &["git", "branch", "old-branch"]).await;

    git.branch_rename(dir.path(), "old-branch", "new-branch")
        .await
        .unwrap();

    let branches = git.list_branches_matching(dir.path(), "*").await.unwrap();
    assert!(branches.contains(&"new-branch".to_string()));
    assert!(!branches.contains(&"old-branch".to_string()));
}

#[tokio::test]
async fn branch_rename_nonexistent_fails() {
    let dir = tempdir().unwrap();
    let _git = init_repo(dir.path()).await;

    let git = GitExecutor::new(30_000);
    let result = git
        .branch_rename(dir.path(), "nonexistent", "new-name")
        .await;
    assert!(result.is_err());
}

#[tokio::test]
async fn branch_rename_to_existing_fails() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;
    run_cmd(dir.path(), &["git", "branch", "branch-a"]).await;
    run_cmd(dir.path(), &["git", "branch", "branch-b"]).await;

    let result = git.branch_rename(dir.path(), "branch-a", "branch-b").await;
    assert!(result.is_err());
}

#[tokio::test]
async fn branch_rename_worktree_branch() {
    let dir = tempdir().unwrap();
    let git = init_repo(dir.path()).await;

    let wt_path = dir.path().join(".worktrees").join("session").join("test");
    git.worktree_add(dir.path(), &wt_path, "session/old-name", "HEAD")
        .await
        .unwrap();

    git.branch_rename(dir.path(), "session/old-name", "session/new-name")
        .await
        .unwrap();

    let branches = git
        .list_branches_matching(dir.path(), "session/*")
        .await
        .unwrap();
    assert!(branches.contains(&"session/new-name".to_string()));
    assert!(!branches.contains(&"session/old-name".to_string()));

    // Worktree should still be functional
    assert!(wt_path.exists());
    std::fs::write(wt_path.join("test.txt"), "works").unwrap();
    let has_changes = git.has_changes(&wt_path).await.unwrap();
    assert!(has_changes);
}
