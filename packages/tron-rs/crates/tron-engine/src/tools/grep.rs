use async_trait::async_trait;
use std::path::Path;
use std::time::Instant;
use tron_core::tools::{ContentType, ExecutionMode, Tool, ToolContext, ToolError, ToolResult};

pub struct GrepTool;

#[async_trait]
impl Tool for GrepTool {
    fn name(&self) -> &str {
        "Grep"
    }

    fn description(&self) -> &str {
        "Search file contents using regex patterns"
    }

    fn parameters_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "required": ["pattern"],
            "properties": {
                "pattern": {
                    "type": "string",
                    "description": "Regex pattern to search for"
                },
                "path": {
                    "type": "string",
                    "description": "File or directory to search in"
                },
                "glob": {
                    "type": "string",
                    "description": "Glob pattern to filter files (e.g. '*.rs')"
                },
                "output_mode": {
                    "type": "string",
                    "enum": ["content", "files_with_matches", "count"],
                    "description": "Output mode (default: files_with_matches)"
                },
                "head_limit": {
                    "type": "integer",
                    "description": "Limit output to first N results"
                }
            }
        })
    }

    fn execution_mode(&self) -> ExecutionMode {
        ExecutionMode::Concurrent
    }

    async fn execute(
        &self,
        args: serde_json::Value,
        ctx: &ToolContext,
    ) -> Result<ToolResult, ToolError> {
        let start = Instant::now();

        let pattern = args["pattern"]
            .as_str()
            .ok_or_else(|| ToolError::InvalidArguments("pattern is required".into()))?;

        let search_path = match args["path"].as_str() {
            Some(p) => {
                let path = Path::new(p);
                if path.is_absolute() {
                    path.to_path_buf()
                } else {
                    ctx.working_directory.join(path)
                }
            }
            None => ctx.working_directory.clone(),
        };

        let glob_filter = args["glob"].as_str().map(String::from);
        let output_mode = args["output_mode"].as_str().unwrap_or("files_with_matches");
        let head_limit = args["head_limit"].as_u64().unwrap_or(0) as usize;

        let regex = regex::Regex::new(pattern)
            .map_err(|e| ToolError::InvalidArguments(format!("Invalid regex: {e}")))?;

        let search_path_clone = search_path.clone();
        let results = tokio::task::spawn_blocking(move || {
            search_files(&search_path_clone, &regex, glob_filter.as_deref())
        })
        .await
        .map_err(|e| ToolError::ExecutionFailed(format!("Search task failed: {e}")))?;

        let output = format_results(&results, output_mode, head_limit);

        Ok(ToolResult {
            content: output,
            is_error: false,
            content_type: ContentType::Text,
            duration: start.elapsed(),
        })
    }
}

#[derive(Debug)]
struct SearchMatch {
    file: String,
    line_number: usize,
    line_content: String,
}

fn search_files(
    path: &Path,
    regex: &regex::Regex,
    glob_filter: Option<&str>,
) -> Vec<SearchMatch> {
    let mut results = Vec::new();

    if path.is_file() {
        search_single_file(path, regex, &mut results);
    } else if path.is_dir() {
        walk_and_search(path, regex, glob_filter, &mut results);
    }

    results
}

fn search_single_file(path: &Path, regex: &regex::Regex, results: &mut Vec<SearchMatch>) {
    let content = match std::fs::read_to_string(path) {
        Ok(c) => c,
        Err(_) => return, // Skip binary/unreadable files
    };

    for (i, line) in content.lines().enumerate() {
        if regex.is_match(line) {
            results.push(SearchMatch {
                file: path.display().to_string(),
                line_number: i + 1,
                line_content: line.to_string(),
            });
        }
    }
}

fn walk_and_search(
    dir: &Path,
    regex: &regex::Regex,
    glob_filter: Option<&str>,
    results: &mut Vec<SearchMatch>,
) {
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return,
    };

    for entry in entries.flatten() {
        let path = entry.path();
        let name = path
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("");

        // Skip hidden dirs and common large dirs
        if path.is_dir() {
            if name.starts_with('.')
                || name == "node_modules"
                || name == "target"
                || name == "dist"
                || name == "build"
                || name == "__pycache__"
                || name == "vendor"
            {
                continue;
            }
            walk_and_search(&path, regex, glob_filter, results);
        } else if path.is_file() {
            // Apply glob filter
            if let Some(filter) = glob_filter {
                if !matches_glob_filter(name, filter) {
                    continue;
                }
            }
            search_single_file(&path, regex, results);
        }
    }
}

fn matches_glob_filter(filename: &str, filter: &str) -> bool {
    if let Some(ext) = filter.strip_prefix("*.") {
        filename.ends_with(&format!(".{ext}"))
    } else {
        filename == filter
    }
}

fn format_results(results: &[SearchMatch], mode: &str, limit: usize) -> String {
    if results.is_empty() {
        return "No matches found.".to_string();
    }

    match mode {
        "content" => {
            let items: Vec<String> = results
                .iter()
                .take(if limit > 0 { limit } else { results.len() })
                .map(|m| format!("{}:{}:{}", m.file, m.line_number, m.line_content))
                .collect();
            items.join("\n")
        }
        "count" => {
            let mut counts: std::collections::HashMap<&str, usize> = std::collections::HashMap::new();
            for m in results {
                *counts.entry(&m.file).or_default() += 1;
            }
            let mut items: Vec<String> = counts
                .iter()
                .map(|(f, c)| format!("{f}:{c}"))
                .collect();
            items.sort();
            if limit > 0 {
                items.truncate(limit);
            }
            items.join("\n")
        }
        _ => {
            // files_with_matches (default)
            let mut files: Vec<&str> = results.iter().map(|m| m.file.as_str()).collect();
            files.sort();
            files.dedup();
            if limit > 0 {
                files.truncate(limit);
            }
            files.join("\n")
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tron_core::ids::{AgentId, SessionId};
    use tokio_util::sync::CancellationToken;

    fn test_ctx(dir: &Path) -> ToolContext {
        ToolContext {
            session_id: SessionId::new(),
            working_directory: dir.to_path_buf(),
            agent_id: AgentId::new(),
            parent_agent_id: None,
            abort_signal: CancellationToken::new(),
        }
    }

    #[tokio::test]
    async fn grep_finds_matches() {
        let dir = std::env::temp_dir().join(format!("tron_grep_{}", uuid::Uuid::now_v7()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("a.rs"), "fn hello() {}\nfn world() {}").unwrap();
        fs::write(dir.join("b.rs"), "fn goodbye() {}").unwrap();

        let tool = GrepTool;
        let result = tool
            .execute(
                serde_json::json!({"pattern": "fn hello", "output_mode": "content"}),
                &test_ctx(&dir),
            )
            .await
            .unwrap();

        assert!(!result.is_error);
        assert!(result.content.contains("fn hello"));

        fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn grep_files_with_matches() {
        let dir = std::env::temp_dir().join(format!("tron_grep_{}", uuid::Uuid::now_v7()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("a.rs"), "fn hello() {}").unwrap();
        fs::write(dir.join("b.rs"), "fn world() {}").unwrap();

        let tool = GrepTool;
        let result = tool
            .execute(
                serde_json::json!({"pattern": "fn", "output_mode": "files_with_matches"}),
                &test_ctx(&dir),
            )
            .await
            .unwrap();

        assert!(result.content.contains("a.rs"));
        assert!(result.content.contains("b.rs"));

        fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn grep_with_glob_filter() {
        let dir = std::env::temp_dir().join(format!("tron_grep_{}", uuid::Uuid::now_v7()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("a.rs"), "hello").unwrap();
        fs::write(dir.join("b.txt"), "hello").unwrap();

        let tool = GrepTool;
        let result = tool
            .execute(
                serde_json::json!({"pattern": "hello", "glob": "*.rs"}),
                &test_ctx(&dir),
            )
            .await
            .unwrap();

        assert!(result.content.contains("a.rs"));
        assert!(!result.content.contains("b.txt"));

        fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn grep_no_matches() {
        let dir = std::env::temp_dir().join(format!("tron_grep_{}", uuid::Uuid::now_v7()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("a.rs"), "fn main() {}").unwrap();

        let tool = GrepTool;
        let result = tool
            .execute(
                serde_json::json!({"pattern": "nonexistent_pattern"}),
                &test_ctx(&dir),
            )
            .await
            .unwrap();

        assert!(result.content.contains("No matches"));

        fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn grep_invalid_regex() {
        let dir = std::env::temp_dir();
        let tool = GrepTool;
        let result = tool
            .execute(
                serde_json::json!({"pattern": "[invalid"}),
                &test_ctx(&dir),
            )
            .await;

        assert!(result.is_err());
    }
}
