//! `Write` tool — creates or overwrites files.
//!
//! Auto-creates parent directories. Reports byte count, whether the file
//! was newly created or overwritten.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};
use tron_core::tools::{Tool, ToolCategory, TronToolResult, text_result};

use crate::errors::ToolError;
use crate::traits::{FileSystemOps, ToolContext, TronTool};
use crate::utils::schema::ToolSchemaBuilder;
use crate::utils::fs_errors::format_fs_error;
use crate::utils::path::resolve_path;
use crate::utils::validation::{validate_path_not_root, validate_required_string};

const MAX_CONTENT_SIZE: usize = 50 * 1024 * 1024; // 50 MB

/// The `Write` tool creates or overwrites files.
pub struct WriteTool {
    fs: Arc<dyn FileSystemOps>,
}

impl WriteTool {
    /// Create a new `Write` tool with the given filesystem.
    pub fn new(fs: Arc<dyn FileSystemOps>) -> Self {
        Self { fs }
    }
}

#[async_trait]
impl TronTool for WriteTool {
    fn name(&self) -> &str {
        "Write"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Filesystem
    }

    fn definition(&self) -> Tool {
        ToolSchemaBuilder::new(
            "Write",
            "Write content to a file. Creates parent directories if they do not exist.",
        )
        .required_property("file_path", json!({"type": "string", "description": "The path to the file to write"}))
        .required_property("content", json!({"type": "string", "description": "The content to write to the file"}))
        .build()
    }

    async fn execute(&self, params: Value, ctx: &ToolContext) -> Result<TronToolResult, ToolError> {
        let file_path = match validate_required_string(&params, "file_path", "path to the file") {
            Ok(p) => p,
            Err(e) => return Ok(e),
        };

        if let Err(e) = validate_path_not_root(&file_path, "file_path") {
            return Ok(e);
        }

        let content = match params.get("content") {
            Some(Value::String(s)) => s.clone(),
            Some(Value::Null) | None => {
                return Ok(text_result(
                    "Missing required parameter: content (the content to write)",
                    true,
                ));
            }
            _ => {
                return Ok(text_result(
                    "Invalid type for parameter: content (expected string)",
                    true,
                ));
            }
        };

        if content.len() > MAX_CONTENT_SIZE {
            return Ok(text_result(
                format!(
                    "Content too large: {} bytes (max {} MB)",
                    content.len(),
                    MAX_CONTENT_SIZE / 1024 / 1024
                ),
                true,
            ));
        }

        let resolved = resolve_path(&file_path, &ctx.working_directory);
        let existed = self.fs.exists(&resolved);

        // Create parent directories
        if let Some(parent) = resolved.parent() {
            if let Err(e) = self.fs.create_dir_all(parent).await {
                return Ok(format_fs_error(
                    &e,
                    &parent.to_string_lossy(),
                    "creating directory",
                ));
            }
        }

        let bytes = content.as_bytes();
        if let Err(e) = self.fs.write_file(&resolved, bytes).await {
            return Ok(format_fs_error(&e, &resolved.to_string_lossy(), "writing"));
        }

        let bytes_written = bytes.len();
        let message = if existed {
            format!(
                "Wrote {} bytes to {} (overwritten)",
                bytes_written,
                resolved.display()
            )
        } else {
            format!(
                "Wrote {} bytes to {} (created)",
                bytes_written,
                resolved.display()
            )
        };

        let details = json!({
            "filePath": resolved.to_string_lossy(),
            "bytesWritten": bytes_written,
            "created": !existed,
        });

        Ok(TronToolResult {
            content: tron_core::tools::ToolResultBody::Blocks(vec![
                tron_core::content::ToolResultContent::text(message),
            ]),
            details: Some(details),
            is_error: None,
            stop_turn: None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    use crate::testutil::{extract_text, make_ctx, MockFs};

    #[tokio::test]
    async fn create_new_file() {
        let fs = Arc::new(MockFs::new());
        let tool = WriteTool::new(fs.clone());
        let result = tool
            .execute(
                json!({"file_path": "/tmp/new.txt", "content": "hello"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(result.is_error.is_none());
        let details = result.details.unwrap();
        assert_eq!(details["bytesWritten"], 5);
        assert!(details["created"].as_bool().unwrap());
    }

    #[tokio::test]
    async fn overwrite_existing_file() {
        let fs = Arc::new(MockFs::new().with_file("/tmp/exist.txt", b"old".to_vec()));
        let tool = WriteTool::new(fs);
        let result = tool
            .execute(
                json!({"file_path": "/tmp/exist.txt", "content": "new content"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        let text = extract_text(&result);
        let details = result.details.unwrap();
        assert!(!details["created"].as_bool().unwrap());
        assert!(text.contains("overwritten"));
    }

    #[tokio::test]
    async fn empty_content() {
        let fs = Arc::new(MockFs::new());
        let tool = WriteTool::new(fs);
        let result = tool
            .execute(
                json!({"file_path": "/tmp/empty.txt", "content": ""}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(result.is_error.is_none());
        let details = result.details.unwrap();
        assert_eq!(details["bytesWritten"], 0);
    }

    #[tokio::test]
    async fn missing_file_path() {
        let fs = Arc::new(MockFs::new());
        let tool = WriteTool::new(fs);
        let result = tool
            .execute(json!({"content": "hello"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(true));
    }

    #[tokio::test]
    async fn missing_content() {
        let fs = Arc::new(MockFs::new());
        let tool = WriteTool::new(fs);
        let result = tool
            .execute(json!({"file_path": "/tmp/test.txt"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(true));
    }

    #[tokio::test]
    async fn root_path_blocked() {
        let fs = Arc::new(MockFs::new());
        let tool = WriteTool::new(fs);
        let result = tool
            .execute(json!({"file_path": "/", "content": "hack"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(true));
    }

    #[tokio::test]
    async fn relative_path_resolved() {
        let fs = Arc::new(MockFs::new());
        let tool = WriteTool::new(fs.clone());
        let result = tool
            .execute(
                json!({"file_path": "sub/file.txt", "content": "data"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(result.is_error.is_none());
        // Check the file was written at resolved path
        assert!(fs.exists(Path::new("/tmp/sub/file.txt")));
    }

    #[tokio::test]
    async fn utf8_special_chars() {
        let fs = Arc::new(MockFs::new());
        let tool = WriteTool::new(fs);
        let content = "caf\u{00E9} \u{1F600} \u{4E16}\u{754C}";
        let result = tool
            .execute(
                json!({"file_path": "/tmp/utf8.txt", "content": content}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(result.is_error.is_none());
        let details = result.details.unwrap();
        assert_eq!(details["bytesWritten"], content.len());
    }

    #[tokio::test]
    async fn details_include_file_path() {
        let fs = Arc::new(MockFs::new());
        let tool = WriteTool::new(fs);
        let result = tool
            .execute(
                json!({"file_path": "/tmp/test.txt", "content": "hi"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        let details = result.details.unwrap();
        assert_eq!(details["filePath"], "/tmp/test.txt");
    }

    #[tokio::test]
    async fn write_rejects_content_over_50mb() {
        let fs = Arc::new(MockFs::new());
        let content = "x".repeat(MAX_CONTENT_SIZE + 1);
        let tool = WriteTool::new(fs);
        let result = tool
            .execute(
                json!({"file_path": "/tmp/huge.txt", "content": content}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(true));
        assert!(extract_text(&result).contains("too large"));
    }

    #[tokio::test]
    async fn write_allows_content_at_exactly_50mb() {
        let fs = Arc::new(MockFs::new());
        let content = "a".repeat(MAX_CONTENT_SIZE);
        let tool = WriteTool::new(fs);
        let result = tool
            .execute(
                json!({"file_path": "/tmp/at_limit.txt", "content": content}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(result.is_error.is_none());
    }

    #[tokio::test]
    async fn large_content() {
        let fs = Arc::new(MockFs::new());
        let tool = WriteTool::new(fs);
        let content = "x".repeat(100_000);
        let result = tool
            .execute(
                json!({"file_path": "/tmp/large.txt", "content": content}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(result.is_error.is_none());
        let details = result.details.unwrap();
        assert_eq!(details["bytesWritten"], 100_000);
    }
}
