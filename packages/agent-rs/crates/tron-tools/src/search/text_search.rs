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
    pub matches: usize,
    /// Number of files searched.
    pub files_searched: usize,
    /// Whether output was truncated.
    pub truncated: bool,
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
        let Ok(entry) = entry else { continue };
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

        // Read file, skip binary
        let Ok(bytes) = std::fs::read(entry.path()) else {
            continue;
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
            matches: 0,
            files_searched,
            truncated: false,
        });
    }

    let hit_limit = matches.len() >= max_results;
    let match_count = matches.len();

    let mut output = String::new();
    for m in &matches {
        let _ = writeln!(output, "{}:{}: {}", m.file, m.line, m.content);
    }

    if hit_limit {
        let _ = writeln!(output, "\n[Showing {match_count} results (limit reached)]");
    }

    // Token-based truncation
    let token_count = crate::utils::truncation::estimate_tokens(output.len());
    let truncated = token_count > MAX_OUTPUT_TOKENS;
    if truncated {
        let max_chars = crate::utils::truncation::tokens_to_chars(MAX_OUTPUT_TOKENS);
        output.truncate(max_chars);
        output.push_str("\n... [output truncated]");
    }

    Ok(TextSearchResult {
        output,
        matches: match_count,
        files_searched,
        truncated,
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
        assert!(r.matches >= 2);
        assert!(r.output.contains("println"));
    }

    #[test]
    fn case_insensitive_matching() {
        let dir = setup_test_dir();
        let r = text_search(dir.path(), "PRINTLN", None, None, None).unwrap();
        assert!(r.matches >= 2);
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
        assert_eq!(r.matches, 0);
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
        assert_eq!(r.matches, 5);
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
        assert_eq!(r.matches, 1);
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
        assert_eq!(r.matches, 0);
        assert_eq!(r.files_searched, 0);
    }
}
