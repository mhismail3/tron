//! Unified diff generation.
//!
//! Produces unified diff output for the Edit tool, matching the format:
//! ```text
//! @@ -start,count +start,count @@
//!  context line
//! -removed line
//! +added line
//!  context line
//! ```

/// Generate a unified diff between two strings.
///
/// `context_lines` controls how many unchanged lines surround each change
/// (default 3 in the Edit tool).
pub fn generate_unified_diff(old: &str, new: &str, context_lines: usize) -> String {
    if old == new {
        return String::new();
    }

    let old_lines: Vec<&str> = old.lines().collect();
    let new_lines: Vec<&str> = new.lines().collect();

    // Find changed regions using a simple LCS-based diff
    let ops = compute_edit_ops(&old_lines, &new_lines);
    if ops.is_empty() {
        return String::new();
    }

    format_hunks(&old_lines, &new_lines, &ops, context_lines)
}

/// Edit operations.
#[derive(Debug, Clone, PartialEq, Eq)]
enum EditOp {
    Equal(usize, usize), // old_idx, new_idx
    Delete(usize),       // old_idx
    Insert(usize),       // new_idx
}

/// Compute edit operations using the Myers diff algorithm (simplified).
fn compute_edit_ops(old: &[&str], new: &[&str]) -> Vec<EditOp> {
    let old_len = old.len();
    let new_len = new.len();

    // Build LCS table
    let mut dp = vec![vec![0u32; new_len + 1]; old_len + 1];
    for (i, old_line) in old.iter().enumerate() {
        for (j, new_line) in new.iter().enumerate() {
            dp[i + 1][j + 1] = if old_line == new_line {
                dp[i][j] + 1
            } else {
                dp[i + 1][j].max(dp[i][j + 1])
            };
        }
    }

    // Backtrack to get edit ops
    let mut ops = Vec::new();
    let mut i = old_len;
    let mut j = new_len;
    while i > 0 || j > 0 {
        if i > 0 && j > 0 && old[i - 1] == new[j - 1] {
            ops.push(EditOp::Equal(i - 1, j - 1));
            i -= 1;
            j -= 1;
        } else if j > 0 && (i == 0 || dp[i][j - 1] >= dp[i - 1][j]) {
            ops.push(EditOp::Insert(j - 1));
            j -= 1;
        } else {
            ops.push(EditOp::Delete(i - 1));
            i -= 1;
        }
    }
    ops.reverse();
    ops
}

/// Format edit operations into unified diff hunks.
fn format_hunks(old: &[&str], new: &[&str], ops: &[EditOp], context_lines: usize) -> String {
    // Find change ranges (groups of non-Equal ops)
    let mut changes: Vec<(usize, usize)> = Vec::new(); // (start_idx, end_idx) in ops
    let mut i = 0;
    while i < ops.len() {
        if matches!(ops[i], EditOp::Equal(..)) {
            i += 1;
        } else {
            let start = i;
            while i < ops.len() && !matches!(ops[i], EditOp::Equal(..)) {
                i += 1;
            }
            changes.push((start, i));
        }
    }

    if changes.is_empty() {
        return String::new();
    }

    // Build hunks with context
    let mut output = String::new();
    for &(change_start, change_end) in &changes {
        // Find context bounds in the ops array
        let ctx_start = change_start.saturating_sub(context_lines);
        let ctx_end = (change_end + context_lines).min(ops.len());

        // Calculate line ranges
        let mut old_start = 0;
        let mut old_count = 0u32;
        let mut new_start = 0;
        let mut new_count = 0u32;
        let mut first = true;

        let mut hunk_lines = Vec::new();
        for op in &ops[ctx_start..ctx_end] {
            match op {
                EditOp::Equal(oi, ni) => {
                    if first {
                        old_start = oi + 1;
                        new_start = ni + 1;
                        first = false;
                    }
                    old_count += 1;
                    new_count += 1;
                    hunk_lines.push(format!(" {}", old[*oi]));
                }
                EditOp::Delete(oi) => {
                    if first {
                        old_start = oi + 1;
                        new_start = if *oi < new.len() {
                            oi + 1
                        } else {
                            new.len() + 1
                        };
                        first = false;
                    }
                    old_count += 1;
                    hunk_lines.push(format!("-{}", old[*oi]));
                }
                EditOp::Insert(ni) => {
                    if first {
                        old_start = if *ni < old.len() {
                            ni + 1
                        } else {
                            old.len() + 1
                        };
                        new_start = ni + 1;
                        first = false;
                    }
                    new_count += 1;
                    hunk_lines.push(format!("+{}", new[*ni]));
                }
            }
        }

        let header = format!("@@ -{old_start},{old_count} +{new_start},{new_count} @@\n");
        output.push_str(&header);
        for line in &hunk_lines {
            output.push_str(line);
            output.push('\n');
        }
    }

    output
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn single_line_change() {
        let diff = generate_unified_diff("hello\n", "world\n", 3);
        assert!(diff.contains("@@"));
        assert!(diff.contains("-hello"));
        assert!(diff.contains("+world"));
    }

    #[test]
    fn multi_line_with_context() {
        let old = "line1\nline2\nline3\nline4\nline5\n";
        let new = "line1\nline2\nchanged\nline4\nline5\n";
        let diff = generate_unified_diff(old, new, 3);
        assert!(diff.contains("-line3"));
        assert!(diff.contains("+changed"));
        // Context lines
        assert!(diff.contains(" line2"));
        assert!(diff.contains(" line4"));
    }

    #[test]
    fn addition_more_lines() {
        let old = "a\nb\n";
        let new = "a\nb\nc\nd\n";
        let diff = generate_unified_diff(old, new, 3);
        assert!(diff.contains("+c"));
        assert!(diff.contains("+d"));
    }

    #[test]
    fn deletion_fewer_lines() {
        let old = "a\nb\nc\nd\n";
        let new = "a\nb\n";
        let diff = generate_unified_diff(old, new, 3);
        assert!(diff.contains("-c"));
        assert!(diff.contains("-d"));
    }

    #[test]
    fn no_changes_empty_diff() {
        let diff = generate_unified_diff("same\n", "same\n", 3);
        assert!(diff.is_empty());
    }
}
