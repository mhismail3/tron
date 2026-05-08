//! Worktree workflow operations.
use super::resolve_diff_dir;
use super::{count_diff_stats, instrument, split_diff_by_file};
use crate::server::domains::worktree::Deps;
use crate::server::shared::errors::CapabilityError;
use crate::server::shared::params::require_string_param;
use serde_json::Value;

// ── GetDiff ─────────────────────────────────────────────────────────

const MAX_DIFF_BYTES: usize = 1_024 * 1_024; // 1 MB

/// Get unified diff of all uncommitted changes for a session's working directory.
///
/// Works for any session — uses the worktree path if one is active, otherwise
/// the session's original working directory. Does not require a coordinator.
pub struct GetDiffOperation;

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
        let (branch_out, status_out, staged_diff_out, unstaged_diff_out) = tokio::join!(
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
        let mut total_additions: usize = 0;
        let mut total_deletions: usize = 0;

        for entry in &file_entries {
            match entry.staging_area {
                "both" => {
                    // Partially staged: emit two entries with separate diffs
                    let (staged_diff, s_add, s_del) = diff_for_file(&entry.path, &staged_diff_map);
                    let (unstaged_diff, u_add, u_del) =
                        diff_for_file(&entry.path, &unstaged_diff_map);

                    total_additions += s_add + u_add;
                    total_deletions += s_del + u_del;

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
                    total_additions += additions;
                    total_deletions += deletions;

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
                    total_additions += additions;
                    total_deletions += deletions;

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
                "totalAdditions": total_additions,
                "totalDeletions": total_deletions,
            },
        });
        if truncated {
            response["truncated"] = serde_json::json!(true);
        }
        Ok(response)
    }
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

// ── Stage / Unstage / Discard handlers ──────────────────────────────

// Extract `sessionId` and `paths` (non-empty string array) from params.
