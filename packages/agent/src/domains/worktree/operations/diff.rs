//! Worktree workflow operations.
use super::resolve_diff_dir;
use super::{count_diff_stats, instrument, split_diff_by_file};
use crate::domains::worktree::Deps;
use crate::shared::server::errors::CapabilityError;
use crate::shared::server::params::require_string_param;
use serde_json::Value;

// ── GetDiff ─────────────────────────────────────────────────────────

const MAX_DIFF_BYTES: usize = 1_024 * 1_024; // 1 MB

/// Get unified diff of all uncommitted changes for a session's working directory.
///
/// Works for any session — uses the worktree path if one is active, otherwise
/// the session's original working directory. Does not require a coordinator.
pub struct GetDiffOperation;
pub struct GetDiffSummaryOperation;

#[derive(Debug, Clone, PartialEq, Eq)]
struct DiffSummaryCounts {
    total_files: usize,
    total_additions: usize,
    total_deletions: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct WorkingTreeDiffSummary {
    is_git_repo: bool,
    branch: Option<String>,
    summary: Option<DiffSummaryCounts>,
}

impl GetDiffOperation {
    #[instrument(skip(self, deps), fields(method = "worktree::get_diff"))]
    pub(crate) async fn run(
        &self,
        params: Option<Value>,
        deps: &Deps,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let dir = resolve_diff_dir(deps, &session_id)?;

        // A session whose working directory is missing (never existed, or
        // deleted between creation and this call) has no diff to show. Return
        // the same lenient shape as "not a git repo" so the iOS agent-control
        // sheet renders an empty state instead of propagating INTERNAL_ERROR.
        if !std::path::Path::new(&dir).is_dir() {
            return Ok(serde_json::json!({ "isGitRepo": false }));
        }

        // Check if this is a git repo
        let check = tokio::process::Command::new("git")
            .args(["-C", &dir, "rev-parse", "--is-inside-work-tree"])
            .output()
            .await
            .map_err(|e| CapabilityError::Internal {
                message: format!("Failed to run git: {e}"),
            })?;

        if !check.status.success() {
            return Ok(serde_json::json!({ "isGitRepo": false }));
        }

        // Run branch, status, and both diffs concurrently.
        // We split into staged (--cached) and unstaged (worktree vs index) diffs
        // so the iOS client can show them in separate containers.
        let (
            branch_out,
            status_out,
            staged_diff_out,
            unstaged_diff_out,
            staged_numstat_out,
            unstaged_numstat_out,
        ) = tokio::join!(
            tokio::process::Command::new("git")
                .args(["-C", &dir, "branch", "--show-current"])
                .output(),
            tokio::process::Command::new("git")
                .args(["-C", &dir, "status", "--porcelain=v1"])
                .output(),
            // Staged diff: index vs HEAD (or all staged if no commits)
            tokio::process::Command::new("git")
                .args(["-C", &dir, "diff", "--cached"])
                .output(),
            // Unstaged diff: worktree vs index
            tokio::process::Command::new("git")
                .args(["-C", &dir, "diff"])
                .output(),
            tokio::process::Command::new("git")
                .args(["-C", &dir, "diff", "--cached", "--numstat"])
                .output(),
            tokio::process::Command::new("git")
                .args(["-C", &dir, "diff", "--numstat"])
                .output()
        );

        let branch = branch_out.ok().and_then(|o| {
            let b = String::from_utf8_lossy(&o.stdout).trim().to_string();
            if b.is_empty() { None } else { Some(b) }
        });

        let status_str = status_out
            .map_err(|e| CapabilityError::Internal {
                message: format!("git status failed: {e}"),
            })
            .map(|o| String::from_utf8_lossy(&o.stdout).to_string())?;

        let staged_diff_str = staged_diff_out
            .map_err(|e| CapabilityError::Internal {
                message: format!("git diff --cached failed: {e}"),
            })
            .map(|o| String::from_utf8_lossy(&o.stdout).to_string())?;

        let unstaged_diff_str = unstaged_diff_out
            .map_err(|e| CapabilityError::Internal {
                message: format!("git diff failed: {e}"),
            })
            .map(|o| String::from_utf8_lossy(&o.stdout).to_string())?;
        let staged_numstat = output_stdout(staged_numstat_out, "git diff --cached --numstat")?;
        let unstaged_numstat = output_stdout(unstaged_numstat_out, "git diff --numstat")?;
        let (staged_summary_additions, staged_summary_deletions) =
            parse_numstat_totals(&staged_numstat);
        let (unstaged_summary_additions, unstaged_summary_deletions) =
            parse_numstat_totals(&unstaged_numstat);

        // Truncation check on combined diff size
        let combined_len = staged_diff_str.len() + unstaged_diff_str.len();
        let truncated = combined_len > MAX_DIFF_BYTES;

        let truncate_str = |s: String, max: usize| -> String {
            if s.len() > max {
                let safe_end = s.floor_char_boundary(max);
                s[..safe_end].to_string()
            } else {
                s
            }
        };

        // Give each diff half the budget if both are large
        let half_budget = MAX_DIFF_BYTES / 2;
        let staged_diff_str = if truncated {
            truncate_str(staged_diff_str, half_budget)
        } else {
            staged_diff_str
        };
        let unstaged_diff_str = if truncated {
            truncate_str(unstaged_diff_str, half_budget)
        } else {
            unstaged_diff_str
        };

        let file_entries = parse_porcelain(&status_str);
        let staged_diff_map = split_diff_by_file(&staged_diff_str);
        let unstaged_diff_map = split_diff_by_file(&unstaged_diff_str);

        let mut files = Vec::new();
        for entry in &file_entries {
            match entry.staging_area {
                "both" => {
                    // Partially staged: emit two entries with separate diffs
                    let (staged_diff, s_add, s_del) = diff_for_file(&entry.path, &staged_diff_map);
                    let (unstaged_diff, u_add, u_del) =
                        diff_for_file(&entry.path, &unstaged_diff_map);

                    files.push(serde_json::json!({
                        "path": entry.path,
                        "status": entry.status,
                        "stagingArea": "staged",
                        "diff": staged_diff,
                        "additions": s_add,
                        "deletions": s_del,
                    }));
                    files.push(serde_json::json!({
                        "path": entry.path,
                        "status": entry.status,
                        "stagingArea": "unstaged",
                        "diff": unstaged_diff,
                        "additions": u_add,
                        "deletions": u_del,
                    }));
                }
                "staged" => {
                    let (diff_text, additions, deletions) =
                        diff_for_file(&entry.path, &staged_diff_map);

                    files.push(serde_json::json!({
                        "path": entry.path,
                        "status": entry.status,
                        "stagingArea": "staged",
                        "diff": diff_text,
                        "additions": additions,
                        "deletions": deletions,
                    }));
                }
                _ => {
                    // "unstaged" (including untracked)
                    let (diff_text, additions, deletions) = if entry.status == "untracked" {
                        // git diff doesn't include untracked files, so read the file
                        // content and synthesize an additions-only diff
                        synthesize_untracked_diff(&dir, &entry.path)
                    } else {
                        diff_for_file(&entry.path, &unstaged_diff_map)
                    };

                    files.push(serde_json::json!({
                        "path": entry.path,
                        "status": entry.status,
                        "stagingArea": "unstaged",
                        "diff": diff_text,
                        "additions": additions,
                        "deletions": deletions,
                    }));
                }
            }
        }

        // Summary counts unique file paths (a "both" file counts once)
        let unique_paths: std::collections::HashSet<&str> =
            file_entries.iter().map(|e| e.path.as_str()).collect();

        let mut response = serde_json::json!({
            "isGitRepo": true,
            "branch": branch,
            "files": files,
            "summary": {
                "totalFiles": unique_paths.len(),
                "totalAdditions": staged_summary_additions + unstaged_summary_additions,
                "totalDeletions": staged_summary_deletions + unstaged_summary_deletions,
            },
        });
        if truncated {
            response["truncated"] = serde_json::json!(true);
        }
        Ok(response)
    }
}

impl GetDiffSummaryOperation {
    #[instrument(skip(self, deps), fields(method = "worktree::get_diff_summary"))]
    pub(crate) async fn run(
        &self,
        params: Option<Value>,
        deps: &Deps,
    ) -> Result<Value, CapabilityError> {
        let session_id = require_string_param(params.as_ref(), "sessionId")?;
        let dir = resolve_diff_dir(deps, &session_id)?;
        let summary = compute_working_tree_diff_summary(&dir).await?;
        Ok(diff_summary_to_value(summary))
    }
}

async fn compute_working_tree_diff_summary(
    dir: &str,
) -> Result<WorkingTreeDiffSummary, CapabilityError> {
    if !std::path::Path::new(dir).is_dir() {
        return Ok(WorkingTreeDiffSummary {
            is_git_repo: false,
            branch: None,
            summary: None,
        });
    }

    let check = tokio::process::Command::new("git")
        .args(["-C", dir, "rev-parse", "--is-inside-work-tree"])
        .output()
        .await
        .map_err(|e| CapabilityError::Internal {
            message: format!("Failed to run git: {e}"),
        })?;

    if !check.status.success() {
        return Ok(WorkingTreeDiffSummary {
            is_git_repo: false,
            branch: None,
            summary: None,
        });
    }

    let (branch_out, status_out, staged_numstat_out, unstaged_numstat_out) = tokio::join!(
        tokio::process::Command::new("git")
            .args(["-C", dir, "branch", "--show-current"])
            .output(),
        tokio::process::Command::new("git")
            .args(["-C", dir, "status", "--porcelain=v1"])
            .output(),
        tokio::process::Command::new("git")
            .args(["-C", dir, "diff", "--cached", "--numstat"])
            .output(),
        tokio::process::Command::new("git")
            .args(["-C", dir, "diff", "--numstat"])
            .output()
    );

    let branch = branch_out.ok().and_then(|o| {
        let b = String::from_utf8_lossy(&o.stdout).trim().to_string();
        if b.is_empty() { None } else { Some(b) }
    });

    let status_str = output_stdout(status_out, "git status")?;
    let staged_numstat = output_stdout(staged_numstat_out, "git diff --cached --numstat")?;
    let unstaged_numstat = output_stdout(unstaged_numstat_out, "git diff --numstat")?;

    let file_entries = parse_porcelain(&status_str);
    let unique_paths: std::collections::HashSet<&str> =
        file_entries.iter().map(|e| e.path.as_str()).collect();
    let (staged_additions, staged_deletions) = parse_numstat_totals(&staged_numstat);
    let (unstaged_additions, unstaged_deletions) = parse_numstat_totals(&unstaged_numstat);

    Ok(WorkingTreeDiffSummary {
        is_git_repo: true,
        branch,
        summary: Some(DiffSummaryCounts {
            total_files: unique_paths.len(),
            total_additions: staged_additions + unstaged_additions,
            total_deletions: staged_deletions + unstaged_deletions,
        }),
    })
}

fn output_stdout(
    result: std::io::Result<std::process::Output>,
    label: &str,
) -> Result<String, CapabilityError> {
    let output = result.map_err(|e| CapabilityError::Internal {
        message: format!("{label} failed: {e}"),
    })?;
    if !output.status.success() {
        return Err(CapabilityError::Internal {
            message: format!(
                "{label} failed: {}",
                String::from_utf8_lossy(&output.stderr)
            ),
        });
    }
    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

fn diff_summary_to_value(summary: WorkingTreeDiffSummary) -> Value {
    if !summary.is_git_repo {
        return serde_json::json!({ "isGitRepo": false });
    }

    let counts = summary.summary.unwrap_or(DiffSummaryCounts {
        total_files: 0,
        total_additions: 0,
        total_deletions: 0,
    });

    serde_json::json!({
        "isGitRepo": true,
        "branch": summary.branch,
        "summary": {
            "totalFiles": counts.total_files,
            "totalAdditions": counts.total_additions,
            "totalDeletions": counts.total_deletions,
        },
    })
}

fn parse_numstat_totals(output: &str) -> (usize, usize) {
    output.lines().fold((0, 0), |(add_total, del_total), line| {
        let mut columns = line.split('\t');
        let additions = columns
            .next()
            .and_then(|v| v.parse::<usize>().ok())
            .unwrap_or(0);
        let deletions = columns
            .next()
            .and_then(|v| v.parse::<usize>().ok())
            .unwrap_or(0);
        (add_total + additions, del_total + deletions)
    })
}

// ── Parsing helpers ─────────────────────────────────────────────────

/// Look up a file's diff text and stats from a diff map, handling binary detection.
pub(crate) fn diff_for_file(
    path: &str,
    diff_map: &std::collections::HashMap<String, String>,
) -> (Option<String>, usize, usize) {
    if let Some(chunk) = diff_map.get(path) {
        if is_binary_diff(chunk) {
            (None, 0, 0)
        } else {
            let (a, d) = count_diff_stats(chunk);
            (Some(chunk.clone()), a, d)
        }
    } else {
        (None, 0, 0)
    }
}

/// Synthesize a unified diff for an untracked file by reading its content.
/// Returns a diff where every line is an addition, matching the format
/// `git diff` would produce for a new file.
pub(crate) fn synthesize_untracked_diff(dir: &str, path: &str) -> (Option<String>, usize, usize) {
    let full_path = std::path::Path::new(dir).join(path);
    let content = match std::fs::read(&full_path) {
        Ok(bytes) => bytes,
        Err(_) => return (None, 0, 0),
    };

    // Check for binary content (null bytes in first 8KB)
    let check_len = content.len().min(8192);
    if content[..check_len].contains(&0) {
        return (None, 0, 0);
    }

    let text = match String::from_utf8(content) {
        Ok(s) => s,
        Err(_) => return (None, 0, 0),
    };

    let lines: Vec<&str> = text.lines().collect();
    let line_count = lines.len();
    if line_count == 0 {
        return (None, 0, 0);
    }

    let mut diff = String::new();
    diff.push_str("--- /dev/null\n");
    diff.push_str(&format!("+++ b/{path}\n"));
    diff.push_str(&format!("@@ -0,0 +1,{line_count} @@\n"));
    for line in &lines {
        diff.push('+');
        diff.push_str(line);
        diff.push('\n');
    }

    (Some(diff), line_count, 0)
}

pub(crate) struct FileEntry {
    path: String,
    status: &'static str,
    staging_area: &'static str,
}

/// Parse `git status --porcelain=v1` output into file entries.
pub(crate) fn parse_porcelain(output: &str) -> Vec<FileEntry> {
    let mut entries = Vec::new();
    for line in output.lines() {
        if line.len() < 4 {
            continue;
        }
        let xy = &line[..2];
        let raw_path = &line[3..];

        // Handle quoted paths (git quotes paths with special characters)
        let path = unquote_path(raw_path);

        let (status, staging_area) = match xy {
            "??" => ("untracked", "unstaged"),
            "!!" => continue, // ignored files
            _ => {
                let x = xy.as_bytes()[0];
                let y = xy.as_bytes()[1];

                // Determine staging area from XY columns:
                // X encodes index (staged) state, Y encodes worktree (unstaged) state
                let area = if (x == b'U' || y == b'U')
                    || (x == b'A' && y == b'A')
                    || (x == b'D' && y == b'D')
                {
                    // Unmerged states are treated as unstaged
                    "unstaged"
                } else if x != b' ' && y != b' ' {
                    "both"
                } else if x != b' ' {
                    "staged"
                } else {
                    "unstaged"
                };

                // Determine file status
                let file_status = if (x == b'U' || y == b'U')
                    || (x == b'A' && y == b'A')
                    || (x == b'D' && y == b'D')
                {
                    "unmerged"
                } else if x == b'R' || y == b'R' {
                    "renamed"
                } else if x == b'C' || y == b'C' {
                    "copied"
                } else if x == b'A' || y == b'A' {
                    "added"
                } else if x == b'D' || y == b'D' {
                    "deleted"
                } else {
                    "modified"
                };

                (file_status, area)
            }
        };

        // For renames/copies, the path format is "old -> new"
        let final_path = if status == "renamed" || status == "copied" {
            if let Some((_old, new)) = path.split_once(" -> ") {
                unquote_path(new)
            } else {
                path
            }
        } else {
            path
        };

        entries.push(FileEntry {
            path: final_path,
            status,
            staging_area,
        });
    }
    entries
}

/// Remove surrounding quotes and unescape if git quoted the path.
pub(crate) fn unquote_path(raw: &str) -> String {
    if raw.starts_with('"') && raw.ends_with('"') && raw.len() >= 2 {
        let inner = &raw[1..raw.len() - 1];
        inner
            .replace("\\\\", "\x00")
            .replace("\\\"", "\"")
            .replace("\\n", "\n")
            .replace("\\t", "\t")
            .replace('\x00', "\\")
    } else {
        raw.to_string()
    }
}

/// Detect if diff shows a binary file.
pub(crate) fn is_binary_diff(chunk: &str) -> bool {
    chunk.contains("Binary files") && chunk.contains("differ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;
    use tempfile::tempdir;

    async fn init_repo(dir: &Path) {
        run_cmd(dir, &["git", "init"]).await;
        run_cmd(dir, &["git", "config", "user.email", "test@test.com"]).await;
        run_cmd(dir, &["git", "config", "user.name", "Test"]).await;
        std::fs::write(dir.join("README.md"), "one\n").unwrap();
        run_cmd(dir, &["git", "add", "-A"]).await;
        run_cmd(dir, &["git", "commit", "-m", "init"]).await;
    }

    async fn run_cmd(dir: &Path, args: &[&str]) {
        let output = tokio::process::Command::new(args[0])
            .args(&args[1..])
            .current_dir(dir)
            .output()
            .await
            .unwrap();
        assert!(
            output.status.success(),
            "cmd {:?} failed: {}",
            args,
            String::from_utf8_lossy(&output.stderr)
        );
    }

    async fn summary_for(dir: &Path) -> WorkingTreeDiffSummary {
        compute_working_tree_diff_summary(&dir.to_string_lossy())
            .await
            .unwrap()
    }

    #[tokio::test]
    async fn diff_summary_reports_non_git_without_details() {
        let dir = tempdir().unwrap();
        let summary = summary_for(dir.path()).await;
        assert!(!summary.is_git_repo);
        assert!(summary.summary.is_none());
    }

    #[tokio::test]
    async fn diff_summary_reports_clean_repo() {
        let dir = tempdir().unwrap();
        init_repo(dir.path()).await;

        let summary = summary_for(dir.path()).await;
        assert!(summary.is_git_repo);
        assert_eq!(
            summary.summary,
            Some(DiffSummaryCounts {
                total_files: 0,
                total_additions: 0,
                total_deletions: 0,
            })
        );
    }

    #[tokio::test]
    async fn diff_summary_counts_tracked_unstaged_changes() {
        let dir = tempdir().unwrap();
        init_repo(dir.path()).await;
        std::fs::write(dir.path().join("README.md"), "one\ntwo\n").unwrap();

        let summary = summary_for(dir.path()).await;
        assert_eq!(
            summary.summary,
            Some(DiffSummaryCounts {
                total_files: 1,
                total_additions: 1,
                total_deletions: 0,
            })
        );
    }

    #[tokio::test]
    async fn diff_summary_counts_staged_changes() {
        let dir = tempdir().unwrap();
        init_repo(dir.path()).await;
        std::fs::write(dir.path().join("staged.txt"), "alpha\nbeta\n").unwrap();
        run_cmd(dir.path(), &["git", "add", "staged.txt"]).await;

        let summary = summary_for(dir.path()).await;
        assert_eq!(
            summary.summary,
            Some(DiffSummaryCounts {
                total_files: 1,
                total_additions: 2,
                total_deletions: 0,
            })
        );
    }

    #[tokio::test]
    async fn diff_summary_counts_partially_staged_file_once() {
        let dir = tempdir().unwrap();
        init_repo(dir.path()).await;
        std::fs::write(dir.path().join("README.md"), "one\ntwo\n").unwrap();
        run_cmd(dir.path(), &["git", "add", "README.md"]).await;
        std::fs::write(dir.path().join("README.md"), "one\ntwo\nthree\n").unwrap();

        let summary = summary_for(dir.path()).await;
        assert_eq!(
            summary.summary,
            Some(DiffSummaryCounts {
                total_files: 1,
                total_additions: 2,
                total_deletions: 0,
            })
        );
    }

    #[tokio::test]
    async fn diff_summary_counts_deleted_file() {
        let dir = tempdir().unwrap();
        init_repo(dir.path()).await;
        std::fs::remove_file(dir.path().join("README.md")).unwrap();

        let summary = summary_for(dir.path()).await;
        assert_eq!(
            summary.summary,
            Some(DiffSummaryCounts {
                total_files: 1,
                total_additions: 0,
                total_deletions: 1,
            })
        );
    }

    #[tokio::test]
    async fn diff_summary_counts_renamed_file() {
        let dir = tempdir().unwrap();
        init_repo(dir.path()).await;
        run_cmd(dir.path(), &["git", "mv", "README.md", "README-renamed.md"]).await;

        let summary = summary_for(dir.path()).await;
        assert_eq!(
            summary.summary,
            Some(DiffSummaryCounts {
                total_files: 1,
                total_additions: 0,
                total_deletions: 0,
            })
        );
    }

    #[tokio::test]
    async fn diff_summary_counts_untracked_file_without_reading_contents() {
        let dir = tempdir().unwrap();
        init_repo(dir.path()).await;
        std::fs::write(dir.path().join("untracked.txt"), "alpha\nbeta\ngamma\n").unwrap();

        let summary = summary_for(dir.path()).await;
        assert_eq!(
            summary.summary,
            Some(DiffSummaryCounts {
                total_files: 1,
                total_additions: 0,
                total_deletions: 0,
            })
        );

        let value = diff_summary_to_value(summary);
        assert!(value.get("files").is_none());
    }

    #[tokio::test]
    async fn diff_summary_treats_binary_numstat_as_zero_line_delta() {
        let dir = tempdir().unwrap();
        init_repo(dir.path()).await;
        std::fs::write(dir.path().join("data.bin"), [0_u8, 1, 2, 3]).unwrap();
        run_cmd(dir.path(), &["git", "add", "data.bin"]).await;
        run_cmd(dir.path(), &["git", "commit", "-m", "add binary"]).await;
        std::fs::write(dir.path().join("data.bin"), [0_u8, 9, 8, 7, 6]).unwrap();

        let summary = summary_for(dir.path()).await;
        assert_eq!(
            summary.summary,
            Some(DiffSummaryCounts {
                total_files: 1,
                total_additions: 0,
                total_deletions: 0,
            })
        );
    }

    #[test]
    fn numstat_parser_ignores_binary_line_counts() {
        assert_eq!(
            parse_numstat_totals("3\t1\tREADME.md\n-\t-\tdata.bin\n"),
            (3, 1)
        );
    }
}

// ── Stage / Unstage / Discard handlers ──────────────────────────────

// Extract `sessionId` and `paths` (non-empty string array) from params.
