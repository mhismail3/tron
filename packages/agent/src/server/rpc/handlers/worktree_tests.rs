use super::*;
use crate::server::rpc::handlers::test_helpers::make_test_context;
use serde_json::json;

// ── Handler tests (coordinator-required) ────────────────────────

#[tokio::test]
async fn get_status_requires_coordinator() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("model", "/tmp", Some("test"))
        .unwrap();
    let err = GetStatusHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap_err();
    assert!(err.to_string().contains("not enabled"));
}

#[tokio::test]
async fn commit_requires_coordinator() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", None)
        .unwrap();
    let err = CommitHandler
        .handle(
            Some(json!({"sessionId": sid, "message": "test commit"})),
            &ctx,
        )
        .await
        .unwrap_err();
    assert!(err.to_string().contains("not enabled"));
}

#[tokio::test]
async fn commit_missing_message() {
    let ctx = make_test_context();
    let err = CommitHandler
        .handle(Some(json!({"sessionId": "s1"})), &ctx)
        .await
        .unwrap_err();
    assert_eq!(err.code(), "INVALID_PARAMS");
}

#[tokio::test]
async fn merge_requires_coordinator() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", None)
        .unwrap();
    let err = MergeHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap_err();
    assert!(err.to_string().contains("not enabled"));
}

#[tokio::test]
async fn list_requires_coordinator() {
    let ctx = make_test_context();
    let err = ListHandler.handle(None, &ctx).await.unwrap_err();
    assert!(err.to_string().contains("not enabled"));
}

#[tokio::test]
async fn acquire_requires_coordinator() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", None)
        .unwrap();
    let err = AcquireHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap_err();
    assert!(err.to_string().contains("not enabled"));
}

#[tokio::test]
async fn release_requires_coordinator() {
    let ctx = make_test_context();
    let err = ReleaseHandler
        .handle(Some(json!({"sessionId": "s1"})), &ctx)
        .await
        .unwrap_err();
    assert!(err.to_string().contains("not enabled"));
}

// ── ListSessionBranches handler tests ───────────────────────────

#[tokio::test]
async fn list_session_branches_requires_coordinator() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", None)
        .unwrap();
    let err = ListSessionBranchesHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap_err();
    assert!(err.to_string().contains("not enabled"));
}

#[tokio::test]
async fn list_session_branches_missing_session_id() {
    let ctx = make_test_context();
    let err = ListSessionBranchesHandler
        .handle(Some(json!({})), &ctx)
        .await
        .unwrap_err();
    assert_eq!(err.code(), "INVALID_PARAMS");
}

#[tokio::test]
async fn list_session_branches_session_not_found() {
    let ctx = make_test_context();
    // Need coordinator for this to get past require_coordinator
    // Without coordinator, it errors with "not enabled" first
    let err = ListSessionBranchesHandler
        .handle(Some(json!({"sessionId": "nonexistent"})), &ctx)
        .await
        .unwrap_err();
    assert!(err.to_string().contains("not enabled"));
}

// ── DeleteBranch handler tests ─────────────────────────────────

#[tokio::test]
async fn delete_branch_requires_coordinator() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", None)
        .unwrap();
    let err = DeleteBranchHandler
        .handle(
            Some(json!({"sessionId": sid, "branch": "session/x"})),
            &ctx,
        )
        .await
        .unwrap_err();
    assert!(err.to_string().contains("not enabled"));
}

#[tokio::test]
async fn delete_branch_missing_branch_param() {
    let ctx = make_test_context();
    let err = DeleteBranchHandler
        .handle(Some(json!({"sessionId": "s1"})), &ctx)
        .await
        .unwrap_err();
    assert_eq!(err.code(), "INVALID_PARAMS");
}

// ── PruneBranches handler tests ─────────────────────────────────

#[tokio::test]
async fn prune_branches_requires_coordinator() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", None)
        .unwrap();
    let err = PruneBranchesHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap_err();
    assert!(err.to_string().contains("not enabled"));
}

#[tokio::test]
async fn prune_branches_missing_session_id() {
    let ctx = make_test_context();
    let err = PruneBranchesHandler
        .handle(Some(json!({})), &ctx)
        .await
        .unwrap_err();
    assert_eq!(err.code(), "INVALID_PARAMS");
}

// ── GetCommittedDiff handler tests ──────────────────────────────

#[tokio::test]
async fn committed_diff_requires_coordinator() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", None)
        .unwrap();
    let err = GetCommittedDiffHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap_err();
    assert!(err.to_string().contains("not enabled"));
}

#[tokio::test]
async fn committed_diff_missing_session_id() {
    let ctx = make_test_context();
    let err = GetCommittedDiffHandler
        .handle(Some(json!({})), &ctx)
        .await
        .unwrap_err();
    assert_eq!(err.code(), "INVALID_PARAMS");
}

// ── Parsing helper tests ────────────────────────────────────────

#[test]
fn parse_porcelain_modified() {
    let entries = parse_porcelain(" M src/main.rs\n");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].path, "src/main.rs");
    assert_eq!(entries[0].status, "modified");
}

#[test]
fn parse_porcelain_index_modified() {
    let entries = parse_porcelain("M  src/main.rs\n");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].status, "modified");
}

#[test]
fn parse_porcelain_added() {
    let entries = parse_porcelain("A  new.rs\n");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].path, "new.rs");
    assert_eq!(entries[0].status, "added");
}

#[test]
fn parse_porcelain_deleted() {
    let entries = parse_porcelain(" D old.rs\n");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].path, "old.rs");
    assert_eq!(entries[0].status, "deleted");
}

#[test]
fn parse_porcelain_untracked() {
    let entries = parse_porcelain("?? file.txt\n");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].path, "file.txt");
    assert_eq!(entries[0].status, "untracked");
}

#[test]
fn parse_porcelain_renamed() {
    let entries = parse_porcelain("R  old.rs -> new.rs\n");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].path, "new.rs");
    assert_eq!(entries[0].status, "renamed");
}

#[test]
fn parse_porcelain_mixed() {
    let input = " M src/main.rs\nA  new.rs\n D old.rs\n?? untracked.txt\n";
    let entries = parse_porcelain(input);
    assert_eq!(entries.len(), 4);
    assert_eq!(entries[0].status, "modified");
    assert_eq!(entries[1].status, "added");
    assert_eq!(entries[2].status, "deleted");
    assert_eq!(entries[3].status, "untracked");
}

#[test]
fn parse_porcelain_empty() {
    let entries = parse_porcelain("");
    assert!(entries.is_empty());
}

#[test]
fn parse_porcelain_quoted_path() {
    let entries = parse_porcelain("?? \"path with spaces/file.txt\"\n");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].path, "path with spaces/file.txt");
}

#[test]
fn parse_porcelain_unmerged() {
    let entries = parse_porcelain("UU conflicted.rs\n");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].status, "unmerged");
}

#[test]
fn parse_porcelain_both_added() {
    let entries = parse_porcelain("AA both_added.rs\n");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].status, "unmerged");
}

#[test]
fn parse_porcelain_added_then_modified() {
    // AM = added in index, modified in worktree → should be "added"
    let entries = parse_porcelain("AM new_file.rs\n");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].status, "added");
}

#[test]
fn parse_porcelain_modified_both() {
    // MM = modified in index AND worktree → should be "modified"
    let entries = parse_porcelain("MM src/lib.rs\n");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].status, "modified");
}

#[test]
fn split_diff_single_file() {
    let diff = "diff --git a/src/main.rs b/src/main.rs\nindex abc..def 100644\n--- a/src/main.rs\n+++ b/src/main.rs\n@@ -1,3 +1,4 @@\n context\n-old\n+new\n+added";
    let map = split_diff_by_file(diff);
    assert_eq!(map.len(), 1);
    assert!(map.contains_key("src/main.rs"));
    assert!(map["src/main.rs"].contains("@@ -1,3 +1,4 @@"));
}

#[test]
fn split_diff_multiple_files() {
    let diff = "diff --git a/a.rs b/a.rs\n--- a/a.rs\n+++ b/a.rs\n@@ -1 +1 @@\n-old\n+new\ndiff --git a/b.rs b/b.rs\n--- a/b.rs\n+++ b/b.rs\n@@ -1 +1 @@\n-x\n+y";
    let map = split_diff_by_file(diff);
    assert_eq!(map.len(), 2);
    assert!(map.contains_key("a.rs"));
    assert!(map.contains_key("b.rs"));
}

#[test]
fn split_diff_empty() {
    let map = split_diff_by_file("");
    assert!(map.is_empty());
}

#[test]
fn count_diff_stats_basic() {
    let chunk = "@@ -1,3 +1,4 @@\n context\n-old\n+new\n+added";
    let (a, d) = count_diff_stats(chunk);
    assert_eq!(a, 2);
    assert_eq!(d, 1);
}

#[test]
fn count_diff_stats_ignores_headers() {
    let chunk = "--- a/file.rs\n+++ b/file.rs\n@@ -1 +1 @@\n-old\n+new";
    let (a, d) = count_diff_stats(chunk);
    assert_eq!(a, 1);
    assert_eq!(d, 1);
}

#[test]
fn is_binary_diff_true() {
    assert!(is_binary_diff(
        "Binary files a/image.png and b/image.png differ"
    ));
}

#[test]
fn is_binary_diff_false() {
    assert!(!is_binary_diff("@@ -1 +1 @@\n-old\n+new"));
}

// ── GetDiff handler tests ───────────────────────────────────────

fn git_output(args: &[&str]) -> std::process::Output {
    let output = std::process::Command::new("git")
        .args(args)
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {:?} failed: {}",
        args,
        String::from_utf8_lossy(&output.stderr)
    );
    output
}

fn run_git(args: &[&str]) {
    drop(git_output(args));
}

/// Helper: create a temp git repo with initial commit, return (`TempDir`, `dir_str`).
fn make_git_repo() -> (tempfile::TempDir, String) {
    let tmp = tempfile::TempDir::new().unwrap();
    let dir = tmp.path().to_str().unwrap().to_string();
    for (args, _) in [
        (vec!["init", &dir], "init"),
        (vec!["-C", &dir, "config", "user.email", "t@t.com"], "email"),
        (vec!["-C", &dir, "config", "user.name", "T"], "name"),
    ] {
        run_git(&args);
    }
    std::fs::write(tmp.path().join("init.txt"), "init").unwrap();
    run_git(&["-C", &dir, "add", "-A"]);
    run_git(&["-C", &dir, "commit", "-m", "init"]);
    (tmp, dir)
}

#[tokio::test]
async fn get_diff_missing_session() {
    let ctx = make_test_context();
    let err = GetDiffHandler
        .handle(Some(json!({"sessionId": "nonexistent"})), &ctx)
        .await
        .unwrap_err();
    assert_eq!(err.code(), "SESSION_NOT_FOUND");
}

#[tokio::test]
async fn get_diff_not_git_repo() {
    let ctx = make_test_context();
    let tmp = tempfile::TempDir::new().unwrap();
    let dir = tmp.path().to_str().unwrap();
    let sid = ctx.session_manager.create_session("m", dir, None).unwrap();

    let result = GetDiffHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    assert_eq!(result["isGitRepo"], false);
}

#[tokio::test]
async fn get_diff_nonexistent_directory() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/nonexistent/path/xyz", None)
        .unwrap();

    let err = GetDiffHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap_err();
    assert!(err.to_string().contains("does not exist"));
}

#[tokio::test]
async fn get_diff_clean_repo() {
    let ctx = make_test_context();
    let (_tmp, dir) = make_git_repo();
    let sid = ctx.session_manager.create_session("m", &dir, None).unwrap();

    let result = GetDiffHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    assert_eq!(result["isGitRepo"], true);
    assert_eq!(result["files"].as_array().unwrap().len(), 0);
    assert_eq!(result["summary"]["totalFiles"], 0);
    // truncated should not be present for normal responses
    assert!(result.get("truncated").is_none());
}

#[tokio::test]
async fn get_diff_with_modified_file() {
    let ctx = make_test_context();
    let (tmp, dir) = make_git_repo();
    let sid = ctx.session_manager.create_session("m", &dir, None).unwrap();

    // Modify the committed file
    std::fs::write(tmp.path().join("init.txt"), "modified content").unwrap();

    let result = GetDiffHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    let files = result["files"].as_array().unwrap();
    assert_eq!(files.len(), 1);
    assert_eq!(files[0]["status"], "modified");
    assert!(files[0]["diff"].is_string());
    assert!(files[0]["additions"].as_u64().unwrap() >= 1);
    assert!(files[0]["deletions"].as_u64().unwrap() >= 1);
}

#[tokio::test]
async fn get_diff_with_new_file() {
    let ctx = make_test_context();
    let (tmp, dir) = make_git_repo();
    let sid = ctx.session_manager.create_session("m", &dir, None).unwrap();

    std::fs::write(tmp.path().join("new.txt"), "new content").unwrap();

    let result = GetDiffHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    let files = result["files"].as_array().unwrap();
    assert_eq!(files.len(), 1);
    assert_eq!(files[0]["status"], "untracked");
    // Untracked files have no diff from git diff HEAD
    assert!(files[0]["diff"].is_null());
}

#[tokio::test]
async fn get_diff_with_deleted_file() {
    let ctx = make_test_context();
    let (tmp, dir) = make_git_repo();
    let sid = ctx.session_manager.create_session("m", &dir, None).unwrap();

    std::fs::remove_file(tmp.path().join("init.txt")).unwrap();

    let result = GetDiffHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    let files = result["files"].as_array().unwrap();
    assert_eq!(files.len(), 1);
    assert_eq!(files[0]["status"], "deleted");
    assert!(files[0]["deletions"].as_u64().unwrap() >= 1);
}

#[tokio::test]
async fn get_diff_with_staged_and_unstaged() {
    let ctx = make_test_context();
    let (tmp, dir) = make_git_repo();
    let sid = ctx.session_manager.create_session("m", &dir, None).unwrap();

    // Stage a change
    std::fs::write(tmp.path().join("init.txt"), "staged").unwrap();
    run_git(&["-C", &dir, "add", "init.txt"]);

    // Make another unstaged change
    std::fs::write(tmp.path().join("init.txt"), "unstaged on top").unwrap();

    let result = GetDiffHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    let files = result["files"].as_array().unwrap();
    // init.txt should show as modified with both staged + unstaged changes in diff
    assert_eq!(files.len(), 1);
    assert_eq!(files[0]["status"], "modified");
    assert!(files[0]["diff"].is_string());
}

#[tokio::test]
async fn get_diff_empty_repo_no_commits() {
    let ctx = make_test_context();
    let tmp = tempfile::TempDir::new().unwrap();
    let dir = tmp.path().to_str().unwrap();
    run_git(&["init", dir]);
    std::fs::write(tmp.path().join("new.txt"), "content").unwrap();

    let sid = ctx.session_manager.create_session("m", dir, None).unwrap();

    let result = GetDiffHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    assert_eq!(result["isGitRepo"], true);
    // Should report the untracked file without crashing
    let files = result["files"].as_array().unwrap();
    assert!(!files.is_empty());
}

#[tokio::test]
async fn get_diff_branch_name() {
    let ctx = make_test_context();
    let (_tmp, dir) = make_git_repo();
    let sid = ctx.session_manager.create_session("m", &dir, None).unwrap();

    run_git(&["-C", &dir, "checkout", "-b", "feature/test"]);

    let result = GetDiffHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    assert_eq!(result["branch"], "feature/test");
}

#[tokio::test]
async fn get_diff_detached_head() {
    let ctx = make_test_context();
    let (_tmp, dir) = make_git_repo();
    let sid = ctx.session_manager.create_session("m", &dir, None).unwrap();

    // Get HEAD hash and checkout detached
    let hash = git_output(&["-C", &dir, "rev-parse", "HEAD"]);
    let hash = String::from_utf8_lossy(&hash.stdout).trim().to_string();
    run_git(&["-C", &dir, "checkout", &hash]);

    let result = GetDiffHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    assert!(result["branch"].is_null());
}

#[tokio::test]
async fn get_diff_falls_back_to_working_directory() {
    let ctx = make_test_context();
    let (_tmp, dir) = make_git_repo();
    // No worktree — should fall back to session working_directory
    let sid = ctx.session_manager.create_session("m", &dir, None).unwrap();

    let result = GetDiffHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    assert_eq!(result["isGitRepo"], true);
}

#[tokio::test]
async fn get_diff_multiple_files() {
    let ctx = make_test_context();
    let (tmp, dir) = make_git_repo();

    // Create additional committed files
    std::fs::write(tmp.path().join("a.txt"), "a").unwrap();
    std::fs::write(tmp.path().join("b.txt"), "b").unwrap();
    std::fs::write(tmp.path().join("c.txt"), "c").unwrap();
    run_git(&["-C", &dir, "add", "-A"]);
    run_git(&["-C", &dir, "commit", "-m", "add files"]);

    let sid = ctx.session_manager.create_session("m", &dir, None).unwrap();

    // Modify 2 files, delete 1, add 1 new, leave 1 unchanged
    std::fs::write(tmp.path().join("a.txt"), "modified-a").unwrap();
    std::fs::write(tmp.path().join("b.txt"), "modified-b").unwrap();
    std::fs::remove_file(tmp.path().join("c.txt")).unwrap();
    std::fs::write(tmp.path().join("new.txt"), "new").unwrap();

    let result = GetDiffHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    let files = result["files"].as_array().unwrap();
    // 2 modified + 1 deleted + 1 untracked = 4
    assert_eq!(files.len(), 4);
    assert_eq!(result["summary"]["totalFiles"], 4);
}

#[tokio::test]
async fn get_diff_binary_file() {
    let ctx = make_test_context();
    let (tmp, dir) = make_git_repo();
    let sid = ctx.session_manager.create_session("m", &dir, None).unwrap();

    // Create a binary file with NUL bytes (git detects binary via NUL), commit it, then modify
    let bin_data: Vec<u8> = vec![0x89, 0x50, 0x4E, 0x47, 0x00, 0x00, 0x1A, 0x0A];
    std::fs::write(tmp.path().join("image.png"), &bin_data).unwrap();
    run_git(&["-C", &dir, "add", "-A"]);
    run_git(&["-C", &dir, "commit", "-m", "add binary"]);

    // Modify the binary
    let mut modified = bin_data.clone();
    modified.extend_from_slice(&[0xFF, 0x00]);
    std::fs::write(tmp.path().join("image.png"), &modified).unwrap();

    let result = GetDiffHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    let files = result["files"].as_array().unwrap();
    let png_file = files.iter().find(|f| f["path"] == "image.png");
    assert!(png_file.is_some());
    let f = png_file.unwrap();
    // Binary files should have null diff and 0 stats
    assert!(f["diff"].is_null());
    assert_eq!(f["additions"], 0);
    assert_eq!(f["deletions"], 0);
}
