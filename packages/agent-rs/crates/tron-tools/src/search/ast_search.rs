//! AST search engine — structural code search via `ast-grep`.
//!
//! Spawns the `sg` binary with the given AST pattern, parses JSON output,
//! and formats results as `file:line: code`.

use std::fmt::Write;
use std::sync::Arc;

use serde_json::Value;

use crate::errors::ToolError;
use crate::traits::{ProcessOptions, ProcessRunner};

const DEFAULT_TIMEOUT_MS: u64 = 60_000;
const DEFAULT_MAX_RESULTS: usize = 50;

/// Result of an AST search operation.
pub struct AstSearchResult {
    /// Formatted output text.
    pub output: String,
    /// Number of matches shown.
    pub matches: usize,
    /// Total matches found by `ast-grep`.
    pub total_matches: usize,
    /// Whether results were truncated.
    pub truncated: bool,
}

/// Run an AST search using `ast-grep` (`sg` binary).
pub async fn ast_search(
    runner: &Arc<dyn ProcessRunner>,
    search_path: &str,
    pattern: &str,
    file_pattern: Option<&str>,
    max_results: Option<usize>,
    working_directory: &str,
) -> Result<AstSearchResult, ToolError> {
    let max_results = max_results.unwrap_or(DEFAULT_MAX_RESULTS);

    let mut command = format!("sg --json --pattern {}", shell_escape(pattern));
    if let Some(fp) = file_pattern {
        let _ = write!(command, " --glob {}", shell_escape(fp));
    }
    command.push(' ');
    command.push_str(search_path);

    let opts = ProcessOptions {
        working_directory: working_directory.to_string(),
        timeout_ms: DEFAULT_TIMEOUT_MS,
        cancellation: tokio_util::sync::CancellationToken::new(),
        env: std::collections::HashMap::new(),
    };

    let output = runner.run_command(&command, &opts).await?;

    // Check for binary-not-found errors
    if output.exit_code != 0 {
        let stderr = output.stderr.to_lowercase();
        if stderr.contains("not found") || stderr.contains("command not found") {
            return Ok(AstSearchResult {
                output: "ast-grep is not installed. Install it with: brew install ast-grep".into(),
                matches: 0,
                total_matches: 0,
                truncated: false,
            });
        }

        // Exit code 1 from sg means "no matches" — not an error
        if output.exit_code == 1 && output.stdout.trim().is_empty() {
            return Ok(AstSearchResult {
                output: format!("No AST matches found for pattern: {pattern}"),
                matches: 0,
                total_matches: 0,
                truncated: false,
            });
        }
    }

    // Parse JSON output
    let stdout = if output.stdout.is_empty() { "[]" } else { &output.stdout };
    let results: Vec<Value> = serde_json::from_str(stdout)
        .map_err(|e| ToolError::Internal { message: format!("Failed to parse ast-grep output: {e}") })?;

    let total_matches = results.len();

    if total_matches == 0 {
        return Ok(AstSearchResult {
            output: format!("No AST matches found for pattern: {pattern}"),
            matches: 0,
            total_matches: 0,
            truncated: false,
        });
    }

    let shown = results.iter().take(max_results);
    let mut formatted = String::new();
    let mut match_count = 0;

    for m in shown {
        let file = m.get("file").and_then(Value::as_str).unwrap_or("");
        let line = m.get("line").and_then(Value::as_u64).unwrap_or(0);
        let code = m.get("code")
            .or_else(|| m.get("text"))
            .and_then(Value::as_str)
            .unwrap_or("");

        let _ = writeln!(formatted, "{file}:{line}: {code}");
        match_count += 1;
    }

    let truncated = total_matches > max_results;
    if truncated {
        let _ = writeln!(formatted, "\n[Showing {match_count} of {total_matches} results]");
    }

    Ok(AstSearchResult {
        output: formatted,
        matches: match_count,
        total_matches,
        truncated,
    })
}

/// Simple shell escaping — wraps in single quotes.
fn shell_escape(s: &str) -> String {
    format!("'{}'", s.replace('\'', "'\\''"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use crate::traits::ProcessOutput;

    struct MockRunner {
        handler: Box<dyn Fn(&str) -> ProcessOutput + Send + Sync>,
    }

    #[async_trait]
    impl ProcessRunner for MockRunner {
        async fn run_command(&self, command: &str, _opts: &ProcessOptions) -> Result<ProcessOutput, ToolError> {
            Ok((self.handler)(command))
        }
    }

    #[tokio::test]
    async fn valid_ast_pattern_formats_results() {
        let runner: Arc<dyn ProcessRunner> = Arc::new(MockRunner {
            handler: Box::new(|_| ProcessOutput {
                stdout: r#"[{"file":"src/main.rs","line":5,"code":"fn main() {}"},{"file":"src/lib.rs","line":1,"code":"fn test() {}"}]"#.into(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 100,
                timed_out: false,
                interrupted: false,
            }),
        });

        let r = ast_search(&runner, ".", "$FN() {}", None, None, "/tmp").await.unwrap();
        assert_eq!(r.matches, 2);
        assert!(r.output.contains("src/main.rs:5:"));
        assert!(r.output.contains("fn main()"));
    }

    #[tokio::test]
    async fn binary_not_found_returns_install_message() {
        let runner: Arc<dyn ProcessRunner> = Arc::new(MockRunner {
            handler: Box::new(|_| ProcessOutput {
                stdout: String::new(),
                stderr: "sg: command not found".into(),
                exit_code: 127,
                duration_ms: 5,
                timed_out: false,
                interrupted: false,
            }),
        });

        let r = ast_search(&runner, ".", "$X", None, None, "/tmp").await.unwrap();
        assert!(r.output.contains("not installed"));
        assert!(r.output.contains("brew install"));
    }

    #[tokio::test]
    async fn empty_results_returns_no_matches() {
        let runner: Arc<dyn ProcessRunner> = Arc::new(MockRunner {
            handler: Box::new(|_| ProcessOutput {
                stdout: "[]".into(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 50,
                timed_out: false,
                interrupted: false,
            }),
        });

        let r = ast_search(&runner, ".", "$X", None, None, "/tmp").await.unwrap();
        assert_eq!(r.matches, 0);
        assert!(r.output.contains("No AST matches"));
    }

    #[tokio::test]
    async fn file_pattern_passed_to_command() {
        let called_with = std::sync::Arc::new(std::sync::Mutex::new(String::new()));
        let called_clone = called_with.clone();

        let runner: Arc<dyn ProcessRunner> = Arc::new(MockRunner {
            handler: Box::new(move |cmd| {
                *called_clone.lock().unwrap() = cmd.to_string();
                ProcessOutput {
                    stdout: "[]".into(),
                    stderr: String::new(),
                    exit_code: 0,
                    duration_ms: 10,
                    timed_out: false,
                    interrupted: false,
                }
            }),
        });

        let _ = ast_search(&runner, ".", "$X", Some("*.rs"), None, "/tmp").await;
        let cmd = called_with.lock().unwrap().clone();
        assert!(cmd.contains("--glob"));
        assert!(cmd.contains("*.rs"));
    }

    #[tokio::test]
    async fn max_results_truncates_output() {
        let matches: Vec<Value> = (1..=20).map(|i| {
            serde_json::json!({"file": format!("f{i}.rs"), "line": i, "code": format!("fn f{i}()")})
        }).collect();
        let json = serde_json::to_string(&matches).unwrap();

        let runner: Arc<dyn ProcessRunner> = Arc::new(MockRunner {
            handler: Box::new(move |_| ProcessOutput {
                stdout: json.clone(),
                stderr: String::new(),
                exit_code: 0,
                duration_ms: 50,
                timed_out: false,
                interrupted: false,
            }),
        });

        let r = ast_search(&runner, ".", "$X", None, Some(5), "/tmp").await.unwrap();
        assert_eq!(r.matches, 5);
        assert_eq!(r.total_matches, 20);
        assert!(r.truncated);
        assert!(r.output.contains("Showing 5 of 20"));
    }

    #[tokio::test]
    async fn exit_code_1_no_output_means_no_matches() {
        let runner: Arc<dyn ProcessRunner> = Arc::new(MockRunner {
            handler: Box::new(|_| ProcessOutput {
                stdout: String::new(),
                stderr: String::new(),
                exit_code: 1,
                duration_ms: 50,
                timed_out: false,
                interrupted: false,
            }),
        });

        let r = ast_search(&runner, ".", "$X", None, None, "/tmp").await.unwrap();
        assert_eq!(r.matches, 0);
        assert!(r.output.contains("No AST matches"));
    }
}
