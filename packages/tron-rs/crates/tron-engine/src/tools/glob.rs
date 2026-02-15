use async_trait::async_trait;
use std::path::{Path, PathBuf};
use std::time::Instant;
use tron_core::tools::{ContentType, ExecutionMode, Tool, ToolContext, ToolError, ToolResult};

pub struct GlobTool;

#[async_trait]
impl Tool for GlobTool {
    fn name(&self) -> &str {
        "Glob"
    }

    fn description(&self) -> &str {
        "Find files matching a glob pattern"
    }

    fn parameters_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "required": ["pattern"],
            "properties": {
                "pattern": {
                    "type": "string",
                    "description": "Glob pattern (e.g. '**/*.rs', 'src/**/*.ts')"
                },
                "path": {
                    "type": "string",
                    "description": "Directory to search in (defaults to working directory)"
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

        let base_dir = match args["path"].as_str() {
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

        let full_pattern = base_dir.join(pattern);
        let pattern_str = full_pattern.to_string_lossy().to_string();

        // Run glob in blocking task to avoid blocking the async runtime
        let matches = tokio::task::spawn_blocking(move || {
            glob_match(&pattern_str)
        })
        .await
        .map_err(|e| ToolError::ExecutionFailed(format!("Glob task failed: {e}")))?;

        if matches.is_empty() {
            return Ok(ToolResult {
                content: "No files matched the pattern.".into(),
                is_error: false,
                content_type: ContentType::Text,
                duration: start.elapsed(),
            });
        }

        // Sort by modification time (most recent first), fall back to name sort
        let mut sorted = matches;
        sorted.sort();

        let output = sorted
            .iter()
            .map(|p| p.display().to_string())
            .collect::<Vec<_>>()
            .join("\n");

        Ok(ToolResult {
            content: format!("{} file(s) matched:\n{}", sorted.len(), output),
            is_error: false,
            content_type: ContentType::Text,
            duration: start.elapsed(),
        })
    }
}

/// Simple glob matching using walkdir + pattern matching.
fn glob_match(pattern: &str) -> Vec<PathBuf> {
    let mut results = Vec::new();

    // Use the glob crate if available, otherwise do a simple walk
    // For now, use std::fs for a basic implementation
    if let Ok(entries) = glob::glob(pattern) {
        for entry in entries.flatten() {
            results.push(entry);
        }
    }

    results
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
    async fn glob_finds_files() {
        let dir = std::env::temp_dir().join(format!("tron_glob_{}", uuid::Uuid::now_v7()));
        fs::create_dir_all(dir.join("src")).unwrap();
        fs::write(dir.join("src/main.rs"), "fn main() {}").unwrap();
        fs::write(dir.join("src/lib.rs"), "pub mod foo;").unwrap();
        fs::write(dir.join("README.md"), "# README").unwrap();

        let tool = GlobTool;
        let result = tool
            .execute(serde_json::json!({"pattern": "src/*.rs"}), &test_ctx(&dir))
            .await
            .unwrap();

        assert!(!result.is_error);
        assert!(result.content.contains("2 file(s) matched"));
        assert!(result.content.contains("main.rs"));
        assert!(result.content.contains("lib.rs"));

        fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn glob_recursive() {
        let dir = std::env::temp_dir().join(format!("tron_glob_{}", uuid::Uuid::now_v7()));
        fs::create_dir_all(dir.join("a/b")).unwrap();
        fs::write(dir.join("a/one.txt"), "1").unwrap();
        fs::write(dir.join("a/b/two.txt"), "2").unwrap();

        let tool = GlobTool;
        let result = tool
            .execute(serde_json::json!({"pattern": "**/*.txt"}), &test_ctx(&dir))
            .await
            .unwrap();

        assert!(result.content.contains("2 file(s) matched"));

        fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn glob_no_matches() {
        let dir = std::env::temp_dir().join(format!("tron_glob_{}", uuid::Uuid::now_v7()));
        fs::create_dir_all(&dir).unwrap();

        let tool = GlobTool;
        let result = tool
            .execute(serde_json::json!({"pattern": "*.xyz"}), &test_ctx(&dir))
            .await
            .unwrap();

        assert!(!result.is_error);
        assert!(result.content.contains("No files matched"));

        fs::remove_dir_all(&dir).ok();
    }
}
