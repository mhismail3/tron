//! CLI subprocess execution for agent-browser.

use std::path::PathBuf;
use std::time::Duration;

use async_trait::async_trait;

use super::error::AgentBrowserError;

/// Timeout for navigation actions (navigate, reload, wait).
pub const TIMEOUT_NAVIGATE: Duration = Duration::from_secs(30);
/// Timeout for observation actions (snapshot, screenshot, getText).
pub const TIMEOUT_OBSERVE: Duration = Duration::from_secs(15);
/// Timeout for interaction actions (click, fill, type, etc.).
pub const TIMEOUT_INTERACT: Duration = Duration::from_secs(15);
/// Timeout for PDF generation.
pub const TIMEOUT_PDF: Duration = Duration::from_secs(30);
/// Timeout for session close.
pub const TIMEOUT_CLOSE: Duration = Duration::from_secs(10);
/// Timeout for URL fetch after navigation.
pub const TIMEOUT_URL_FETCH: Duration = Duration::from_secs(5);

/// Output from a CLI command.
#[derive(Debug, Clone)]
pub struct CliOutput {
    /// Standard output.
    pub stdout: String,
    /// Standard error.
    pub stderr: String,
    /// Process exit code.
    pub exit_code: i32,
}

/// Abstraction for running CLI commands. Allows mocking in tests.
#[async_trait]
pub trait CliRunner: Send + Sync {
    /// Run a command with the given args.
    /// Session ID and flags are NOT auto-added — caller must include them in args.
    async fn run(
        &self,
        session_id: &str,
        args: &[String],
        timeout: Duration,
    ) -> Result<CliOutput, AgentBrowserError>;
}

/// Real implementation that spawns agent-browser subprocesses.
pub struct ProcessCliRunner {
    binary_path: PathBuf,
    stream_port: u16,
    headed: bool,
}

impl ProcessCliRunner {
    /// Create a new CLI runner.
    pub fn new(binary_path: PathBuf, stream_port: u16, headed: bool) -> Self {
        Self {
            binary_path,
            stream_port,
            headed,
        }
    }

    fn build_args(&self, session_id: &str, args: &[String]) -> Vec<String> {
        let mut cmd_args: Vec<String> = args.to_vec();
        cmd_args.push("--session".into());
        cmd_args.push(session_id.into());
        if self.headed {
            cmd_args.push("--headed".into());
        }
        cmd_args
    }
}

#[async_trait]
impl CliRunner for ProcessCliRunner {
    async fn run(
        &self,
        session_id: &str,
        args: &[String],
        timeout: Duration,
    ) -> Result<CliOutput, AgentBrowserError> {
        let cmd_args = self.build_args(session_id, args);

        let child = tokio::process::Command::new(&self.binary_path)
            .args(&cmd_args)
            .env(
                "AGENT_BROWSER_STREAM_PORT",
                self.stream_port.to_string(),
            )
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .map_err(|e| AgentBrowserError::SpawnError(e.to_string()))?;

        match tokio::time::timeout(timeout, child.wait_with_output()).await {
            Ok(Ok(output)) => Ok(CliOutput {
                stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
                stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
                exit_code: output.status.code().unwrap_or(-1),
            }),
            Ok(Err(e)) => Err(AgentBrowserError::SpawnError(e.to_string())),
            Err(_) => {
                // child was consumed by wait_with_output — the future is dropped,
                // which drops the Child, which kills the process on Unix.
                Err(AgentBrowserError::Timeout {
                    timeout_ms: timeout.as_millis() as u64,
                })
            }
        }
    }
}

/// Parse agent-browser `--json` output. Returns the parsed `Value`.
pub fn parse_json_output(output: &CliOutput) -> Result<serde_json::Value, AgentBrowserError> {
    if output.exit_code != 0 {
        return Err(AgentBrowserError::CommandFailed {
            exit_code: output.exit_code,
            stderr: output.stderr.clone(),
        });
    }
    serde_json::from_str(&output.stdout).map_err(|e| AgentBrowserError::ParseError {
        context: format!(
            "JSON parse failed: {e}. Raw output: {}",
            output.stdout.chars().take(200).collect::<String>()
        ),
    })
}

#[cfg(test)]
pub struct MockCliRunner {
    /// Queue of responses. Each call pops from the front.
    responses: std::sync::Mutex<Vec<Result<CliOutput, AgentBrowserError>>>,
    /// Record of all calls made (session_id, args).
    pub calls: std::sync::Mutex<Vec<(String, Vec<String>)>>,
}

#[cfg(test)]
impl MockCliRunner {
    /// Create a mock with queued responses.
    pub fn new(responses: Vec<Result<CliOutput, AgentBrowserError>>) -> Self {
        Self {
            responses: std::sync::Mutex::new(responses),
            calls: std::sync::Mutex::new(Vec::new()),
        }
    }
}

#[cfg(test)]
#[async_trait]
impl CliRunner for MockCliRunner {
    async fn run(
        &self,
        session_id: &str,
        args: &[String],
        _timeout: Duration,
    ) -> Result<CliOutput, AgentBrowserError> {
        self.calls
            .lock()
            .unwrap()
            .push((session_id.to_string(), args.to_vec()));
        self.responses
            .lock()
            .unwrap()
            .remove(0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn process_cli_runner_builds_correct_args() {
        let runner = ProcessCliRunner::new("/usr/local/bin/agent-browser".into(), 9223, false);
        let args = runner.build_args("s1", &["open".into(), "https://example.com".into()]);
        assert_eq!(
            args,
            vec!["open", "https://example.com", "--session", "s1"]
        );
    }

    #[test]
    fn process_cli_runner_adds_session_flag() {
        let runner = ProcessCliRunner::new("/usr/local/bin/agent-browser".into(), 9223, false);
        let args = runner.build_args("test-sess", &["snapshot".into()]);
        assert!(args.contains(&"--session".to_string()));
        assert!(args.contains(&"test-sess".to_string()));
    }

    #[test]
    fn process_cli_runner_adds_headed_flag_when_configured() {
        let runner = ProcessCliRunner::new("/usr/local/bin/agent-browser".into(), 9223, true);
        let args = runner.build_args("s1", &["open".into(), "https://example.com".into()]);
        assert!(args.contains(&"--headed".to_string()));
    }

    #[test]
    fn process_cli_runner_no_headed_flag_by_default() {
        let runner = ProcessCliRunner::new("/usr/local/bin/agent-browser".into(), 9223, false);
        let args = runner.build_args("s1", &["open".into(), "https://example.com".into()]);
        assert!(!args.contains(&"--headed".to_string()));
    }

    #[test]
    fn parse_json_success() {
        let output = CliOutput {
            stdout: r#"{"url":"https://example.com"}"#.into(),
            stderr: String::new(),
            exit_code: 0,
        };
        let val = parse_json_output(&output).unwrap();
        assert_eq!(val["url"], "https://example.com");
    }

    #[test]
    fn parse_json_nonzero_exit() {
        let output = CliOutput {
            stdout: String::new(),
            stderr: "element not found".into(),
            exit_code: 1,
        };
        let err = parse_json_output(&output).unwrap_err();
        match err {
            AgentBrowserError::CommandFailed { exit_code, stderr } => {
                assert_eq!(exit_code, 1);
                assert_eq!(stderr, "element not found");
            }
            other => panic!("expected CommandFailed, got: {other:?}"),
        }
    }

    #[test]
    fn parse_json_invalid_json() {
        let output = CliOutput {
            stdout: "not json".into(),
            stderr: String::new(),
            exit_code: 0,
        };
        let err = parse_json_output(&output).unwrap_err();
        assert!(matches!(err, AgentBrowserError::ParseError { .. }));
    }

    #[test]
    fn parse_json_empty_stdout() {
        let output = CliOutput {
            stdout: String::new(),
            stderr: String::new(),
            exit_code: 0,
        };
        let err = parse_json_output(&output).unwrap_err();
        assert!(matches!(err, AgentBrowserError::ParseError { .. }));
    }

    #[test]
    fn parse_json_truncates_long_output_in_error() {
        let long_output = "x".repeat(500);
        let output = CliOutput {
            stdout: long_output,
            stderr: String::new(),
            exit_code: 0,
        };
        let err = parse_json_output(&output).unwrap_err();
        match err {
            AgentBrowserError::ParseError { context } => {
                // Truncated to 200 chars in error message
                assert!(context.len() < 350);
            }
            other => panic!("expected ParseError, got: {other:?}"),
        }
    }

    #[tokio::test]
    async fn mock_records_calls() {
        let mock = MockCliRunner::new(vec![Ok(CliOutput {
            stdout: "ok".into(),
            stderr: String::new(),
            exit_code: 0,
        })]);
        let _ = mock
            .run("s1", &["open".into(), "https://example.com".into()], Duration::from_secs(5))
            .await;
        let calls = mock.calls.lock().unwrap();
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].0, "s1");
        assert_eq!(calls[0].1, vec!["open", "https://example.com"]);
    }

    #[tokio::test]
    async fn mock_returns_queued_responses() {
        let mock = MockCliRunner::new(vec![
            Ok(CliOutput {
                stdout: "first".into(),
                stderr: String::new(),
                exit_code: 0,
            }),
            Ok(CliOutput {
                stdout: "second".into(),
                stderr: String::new(),
                exit_code: 0,
            }),
        ]);
        let r1 = mock.run("s1", &[], Duration::from_secs(5)).await.unwrap();
        let r2 = mock.run("s1", &[], Duration::from_secs(5)).await.unwrap();
        assert_eq!(r1.stdout, "first");
        assert_eq!(r2.stdout, "second");
    }
}
