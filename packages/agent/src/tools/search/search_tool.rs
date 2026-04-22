//! Unified `Search` tool — auto-detects text vs AST mode.
//!
//! If the pattern contains AST metavariables (`$VAR` or `$$$`), uses `ast-grep`.
//! Otherwise, uses regex-based text search. The `type` parameter can force
//! a specific mode.

use std::sync::{Arc, LazyLock};

use async_trait::async_trait;
use regex::Regex;

static AST_METAVAR_RE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\$[A-Z_][A-Z0-9_]*|\$\$\$").unwrap());
use serde_json::{Value, json};
use crate::core::tools::{Tool, ToolCategory, ToolResultBody, TronToolResult};

use crate::tools::errors::ToolError;
use crate::tools::search::ast_search;
use crate::tools::search::text_search;
use crate::tools::traits::{ProcessRunner, ToolContext, TronTool};
use crate::tools::utils::path::resolve_path;
use crate::tools::utils::schema::ToolSchemaBuilder;
use crate::tools::utils::validation::{get_optional_string, get_optional_u64, validate_required_string};

/// Returns `true` if `pattern` contains AST metavariables (`$VAR` or `$$$`).
fn has_ast_metavariables(pattern: &str) -> bool {
    AST_METAVAR_RE.is_match(pattern)
}

/// Classify a Search tool failure into a structured error class for iOS.
///
/// In practice the text-search path only errors on invalid regex patterns;
/// AST search errors bubble up as `ToolError::Internal`. Keep the classifier
/// open to future error kinds without text-scanning on the client.
pub(crate) fn classify_search_error(message: &str) -> &'static str {
    let lower = message.to_lowercase();
    if lower.contains("invalid regex")
        || lower.contains("invalid pattern")
        || lower.contains("unterminated")
    {
        return "invalid_pattern";
    }
    "other"
}

/// Build an error TronToolResult with structured details for Search.
fn search_error(message: impl Into<String>) -> TronToolResult {
    let msg = message.into();
    let class = classify_search_error(&msg);
    TronToolResult {
        content: ToolResultBody::Blocks(vec![
            crate::core::content::ToolResultContent::text(&msg),
        ]),
        details: Some(json!({
            "error": msg,
            "errorClass": class,
        })),
        is_error: Some(true),
        stop_turn: None,
    }
}

/// The unified `Search` tool — routes to text or AST search.
pub struct SearchTool {
    runner: Arc<dyn ProcessRunner>,
}

impl SearchTool {
    /// Create a new `Search` tool with the given process runner (for AST search).
    pub fn new(runner: Arc<dyn ProcessRunner>) -> Self {
        Self { runner }
    }
}

#[async_trait]
impl TronTool for SearchTool {
    fn name(&self) -> &str {
        "Search"
    }

    fn category(&self) -> ToolCategory {
        ToolCategory::Custom
    }

    fn definition(&self) -> Tool {
        ToolSchemaBuilder::new(
            "Search",
            "Search code using text or AST patterns. Automatically detects search mode.\n\n\
Text search (default):\n\
- Fast regex-based content search\n\
- Works for any text pattern\n\n\
AST search (auto-detected):\n\
- Structural code search using AST\n\
- Triggered by $VAR or $$$ in pattern\n\
- Example: \"function $NAME() {}\" finds all function definitions\n\n\
Parameters:\n\
- pattern: Search pattern (regex for text, AST pattern with $VAR for structural)\n\
- path: File or directory to search (default: current directory)\n\
- type: Force search mode ('text' or 'ast'), optional\n\
- filePattern: Glob to filter files (e.g., \"*.ts\")\n\
- context: Lines of context around matches (text mode only)\n\n\
Examples:\n\
- Text: { \"pattern\": \"TODO.*bug\" }\n\
- AST: { \"pattern\": \"function $NAME() {}\" }\n\
- Force: { \"pattern\": \"test\", \"type\": \"ast\" }",
        )
        .required_property("pattern", json!({"type": "string", "description": "Search pattern (regex for text, AST pattern with $VAR for structural)"}))
        .property("path", json!({"type": "string", "description": "File or directory to search (defaults to current directory)"}))
        .property("type", json!({"type": "string", "enum": ["text", "ast"], "description": "Force search mode: text or ast"}))
        .property("filePattern", json!({"type": "string", "description": "Glob pattern to filter files (e.g. *.ts, *.rs)"}))
        .property("context", json!({"type": "number", "description": "Context lines before/after match (text mode only)"}))
        .property("maxResults", json!({"type": "number", "description": "Maximum number of results to return"}))
        .build()
    }

    async fn execute(&self, params: Value, ctx: &ToolContext) -> Result<TronToolResult, ToolError> {
        let pattern = match validate_required_string(&params, "pattern", "a search pattern") {
            Ok(p) => p,
            Err(e) => return Ok(e),
        };

        let force_type = get_optional_string(&params, "type");
        let file_pattern = get_optional_string(&params, "filePattern");
        #[allow(clippy::cast_possible_truncation)]
        let max_results = get_optional_u64(&params, "maxResults").map(|v| v as usize);
        #[allow(clippy::cast_possible_truncation)]
        let context = get_optional_u64(&params, "context").map(|v| v as usize);

        let search_path = get_optional_string(&params, "path").map_or_else(
            || resolve_path(".", &ctx.working_directory),
            |p| resolve_path(&p, &ctx.working_directory),
        );

        let use_ast = match force_type.as_deref() {
            Some("ast") => true,
            Some("text") => false,
            _ => has_ast_metavariables(&pattern),
        };

        if use_ast {
            let search_path_str = search_path.to_string_lossy();
            let result = ast_search::ast_search(
                &self.runner,
                &search_path_str,
                &pattern,
                file_pattern.as_deref(),
                max_results,
                &ctx.working_directory,
            )
            .await?;

            Ok(TronToolResult {
                content: ToolResultBody::Blocks(vec![crate::core::content::ToolResultContent::text(
                    result.output,
                )]),
                details: Some(json!({
                    "mode": "ast",
                    "matchCount": result.match_count,
                    "totalMatches": result.total_matches,
                    "truncated": result.truncated,
                    "matches": result.matches_json,
                })),
                is_error: None,
                stop_turn: None,
            })
        } else {
            let result = text_search::text_search(
                &search_path,
                &pattern,
                file_pattern.as_deref(),
                max_results,
                context,
            );

            match result {
                Ok(r) => Ok(TronToolResult {
                    content: ToolResultBody::Blocks(vec![
                        crate::core::content::ToolResultContent::text(r.output),
                    ]),
                    details: Some(json!({
                        "mode": "text",
                        "matchCount": r.match_count,
                        "filesSearched": r.files_searched,
                        "skippedUnreadable": r.skipped_unreadable,
                        "truncated": r.truncated,
                        "matches": r.matches_json,
                    })),
                    is_error: None,
                    stop_turn: None,
                }),
                Err(msg) => Ok(search_error(msg)),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::tools::testutil::extract_text;
    use crate::tools::traits::ProcessOutput;

    struct MockRunner {
        handler: Box<dyn Fn(&str) -> ProcessOutput + Send + Sync>,
    }

    #[async_trait]
    impl ProcessRunner for MockRunner {
        async fn run_command(
            &self,
            command: &str,
            _opts: &crate::tools::traits::ProcessOptions,
        ) -> Result<ProcessOutput, ToolError> {
            Ok((self.handler)(command))
        }
    }

    fn ast_runner() -> Arc<dyn ProcessRunner> {
        Arc::new(MockRunner {
            handler: Box::new(|_| ProcessOutput {
                stdout: r#"[{"file":"src/main.rs","line":1,"code":"fn main() {}"}]"#.into(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 50,
                timed_out: false,
                interrupted: false,
            }),
        })
    }

    fn make_ctx(dir: &str) -> ToolContext {
        ToolContext {
            tool_call_id: "call-1".into(),
            session_id: "sess-1".into(),
            working_directory: dir.into(),
            cancellation: tokio_util::sync::CancellationToken::new(),
            subagent_depth: 0,
            subagent_max_depth: 0,
            workspace_id: None,
            output_tx: None,
            process_manager: None,
            job_manager: None,
            output_buffer_registry: None,
            event_emitter: None,
            event_persister: None,
            turn: 0,
            all_tool_names: vec![],
        }
    }

    #[test]
    fn auto_detect_text_mode() {
        assert!(!has_ast_metavariables("function.*test"));
        assert!(!has_ast_metavariables("println"));
        assert!(!has_ast_metavariables("$lowercase"));
    }

    #[test]
    fn auto_detect_ast_mode_dollar_var() {
        assert!(has_ast_metavariables("function $NAME()"));
        assert!(has_ast_metavariables("$VAR = 5"));
        assert!(has_ast_metavariables("$_INTERNAL"));
    }

    #[test]
    fn auto_detect_ast_mode_triple_dollar() {
        assert!(has_ast_metavariables("fn $$$"));
        assert!(has_ast_metavariables("$$$"));
    }

    #[tokio::test]
    async fn forced_text_mode_ignores_metavariables() {
        let dir = tempfile::TempDir::new().unwrap();
        std::fs::write(dir.path().join("test.txt"), "$NAME = hello\n").unwrap();

        let tool = SearchTool::new(ast_runner());
        let ctx = make_ctx(dir.path().to_str().unwrap());
        let r = tool
            .execute(json!({"pattern": "$NAME", "type": "text"}), &ctx)
            .await
            .unwrap();
        let details = r.details.unwrap();
        assert_eq!(details["mode"], "text");
    }

    #[tokio::test]
    async fn forced_ast_mode_ignores_text_pattern() {
        let tool = SearchTool::new(ast_runner());
        let ctx = make_ctx("/tmp");
        let r = tool
            .execute(json!({"pattern": "simple_text", "type": "ast"}), &ctx)
            .await
            .unwrap();
        let details = r.details.unwrap();
        assert_eq!(details["mode"], "ast");
    }

    #[tokio::test]
    async fn text_search_via_tool() {
        let dir = tempfile::TempDir::new().unwrap();
        std::fs::write(dir.path().join("file.rs"), "fn main() {}\nfn test() {}\n").unwrap();

        let tool = SearchTool::new(ast_runner());
        let ctx = make_ctx(dir.path().to_str().unwrap());
        let r = tool.execute(json!({"pattern": "fn "}), &ctx).await.unwrap();
        let details = r.details.unwrap();
        assert_eq!(details["mode"], "text");
        assert!(details["matchCount"].as_u64().unwrap() >= 2);
        let matches = details["matches"].as_array().expect("matches array");
        assert!(matches.len() >= 2);
        assert_eq!(matches[0]["filePath"], "file.rs");
        assert!(matches[0]["lineNumber"].as_u64().unwrap() >= 1);
        assert!(matches[0]["content"].as_str().unwrap().contains("fn"));
    }

    #[tokio::test]
    async fn missing_pattern_returns_error() {
        let tool = SearchTool::new(ast_runner());
        let ctx = make_ctx("/tmp");
        let r = tool.execute(json!({}), &ctx).await.unwrap();
        assert_eq!(r.is_error, Some(true));
    }

    #[tokio::test]
    async fn invalid_regex_returns_error() {
        let dir = tempfile::TempDir::new().unwrap();
        let tool = SearchTool::new(ast_runner());
        let ctx = make_ctx(dir.path().to_str().unwrap());
        let r = tool
            .execute(json!({"pattern": "[invalid", "type": "text"}), &ctx)
            .await
            .unwrap();
        assert_eq!(r.is_error, Some(true));
        assert!(extract_text(&r).contains("Invalid regex"));
        let d = r.details.as_ref().expect("details present");
        assert_eq!(d["errorClass"], "invalid_pattern");
        assert!(d["error"].as_str().unwrap().contains("Invalid regex"));
    }

    #[test]
    fn classify_invalid_regex_patterns() {
        assert_eq!(classify_search_error("Invalid regex pattern: ["), "invalid_pattern");
        assert_eq!(classify_search_error("unterminated character class"), "invalid_pattern");
        assert_eq!(classify_search_error("invalid pattern"), "invalid_pattern");
    }

    #[test]
    fn classify_unknown_returns_other() {
        assert_eq!(classify_search_error("weird failure"), "other");
    }

    #[tokio::test]
    async fn max_results_parameter_forwarded() {
        let dir = tempfile::TempDir::new().unwrap();
        let lines: Vec<String> = (1..=50).map(|i| format!("match line {i}")).collect();
        std::fs::write(dir.path().join("big.txt"), lines.join("\n")).unwrap();

        let tool = SearchTool::new(ast_runner());
        let ctx = make_ctx(dir.path().to_str().unwrap());
        let r = tool
            .execute(json!({"pattern": "match", "maxResults": 3}), &ctx)
            .await
            .unwrap();
        let details = r.details.unwrap();
        assert_eq!(details["matchCount"], 3);
        assert_eq!(details["matches"].as_array().unwrap().len(), 3);
    }

    #[tokio::test]
    async fn text_search_structured_matches_grouped_per_file() {
        let dir = tempfile::TempDir::new().unwrap();
        std::fs::write(dir.path().join("a.rs"), "hit one\nmiss\nhit two\n").unwrap();
        std::fs::write(dir.path().join("b.rs"), "hit three\n").unwrap();
        let tool = SearchTool::new(ast_runner());
        let ctx = make_ctx(dir.path().to_str().unwrap());
        let r = tool.execute(json!({"pattern": "hit"}), &ctx).await.unwrap();
        let details = r.details.unwrap();
        let matches = details["matches"].as_array().unwrap();
        assert_eq!(matches.len(), 3);
        // Each match carries all three required fields.
        for m in matches {
            assert!(m.get("filePath").is_some());
            assert!(m.get("lineNumber").is_some());
            assert!(m.get("content").is_some());
        }
    }

    #[tokio::test]
    async fn text_search_no_matches_emits_empty_array() {
        let dir = tempfile::TempDir::new().unwrap();
        std::fs::write(dir.path().join("a.rs"), "hello world").unwrap();
        let tool = SearchTool::new(ast_runner());
        let ctx = make_ctx(dir.path().to_str().unwrap());
        let r = tool.execute(json!({"pattern": "nonexistent_xyz"}), &ctx).await.unwrap();
        let details = r.details.unwrap();
        assert_eq!(details["matchCount"], 0);
        assert_eq!(details["matches"].as_array().unwrap().len(), 0);
    }

    #[tokio::test]
    async fn ast_search_emits_structured_matches() {
        let tool = SearchTool::new(ast_runner());
        let ctx = make_ctx("/tmp");
        let r = tool
            .execute(json!({"pattern": "fn $NAME()", "type": "ast"}), &ctx)
            .await
            .unwrap();
        let details = r.details.unwrap();
        assert_eq!(details["mode"], "ast");
        let matches = details["matches"].as_array().expect("matches array");
        assert!(!matches.is_empty());
        assert_eq!(matches[0]["filePath"], "src/main.rs");
        assert_eq!(matches[0]["lineNumber"], 1);
        assert!(matches[0]["content"].as_str().unwrap().contains("fn"));
    }
}
