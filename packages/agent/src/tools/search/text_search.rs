//! Text search engine — regex-based file content search.
//!
//! Recursively walks a directory, matching lines against a case-insensitive
//! regex pattern. Skips common build/hidden directories and binary files.
//! Results are formatted as `file:line: content`.

use std::fmt::Write;
use std::path::Path;

use regex::RegexBuilder;

const SKIP_DIRS: &[&str] = &[
    "node_modules",
    ".git",
    "dist",
    "build",
    ".next",
    "coverage",
    "__pycache__",
];
const DEFAULT_MAX_RESULTS: usize = 100;
const MAX_OUTPUT_TOKENS: usize = 15_000;

/// A single text search match.
pub struct TextMatch {
    /// Relative file path.
    pub file: String,
    /// 1-indexed line number.
    pub line: usize,
    /// Trimmed line content.
    pub content: String,
}

/// Result of a text search operation.
#[derive(Debug)]
pub struct TextSearchResult {
    /// Formatted output text.
    pub output: String,
    /// Number of matches found.
    pub match_count: usize,
    /// Number of files searched.
    pub files_searched: usize,
    /// Whether output was truncated.
    pub truncated: bool,
    /// Number of files encountered but not read due to I/O errors
    /// (permission denied, dangling symlinks, EIO, etc). Surfaced so the
    /// caller can distinguish "no matches" from "couldn't look" and the
    /// agent doesn't silently miss data.
    pub skipped_unreadable: usize,
    /// Structured match data: `[{filePath, lineNumber, content}]`.
    /// Emitted via `tool.details.matches` so iOS renders without regex.
    pub matches_json: Vec<serde_json::Value>,
}

/// Run a text search across files under `search_root`.
///
/// Returns formatted results in `file:line: content` format.
pub fn text_search(
    search_root: &Path,
    pattern: &str,
    file_pattern: Option<&str>,
    max_results: Option<usize>,
    context: Option<usize>,
) -> Result<TextSearchResult, String> {
    let regex = RegexBuilder::new(pattern)
        .case_insensitive(true)
        .build()
        .map_err(|e| format!("Invalid regex pattern: {e}"))?;

    let max_results = max_results.unwrap_or(DEFAULT_MAX_RESULTS);
    let _context_lines = context.unwrap_or(0);

    let file_glob = file_pattern.and_then(|fp| {
        globset::GlobBuilder::new(fp)
            .literal_separator(false)
            .build()
            .ok()
            .map(|g| g.compile_matcher())
    });

    let mut matches = Vec::new();
    let mut files_searched = 0;
    let mut skipped_unreadable = 0usize;

    let walker = walkdir::WalkDir::new(search_root);
    for entry in walker.into_iter().filter_entry(|e| {
        let name = e.file_name().to_string_lossy();
        if e.depth() > 0 && e.file_type().is_dir() {
            if name.starts_with('.') {
                return false;
            }
            if SKIP_DIRS.contains(&name.as_ref()) {
                return false;
            }
        }
        true
    }) {
        let entry = match entry {
            Ok(e) => e,
            Err(err) => {
                skipped_unreadable += 1;
                tracing::debug!(
                    error = %err,
                    "text_search: walkdir entry error (skipping)"
                );
                continue;
            }
        };
        if entry.file_type().is_dir() {
            continue;
        }

        let rel_path = entry
            .path()
            .strip_prefix(search_root)
            .unwrap_or(entry.path());

        // Apply file pattern filter
        if let Some(ref glob) = file_glob {
            let file_name = entry.file_name().to_string_lossy();
            if !glob.is_match(rel_path) && !glob.is_match(file_name.as_ref()) {
                continue;
            }
        }

        // Read file, skip on I/O error (permission denied, dangling symlink,
        // EIO). Count and log so the skip is visible to operators.
        let bytes = match std::fs::read(entry.path()) {
            Ok(b) => b,
            Err(err) => {
                skipped_unreadable += 1;
                tracing::debug!(
                    path = %entry.path().display(),
                    error = %err,
                    "text_search: skipping unreadable file"
                );
                continue;
            }
        };
        let check_len = bytes.len().min(8192);
        if bytes[..check_len].contains(&0) {
            continue;
        }

        let file_text = String::from_utf8_lossy(&bytes);
        files_searched += 1;

        for (line_idx, line) in file_text.lines().enumerate() {
            if regex.is_match(line) {
                matches.push(TextMatch {
                    file: rel_path.to_string_lossy().into_owned(),
                    line: line_idx + 1,
                    content: line.trim().to_string(),
                });

                if matches.len() >= max_results {
                    break;
                }
            }
        }

        if matches.len() >= max_results {
            break;
        }
    }

    if matches.is_empty() {
        return Ok(TextSearchResult {
            output: format!("No matches found for pattern: {pattern}"),
            match_count: 0,
            files_searched,
            truncated: false,
            skipped_unreadable,
            matches_json: Vec::new(),
        });
    }

    let hit_limit = matches.len() >= max_results;
    let match_count = matches.len();

    let mut output = String::new();
    let mut matches_json: Vec<serde_json::Value> = Vec::with_capacity(match_count);
    for m in &matches {
        let _ = writeln!(output, "{}:{}: {}", m.file, m.line, m.content);
        matches_json.push(serde_json::json!({
            "filePath": m.file,
            "lineNumber": m.line,
            "content": m.content,
        }));
    }

    if hit_limit {
        let _ = writeln!(output, "\n[Showing {match_count} results (limit reached)]");
    }

    // Token-based truncation
    let token_count = crate::tools::utils::truncation::estimate_tokens(output.len());
    let truncated = token_count > MAX_OUTPUT_TOKENS;
    if truncated {
        let max_chars = crate::tools::utils::truncation::tokens_to_chars(MAX_OUTPUT_TOKENS);
        output.truncate(max_chars);
        output.push_str("\n... [output truncated]");
    }

    Ok(TextSearchResult {
        output,
        match_count,
        files_searched,
        truncated,
        skipped_unreadable,
        matches_json,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn setup_test_dir() -> TempDir {
        let dir = TempDir::new().unwrap();
        std::fs::write(
            dir.path().join("main.rs"),
            "fn main() {\n    println!(\"hello world\");\n}\n",
        )
        .unwrap();
        std::fs::write(
            dir.path().join("lib.rs"),
            "pub fn greet() {\n    println!(\"greetings\");\n}\n",
        )
        .unwrap();
        std::fs::write(
            dir.path().join("test.ts"),
            "function test() {\n  console.log('test');\n}\n",
        )
        .unwrap();
        std::fs::create_dir_all(dir.path().join("src")).unwrap();
        std::fs::write(
            dir.path().join("src/utils.rs"),
            "pub fn helper() {\n    println!(\"helper\");\n}\n",
        )
        .unwrap();
        dir
    }

    #[test]
    fn regex_matches_in_single_file() {
        let dir = setup_test_dir();
        let r = text_search(dir.path(), "println", None, None, None).unwrap();
        assert!(r.match_count >= 2);
        assert!(r.output.contains("println"));
    }

    #[test]
    fn case_insensitive_matching() {
        let dir = setup_test_dir();
        let r = text_search(dir.path(), "PRINTLN", None, None, None).unwrap();
        assert!(r.match_count >= 2);
    }

    #[test]
    fn multiple_files_grouped() {
        let dir = setup_test_dir();
        let r = text_search(dir.path(), "fn ", None, None, None).unwrap();
        assert!(r.output.contains("main.rs"));
        assert!(r.output.contains("lib.rs"));
    }

    #[test]
    fn file_filtering_by_glob() {
        let dir = setup_test_dir();
        let r = text_search(dir.path(), "function", Some("*.ts"), None, None).unwrap();
        assert!(r.output.contains("test.ts"));
        assert!(!r.output.contains("main.rs"));
    }

    #[test]
    fn skip_directories() {
        let dir = TempDir::new().unwrap();
        std::fs::create_dir_all(dir.path().join("node_modules")).unwrap();
        std::fs::write(
            dir.path().join("node_modules/pkg.js"),
            "function hidden() {}",
        )
        .unwrap();
        std::fs::create_dir_all(dir.path().join(".git")).unwrap();
        std::fs::write(dir.path().join(".git/config"), "hidden").unwrap();
        std::fs::write(dir.path().join("visible.js"), "function visible() {}").unwrap();

        let r = text_search(dir.path(), "function", None, None, None).unwrap();
        assert!(r.output.contains("visible.js"));
        assert!(!r.output.contains("node_modules"));
        assert!(!r.output.contains(".git"));
    }

    #[test]
    fn no_matches_returns_message() {
        let dir = setup_test_dir();
        let r = text_search(dir.path(), "zzzznonexistent", None, None, None).unwrap();
        assert_eq!(r.match_count, 0);
        assert!(r.output.contains("No matches found"));
    }

    #[test]
    fn invalid_regex_returns_error() {
        let dir = setup_test_dir();
        let r = text_search(dir.path(), "[invalid", None, None, None);
        assert!(r.is_err());
        assert!(r.unwrap_err().contains("Invalid regex"));
    }

    #[test]
    fn max_results_limit_enforced() {
        let dir = TempDir::new().unwrap();
        let lines: Vec<String> = (1..=50).map(|i| format!("match line {i}")).collect();
        std::fs::write(dir.path().join("many.txt"), lines.join("\n")).unwrap();

        let r = text_search(dir.path(), "match", None, Some(5), None).unwrap();
        assert_eq!(r.match_count, 5);
        assert!(r.output.contains("limit reached"));
    }

    #[test]
    fn binary_files_skipped() {
        let dir = TempDir::new().unwrap();
        let mut bin = b"match this".to_vec();
        bin.push(0);
        bin.extend_from_slice(b"more data");
        std::fs::write(dir.path().join("binary.bin"), &bin).unwrap();
        std::fs::write(dir.path().join("text.txt"), "match this text").unwrap();

        let r = text_search(dir.path(), "match", None, None, None).unwrap();
        assert_eq!(r.match_count, 1);
        assert!(r.output.contains("text.txt"));
        assert!(!r.output.contains("binary.bin"));
    }

    #[test]
    fn files_searched_count_tracked() {
        let dir = setup_test_dir();
        let r = text_search(dir.path(), "println", None, None, None).unwrap();
        assert!(r.files_searched >= 2);
    }

    #[test]
    fn output_format_file_line_content() {
        let dir = TempDir::new().unwrap();
        std::fs::write(
            dir.path().join("test.txt"),
            "line one\nline two\nline three\n",
        )
        .unwrap();
        let r = text_search(dir.path(), "two", None, None, None).unwrap();
        assert!(r.output.contains("test.txt:2:"));
        assert!(r.output.contains("line two"));
    }

    #[test]
    fn empty_directory_no_matches() {
        let dir = TempDir::new().unwrap();
        let r = text_search(dir.path(), "anything", None, None, None).unwrap();
        assert_eq!(r.match_count, 0);
        assert_eq!(r.files_searched, 0);
        assert_eq!(r.skipped_unreadable, 0);
    }

    #[test]
    fn skipped_unreadable_zero_for_normal_search() {
        let dir = setup_test_dir();
        let r = text_search(dir.path(), "println", None, None, None).unwrap();
        assert_eq!(r.skipped_unreadable, 0);
    }

    #[cfg(unix)]
    #[test]
    fn dangling_symlink_counted_as_skipped_unreadable() {
        use std::os::unix::fs::symlink;
        let dir = TempDir::new().unwrap();
        std::fs::write(dir.path().join("real.txt"), "match this").unwrap();
        // Symlink whose target does not exist — std::fs::read fails with
        // ENOENT after walkdir yields the entry.
        symlink("/does/not/exist/anywhere", dir.path().join("broken.lnk")).unwrap();

        let r = text_search(dir.path(), "match", None, None, None).unwrap();
        // The real file is still searched and matched.
        assert_eq!(r.match_count, 1);
        // The dangling symlink was counted, not silently dropped.
        assert!(
            r.skipped_unreadable >= 1,
            "expected ≥1 skipped, got {}",
            r.skipped_unreadable
        );
    }
}
