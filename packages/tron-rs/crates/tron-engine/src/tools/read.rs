use async_trait::async_trait;
use std::time::Instant;
use tron_core::tools::{ContentType, ExecutionMode, Tool, ToolContext, ToolError, ToolResult};

pub struct ReadTool;

#[async_trait]
impl Tool for ReadTool {
    fn name(&self) -> &str {
        "Read"
    }

    fn description(&self) -> &str {
        "Read file contents from the filesystem"
    }

    fn parameters_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "required": ["file_path"],
            "properties": {
                "file_path": {
                    "type": "string",
                    "description": "Absolute path to the file to read"
                },
                "offset": {
                    "type": "integer",
                    "description": "Line number to start reading from (1-based)"
                },
                "limit": {
                    "type": "integer",
                    "description": "Maximum number of lines to read"
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

        let file_path = args["file_path"]
            .as_str()
            .ok_or_else(|| ToolError::InvalidArguments("file_path is required".into()))?;

        let path = resolve_path(file_path, &ctx.working_directory);

        let content = tokio::fs::read_to_string(&path)
            .await
            .map_err(|e| ToolError::ExecutionFailed(format!("Failed to read {}: {}", path.display(), e)))?;

        let offset = args["offset"].as_u64().unwrap_or(1).max(1) as usize;
        let limit = args["limit"].as_u64().unwrap_or(2000) as usize;

        let lines: Vec<&str> = content.lines().collect();
        let start_idx = (offset - 1).min(lines.len());
        let end_idx = (start_idx + limit).min(lines.len());

        let mut output = String::new();
        for (i, line) in lines[start_idx..end_idx].iter().enumerate() {
            let line_num = start_idx + i + 1;
            let truncated = if line.len() > 2000 {
                &line[..2000]
            } else {
                line
            };
            output.push_str(&format!("{:>6}\t{}\n", line_num, truncated));
        }

        if output.is_empty() {
            output = "(empty file)".to_string();
        }

        Ok(ToolResult {
            content: output,
            is_error: false,
            content_type: ContentType::Text,
            duration: start.elapsed(),
        })
    }
}

fn resolve_path(file_path: &str, working_dir: &std::path::Path) -> std::path::PathBuf {
    let path = std::path::Path::new(file_path);
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        working_dir.join(path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tron_core::ids::{AgentId, SessionId};
    use tokio_util::sync::CancellationToken;

    fn test_ctx(dir: &std::path::Path) -> ToolContext {
        ToolContext {
            session_id: SessionId::new(),
            working_directory: dir.to_path_buf(),
            agent_id: AgentId::new(),
            parent_agent_id: None,
            abort_signal: CancellationToken::new(),
        }
    }

    #[tokio::test]
    async fn read_file() {
        let dir = std::env::temp_dir().join(format!("tron_read_{}", uuid::Uuid::now_v7()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("test.txt"), "line 1\nline 2\nline 3\n").unwrap();

        let tool = ReadTool;
        let result = tool
            .execute(
                serde_json::json!({"file_path": dir.join("test.txt").to_str().unwrap()}),
                &test_ctx(&dir),
            )
            .await
            .unwrap();

        assert!(!result.is_error);
        assert!(result.content.contains("line 1"));
        assert!(result.content.contains("line 2"));
        assert!(result.content.contains("line 3"));

        fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn read_with_offset_and_limit() {
        let dir = std::env::temp_dir().join(format!("tron_read_{}", uuid::Uuid::now_v7()));
        fs::create_dir_all(&dir).unwrap();
        let content: String = (1..=10).map(|i| format!("line {i}\n")).collect();
        fs::write(dir.join("test.txt"), &content).unwrap();

        let tool = ReadTool;
        let result = tool
            .execute(
                serde_json::json!({"file_path": dir.join("test.txt").to_str().unwrap(), "offset": 3, "limit": 2}),
                &test_ctx(&dir),
            )
            .await
            .unwrap();

        assert!(result.content.contains("line 3"));
        assert!(result.content.contains("line 4"));
        assert!(!result.content.contains("line 5"));

        fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn read_nonexistent_file() {
        let dir = std::env::temp_dir();
        let tool = ReadTool;
        let result = tool
            .execute(
                serde_json::json!({"file_path": "/nonexistent/file.txt"}),
                &test_ctx(&dir),
            )
            .await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn read_relative_path() {
        let dir = std::env::temp_dir().join(format!("tron_read_{}", uuid::Uuid::now_v7()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("relative.txt"), "content").unwrap();

        let tool = ReadTool;
        let result = tool
            .execute(
                serde_json::json!({"file_path": "relative.txt"}),
                &test_ctx(&dir),
            )
            .await
            .unwrap();

        assert!(result.content.contains("content"));

        fs::remove_dir_all(&dir).ok();
    }
}
