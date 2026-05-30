use crate::domains::worktree::git::WorktreeListEntry;

/// Parse `git worktree list --porcelain` output.
pub(super) fn parse_worktree_porcelain(output: &str) -> Vec<WorktreeListEntry> {
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
            branch = Some(full.strip_prefix("refs/heads/").unwrap_or(full).to_string());
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

pub(super) fn parse_nul_paths(output: &[u8]) -> Vec<String> {
    output
        .split(|byte| *byte == 0)
        .filter(|part| !part.is_empty())
        .map(|part| String::from_utf8_lossy(part).to_string())
        .filter(|path| !path.is_empty())
        .collect()
}
