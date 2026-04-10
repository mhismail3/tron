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

/// Generate a structured diff between two strings as an array of typed
/// line objects for iOS to render without parsing text.
///
/// Each entry is one of:
/// - `{"type": "hunk_header", "oldStart": u64, "oldCount": u64, "newStart": u64, "newCount": u64}`
/// - `{"type": "context", "content": String, "oldLine": u64, "newLine": u64}`
/// - `{"type": "deletion", "content": String, "oldLine": u64}`
/// - `{"type": "addition", "content": String, "newLine": u64}`
pub fn generate_structured_diff(
    old: &str,
    new: &str,
    context_lines: usize,
) -> Vec<serde_json::Value> {
    if old == new {
        return Vec::new();
    }
    let old_lines: Vec<&str> = old.lines().collect();
    let new_lines: Vec<&str> = new.lines().collect();
    let ops = compute_edit_ops(&old_lines, &new_lines);
    if ops.is_empty() {
        return Vec::new();
    }
    format_hunks_structured(&old_lines, &new_lines, &ops, context_lines)
}

fn format_hunks_structured(
    old: &[&str],
    new: &[&str],
    ops: &[EditOp],
    context_lines: usize,
) -> Vec<serde_json::Value> {
    use serde_json::json;

    let mut changes: Vec<(usize, usize)> = Vec::new();
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
        return Vec::new();
    }

    let mut output: Vec<serde_json::Value> = Vec::new();
    for &(change_start, change_end) in &changes {
        let ctx_start = change_start.saturating_sub(context_lines);
        let ctx_end = (change_end + context_lines).min(ops.len());

        let mut old_start: usize = 0;
        let mut old_count: u64 = 0;
        let mut new_start: usize = 0;
        let mut new_count: u64 = 0;
        let mut first = true;
        let mut hunk_body: Vec<serde_json::Value> = Vec::new();

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
                    hunk_body.push(json!({
                        "type": "context",
                        "content": old[*oi],
                        "oldLine": oi + 1,
                        "newLine": ni + 1,
                    }));
                }
                EditOp::Delete(oi) => {
                    if first {
                        old_start = oi + 1;
                        new_start = if *oi < new.len() { oi + 1 } else { new.len() + 1 };
                        first = false;
                    }
                    old_count += 1;
                    hunk_body.push(json!({
                        "type": "deletion",
                        "content": old[*oi],
                        "oldLine": oi + 1,
                    }));
                }
                EditOp::Insert(ni) => {
                    if first {
                        old_start = if *ni < old.len() { ni + 1 } else { old.len() + 1 };
                        new_start = ni + 1;
                        first = false;
                    }
                    new_count += 1;
                    hunk_body.push(json!({
                        "type": "addition",
                        "content": new[*ni],
                        "newLine": ni + 1,
                    }));
                }
            }
        }

        output.push(json!({
            "type": "hunk_header",
            "oldStart": old_start as u64,
            "oldCount": old_count,
            "newStart": new_start as u64,
            "newCount": new_count,
        }));
        output.extend(hunk_body);
    }

    output
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

    // =========================================================================
    // generate_structured_diff — edge-case matrix
    // =========================================================================

    use serde_json::Value;

    fn entry_type(v: &Value) -> &str {
        v.get("type").and_then(Value::as_str).unwrap_or("")
    }

    fn all_types(entries: &[Value]) -> Vec<&str> {
        entries.iter().map(entry_type).collect()
    }

    #[test]
    fn structured_diff_identical_inputs_empty() {
        let entries = generate_structured_diff("hello\nworld\n", "hello\nworld\n", 3);
        assert!(entries.is_empty());
    }

    #[test]
    fn structured_diff_both_empty() {
        assert!(generate_structured_diff("", "", 3).is_empty());
    }

    #[test]
    fn structured_diff_single_line_change_has_hunk_header_and_lines() {
        let entries = generate_structured_diff("hello world\n", "hello tron\n", 1);
        let types = all_types(&entries);
        assert!(types.contains(&"hunk_header"));
        assert!(types.iter().any(|t| *t == "deletion"));
        assert!(types.iter().any(|t| *t == "addition"));
    }

    #[test]
    fn structured_diff_empty_old_only_additions() {
        let entries = generate_structured_diff("", "a\nb\nc\n", 3);
        let types = all_types(&entries);
        assert!(types.contains(&"hunk_header"));
        assert!(types.iter().all(|t| *t == "hunk_header" || *t == "addition"));
        // Every addition has a newLine, never an oldLine.
        for e in entries.iter().filter(|e| entry_type(e) == "addition") {
            assert!(e.get("newLine").is_some(), "addition missing newLine");
            assert!(e.get("oldLine").is_none(), "addition should not have oldLine");
        }
    }

    #[test]
    fn structured_diff_empty_new_only_deletions() {
        let entries = generate_structured_diff("a\nb\nc\n", "", 3);
        let types = all_types(&entries);
        assert!(types.contains(&"hunk_header"));
        assert!(types.iter().all(|t| *t == "hunk_header" || *t == "deletion"));
        for e in entries.iter().filter(|e| entry_type(e) == "deletion") {
            assert!(e.get("oldLine").is_some(), "deletion missing oldLine");
            assert!(e.get("newLine").is_none(), "deletion should not have newLine");
        }
    }

    #[test]
    fn structured_diff_hunk_header_shape() {
        let entries = generate_structured_diff("a\n", "b\n", 1);
        let header = entries
            .iter()
            .find(|v| entry_type(v) == "hunk_header")
            .expect("hunk header present");
        for key in ["oldStart", "oldCount", "newStart", "newCount"] {
            let v = header.get(key).unwrap_or_else(|| panic!("missing {key}"));
            assert!(v.as_u64().is_some(), "{key} not u64");
        }
    }

    #[test]
    fn structured_diff_line_entries_have_content() {
        let entries = generate_structured_diff("a\nb\n", "a\nc\n", 3);
        for entry in entries.iter().filter(|e| entry_type(e) != "hunk_header") {
            let content = entry.get("content").and_then(Value::as_str);
            assert!(content.is_some(), "entry missing content: {entry}");
        }
    }

    #[test]
    fn structured_diff_context_entries_have_both_line_numbers() {
        let entries =
            generate_structured_diff("a\nb\nc\nd\ne\n", "a\nb\nX\nd\ne\n", 3);
        let context_entries: Vec<&Value> = entries
            .iter()
            .filter(|e| entry_type(e) == "context")
            .collect();
        assert!(!context_entries.is_empty(), "expected context entries");
        for e in context_entries {
            assert!(e.get("oldLine").is_some(), "context missing oldLine");
            assert!(e.get("newLine").is_some(), "context missing newLine");
        }
    }

    #[test]
    fn structured_diff_context_zero_no_context_entries() {
        let entries =
            generate_structured_diff("a\nb\nc\nd\ne\n", "a\nb\nX\nd\ne\n", 0);
        assert!(
            !entries.iter().any(|e| entry_type(e) == "context"),
            "context_lines=0 must produce no context entries"
        );
        // Still emits hunk header + the changed lines.
        assert!(entries.iter().any(|e| entry_type(e) == "hunk_header"));
    }

    #[test]
    fn structured_diff_context_larger_than_file_does_not_panic() {
        // context_lines larger than the entire file must clamp, not trap.
        let entries = generate_structured_diff("a\n", "b\n", 1_000);
        assert!(!entries.is_empty());
        assert!(entries.iter().any(|e| entry_type(e) == "hunk_header"));
    }

    #[test]
    fn structured_diff_multi_hunk_emits_multiple_headers() {
        // Two distant changes separated by enough context to force two hunks.
        let old = "l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\nl13\nl14\nl15\n";
        let new = "l1\nCHANGED1\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10\nl11\nl12\nl13\nl14\nCHANGED15\n";
        let entries = generate_structured_diff(old, new, 1);
        let header_count = entries
            .iter()
            .filter(|e| entry_type(e) == "hunk_header")
            .count();
        assert!(header_count >= 2, "expected ≥2 hunks, got {header_count}");
    }

    #[test]
    fn structured_diff_preserves_unicode() {
        let old = "hello 🚀\n";
        let new = "hello 日本語\n";
        let entries = generate_structured_diff(old, new, 1);
        let joined: String = entries
            .iter()
            .filter_map(|e| e.get("content").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join("\n");
        assert!(joined.contains("🚀"));
        assert!(joined.contains("日本語"));
    }

    #[test]
    fn structured_diff_preserves_tabs_and_long_lines() {
        let long_old = format!("{}\n", "x".repeat(5_000));
        let long_new = format!("{}\n", "y".repeat(5_000));
        let entries = generate_structured_diff(&long_old, &long_new, 1);
        let has_long = entries
            .iter()
            .filter_map(|e| e.get("content").and_then(Value::as_str))
            .any(|s| s.len() == 5_000);
        assert!(has_long, "long lines must be preserved verbatim");

        let tab_entries =
            generate_structured_diff("a\tb\n", "a\tc\n", 1);
        assert!(tab_entries
            .iter()
            .filter_map(|e| e.get("content").and_then(Value::as_str))
            .any(|s| s.contains('\t')));
    }

    #[test]
    fn structured_diff_trailing_newline_variants() {
        // No panic regardless of trailing newline shape.
        let _ = generate_structured_diff("a", "b", 1);
        let _ = generate_structured_diff("a\n", "b", 1);
        let _ = generate_structured_diff("a", "b\n", 1);
        let _ = generate_structured_diff("a\n", "b\n", 1);
    }

    #[test]
    fn structured_diff_old_line_numbers_monotonic_within_hunk() {
        let old = "a\nb\nc\nd\ne\n";
        let new = "a\nb\nX\nY\ne\n";
        let entries = generate_structured_diff(old, new, 3);
        let mut prev: Option<u64> = None;
        for entry in &entries {
            let ty = entry_type(entry);
            if ty == "hunk_header" {
                prev = None; // reset per hunk
                continue;
            }
            if let Some(line) = entry.get("oldLine").and_then(Value::as_u64) {
                if let Some(p) = prev {
                    assert!(
                        line >= p,
                        "oldLine not monotonic: {p} -> {line} at {entry}"
                    );
                }
                prev = Some(line);
            }
        }
    }

    #[test]
    fn structured_diff_new_line_numbers_monotonic_within_hunk() {
        let old = "a\nb\nc\nd\ne\n";
        let new = "a\nb\nX\nY\ne\n";
        let entries = generate_structured_diff(old, new, 3);
        let mut prev: Option<u64> = None;
        for entry in &entries {
            let ty = entry_type(entry);
            if ty == "hunk_header" {
                prev = None;
                continue;
            }
            if let Some(line) = entry.get("newLine").and_then(Value::as_u64) {
                if let Some(p) = prev {
                    assert!(
                        line >= p,
                        "newLine not monotonic: {p} -> {line} at {entry}"
                    );
                }
                prev = Some(line);
            }
        }
    }

    #[test]
    fn structured_diff_entry_types_are_exhaustive() {
        // No unexpected entry types slip into the wire format. iOS decoder
        // matches on exactly these four strings.
        let entries = generate_structured_diff("a\nb\nc\n", "a\nx\nc\n", 3);
        for entry in &entries {
            let ty = entry_type(entry);
            assert!(
                matches!(ty, "hunk_header" | "context" | "deletion" | "addition"),
                "unexpected entry type: {ty}"
            );
        }
    }
}
