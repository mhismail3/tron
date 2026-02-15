use async_trait::async_trait;
use std::time::Instant;
use tron_core::tools::{ContentType, ExecutionMode, Tool, ToolContext, ToolError, ToolResult};

pub struct EditTool;

#[async_trait]
impl Tool for EditTool {
    fn name(&self) -> &str {
        "Edit"
    }

    fn description(&self) -> &str {
        "Perform exact string replacement in a file"
    }

    fn parameters_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "required": ["file_path", "old_string", "new_string"],
            "properties": {
                "file_path": {
                    "type": "string",
                    "description": "Absolute path to the file to edit"
                },
                "old_string": {
                    "type": "string",
                    "description": "The exact string to find and replace"
                },
                "new_string": {
                    "type": "string",
                    "description": "The replacement string"
                },
                "replace_all": {
                    "type": "boolean",
                    "description": "Replace all occurrences (default: false)"
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
        let old_string = args["old_string"]
            .as_str()
            .ok_or_else(|| ToolError::InvalidArguments("old_string is required".into()))?;
        let new_string = args["new_string"]
            .as_str()
            .ok_or_else(|| ToolError::InvalidArguments("new_string is required".into()))?;
        let replace_all = args["replace_all"].as_bool().unwrap_or(false);

        let path = resolve_path(file_path, &ctx.working_directory);

        let content = tokio::fs::read_to_string(&path)
            .await
            .map_err(|e| ToolError::ExecutionFailed(format!("Failed to read {}: {e}", path.display())))?;

        if old_string == new_string {
            return Err(ToolError::InvalidArguments(
                "old_string and new_string must be different".into(),
            ));
        }

        let (new_content, count) = if replace_all {
            let count = content.matches(old_string).count();
            if count == 0 {
                return Err(ToolError::ExecutionFailed(
                    "old_string not found in file".into(),
                ));
            }
            (content.replace(old_string, new_string), count)
        } else {
            let count = content.matches(old_string).count();
            if count == 0 {
                return Err(ToolError::ExecutionFailed(
                    "old_string not found in file".into(),
                ));
            }
            if count > 1 {
                return Err(ToolError::ExecutionFailed(format!(
                    "old_string is not unique in the file ({count} occurrences). Use replace_all or provide more context."
                )));
            }
            (content.replacen(old_string, new_string, 1), 1)
        };

        tokio::fs::write(&path, &new_content)
            .await
            .map_err(|e| ToolError::ExecutionFailed(format!("Failed to write {}: {e}", path.display())))?;

        Ok(ToolResult {
            content: format!("Replaced {count} occurrence(s) in {}", path.display()),
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
    async fn edit_single_replacement() {
        let dir = std::env::temp_dir().join(format!("tron_edit_{}", uuid::Uuid::now_v7()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("test.rs"), "fn hello() {\n    println!(\"hello\");\n}\n").unwrap();

        let tool = EditTool;
        let result = tool
            .execute(
                serde_json::json!({
                    "file_path": dir.join("test.rs").to_str().unwrap(),
                    "old_string": "hello",
                    "new_string": "world"
                }),
                &test_ctx(&dir),
            )
            .await;

        // "hello" appears twice — should fail (not unique)
        assert!(result.is_err());
        let err = result.unwrap_err().to_string();
        assert!(err.contains("not unique"));

        fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn edit_unique_string() {
        let dir = std::env::temp_dir().join(format!("tron_edit_{}", uuid::Uuid::now_v7()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("test.rs"), "fn main() {\n    println!(\"hello\");\n}\n").unwrap();

        let tool = EditTool;
        let result = tool
            .execute(
                serde_json::json!({
                    "file_path": dir.join("test.rs").to_str().unwrap(),
                    "old_string": "fn main()",
                    "new_string": "fn start()"
                }),
                &test_ctx(&dir),
            )
            .await
            .unwrap();

        assert!(!result.is_error);
        let content = fs::read_to_string(dir.join("test.rs")).unwrap();
        assert!(content.contains("fn start()"));
        assert!(!content.contains("fn main()"));

        fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn edit_replace_all() {
        let dir = std::env::temp_dir().join(format!("tron_edit_{}", uuid::Uuid::now_v7()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("test.txt"), "foo bar foo baz foo").unwrap();

        let tool = EditTool;
        let result = tool
            .execute(
                serde_json::json!({
                    "file_path": dir.join("test.txt").to_str().unwrap(),
                    "old_string": "foo",
                    "new_string": "qux",
                    "replace_all": true
                }),
                &test_ctx(&dir),
            )
            .await
            .unwrap();

        assert!(result.content.contains("3 occurrence"));
        let content = fs::read_to_string(dir.join("test.txt")).unwrap();
        assert_eq!(content, "qux bar qux baz qux");

        fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn edit_not_found() {
        let dir = std::env::temp_dir().join(format!("tron_edit_{}", uuid::Uuid::now_v7()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("test.txt"), "hello world").unwrap();

        let tool = EditTool;
        let result = tool
            .execute(
                serde_json::json!({
                    "file_path": dir.join("test.txt").to_str().unwrap(),
                    "old_string": "nonexistent",
                    "new_string": "replacement"
                }),
                &test_ctx(&dir),
            )
            .await;

        assert!(result.is_err());

        fs::remove_dir_all(&dir).ok();
    }

    #[tokio::test]
    async fn edit_same_string_rejected() {
        let dir = std::env::temp_dir().join(format!("tron_edit_{}", uuid::Uuid::now_v7()));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("test.txt"), "hello").unwrap();

        let tool = EditTool;
        let result = tool
            .execute(
                serde_json::json!({
                    "file_path": dir.join("test.txt").to_str().unwrap(),
                    "old_string": "hello",
                    "new_string": "hello"
                }),
                &test_ctx(&dir),
            )
            .await;

        assert!(result.is_err());

        fs::remove_dir_all(&dir).ok();
    }
}
