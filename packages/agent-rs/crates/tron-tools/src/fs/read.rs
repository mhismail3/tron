//! `Read` tool — reads file contents with line numbers.
//!
//! Outputs lines in the format `   1→line content` with right-aligned line
//! numbers and arrow separators. Supports offset/limit for partial reads and
//! truncates long lines and large outputs.

use std::fmt::Write;
use std::sync::Arc;

use async_trait::async_trait;
use serde_json::{json, Value};
use tron_core::tools::{
    Tool, ToolCategory, ToolParameterSchema, ToolResultBody, TronToolResult, error_result,
};

use crate::errors::ToolError;
use crate::traits::{FileSystemOps, ToolContext, TronTool};
use crate::utils::fs_errors::format_fs_error;
use crate::utils::path::resolve_path;
use crate::utils::truncation::{TruncateOptions, estimate_tokens, truncate_output};
use crate::utils::validation::validate_required_string;

const MAX_LINE_LENGTH: usize = 2000;
const MAX_OUTPUT_TOKENS: usize = 20_000;
const ARROW: &str = "\u{2192}";

/// The `Read` tool reads file contents with line numbers.
pub struct ReadTool {
    fs: Arc<dyn FileSystemOps>,
}

impl ReadTool {
    /// Create a new `Read` tool with the given filesystem.
    pub fn new(fs: Arc<dyn FileSystemOps>) -> Self {
        Self { fs }
    }
}

/// Format lines with line numbers into a string.
fn format_lines(lines: &[&str], start: usize, end: usize) -> String {
    let width = format!("{end}").len().max(6);
    let mut output = String::new();
    for (i, line) in lines.iter().enumerate() {
        let line_num = start + i + 1;
        let display_line = if line.len() > MAX_LINE_LENGTH {
            format!("{}... [line truncated]", &line[..MAX_LINE_LENGTH])
        } else {
            (*line).to_string()
        };
        let _ = writeln!(output, "{line_num:>width$}{ARROW}{display_line}");
    }
    output
}

#[async_trait]
impl TronTool for ReadTool {
    fn name(&self) -> &str {
        "Read"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Filesystem
    }

    fn definition(&self) -> Tool {
        Tool {
            name: "Read".into(),
            description: "Read the contents of a file. Returns the file content with line numbers.".into(),
            parameters: ToolParameterSchema {
                schema_type: "object".into(),
                properties: Some({
                    let mut m = serde_json::Map::new();
                    let _ = m.insert(
                        "file_path".into(),
                        json!({"type": "string", "description": "The path to the file to read (absolute or relative)"}),
                    );
                    let _ = m.insert(
                        "offset".into(),
                        json!({"type": "number", "description": "Line number to start reading from (0-indexed)"}),
                    );
                    let _ = m.insert(
                        "limit".into(),
                        json!({"type": "number", "description": "Maximum number of lines to read"}),
                    );
                    m
                }),
                required: Some(vec!["file_path".into()]),
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
        let file_path = match validate_required_string(&params, "file_path", "path to the file") {
            Ok(p) => p,
            Err(e) => return Ok(e),
        };

        let resolved = resolve_path(&file_path, &ctx.working_directory);
        #[allow(clippy::cast_possible_truncation)]
        let offset = params.get("offset").and_then(Value::as_u64).unwrap_or(0) as usize;
        let limit = params.get("limit").and_then(Value::as_u64);

        // Check if path is a directory
        if let Ok(meta) = self.fs.metadata(&resolved).await {
            if meta.is_dir() {
                return Ok(error_result(format!("Is a directory: {}", resolved.display())));
            }
        }

        let bytes = match self.fs.read_file(&resolved).await {
            Ok(b) => b,
            Err(e) => return Ok(format_fs_error(&e, &resolved.to_string_lossy(), "reading")),
        };

        // Binary detection
        let check_len = bytes.len().min(8192);
        if bytes[..check_len].contains(&0) {
            return Ok(error_result(format!("Cannot read binary file: {}", resolved.display())));
        }

        let content = String::from_utf8_lossy(&bytes);
        let all_lines: Vec<&str> = content.lines().collect();
        let total_lines = all_lines.len();
        let start = offset.min(total_lines);
        #[allow(clippy::cast_possible_truncation)]
        let end = limit.map_or(total_lines, |l| (start + l as usize).min(total_lines));
        let selected = &all_lines[start..end];

        if selected.is_empty() {
            return Ok(TronToolResult {
                content: ToolResultBody::Text(String::new()),
                details: Some(json!({
                    "filePath": resolved.to_string_lossy(),
                    "totalLines": total_lines,
                    "linesReturned": 0,
                    "startLine": start + 1,
                    "endLine": start,
                    "truncated": false,
                })),
                is_error: None,
                stop_turn: None,
            });
        }

        let output = format_lines(selected, start, end);
        let original_tokens = estimate_tokens(output.len());
        let is_truncated = original_tokens > MAX_OUTPUT_TOKENS;
        let final_output = if is_truncated {
            truncate_output(&output, MAX_OUTPUT_TOKENS, &TruncateOptions {
                preserve_start_lines: 20,
                preserve_end_lines: 20,
                ..Default::default()
            }).content
        } else {
            output
        };

        Ok(TronToolResult {
            content: ToolResultBody::Blocks(vec![
                tron_core::content::ToolResultContent::text(final_output.clone()),
            ]),
            details: Some(json!({
                "filePath": resolved.to_string_lossy(),
                "totalLines": total_lines,
                "linesReturned": selected.len(),
                "startLine": start + 1,
                "endLine": end,
                "truncated": is_truncated,
                "originalTokens": original_tokens,
                "finalTokens": estimate_tokens(final_output.len()),
            })),
            is_error: None,
            stop_turn: None,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io;
    use std::path::{Path, PathBuf};

    struct MockFs {
        files: std::collections::HashMap<PathBuf, Vec<u8>>,
    }

    impl MockFs {
        fn new() -> Self {
            Self { files: std::collections::HashMap::new() }
        }
        fn add_file(&mut self, path: impl Into<PathBuf>, content: impl Into<Vec<u8>>) {
            let _ = self.files.insert(path.into(), content.into());
        }
    }

    #[async_trait]
    impl FileSystemOps for MockFs {
        async fn read_file(&self, path: &Path) -> Result<Vec<u8>, io::Error> {
            self.files.get(path).cloned()
                .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "file not found"))
        }
        async fn write_file(&self, _path: &Path, _content: &[u8]) -> Result<(), io::Error> { Ok(()) }
        async fn metadata(&self, path: &Path) -> Result<std::fs::Metadata, io::Error> {
            if self.files.contains_key(path) {
                Err(io::Error::new(io::ErrorKind::Other, "mock"))
            } else {
                Err(io::Error::new(io::ErrorKind::NotFound, "not found"))
            }
        }
        async fn create_dir_all(&self, _path: &Path) -> Result<(), io::Error> { Ok(()) }
        fn exists(&self, path: &Path) -> bool { self.files.contains_key(path) }
    }

    fn make_ctx() -> ToolContext {
        ToolContext {
            tool_call_id: "call-1".into(),
            session_id: "sess-1".into(),
            working_directory: "/tmp".into(),
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

    #[tokio::test]
    async fn valid_file_with_line_numbers() {
        let mut fs = MockFs::new();
        fs.add_file("/tmp/test.txt", b"hello\nworld\n".to_vec());
        let tool = ReadTool::new(Arc::new(fs));
        let r = tool.execute(json!({"file_path": "/tmp/test.txt"}), &make_ctx()).await.unwrap();
        let text = extract_text(&r);
        assert!(text.contains("hello"));
        assert!(text.contains("world"));
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn offset_and_limit() {
        let mut fs = MockFs::new();
        let content = (1..=20).map(|i| format!("line {i}")).collect::<Vec<_>>().join("\n");
        fs.add_file("/tmp/big.txt", content.into_bytes());
        let tool = ReadTool::new(Arc::new(fs));
        let r = tool.execute(json!({"file_path": "/tmp/big.txt", "offset": 5, "limit": 3}), &make_ctx()).await.unwrap();
        let text = extract_text(&r);
        assert!(text.contains("line 6"));
        assert!(text.contains("line 8"));
    }

    #[tokio::test]
    async fn offset_beyond_file_length() {
        let mut fs = MockFs::new();
        fs.add_file("/tmp/small.txt", b"one\ntwo\n".to_vec());
        let tool = ReadTool::new(Arc::new(fs));
        let r = tool.execute(json!({"file_path": "/tmp/small.txt", "offset": 100}), &make_ctx()).await.unwrap();
        let details = r.details.unwrap();
        assert_eq!(details["linesReturned"], 0);
    }

    #[tokio::test]
    async fn file_not_found() {
        let tool = ReadTool::new(Arc::new(MockFs::new()));
        let r = tool.execute(json!({"file_path": "/tmp/missing.txt"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("File not found"));
    }

    #[tokio::test]
    async fn empty_file() {
        let mut fs = MockFs::new();
        fs.add_file("/tmp/empty.txt", Vec::new());
        let tool = ReadTool::new(Arc::new(fs));
        let r = tool.execute(json!({"file_path": "/tmp/empty.txt"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
        assert_eq!(r.details.unwrap()["totalLines"], 0);
    }

    #[tokio::test]
    async fn long_lines_truncated() {
        let mut fs = MockFs::new();
        fs.add_file("/tmp/long.txt", "x".repeat(3000).into_bytes());
        let tool = ReadTool::new(Arc::new(fs));
        let r = tool.execute(json!({"file_path": "/tmp/long.txt"}), &make_ctx()).await.unwrap();
        assert!(extract_text(&r).contains("[line truncated]"));
    }

    #[tokio::test]
    async fn binary_file_detection() {
        let mut fs = MockFs::new();
        let mut content = b"hello".to_vec();
        content.push(0);
        content.extend_from_slice(b"world");
        fs.add_file("/tmp/binary.bin", content);
        let tool = ReadTool::new(Arc::new(fs));
        let r = tool.execute(json!({"file_path": "/tmp/binary.bin"}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("binary"));
    }

    #[tokio::test]
    async fn relative_path_resolved() {
        let mut fs = MockFs::new();
        fs.add_file("/tmp/src/main.rs", b"fn main() {}".to_vec());
        let tool = ReadTool::new(Arc::new(fs));
        let r = tool.execute(json!({"file_path": "src/main.rs"}), &make_ctx()).await.unwrap();
        assert!(r.is_error.is_none());
    }

    #[tokio::test]
    async fn missing_file_path_param() {
        let tool = ReadTool::new(Arc::new(MockFs::new()));
        let r = tool.execute(json!({}), &make_ctx()).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn details_include_expected_fields() {
        let mut fs = MockFs::new();
        fs.add_file("/tmp/test.txt", b"a\nb\nc\n".to_vec());
        let tool = ReadTool::new(Arc::new(fs));
        let r = tool.execute(json!({"file_path": "/tmp/test.txt"}), &make_ctx()).await.unwrap();
        let d = r.details.unwrap();
        assert_eq!(d["totalLines"], 3);
        assert_eq!(d["linesReturned"], 3);
        assert_eq!(d["startLine"], 1);
        assert_eq!(d["endLine"], 3);
        assert!(!d["truncated"].as_bool().unwrap());
    }

    #[tokio::test]
    async fn utf8_emoji_preserved() {
        let mut fs = MockFs::new();
        fs.add_file("/tmp/emoji.txt", "hello \u{1F600}\nworld".as_bytes().to_vec());
        let tool = ReadTool::new(Arc::new(fs));
        let r = tool.execute(json!({"file_path": "/tmp/emoji.txt"}), &make_ctx()).await.unwrap();
        assert!(extract_text(&r).contains('\u{1F600}'));
    }

    #[tokio::test]
    async fn line_number_formatting() {
        let mut fs = MockFs::new();
        fs.add_file("/tmp/test.txt", b"first\nsecond\n".to_vec());
        let tool = ReadTool::new(Arc::new(fs));
        let r = tool.execute(json!({"file_path": "/tmp/test.txt"}), &make_ctx()).await.unwrap();
        assert!(extract_text(&r).contains(ARROW));
    }

    #[tokio::test]
    async fn large_file_output_truncated() {
        let mut fs = MockFs::new();
        let lines: Vec<String> = (1..=5000).map(|i| format!("line {i}: {}", "x".repeat(100))).collect();
        fs.add_file("/tmp/huge.txt", lines.join("\n").into_bytes());
        let tool = ReadTool::new(Arc::new(fs));
        let r = tool.execute(json!({"file_path": "/tmp/huge.txt"}), &make_ctx()).await.unwrap();
        assert!(r.details.unwrap()["truncated"].as_bool().unwrap());
    }
}
