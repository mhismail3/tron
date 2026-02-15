//! `Find` tool — glob-based file search.
//!
//! Searches a directory tree using glob patterns, with options for type filtering,
//! depth limiting, exclusions, and sorting.

use std::fmt::Write;

use async_trait::async_trait;
use serde_json::{json, Value};
use tron_core::tools::{
    Tool, ToolCategory, ToolParameterSchema, ToolResultBody, TronToolResult, error_result,
};

use crate::errors::ToolError;
use crate::traits::{ToolContext, TronTool};
use crate::utils::path::resolve_path;
use crate::utils::validation::{
    get_optional_bool, get_optional_string, get_optional_u64, validate_required_string,
};

const DEFAULT_MAX_RESULTS: usize = 200;

/// Format byte count as human-readable size (matching TS server output).
#[allow(clippy::cast_precision_loss)]
fn format_size(bytes: u64) -> String {
    if bytes < 1024 {
        format!("{bytes}")
    } else if bytes < 1_048_576 {
        format!("{:.1}K", bytes as f64 / 1024.0)
    } else if bytes < 1_073_741_824 {
        format!("{:.1}M", bytes as f64 / 1_048_576.0)
    } else {
        format!("{:.1}G", bytes as f64 / 1_073_741_824.0)
    }
}
const SKIP_DIRS: &[&str] = &[".git", "node_modules", "dist", ".next", "coverage", "__pycache__"];

/// The `Find` tool searches for files using glob patterns.
pub struct FindTool;

impl FindTool {
    /// Create a new `Find` tool.
    pub fn new() -> Self {
        Self
    }
}

impl Default for FindTool {
    fn default() -> Self {
        Self::new()
    }
}

/// Check if a path matches any of the exclude patterns.
fn is_excluded(path: &std::path::Path, exclude_matchers: &[globset::GlobMatcher]) -> bool {
    exclude_matchers.iter().any(|m| {
        m.is_match(path)
            || path
                .file_name()
                .is_some_and(|name| m.is_match(std::path::Path::new(name)))
    })
}

/// Collect matching entries from a directory walk.
fn collect_entries(
    search_root: &std::path::Path,
    glob: &globset::GlobMatcher,
    exclude_matchers: &[globset::GlobMatcher],
    type_filter: &str,
    max_depth: Option<usize>,
    max_results: usize,
    show_size: bool,
    sort_by_time: bool,
) -> Vec<(String, Option<u64>, Option<std::time::SystemTime>)> {
    let mut walker = walkdir::WalkDir::new(search_root);
    if let Some(depth) = max_depth {
        walker = walker.max_depth(depth);
    }

    let mut entries = Vec::new();

    for entry in walker.into_iter().filter_entry(|e| {
        let name = e.file_name().to_string_lossy();
        if e.depth() > 0 && name.starts_with('.') && e.file_type().is_dir() {
            return false;
        }
        if e.file_type().is_dir() && SKIP_DIRS.contains(&name.as_ref()) {
            return false;
        }
        true
    }) {
        let Ok(entry) = entry else { continue };

        let is_dir = entry.file_type().is_dir();
        match type_filter {
            "file" if is_dir => continue,
            "directory" if !is_dir => continue,
            _ => {}
        }

        let rel_path = entry.path().strip_prefix(search_root).unwrap_or(entry.path());
        if !glob.is_match(rel_path) && !glob.is_match(entry.file_name()) {
            continue;
        }

        // Check exclude patterns
        if is_excluded(rel_path, exclude_matchers) {
            continue;
        }

        let size = if show_size || sort_by_time { entry.metadata().ok().map(|m| m.len()) } else { None };
        let modified = if sort_by_time { entry.metadata().ok().and_then(|m| m.modified().ok()) } else { None };

        entries.push((rel_path.to_string_lossy().into_owned(), size, modified));

        if entries.len() >= max_results && !sort_by_time {
            break;
        }
    }

    if sort_by_time {
        entries.sort_by(|a, b| b.2.cmp(&a.2));
        entries.truncate(max_results);
    }

    entries
}

#[async_trait]
impl TronTool for FindTool {
    fn name(&self) -> &str {
        "Find"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Filesystem
    }

    fn definition(&self) -> Tool {
        Tool {
            name: "Find".into(),
            description: "Find files and directories matching a glob pattern.".into(),
            parameters: ToolParameterSchema {
                schema_type: "object".into(),
                properties: Some({
                    let mut m = serde_json::Map::new();
                    let _ = m.insert("pattern".into(), json!({"type": "string", "description": "Glob pattern to match"}));
                    let _ = m.insert("path".into(), json!({"type": "string", "description": "Directory to search in"}));
                    let _ = m.insert("type".into(), json!({"type": "string", "enum": ["file", "directory", "all"], "description": "Type filter"}));
                    let _ = m.insert("maxDepth".into(), json!({"type": "number", "description": "Maximum recursion depth"}));
                    let _ = m.insert("maxResults".into(), json!({"type": "number", "description": "Maximum number of results"}));
                    let _ = m.insert("exclude".into(), json!({"type": "array", "description": "Patterns to exclude from results", "items": {"type": "string"}}));
                    let _ = m.insert("showSize".into(), json!({"type": "boolean", "description": "Include file sizes"}));
                    let _ = m.insert("sortByTime".into(), json!({"type": "boolean", "description": "Sort by modification time (newest first)"}));
                    m
                }),
                required: Some(vec!["pattern".into()]),
                description: None,
                extra: serde_json::Map::new(),
            },
        }
    }

    async fn execute(
        &self,
        params: Value,
        ctx: &ToolContext,
    ) -> Result<TronToolResult, ToolError> {
        let pattern = match validate_required_string(&params, "pattern", "glob pattern") {
            Ok(p) => p,
            Err(e) => return Ok(e),
        };

        let search_root = get_optional_string(&params, "path")
            .map_or_else(|| resolve_path(".", &ctx.working_directory), |p| resolve_path(&p, &ctx.working_directory));

        let type_filter = get_optional_string(&params, "type").unwrap_or_else(|| "all".into());
        #[allow(clippy::cast_possible_truncation)]
        let max_depth = get_optional_u64(&params, "maxDepth").map(|v| v as usize);
        #[allow(clippy::cast_possible_truncation)]
        let max_results = get_optional_u64(&params, "maxResults").map_or(DEFAULT_MAX_RESULTS, |v| v as usize);
        let show_size = get_optional_bool(&params, "showSize").unwrap_or(false);
        let sort_by_time = get_optional_bool(&params, "sortByTime").unwrap_or(false);

        // Parse exclude patterns
        let exclude_matchers: Vec<globset::GlobMatcher> = params
            .get("exclude")
            .and_then(|v| v.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| v.as_str())
                    .filter_map(|p| {
                        globset::GlobBuilder::new(p)
                            .literal_separator(false)
                            .build()
                            .ok()
                            .map(|g| g.compile_matcher())
                    })
                    .collect()
            })
            .unwrap_or_default();

        let glob = match globset::GlobBuilder::new(&pattern).literal_separator(false).build() {
            Ok(g) => g.compile_matcher(),
            Err(e) => return Ok(error_result(format!("Invalid glob pattern: {e}"))),
        };

        let entries = collect_entries(&search_root, &glob, &exclude_matchers, &type_filter, max_depth, max_results, show_size, sort_by_time);
        let truncated = entries.len() >= max_results;

        let mut output = String::new();
        for (path, size, _) in &entries {
            if show_size {
                if let Some(s) = size {
                    let _ = writeln!(output, "{:>8}  {path}", format_size(*s));
                } else {
                    let _ = writeln!(output, "       -  {path}");
                }
            } else {
                output.push_str(path);
                output.push('\n');
            }
        }

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![
                tron_core::content::ToolResultContent::text(output),
            ]),
            details: Some(json!({
                "matchCount": entries.len(),
                "truncated": truncated,
                "searchRoot": search_root.to_string_lossy(),
            })),
            is_error: None,
            stop_turn: None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use tempfile::TempDir;

    fn make_ctx(dir: &str) -> ToolContext {
        ToolContext {
            tool_call_id: "call-1".into(),
            session_id: "sess-1".into(),
            working_directory: dir.into(),
            cancellation: tokio_util::sync::CancellationToken::new(),
            subagent_depth: 0,
            subagent_max_depth: 0,
        }
    }

    fn extract_text(result: &TronToolResult) -> String {
        match &result.content {
            ToolResultBody::Text(t) => t.clone(),
            ToolResultBody::Blocks(blocks) => blocks.iter().filter_map(|b| match b {
                tron_core::content::ToolResultContent::Text { text } => Some(text.as_str()),
                _ => None,
            }).collect::<Vec<_>>().join(""),
        }
    }

    fn setup_test_dir() -> TempDir {
        let dir = TempDir::new().unwrap();
        std::fs::write(dir.path().join("a.rs"), "fn main() {}").unwrap();
        std::fs::write(dir.path().join("b.rs"), "fn test() {}").unwrap();
        std::fs::write(dir.path().join("c.txt"), "hello").unwrap();
        std::fs::create_dir_all(dir.path().join("src")).unwrap();
        std::fs::write(dir.path().join("src/lib.rs"), "pub mod foo;").unwrap();
        std::fs::write(dir.path().join("src/test.ts"), "export {}").unwrap();
        dir
    }

    #[tokio::test]
    async fn glob_matches_rs_files() {
        let dir = setup_test_dir();
        let tool: Arc<dyn TronTool> = Arc::new(FindTool::new());
        let ctx = make_ctx(dir.path().to_str().unwrap());
        let r = tool.execute(json!({"pattern": "*.rs"}), &ctx).await.unwrap();
        let text = extract_text(&r);
        assert!(text.contains("a.rs"));
        assert!(text.contains("b.rs"));
        assert!(!text.contains("c.txt"));
    }

    #[tokio::test]
    async fn recursive_glob() {
        let dir = setup_test_dir();
        let tool = FindTool::new();
        let ctx = make_ctx(dir.path().to_str().unwrap());
        let r = tool.execute(json!({"pattern": "**/*.rs"}), &ctx).await.unwrap();
        assert!(extract_text(&r).contains("lib.rs"));
    }

    #[tokio::test]
    async fn path_parameter_sets_root() {
        let dir = setup_test_dir();
        let tool = FindTool::new();
        let ctx = make_ctx(dir.path().to_str().unwrap());
        let r = tool.execute(json!({"pattern": "*.rs", "path": "src"}), &ctx).await.unwrap();
        let text = extract_text(&r);
        assert!(text.contains("lib.rs"));
        assert!(!text.contains("a.rs"));
    }

    #[tokio::test]
    async fn type_file_excludes_dirs() {
        let dir = setup_test_dir();
        let tool = FindTool::new();
        let ctx = make_ctx(dir.path().to_str().unwrap());
        let r = tool.execute(json!({"pattern": "*", "type": "file"}), &ctx).await.unwrap();
        assert!(!extract_text(&r).contains("src\n"));
    }

    #[tokio::test]
    async fn type_directory_excludes_files() {
        let dir = setup_test_dir();
        let tool = FindTool::new();
        let ctx = make_ctx(dir.path().to_str().unwrap());
        let r = tool.execute(json!({"pattern": "*", "type": "directory"}), &ctx).await.unwrap();
        assert!(!extract_text(&r).contains("a.rs"));
    }

    #[tokio::test]
    async fn max_results_limits_output() {
        let dir = setup_test_dir();
        let tool = FindTool::new();
        let ctx = make_ctx(dir.path().to_str().unwrap());
        let r = tool.execute(json!({"pattern": "*", "maxResults": 2}), &ctx).await.unwrap();
        assert!(r.details.unwrap()["matchCount"].as_u64().unwrap() <= 2);
    }

    #[tokio::test]
    async fn empty_directory_empty_results() {
        let dir = TempDir::new().unwrap();
        let tool = FindTool::new();
        let ctx = make_ctx(dir.path().to_str().unwrap());
        let r = tool.execute(json!({"pattern": "*.xyz"}), &ctx).await.unwrap();
        assert_eq!(r.details.unwrap()["matchCount"], 0);
    }

    // ── format_size tests ──

    #[test]
    fn format_size_bytes() {
        assert_eq!(format_size(512), "512");
    }

    #[test]
    fn format_size_zero() {
        assert_eq!(format_size(0), "0");
    }

    #[test]
    fn format_size_kilobytes() {
        assert_eq!(format_size(6158), "6.0K");
    }

    #[test]
    fn format_size_exact_boundary() {
        assert_eq!(format_size(1024), "1.0K");
    }

    #[test]
    fn format_size_megabytes() {
        assert_eq!(format_size(2_500_000), "2.4M");
    }

    #[test]
    fn format_size_gigabytes() {
        assert_eq!(format_size(1_500_000_000), "1.4G");
    }

    #[tokio::test]
    async fn show_size_human_readable() {
        let dir = TempDir::new().unwrap();
        // Write a file with known content (>1K so we get "K" suffix)
        std::fs::write(dir.path().join("big.txt"), "x".repeat(6158)).unwrap();
        let tool = FindTool::new();
        let ctx = make_ctx(dir.path().to_str().unwrap());
        let r = tool.execute(json!({"pattern": "big.txt", "showSize": true}), &ctx).await.unwrap();
        let text = extract_text(&r);
        assert!(text.contains("6.0K"), "expected human-readable size, got: {text}");
    }

    #[tokio::test]
    async fn show_size_8_char_width() {
        let dir = TempDir::new().unwrap();
        std::fs::write(dir.path().join("f.txt"), "hello").unwrap();
        let tool = FindTool::new();
        let ctx = make_ctx(dir.path().to_str().unwrap());
        let r = tool.execute(json!({"pattern": "f.txt", "showSize": true}), &ctx).await.unwrap();
        let text = extract_text(&r);
        // Size field is right-aligned in 8 chars: "       5  f.txt"
        let line = text.lines().next().unwrap();
        let size_part = &line[..8];
        assert_eq!(size_part.len(), 8);
        assert!(size_part.trim().parse::<u64>().is_ok() || size_part.contains('K') || size_part.contains('M'));
    }

    #[tokio::test]
    async fn exclude_single_pattern() {
        let dir = setup_test_dir();
        let tool = FindTool::new();
        let ctx = make_ctx(dir.path().to_str().unwrap());
        let r = tool.execute(json!({"pattern": "**/*", "type": "file", "exclude": ["*.txt"]}), &ctx).await.unwrap();
        let text = extract_text(&r);
        assert!(text.contains(".rs"), "should still find .rs files");
        assert!(!text.contains("c.txt"), "should exclude .txt files");
    }

    #[tokio::test]
    async fn exclude_multiple_patterns() {
        let dir = setup_test_dir();
        let tool = FindTool::new();
        let ctx = make_ctx(dir.path().to_str().unwrap());
        let r = tool.execute(json!({"pattern": "**/*", "type": "file", "exclude": ["*.txt", "*.ts"]}), &ctx).await.unwrap();
        let text = extract_text(&r);
        assert!(text.contains(".rs"));
        assert!(!text.contains("c.txt"));
        assert!(!text.contains("test.ts"));
    }

    #[tokio::test]
    async fn exclude_empty_array_no_effect() {
        let dir = setup_test_dir();
        let tool = FindTool::new();
        let ctx = make_ctx(dir.path().to_str().unwrap());
        let r = tool.execute(json!({"pattern": "*.rs", "exclude": []}), &ctx).await.unwrap();
        let text = extract_text(&r);
        assert!(text.contains("a.rs"));
        assert!(text.contains("b.rs"));
    }

    #[tokio::test]
    async fn exclude_schema_present() {
        let tool = FindTool::new();
        let def = tool.definition();
        let props = def.parameters.properties.as_ref().unwrap();
        assert!(props.contains_key("exclude"), "schema should have exclude property");
        let exclude = &props["exclude"];
        assert_eq!(exclude["type"], "array");
        assert_eq!(exclude["items"]["type"], "string");
    }

    #[tokio::test]
    async fn hidden_directories_skipped() {
        let dir = TempDir::new().unwrap();
        std::fs::create_dir_all(dir.path().join(".hidden")).unwrap();
        std::fs::write(dir.path().join(".hidden/secret.txt"), "secret").unwrap();
        std::fs::write(dir.path().join("visible.txt"), "visible").unwrap();
        let tool = FindTool::new();
        let ctx = make_ctx(dir.path().to_str().unwrap());
        let r = tool.execute(json!({"pattern": "**/*.txt"}), &ctx).await.unwrap();
        let text = extract_text(&r);
        assert!(text.contains("visible.txt"));
        assert!(!text.contains("secret.txt"));
    }
}
