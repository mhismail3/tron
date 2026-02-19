//! `Edit` tool — exact string replacement with diff output.
//!
//! Finds an exact substring in a file and replaces it. Returns a unified diff
//! showing the change. Supports `replace_all` for multiple occurrences.

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{Value, json};
use tron_core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult, error_result};

use crate::errors::ToolError;
use crate::traits::{FileSystemOps, ToolContext, TronTool};
use crate::utils::schema::ToolSchemaBuilder;
use crate::utils::diff::generate_unified_diff;
use crate::utils::fs_errors::format_fs_error;
use crate::utils::path::resolve_path;
use crate::utils::validation::validate_required_string;

const MAX_FILE_SIZE: usize = 50 * 1024 * 1024; // 50 MB

/// The `Edit` tool performs exact string replacement in files.
pub struct EditTool {
    fs: Arc<dyn FileSystemOps>,
}

impl EditTool {
    /// Create a new `Edit` tool with the given filesystem.
    pub fn new(fs: Arc<dyn FileSystemOps>) -> Self {
        Self { fs }
    }
}

fn truncate_preview(s: &str, max_len: usize) -> String {
    // max_len is the body limit; total output may be up to max_len + suffix.
    let total = max_len.saturating_add(3);
    tron_core::text::truncate_with_suffix(s, total, "...")
}

#[async_trait]
impl TronTool for EditTool {
    fn name(&self) -> &str {
        "Edit"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Filesystem
    }

    fn definition(&self) -> Tool {
        ToolSchemaBuilder::new(
            "Edit",
            "Edit a file by replacing old_string with new_string. Requires exact match.",
        )
        .required_property("file_path", json!({"type": "string", "description": "The path to the file to edit"}))
        .required_property("old_string", json!({"type": "string", "description": "The exact string to find and replace"}))
        .required_property("new_string", json!({"type": "string", "description": "The replacement string"}))
        .property("replace_all", json!({"type": "boolean", "description": "Replace all occurrences (default: false)"}))
        .build()
    }

    async fn execute(&self, params: Value, ctx: &ToolContext) -> Result<TronToolResult, ToolError> {
        let file_path = match validate_required_string(&params, "file_path", "path to the file") {
            Ok(p) => p,
            Err(e) => return Ok(e),
        };

        let old_string = match params.get("old_string") {
            Some(Value::String(s)) => s.clone(),
            _ => {
                return Ok(error_result(
                    "Missing required parameter: old_string (the string to find)",
                ));
            }
        };

        let new_string = match params.get("new_string") {
            Some(Value::String(s)) => s.clone(),
            _ => {
                return Ok(error_result(
                    "Missing required parameter: new_string (the replacement string)",
                ));
            }
        };

        if old_string.is_empty() {
            return Ok(error_result("old_string must not be empty"));
        }

        if old_string == new_string {
            return Ok(error_result(
                "old_string and new_string are identical — no changes would be made",
            ));
        }

        let replace_all = params
            .get("replace_all")
            .and_then(Value::as_bool)
            .unwrap_or(false);

        let resolved = resolve_path(&file_path, &ctx.working_directory);

        // Pre-read metadata size check (fail-open: if metadata() errors, proceed)
        if let Ok(meta) = self.fs.metadata(&resolved).await {
            #[allow(clippy::cast_possible_truncation)]
            let file_size = meta.len() as usize;
            if file_size > MAX_FILE_SIZE {
                return Ok(error_result(format!(
                    "File too large to edit: {} bytes (max {} MB)",
                    file_size,
                    MAX_FILE_SIZE / 1024 / 1024
                )));
            }
        }

        // Read the file
        let bytes = match self.fs.read_file(&resolved).await {
            Ok(b) => b,
            Err(e) => return Ok(format_fs_error(&e, &resolved.to_string_lossy(), "reading")),
        };

        // Post-read size check (hard limit)
        if bytes.len() > MAX_FILE_SIZE {
            return Ok(error_result(format!(
                "File too large to edit: {} bytes (max {} MB)",
                bytes.len(),
                MAX_FILE_SIZE / 1024 / 1024
            )));
        }

        let content = String::from_utf8_lossy(&bytes).into_owned();

        // Count occurrences
        let count = content.matches(&old_string).count();
        if count == 0 {
            let preview = truncate_preview(&old_string, 50);
            return Ok(error_result(format!(
                "old_string not found in file: \"{preview}\""
            )));
        }

        if count > 1 && !replace_all {
            return Ok(error_result(format!(
                "Found {count} occurrences of old_string. Use replace_all: true to replace all, or make old_string more specific."
            )));
        }

        // Perform replacement
        let new_content = if replace_all {
            content.replace(&old_string, &new_string)
        } else {
            content.replacen(&old_string, &new_string, 1)
        };

        let replacements = if replace_all { count } else { 1 };

        // Generate diff
        let diff = generate_unified_diff(&content, &new_content, 3);

        // Write the modified file
        if let Err(e) = self.fs.write_file(&resolved, new_content.as_bytes()).await {
            return Ok(format_fs_error(&e, &resolved.to_string_lossy(), "writing"));
        }

        let details = json!({
            "filePath": resolved.to_string_lossy(),
            "replacements": replacements,
            "oldStringPreview": truncate_preview(&old_string, 50),
            "newStringPreview": truncate_preview(&new_string, 50),
            "diff": diff,
        });

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![tron_core::content::ToolResultContent::text(
                diff,
            )]),
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
    async fn exact_match_replace() {
        let fs = Arc::new(MockFs::new().with_file("/tmp/f.txt", "hello world"));
        let tool = EditTool::new(fs.clone());
        let result = tool
            .execute(
                json!({"file_path": "/tmp/f.txt", "old_string": "hello", "new_string": "goodbye"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(result.is_error.is_none());
        assert_eq!(
            fs.read_content(Path::new("/tmp/f.txt")).unwrap(),
            "goodbye world"
        );
        let text = extract_text(&result);
        assert!(text.contains("-hello"));
        assert!(text.contains("+goodbye"));
    }

    #[tokio::test]
    async fn old_string_not_found() {
        let fs = Arc::new(MockFs::new().with_file("/tmp/f.txt", "hello"));
        let tool = EditTool::new(fs);
        let result = tool
            .execute(
                json!({"file_path": "/tmp/f.txt", "old_string": "xyz", "new_string": "abc"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(true));
        let text = extract_text(&result);
        assert!(text.contains("not found"));
    }

    #[tokio::test]
    async fn multiple_without_replace_all() {
        let fs = Arc::new(MockFs::new().with_file("/tmp/f.txt", "aaa bbb aaa"));
        let tool = EditTool::new(fs);
        let result = tool
            .execute(
                json!({"file_path": "/tmp/f.txt", "old_string": "aaa", "new_string": "xxx"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(true));
        let text = extract_text(&result);
        assert!(text.contains("2 occurrences"));
    }

    #[tokio::test]
    async fn replace_all_multiple() {
        let fs = Arc::new(MockFs::new().with_file("/tmp/f.txt", "aaa bbb aaa"));
        let tool = EditTool::new(fs.clone());
        let result = tool.execute(
            json!({"file_path": "/tmp/f.txt", "old_string": "aaa", "new_string": "xxx", "replace_all": true}),
            &make_ctx(),
        ).await.unwrap();
        assert!(result.is_error.is_none());
        assert_eq!(
            fs.read_content(Path::new("/tmp/f.txt")).unwrap(),
            "xxx bbb xxx"
        );
        let details = result.details.unwrap();
        assert_eq!(details["replacements"], 2);
    }

    #[tokio::test]
    async fn identical_strings_error() {
        let fs = Arc::new(MockFs::new().with_file("/tmp/f.txt", "hello"));
        let tool = EditTool::new(fs);
        let result = tool
            .execute(
                json!({"file_path": "/tmp/f.txt", "old_string": "hello", "new_string": "hello"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(true));
        let text = extract_text(&result);
        assert!(text.contains("identical"));
    }

    #[tokio::test]
    async fn empty_old_string() {
        let fs = Arc::new(MockFs::new().with_file("/tmp/f.txt", "hello"));
        let tool = EditTool::new(fs);
        let result = tool
            .execute(
                json!({"file_path": "/tmp/f.txt", "old_string": "", "new_string": "x"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(true));
    }

    #[tokio::test]
    async fn multiline_replacement() {
        let content = "line1\nline2\nline3\n";
        let fs = Arc::new(MockFs::new().with_file("/tmp/f.txt", content));
        let tool = EditTool::new(fs.clone());
        let result = tool.execute(
            json!({"file_path": "/tmp/f.txt", "old_string": "line2\nline3", "new_string": "new2\nnew3"}),
            &make_ctx(),
        ).await.unwrap();
        assert!(result.is_error.is_none());
        assert_eq!(
            fs.read_content(Path::new("/tmp/f.txt")).unwrap(),
            "line1\nnew2\nnew3\n"
        );
    }

    #[tokio::test]
    async fn unicode_replacement() {
        let fs = Arc::new(MockFs::new().with_file("/tmp/f.txt", "caf\u{00E9} \u{1F600}"));
        let tool = EditTool::new(fs.clone());
        let result = tool.execute(
            json!({"file_path": "/tmp/f.txt", "old_string": "caf\u{00E9}", "new_string": "coffee"}),
            &make_ctx(),
        ).await.unwrap();
        assert!(result.is_error.is_none());
        assert_eq!(
            fs.read_content(Path::new("/tmp/f.txt")).unwrap(),
            "coffee \u{1F600}"
        );
    }

    #[tokio::test]
    async fn diff_output_format() {
        let fs = Arc::new(MockFs::new().with_file("/tmp/f.txt", "a\nb\nc\nd\ne"));
        let tool = EditTool::new(fs);
        let result = tool
            .execute(
                json!({"file_path": "/tmp/f.txt", "old_string": "c", "new_string": "C"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        let text = extract_text(&result);
        assert!(text.contains("@@"));
        assert!(text.contains("-c"));
        assert!(text.contains("+C"));
    }

    #[tokio::test]
    async fn file_not_found() {
        let fs = Arc::new(MockFs::new());
        let tool = EditTool::new(fs);
        let result = tool
            .execute(
                json!({"file_path": "/tmp/missing.txt", "old_string": "a", "new_string": "b"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(true));
    }

    #[tokio::test]
    async fn missing_file_path() {
        let fs = Arc::new(MockFs::new());
        let tool = EditTool::new(fs);
        let result = tool
            .execute(json!({"old_string": "a", "new_string": "b"}), &make_ctx())
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(true));
    }

    #[tokio::test]
    async fn missing_old_string() {
        let fs = Arc::new(MockFs::new());
        let tool = EditTool::new(fs);
        let result = tool
            .execute(
                json!({"file_path": "/tmp/f.txt", "new_string": "b"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(true));
    }

    #[tokio::test]
    async fn missing_new_string() {
        let fs = Arc::new(MockFs::new());
        let tool = EditTool::new(fs);
        let result = tool
            .execute(
                json!({"file_path": "/tmp/f.txt", "old_string": "a"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(true));
    }

    #[tokio::test]
    async fn details_include_replacements_and_diff() {
        let fs = Arc::new(MockFs::new().with_file("/tmp/f.txt", "hello world"));
        let tool = EditTool::new(fs);
        let result = tool
            .execute(
                json!({"file_path": "/tmp/f.txt", "old_string": "hello", "new_string": "goodbye"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        let details = result.details.unwrap();
        assert_eq!(details["replacements"], 1);
        assert!(details["diff"].as_str().unwrap().contains("@@"));
    }

    #[tokio::test]
    async fn whitespace_differences_detected() {
        let fs = Arc::new(MockFs::new().with_file("/tmp/f.txt", "hello  world"));
        let tool = EditTool::new(fs.clone());
        let result = tool.execute(
            json!({"file_path": "/tmp/f.txt", "old_string": "hello  world", "new_string": "hello world"}),
            &make_ctx(),
        ).await.unwrap();
        assert!(result.is_error.is_none());
        assert_eq!(
            fs.read_content(Path::new("/tmp/f.txt")).unwrap(),
            "hello world"
        );
    }

    #[tokio::test]
    async fn tab_chars_preserved() {
        let fs = Arc::new(MockFs::new().with_file("/tmp/f.txt", "\thello\t"));
        let tool = EditTool::new(fs.clone());
        let result = tool.execute(
            json!({"file_path": "/tmp/f.txt", "old_string": "\thello\t", "new_string": "  hello  "}),
            &make_ctx(),
        ).await.unwrap();
        assert!(result.is_error.is_none());
        assert_eq!(
            fs.read_content(Path::new("/tmp/f.txt")).unwrap(),
            "  hello  "
        );
    }

    #[tokio::test]
    async fn replace_in_first_line() {
        let fs = Arc::new(MockFs::new().with_file("/tmp/f.txt", "FIRST\nsecond\nthird"));
        let tool = EditTool::new(fs.clone());
        let result = tool
            .execute(
                json!({"file_path": "/tmp/f.txt", "old_string": "FIRST", "new_string": "first"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(result.is_error.is_none());
        let content = fs.read_content(Path::new("/tmp/f.txt")).unwrap();
        assert!(content.starts_with("first\n"));
    }

    #[tokio::test]
    async fn replace_in_last_line() {
        let fs = Arc::new(MockFs::new().with_file("/tmp/f.txt", "first\nsecond\nLAST"));
        let tool = EditTool::new(fs.clone());
        let result = tool
            .execute(
                json!({"file_path": "/tmp/f.txt", "old_string": "LAST", "new_string": "last"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(result.is_error.is_none());
        let content = fs.read_content(Path::new("/tmp/f.txt")).unwrap();
        assert!(content.ends_with("last"));
    }

    #[tokio::test]
    async fn edit_rejects_file_over_50mb() {
        let content = vec![b'x'; MAX_FILE_SIZE + 1];
        let fs = Arc::new(MockFs::new().with_file("/tmp/huge.txt", &content));
        let tool = EditTool::new(fs);
        let result = tool
            .execute(
                json!({"file_path": "/tmp/huge.txt", "old_string": "x", "new_string": "y"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert_eq!(result.is_error, Some(true));
        assert!(extract_text(&result).contains("too large"));
    }

    #[tokio::test]
    async fn edit_allows_file_at_exactly_50mb() {
        let mut content = vec![b'a'; MAX_FILE_SIZE - 1];
        content.push(b'x');
        let fs = Arc::new(MockFs::new().with_file("/tmp/at_limit.txt", &content));
        let tool = EditTool::new(fs);
        let result = tool
            .execute(
                json!({"file_path": "/tmp/at_limit.txt", "old_string": "x", "new_string": "y"}),
                &make_ctx(),
            )
            .await
            .unwrap();
        assert!(result.is_error.is_none());
    }

    #[tokio::test]
    async fn large_file_single_replacement() {
        let lines: Vec<String> = (1..=10_000).map(|i| format!("line {i}")).collect();
        let content = lines.join("\n");
        let fs = Arc::new(MockFs::new().with_file("/tmp/big.txt", content.as_str()));
        let tool = EditTool::new(fs.clone());
        let result = tool.execute(
            json!({"file_path": "/tmp/big.txt", "old_string": "line 5000", "new_string": "REPLACED"}),
            &make_ctx(),
        ).await.unwrap();
        assert!(result.is_error.is_none());
        let new_content = fs.read_content(Path::new("/tmp/big.txt")).unwrap();
        assert!(new_content.contains("REPLACED"));
        assert!(!new_content.contains("line 5000"));
    }
}
