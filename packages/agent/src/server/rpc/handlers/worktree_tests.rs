use super::*;
use crate::server::rpc::handlers::test_helpers::make_test_context;
use serde_json::json;

// ── Handler tests (coordinator-required) ────────────────────────

#[tokio::test]
async fn get_status_requires_coordinator() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("model", "/tmp", Some("test"), None)
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
        .create_session("m", "/tmp", None, None)
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
        .create_session("m", "/tmp", None, None)
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
        .create_session("m", "/tmp", None, None)
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

// ── IsGitRepo handler tests ─────────────────────────────────────

#[tokio::test]
async fn is_git_repo_requires_coordinator() {
    let ctx = make_test_context();
    let err = IsGitRepoHandler
        .handle(Some(json!({"path": "/tmp"})), &ctx)
        .await
        .unwrap_err();
    assert!(err.to_string().contains("not enabled"));
}

#[tokio::test]
async fn is_git_repo_missing_path() {
    let ctx = make_test_context();
    let err = IsGitRepoHandler
        .handle(Some(json!({})), &ctx)
        .await
        .unwrap_err();
    assert_eq!(err.code(), "INVALID_PARAMS");
}

// ── ListSessionBranches handler tests ───────────────────────────

#[tokio::test]
async fn list_session_branches_requires_coordinator() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/tmp", None, None)
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
        .create_session("m", "/tmp", None, None)
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
        .create_session("m", "/tmp", None, None)
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
        .create_session("m", "/tmp", None, None)
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

// ── Staging area tests ──────────────────────────────────────────

#[test]
fn parse_porcelain_staging_area_staged_only() {
    // X=M, Y=' ' → staged
    let entries = parse_porcelain("M  foo.rs\n");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].staging_area, "staged");
    assert_eq!(entries[0].status, "modified");
}

#[test]
fn parse_porcelain_staging_area_unstaged_only() {
    // X=' ', Y='M' → unstaged
    let entries = parse_porcelain(" M foo.rs\n");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].staging_area, "unstaged");
    assert_eq!(entries[0].status, "modified");
}

#[test]
fn parse_porcelain_staging_area_both() {
    // X='M', Y='M' → both
    let entries = parse_porcelain("MM foo.rs\n");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].staging_area, "both");
    assert_eq!(entries[0].status, "modified");
}

#[test]
fn parse_porcelain_staging_area_untracked() {
    let entries = parse_porcelain("?? newfile.rs\n");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].staging_area, "unstaged");
    assert_eq!(entries[0].status, "untracked");
}

#[test]
fn parse_porcelain_staging_area_added_staged() {
    // X='A', Y=' ' → staged
    let entries = parse_porcelain("A  newfile.rs\n");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].staging_area, "staged");
    assert_eq!(entries[0].status, "added");
}

#[test]
fn parse_porcelain_staging_area_added_unstaged() {
    // X=' ', Y='A' → unstaged
    let entries = parse_porcelain(" A newfile.rs\n");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].staging_area, "unstaged");
    assert_eq!(entries[0].status, "added");
}

#[test]
fn parse_porcelain_staging_area_deleted_staged() {
    // X='D', Y=' ' → staged
    let entries = parse_porcelain("D  removed.rs\n");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].staging_area, "staged");
    assert_eq!(entries[0].status, "deleted");
}

#[test]
fn parse_porcelain_staging_area_deleted_unstaged() {
    // X=' ', Y='D' → unstaged
    let entries = parse_porcelain(" D removed.rs\n");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].staging_area, "unstaged");
    assert_eq!(entries[0].status, "deleted");
}

#[test]
fn parse_porcelain_staging_area_renamed_staged() {
    // X='R', Y=' ' → staged
    let entries = parse_porcelain("R  old.rs -> new.rs\n");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].staging_area, "staged");
    assert_eq!(entries[0].status, "renamed");
    assert_eq!(entries[0].path, "new.rs");
}

#[test]
fn parse_porcelain_staging_area_copied_staged() {
    // X='C', Y=' ' → staged
    let entries = parse_porcelain("C  src.rs -> dest.rs\n");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].staging_area, "staged");
    assert_eq!(entries[0].status, "copied");
}

#[test]
fn parse_porcelain_staging_area_unmerged_uu() {
    let entries = parse_porcelain("UU conflict.rs\n");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].staging_area, "unstaged");
    assert_eq!(entries[0].status, "unmerged");
}

#[test]
fn parse_porcelain_staging_area_unmerged_aa() {
    let entries = parse_porcelain("AA conflict.rs\n");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].staging_area, "unstaged");
    assert_eq!(entries[0].status, "unmerged");
}

#[test]
fn parse_porcelain_staging_area_unmerged_dd() {
    let entries = parse_porcelain("DD gone.rs\n");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].staging_area, "unstaged");
    assert_eq!(entries[0].status, "unmerged");
}

#[test]
fn parse_porcelain_staging_area_added_then_modified() {
    // AM = added in index, modified in worktree → both
    let entries = parse_porcelain("AM new_file.rs\n");
    assert_eq!(entries.len(), 1);
    assert_eq!(entries[0].staging_area, "both");
    assert_eq!(entries[0].status, "added");
}

#[test]
fn parse_porcelain_staging_area_mixed() {
    let input = "M  staged.rs\n M unstaged.rs\nMM both.rs\n?? untracked.rs\n";
    let entries = parse_porcelain(input);
    assert_eq!(entries.len(), 4);
    assert_eq!(entries[0].staging_area, "staged");
    assert_eq!(entries[1].staging_area, "unstaged");
    assert_eq!(entries[2].staging_area, "both");
    assert_eq!(entries[3].staging_area, "unstaged");
}

#[test]
fn parse_porcelain_staging_area_ignored_skipped() {
    let entries = parse_porcelain("!! ignored.rs\n");
    assert!(entries.is_empty());
}

#[test]
fn parse_porcelain_staging_area_empty() {
    let entries = parse_porcelain("");
    assert!(entries.is_empty());
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
    let sid = ctx.session_manager.create_session("m", dir, None, None).unwrap();

    let result = GetDiffHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    assert_eq!(result["isGitRepo"], false);
}

/// Regression: a session whose working directory does not exist on disk
/// (e.g. freshly created on a machine where the cwd hasn't been provisioned
/// yet) must not surface as INTERNAL_ERROR to the iOS client — iOS opens
/// the agent-control sheet with a parallel `worktree.getDiff` and a failure
/// there blocks the entire sheet. Treat it the same as "not a git repo".
#[tokio::test]
async fn get_diff_nonexistent_directory_is_not_internal_error() {
    let ctx = make_test_context();
    let sid = ctx
        .session_manager
        .create_session("m", "/nonexistent/path/xyz", None, None)
        .unwrap();

    let result = GetDiffHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    assert_eq!(result["isGitRepo"], false);
    assert!(
        result.get("branch").is_none(),
        "nonexistent dir has no branch to report"
    );
    assert!(
        result.get("files").is_none(),
        "nonexistent dir has no files to report"
    );
}

#[tokio::test]
async fn get_diff_clean_repo() {
    let ctx = make_test_context();
    let (_tmp, dir) = make_git_repo();
    let sid = ctx.session_manager.create_session("m", &dir, None, None).unwrap();

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
    let sid = ctx.session_manager.create_session("m", &dir, None, None).unwrap();

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
    let sid = ctx.session_manager.create_session("m", &dir, None, None).unwrap();

    std::fs::write(tmp.path().join("new.txt"), "new content").unwrap();

    let result = GetDiffHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    let files = result["files"].as_array().unwrap();
    assert_eq!(files.len(), 1);
    assert_eq!(files[0]["status"], "untracked");
    // Untracked files get a synthesized diff with their content
    let diff = files[0]["diff"].as_str().unwrap();
    assert!(diff.contains("+new content"));
    assert_eq!(files[0]["additions"], 1);
}

#[tokio::test]
async fn get_diff_with_deleted_file() {
    let ctx = make_test_context();
    let (tmp, dir) = make_git_repo();
    let sid = ctx.session_manager.create_session("m", &dir, None, None).unwrap();

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
    let sid = ctx.session_manager.create_session("m", &dir, None, None).unwrap();

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
    // "both" files emit TWO entries: one staged, one unstaged
    assert_eq!(files.len(), 2);
    let staged = files.iter().find(|f| f["stagingArea"] == "staged").unwrap();
    let unstaged = files.iter().find(|f| f["stagingArea"] == "unstaged").unwrap();
    assert_eq!(staged["status"], "modified");
    assert_eq!(unstaged["status"], "modified");
    assert!(staged["diff"].is_string());
    assert!(unstaged["diff"].is_string());
    // Summary should count 1 unique file
    assert_eq!(result["summary"]["totalFiles"], 1);
}

#[tokio::test]
async fn get_diff_empty_repo_no_commits() {
    let ctx = make_test_context();
    let tmp = tempfile::TempDir::new().unwrap();
    let dir = tmp.path().to_str().unwrap();
    run_git(&["init", dir]);
    std::fs::write(tmp.path().join("new.txt"), "content").unwrap();

    let sid = ctx.session_manager.create_session("m", dir, None, None).unwrap();

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
    let sid = ctx.session_manager.create_session("m", &dir, None, None).unwrap();

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
    let sid = ctx.session_manager.create_session("m", &dir, None, None).unwrap();

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
    let sid = ctx.session_manager.create_session("m", &dir, None, None).unwrap();

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

    let sid = ctx.session_manager.create_session("m", &dir, None, None).unwrap();

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
    let sid = ctx.session_manager.create_session("m", &dir, None, None).unwrap();

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

// ── GetDiff staging area integration tests ──────────────────────

#[tokio::test]
async fn get_diff_staging_area_staged_only() {
    let ctx = make_test_context();
    let (tmp, dir) = make_git_repo();
    let sid = ctx.session_manager.create_session("m", &dir, None, None).unwrap();

    std::fs::write(tmp.path().join("init.txt"), "staged change").unwrap();
    run_git(&["-C", &dir, "add", "init.txt"]);

    let result = GetDiffHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    let files = result["files"].as_array().unwrap();
    assert_eq!(files.len(), 1);
    assert_eq!(files[0]["stagingArea"], "staged");
    assert_eq!(files[0]["status"], "modified");
    assert!(files[0]["diff"].is_string());
}

#[tokio::test]
async fn get_diff_staging_area_unstaged_only() {
    let ctx = make_test_context();
    let (tmp, dir) = make_git_repo();
    let sid = ctx.session_manager.create_session("m", &dir, None, None).unwrap();

    std::fs::write(tmp.path().join("init.txt"), "unstaged change").unwrap();

    let result = GetDiffHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    let files = result["files"].as_array().unwrap();
    assert_eq!(files.len(), 1);
    assert_eq!(files[0]["stagingArea"], "unstaged");
}

#[tokio::test]
async fn get_diff_staging_area_untracked() {
    let ctx = make_test_context();
    let (tmp, dir) = make_git_repo();
    let sid = ctx.session_manager.create_session("m", &dir, None, None).unwrap();

    std::fs::write(tmp.path().join("brand_new.txt"), "new").unwrap();

    let result = GetDiffHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    let files = result["files"].as_array().unwrap();
    assert_eq!(files.len(), 1);
    assert_eq!(files[0]["stagingArea"], "unstaged");
    assert_eq!(files[0]["status"], "untracked");
}

#[tokio::test]
async fn get_diff_staging_area_deleted_staged() {
    let ctx = make_test_context();
    let (tmp, dir) = make_git_repo();
    let sid = ctx.session_manager.create_session("m", &dir, None, None).unwrap();

    std::fs::remove_file(tmp.path().join("init.txt")).unwrap();
    run_git(&["-C", &dir, "add", "init.txt"]);

    let result = GetDiffHandler
        .handle(Some(json!({"sessionId": sid})), &ctx)
        .await
        .unwrap();
    let files = result["files"].as_array().unwrap();
    assert_eq!(files.len(), 1);
    assert_eq!(files[0]["stagingArea"], "staged");
    assert_eq!(files[0]["status"], "deleted");
}

// ── StageFiles handler tests ────────────────────────────────────

#[tokio::test]
async fn stage_files_success() {
    let ctx = make_test_context();
    let (tmp, dir) = make_git_repo();
    let sid = ctx.session_manager.create_session("m", &dir, None, None).unwrap();

    std::fs::write(tmp.path().join("init.txt"), "modified").unwrap();

    let result = StageFilesHandler
        .handle(
            Some(json!({"sessionId": sid, "paths": ["init.txt"]})),
            &ctx,
        )
        .await
        .unwrap();
    assert_eq!(result["success"], true);

    // Verify staged via git status
    let status = git_output(&["-C", &dir, "status", "--porcelain=v1"]);
    let status_str = String::from_utf8_lossy(&status.stdout);
    assert!(status_str.contains("M  init.txt"), "Expected staged: {status_str}");
}

#[tokio::test]
async fn stage_files_untracked() {
    let ctx = make_test_context();
    let (tmp, dir) = make_git_repo();
    let sid = ctx.session_manager.create_session("m", &dir, None, None).unwrap();

    std::fs::write(tmp.path().join("new.txt"), "new content").unwrap();

    let result = StageFilesHandler
        .handle(
            Some(json!({"sessionId": sid, "paths": ["new.txt"]})),
            &ctx,
        )
        .await
        .unwrap();
    assert_eq!(result["success"], true);

    let status = git_output(&["-C", &dir, "status", "--porcelain=v1"]);
    let status_str = String::from_utf8_lossy(&status.stdout);
    assert!(status_str.contains("A  new.txt"), "Expected staged add: {status_str}");
}

#[tokio::test]
async fn stage_files_missing_params() {
    let ctx = make_test_context();
    let err = StageFilesHandler
        .handle(Some(json!({"sessionId": "s1"})), &ctx)
        .await
        .unwrap_err();
    assert_eq!(err.code(), "INVALID_PARAMS");
}

#[tokio::test]
async fn stage_files_empty_paths() {
    let ctx = make_test_context();
    let err = StageFilesHandler
        .handle(Some(json!({"sessionId": "s1", "paths": []})), &ctx)
        .await
        .unwrap_err();
    assert_eq!(err.code(), "INVALID_PARAMS");
}

// ── UnstageFiles handler tests ──────────────────────────────────

#[tokio::test]
async fn unstage_files_success() {
    let ctx = make_test_context();
    let (tmp, dir) = make_git_repo();
    let sid = ctx.session_manager.create_session("m", &dir, None, None).unwrap();

    std::fs::write(tmp.path().join("init.txt"), "modified").unwrap();
    run_git(&["-C", &dir, "add", "init.txt"]);

    let result = UnstageFilesHandler
        .handle(
            Some(json!({"sessionId": sid, "paths": ["init.txt"]})),
            &ctx,
        )
        .await
        .unwrap();
    assert_eq!(result["success"], true);

    let status = git_output(&["-C", &dir, "status", "--porcelain=v1"]);
    let status_str = String::from_utf8_lossy(&status.stdout);
    assert!(status_str.contains(" M init.txt"), "Expected unstaged: {status_str}");
}

#[tokio::test]
async fn unstage_files_no_commits() {
    let ctx = make_test_context();
    let tmp = tempfile::TempDir::new().unwrap();
    let dir = tmp.path().to_str().unwrap().to_string();
    run_git(&["init", &dir]);
    run_git(&["-C", &dir, "config", "user.email", "t@t.com"]);
    run_git(&["-C", &dir, "config", "user.name", "T"]);

    std::fs::write(tmp.path().join("new.txt"), "content").unwrap();
    run_git(&["-C", &dir, "add", "new.txt"]);

    let sid = ctx.session_manager.create_session("m", &dir, None, None).unwrap();

    let result = UnstageFilesHandler
        .handle(
            Some(json!({"sessionId": sid, "paths": ["new.txt"]})),
            &ctx,
        )
        .await
        .unwrap();
    assert_eq!(result["success"], true);

    // File should still exist but be untracked
    assert!(tmp.path().join("new.txt").exists());
    let status = git_output(&["-C", &dir, "status", "--porcelain=v1"]);
    let status_str = String::from_utf8_lossy(&status.stdout);
    assert!(status_str.contains("?? new.txt"), "Expected untracked: {status_str}");
}

#[tokio::test]
async fn unstage_files_missing_params() {
    let ctx = make_test_context();
    let err = UnstageFilesHandler
        .handle(Some(json!({})), &ctx)
        .await
        .unwrap_err();
    assert_eq!(err.code(), "INVALID_PARAMS");
}

// ── DiscardFiles handler tests ──────────────────────────────────

#[tokio::test]
async fn discard_files_tracked_modified() {
    let ctx = make_test_context();
    let (tmp, dir) = make_git_repo();
    let sid = ctx.session_manager.create_session("m", &dir, None, None).unwrap();

    std::fs::write(tmp.path().join("init.txt"), "modified").unwrap();

    let result = DiscardFilesHandler
        .handle(
            Some(json!({"sessionId": sid, "paths": ["init.txt"]})),
            &ctx,
        )
        .await
        .unwrap();
    assert_eq!(result["success"], true);

    // File should be restored to committed content
    let content = std::fs::read_to_string(tmp.path().join("init.txt")).unwrap();
    assert_eq!(content, "init");
}

#[tokio::test]
async fn discard_files_untracked() {
    let ctx = make_test_context();
    let (tmp, dir) = make_git_repo();
    let sid = ctx.session_manager.create_session("m", &dir, None, None).unwrap();

    std::fs::write(tmp.path().join("new.txt"), "content").unwrap();
    assert!(tmp.path().join("new.txt").exists());

    let result = DiscardFilesHandler
        .handle(
            Some(json!({"sessionId": sid, "paths": ["new.txt"]})),
            &ctx,
        )
        .await
        .unwrap();
    assert_eq!(result["success"], true);
    assert!(!tmp.path().join("new.txt").exists());
}

#[tokio::test]
async fn discard_files_path_traversal_blocked() {
    let ctx = make_test_context();
    let (_tmp, dir) = make_git_repo();
    let sid = ctx.session_manager.create_session("m", &dir, None, None).unwrap();

    let err = DiscardFilesHandler
        .handle(
            Some(json!({"sessionId": sid, "paths": ["../../../etc/passwd"]})),
            &ctx,
        )
        .await
        .unwrap_err();
    assert!(err.to_string().contains("escapes repository root") || err.to_string().contains("not found"),
        "Expected path validation error: {}", err);
}

#[tokio::test]
async fn discard_files_absolute_path_blocked() {
    let ctx = make_test_context();
    let (_tmp, dir) = make_git_repo();
    let sid = ctx.session_manager.create_session("m", &dir, None, None).unwrap();

    let err = DiscardFilesHandler
        .handle(
            Some(json!({"sessionId": sid, "paths": ["/etc/passwd"]})),
            &ctx,
        )
        .await
        .unwrap_err();
    assert_eq!(err.code(), "INVALID_PARAMS");
}

#[tokio::test]
async fn discard_files_missing_params() {
    let ctx = make_test_context();
    let err = DiscardFilesHandler
        .handle(Some(json!({"sessionId": "s1"})), &ctx)
        .await
        .unwrap_err();
    assert_eq!(err.code(), "INVALID_PARAMS");
}

#[tokio::test]
async fn discard_files_deleted_file() {
    let ctx = make_test_context();
    let (tmp, dir) = make_git_repo();
    let sid = ctx.session_manager.create_session("m", &dir, None, None).unwrap();

    std::fs::remove_file(tmp.path().join("init.txt")).unwrap();
    assert!(!tmp.path().join("init.txt").exists());

    let result = DiscardFilesHandler
        .handle(
            Some(json!({"sessionId": sid, "paths": ["init.txt"]})),
            &ctx,
        )
        .await
        .unwrap();
    assert_eq!(result["success"], true);
    // File should be restored
    assert!(tmp.path().join("init.txt").exists());
    let content = std::fs::read_to_string(tmp.path().join("init.txt")).unwrap();
    assert_eq!(content, "init");
}

// ── CommitHandler flag parsing (integration tests) ──────────────────
//
// These exercise the real `CommitHandler` end-to-end against a real
// `WorktreeCoordinator` and a real git repo. They lock in wire-level
// defaults that old iOS clients depend on: `stageAll` must default to
// `true` so clients that send only `{sessionId, message}` continue to
// see the pre-flag "commit everything" behavior.

async fn commit_test_context_async() -> (
    tempfile::TempDir,
    crate::server::rpc::context::RpcContext,
    std::sync::Arc<crate::worktree::WorktreeCoordinator>,
    String,
    std::path::PathBuf,
) {
    use crate::events::EventStore;
    use crate::runtime::orchestrator::orchestrator::Orchestrator;
    use crate::runtime::orchestrator::session_manager::SessionManager;
    use crate::server::rpc::context::RpcContext;
    use crate::server::rpc::session_context::ContextArtifactsService;
    use crate::skills::registry::SkillRegistry;
    use crate::worktree::types::AcquireResult;
    use crate::worktree::{WorktreeConfig, WorktreeCoordinator};
    use std::sync::Arc;

    let tmp = tempfile::TempDir::new().unwrap();
    let dir = tmp.path().to_str().unwrap().to_string();
    run_git(&["init", &dir]);
    run_git(&["-C", &dir, "config", "user.email", "t@t.com"]);
    run_git(&["-C", &dir, "config", "user.name", "T"]);
    std::fs::write(tmp.path().join("seed.txt"), "seed").unwrap();
    run_git(&["-C", &dir, "add", "-A"]);
    run_git(&["-C", &dir, "commit", "-m", "init"]);

    let pool = crate::events::new_in_memory(&crate::events::ConnectionConfig::default()).unwrap();
    {
        let conn = pool.get().unwrap();
        let _ = crate::events::run_migrations(&conn).unwrap();
    }
    let store = Arc::new(EventStore::new(pool));
    let mgr = Arc::new(SessionManager::new(store.clone()));
    let orch = Arc::new(Orchestrator::new(mgr.clone()));
    let coord = Arc::new(WorktreeCoordinator::new(WorktreeConfig::default(), store.clone()));

    let sid = mgr.create_session("m", &dir, Some("test"), None).unwrap();

    let wt_path = match coord.maybe_acquire(&sid, tmp.path()).await.unwrap() {
        AcquireResult::Acquired(info) => info.worktree_path,
        other => panic!("expected Acquired, got {other:?}"),
    };

    let ctx = RpcContext {
        orchestrator: orch,
        session_manager: mgr,
        event_store: store,
        skill_registry: Arc::new(parking_lot::RwLock::new(SkillRegistry::new())),
        memory_registry: Arc::new(parking_lot::Mutex::new(
            crate::runtime::memory::MemoryRegistry::new(),
        )),
        settings_path: std::path::PathBuf::from("/tmp/tron-test-settings.json"),
        agent_deps: None,
        server_start_time: std::time::Instant::now(),
        transcription_engine: Arc::new(std::sync::OnceLock::new()),
        subagent_manager: None,
        health_tracker: Arc::new(crate::llm::ProviderHealthTracker::new()),
        shutdown_coordinator: None,
        origin: "localhost:9847".to_string(),
        cron_scheduler: None,
        worktree_coordinator: Some(coord.clone()),
        device_request_broker: None,
        context_artifacts: Arc::new(ContextArtifactsService::new()),
        auth_path: std::path::PathBuf::from("/tmp/tron-test-auth.json"),
        broadcast_manager: None,
        oauth_flows: Arc::new(tokio::sync::Mutex::new(std::collections::HashMap::new())),
        mcp_router: None,
        display_stream_registry: None,
        process_manager: None,
        job_manager: None,
        output_buffer_registry: None,
        hook_abort_tracker: Arc::new(
            crate::runtime::hooks::abort_tracker::HookAbortTracker::new(),
        ),
        ws_port: 9847,
        onboarded_marker_path: std::path::PathBuf::from("/tmp/tron-test-onboarded.marker"),
    };

    (tmp, ctx, coord, sid, wt_path)
}

#[tokio::test]
async fn commit_handler_rejects_missing_stage_all() {
    // I7: `stageAll` is contractually required on the wire. A client that
    // sends only `{sessionId, message}` is bugged and must surface an
    // InvalidParams error — no silent "true by default" fallback, no
    // accidental `git add -A` on an untagged request.
    let (_tmp, ctx, _coord, sid, wt) = commit_test_context_async().await;

    std::fs::write(wt.join("new.txt"), "new").unwrap();
    let err = CommitHandler
        .handle(
            Some(json!({"sessionId": sid, "message": "legacy"})),
            &ctx,
        )
        .await
        .expect_err("missing stageAll must be rejected, not defaulted");

    assert_eq!(err.code(), "INVALID_PARAMS");
    assert!(
        err.to_string().contains("stageAll"),
        "error should name the missing parameter, got {err:?}"
    );
}

#[tokio::test]
async fn commit_handler_rejects_non_bool_stage_all() {
    // I7 regression guard: non-bool `stageAll` (string, number, null) must
    // be rejected up front rather than silently coerced. The old handler
    // treated anything non-bool as "absent" and defaulted to true.
    let (_tmp, ctx, _coord, sid, _wt) = commit_test_context_async().await;

    for bogus in [json!("yes"), json!(1), json!(null), json!([true])] {
        let err = CommitHandler
            .handle(
                Some(json!({
                    "sessionId": sid,
                    "message": "bogus",
                    "stageAll": bogus,
                })),
                &ctx,
            )
            .await
            .expect_err("non-bool stageAll must be rejected");
        assert_eq!(err.code(), "INVALID_PARAMS", "bogus value {bogus:?}");
    }
}

#[tokio::test]
async fn commit_handler_stage_all_false_only_commits_index() {
    let (_tmp, ctx, _coord, sid, wt) = commit_test_context_async().await;

    std::fs::write(wt.join("indexed.txt"), "a").unwrap();
    std::fs::write(wt.join("untracked.txt"), "b").unwrap();
    run_git(&["-C", wt.to_str().unwrap(), "add", "indexed.txt"]);

    let result = CommitHandler
        .handle(
            Some(json!({
                "sessionId": sid,
                "message": "partial",
                "stageAll": false,
            })),
            &ctx,
        )
        .await
        .unwrap();

    let files: Vec<String> = result["filesChanged"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .collect();
    assert!(files.contains(&"indexed.txt".to_string()));
    assert!(
        !files.contains(&"untracked.txt".to_string()),
        "stageAll=false must not include untracked files: {files:?}"
    );
}

#[tokio::test]
async fn commit_handler_amend_rewrites_head() {
    let (_tmp, ctx, _coord, sid, wt) = commit_test_context_async().await;

    // Seed a first commit via the handler — stageAll:true so the new file
    // is picked up from the worktree.
    std::fs::write(wt.join("v1.txt"), "one").unwrap();
    let first = CommitHandler
        .handle(
            Some(json!({
                "sessionId": sid,
                "message": "first",
                "stageAll": true,
            })),
            &ctx,
        )
        .await
        .unwrap();
    let first_hash = first["commitHash"].as_str().unwrap().to_string();

    // Amend: no new changes, new message — SHA must change.
    let amended = CommitHandler
        .handle(
            Some(json!({
                "sessionId": sid,
                "message": "first (amended)",
                "amend": true,
                "stageAll": true,
            })),
            &ctx,
        )
        .await
        .unwrap();
    let amended_hash = amended["commitHash"].as_str().unwrap().to_string();

    assert_ne!(
        first_hash, amended_hash,
        "amend must produce a new SHA"
    );

    // Confirm only one commit since init (merge base).
    let wt_str = wt.to_str().unwrap();
    let out = git_output(&["-C", wt_str, "rev-list", "--count", "HEAD"]);
    let out_str = String::from_utf8_lossy(&out.stdout);
    let count: u32 = out_str.trim().parse().unwrap();
    // init commit + amended = 2; if amend duplicated a commit it would be 3.
    assert_eq!(count, 2, "amend must not add a new parent commit");
}

#[tokio::test]
async fn commit_handler_signoff_adds_trailer() {
    let (_tmp, ctx, _coord, sid, wt) = commit_test_context_async().await;

    std::fs::write(wt.join("signed.txt"), "x").unwrap();
    let _ = CommitHandler
        .handle(
            Some(json!({
                "sessionId": sid,
                "message": "body",
                "signoff": true,
                "stageAll": true,
            })),
            &ctx,
        )
        .await
        .unwrap();

    let wt_str = wt.to_str().unwrap();
    let out = git_output(&["-C", wt_str, "log", "-1", "--format=%B"]);
    let body = String::from_utf8_lossy(&out.stdout);
    assert!(
        body.lines().any(|line| line.starts_with("Signed-off-by:")),
        "expected Signed-off-by trailer in commit body, got:\n{body}"
    );
}

#[tokio::test]
async fn commit_handler_soft_bool_flags_are_lenient() {
    // `amend` and `signoff` remain opt-in feature flags parsed via
    // `opt_bool` — non-bool values (e.g. a stringly typed "yes" from a
    // misbehaving client) fall back to their defaults of false rather
    // than erroring out. Only `stageAll` is strict (see
    // commit_handler_rejects_non_bool_stage_all).
    let (_tmp, ctx, _coord, sid, wt) = commit_test_context_async().await;

    std::fs::write(wt.join("z.txt"), "z").unwrap();
    let result = CommitHandler
        .handle(
            Some(json!({
                "sessionId": sid,
                "message": "soft flags",
                "amend": "yes",
                "signoff": 1,
                "stageAll": true,
            })),
            &ctx,
        )
        .await
        .unwrap();
    assert!(result["commitHash"].is_string(), "expected a real commit hash, got {result:?}");
}

#[tokio::test]
async fn commit_handler_nothing_to_commit_returns_null_hash() {
    // Clean tree, stageAll:true → coordinator returns None → handler
    // responds with null commitHash. iOS surfaces this as a friendly
    // "nothing to commit" banner. Failures throw typed RPC errors instead.
    let (_tmp, ctx, _coord, sid, _wt) = commit_test_context_async().await;

    let result = CommitHandler
        .handle(
            Some(json!({
                "sessionId": sid,
                "message": "empty",
                "stageAll": true,
            })),
            &ctx,
        )
        .await
        .unwrap();
    assert!(result["commitHash"].is_null());
    assert_eq!(result["message"], "nothing to commit");
}
