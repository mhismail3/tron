use async_trait::async_trait;
use std::time::Instant;
use tron_core::tools::{ContentType, ExecutionMode, Tool, ToolContext, ToolError, ToolResult};

pub struct WriteTool;

#[async_trait]
impl Tool for WriteTool {
    fn name(&self) -> &str {
        "Write"
    }

    fn description(&self) -> &str {
        "Write content to a file on the filesystem"
    }

    fn parameters_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "required": ["file_path", "content"],
            "properties": {
                "file_path": {
                    "type": "string",
                    "description": "Absolute path to the file to write"
                },
                "content": {
                    "type": "string",
                    "description": "Content to write to the file"
                }
            }
        })
    }

    fn execution_mode(&self) -> ExecutionMode {
        ExecutionMode::Sequential
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
        let content = args["content"]
            .as_str()
            .ok_or_else(|| ToolError::InvalidArguments("content is required".into()))?;

        let path = resolve_path(file_path, &ctx.working_directory);

        // Ensure parent directory exists
        if let Some(parent) = path.parent() {
            tokio::fs::create_dir_all(parent)
                .await
                .map_err(|e| ToolError::ExecutionFailed(format!("Failed to create directory: {e}")))?;
        }

        tokio::fs::write(&path, content)
            .await
            .map_err(|e| ToolError::ExecutionFailed(format!("Failed to write {}: {e}", path.display())))?;

        let line_count = content.lines().count();
        Ok(ToolResult {
            content: format!(
                "Wrote {} bytes ({} lines) to {}",
                content.len(),
                line_count,
                path.display()
            ),
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
    async fn write_new_file() {
        let dir = std::env::temp_dir().join(format!("tron_write_{}", uuid::Uuid::now_v7()));
        fs::create_dir_all(&dir).unwrap();

        let tool = WriteTool;
        let result = tool
            .execute(
                serde_json::json!({
                    "file_path": dir.join("output.txt").to_str().unwrap(),
                    "content": "hello world\n"
                }),
                &test_ctx(&dir),
            )
            .await
            .unwrap();

        assert!(!result.is_error);
        assert!(result.content.contains("12 bytes"));
        assert_eq!(fs::read_to_string(dir.join("output.txt")).unwrap(), "hello world\n");

        fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn write_creates_parent_dirs() {
        let dir = std::env::temp_dir().join(format!("tron_write_{}", uuid::Uuid::now_v7()));

        let tool = WriteTool;
        let result = tool
            .execute(
                serde_json::json!({
                    "file_path": dir.join("a/b/c/file.txt").to_str().unwrap(),
                    "content": "nested"
                }),
                &test_ctx(&dir),
            )
            .await
            .unwrap();

        assert!(!result.is_error);
        assert_eq!(fs::read_to_string(dir.join("a/b/c/file.txt")).unwrap(), "nested");

        fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn write_overwrites_existing() {
        let dir = std::env::temp_dir().join(format!("tron_write_{}", uuid::Uuid::now_v7()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("existing.txt"), "old content").unwrap();

        let tool = WriteTool;
        tool.execute(
            serde_json::json!({
                "file_path": dir.join("existing.txt").to_str().unwrap(),
                "content": "new content"
            }),
            &test_ctx(&dir),
        )
        .await
        .unwrap();

        assert_eq!(fs::read_to_string(dir.join("existing.txt")).unwrap(), "new content");

        fs::remove_dir_all(&dir).ok();
    }
}
