//! Real process runner using `tokio::process::Command`.

use std::time::Instant;

use async_trait::async_trait;
use tokio::io::AsyncReadExt;
use tracing::debug;

use crate::errors::ToolError;
use crate::traits::{ProcessOptions, ProcessOutput, ProcessRunner};

/// Safety cap for stdout/stderr reads. Prevents OOM if a process writes
/// gigabytes of output. The Bash tool truncates at 400KB chars on top of this.
const MAX_OUTPUT_BYTES: u64 = 10 * 1024 * 1024; // 10MB

/// Real subprocess execution backed by `tokio::process::Command`.
pub struct TokioProcessRunner;

#[async_trait]
impl ProcessRunner for TokioProcessRunner {
    async fn run_command(
        &self,
        command: &str,
        opts: &ProcessOptions,
    ) -> Result<ProcessOutput, ToolError> {
        let start = Instant::now();

        let mut cmd = tokio::process::Command::new("bash");
        let _ = cmd
            .arg("-c")
            .arg(command)
            .current_dir(&opts.working_directory)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());

        // Inject environment variables
        for (key, value) in &opts.env {
            let _ = cmd.env(key, value);
        }

        debug!(command, working_dir = %opts.working_directory, "spawning process");

        let mut child = cmd.spawn().map_err(|e| ToolError::Internal {
            message: format!("Failed to spawn process: {e}"),
        })?;

        let timeout = std::time::Duration::from_millis(opts.timeout_ms);
        let cancel = opts.cancellation.clone();

        // Take ownership of pipes before the select so we can kill the child
        // on timeout/cancel without wait_with_output() consuming it.
        let stdout_pipe = child.stdout.take();
        let stderr_pipe = child.stderr.take();

        let stdout_handle = tokio::spawn(async move {
            let mut buf = Vec::new();
            if let Some(pipe) = stdout_pipe {
                let _ = pipe.take(MAX_OUTPUT_BYTES).read_to_end(&mut buf).await;
            }
            buf
        });
        let stderr_handle = tokio::spawn(async move {
            let mut buf = Vec::new();
            if let Some(pipe) = stderr_pipe {
                let _ = pipe.take(MAX_OUTPUT_BYTES).read_to_end(&mut buf).await;
            }
            buf
        });

        // Wait with timeout and cancellation
        tokio::select! {
            status = child.wait() => {
                let status = status.map_err(|e| ToolError::Internal {
                    message: format!("Process wait failed: {e}"),
                })?;
                let stdout_bytes = stdout_handle.await.unwrap_or_default();
                let stderr_bytes = stderr_handle.await.unwrap_or_default();

                let duration_ms = u64::try_from(start.elapsed().as_millis()).unwrap_or(u64::MAX);
                let exit_code = status.code().unwrap_or(-1);
                let mut stdout = String::from_utf8_lossy(&stdout_bytes).into_owned();
                let mut stderr = String::from_utf8_lossy(&stderr_bytes).into_owned();
                if stdout_bytes.len() as u64 >= MAX_OUTPUT_BYTES {
                    stdout.push_str("\n[output capped at 10MB]");
                }
                if stderr_bytes.len() as u64 >= MAX_OUTPUT_BYTES {
                    stderr.push_str("\n[output capped at 10MB]");
                }

                debug!(command, exit_code, duration_ms, "process completed");

                Ok(ProcessOutput {
                    stdout,
                    stderr,
                    exit_code,
                    duration_ms,
                    timed_out: false,
                    interrupted: false,
                })
            }
            () = tokio::time::sleep(timeout) => {
                let _ = child.kill().await;
                stdout_handle.abort();
                stderr_handle.abort();
                debug!(command, timeout_ms = opts.timeout_ms, "process timed out");
                Ok(ProcessOutput {
                    stdout: String::new(),
                    stderr: "Process timed out".into(),
                    exit_code: -1,
                    duration_ms: u64::try_from(start.elapsed().as_millis()).unwrap_or(u64::MAX),
                    timed_out: true,
                    interrupted: false,
                })
            }
            () = cancel.cancelled() => {
                let _ = child.kill().await;
                stdout_handle.abort();
                stderr_handle.abort();
                debug!(command, "process cancelled");
                Ok(ProcessOutput {
                    stdout: String::new(),
                    stderr: "Process cancelled".into(),
                    exit_code: -1,
                    duration_ms: u64::try_from(start.elapsed().as_millis()).unwrap_or(u64::MAX),
                    timed_out: false,
                    interrupted: true,
                })
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio_util::sync::CancellationToken;

    fn default_opts() -> ProcessOptions {
        ProcessOptions {
            working_directory: "/tmp".into(),
            timeout_ms: 10_000,
            cancellation: CancellationToken::new(),
            env: std::collections::HashMap::new(),
        }
    }

    #[tokio::test]
    async fn run_echo() {
        let runner = TokioProcessRunner;
        let result = runner
            .run_command("echo hello", &default_opts())
            .await
            .unwrap();
        assert_eq!(result.exit_code, 0);
        assert_eq!(result.stdout.trim(), "hello");
        assert!(!result.timed_out);
        assert!(!result.interrupted);
    }

    #[tokio::test]
    async fn run_exit_code() {
        let runner = TokioProcessRunner;
        let result = runner
            .run_command("exit 42", &default_opts())
            .await
            .unwrap();
        assert_eq!(result.exit_code, 42);
    }

    #[tokio::test]
    async fn run_with_env() {
        let runner = TokioProcessRunner;
        let mut opts = default_opts();
        let _ = opts.env.insert("TEST_VAR".into(), "test_value".into());
        let result = runner.run_command("echo $TEST_VAR", &opts).await.unwrap();
        assert_eq!(result.stdout.trim(), "test_value");
    }

    #[tokio::test]
    async fn run_captures_stderr() {
        let runner = TokioProcessRunner;
        let result = runner
            .run_command("echo err >&2", &default_opts())
            .await
            .unwrap();
        assert_eq!(result.stderr.trim(), "err");
    }

    #[tokio::test]
    async fn run_timeout() {
        let runner = TokioProcessRunner;
        let mut opts = default_opts();
        opts.timeout_ms = 50;
        let result = runner.run_command("sleep 10", &opts).await.unwrap();
        assert!(result.timed_out);
    }

    #[tokio::test]
    async fn run_cancellation() {
        let runner = TokioProcessRunner;
        let opts = default_opts();
        let cancel = opts.cancellation.clone();

        let handle = tokio::spawn(async move { runner.run_command("sleep 10", &opts).await });

        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        cancel.cancel();

        let result = handle.await.unwrap().unwrap();
        assert!(result.interrupted);
    }

    #[tokio::test]
    async fn process_kill_on_timeout() {
        // Spawn a long-running process with a short timeout, then verify
        // the process is actually dead (not orphaned).
        let runner = TokioProcessRunner;
        let mut opts = default_opts();
        opts.timeout_ms = 100;

        let start = Instant::now();
        let result = runner.run_command("sleep 60", &opts).await.unwrap();
        let elapsed = start.elapsed();

        assert!(result.timed_out);
        assert!(
            elapsed.as_millis() < 2_000,
            "should exit quickly, not wait for sleep 60"
        );
    }

    #[tokio::test]
    async fn process_kill_on_cancel() {
        // Spawn a long-running process, cancel it immediately, verify cleanup
        let runner = TokioProcessRunner;
        let opts = default_opts();
        let cancel = opts.cancellation.clone();

        let handle = tokio::spawn(async move { runner.run_command("sleep 60", &opts).await });

        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        cancel.cancel();

        let start = Instant::now();
        let result = handle.await.unwrap().unwrap();
        let elapsed = start.elapsed();

        assert!(result.interrupted);
        assert!(elapsed.as_millis() < 2_000, "cancel should resolve quickly");
    }

    #[tokio::test]
    async fn process_normal_completion_unaffected() {
        // Normal completion still captures stdout/stderr correctly
        let runner = TokioProcessRunner;
        let result = runner
            .run_command("echo stdout_val && echo stderr_val >&2", &default_opts())
            .await
            .unwrap();
        assert_eq!(result.exit_code, 0);
        assert_eq!(result.stdout.trim(), "stdout_val");
        assert_eq!(result.stderr.trim(), "stderr_val");
        assert!(!result.timed_out);
        assert!(!result.interrupted);
    }

    #[tokio::test]
    async fn run_large_stdout_capped() {
        let runner = TokioProcessRunner;
        let mut opts = default_opts();
        opts.timeout_ms = 30_000;
        // Generate 20MB of output (exceeds 10MB cap)
        let result = runner
            .run_command("head -c 20000000 /dev/zero | tr '\\0' 'A'", &opts)
            .await
            .unwrap();
        assert!(
            result.stdout.len() <= MAX_OUTPUT_BYTES as usize + 50,
            "stdout should be capped near 10MB, got {}",
            result.stdout.len()
        );
        assert!(
            result.stdout.contains("[output capped at 10MB]"),
            "should contain truncation marker"
        );
    }

    #[tokio::test]
    async fn run_large_stderr_capped() {
        let runner = TokioProcessRunner;
        let mut opts = default_opts();
        opts.timeout_ms = 30_000;
        let result = runner
            .run_command("head -c 20000000 /dev/zero | tr '\\0' 'A' >&2", &opts)
            .await
            .unwrap();
        assert!(
            result.stderr.len() <= MAX_OUTPUT_BYTES as usize + 50,
            "stderr should be capped near 10MB, got {}",
            result.stderr.len()
        );
        assert!(
            result.stderr.contains("[output capped at 10MB]"),
            "should contain truncation marker"
        );
    }

    #[tokio::test]
    async fn run_normal_output_not_capped() {
        let runner = TokioProcessRunner;
        let result = runner
            .run_command("echo hello", &default_opts())
            .await
            .unwrap();
        assert_eq!(result.stdout.trim(), "hello");
        assert!(
            !result.stdout.contains("[output capped"),
            "normal output should not have truncation marker"
        );
    }

    #[tokio::test]
    async fn run_output_at_exact_limit() {
        let runner = TokioProcessRunner;
        let mut opts = default_opts();
        opts.timeout_ms = 30_000;
        // Generate exactly MAX_OUTPUT_BYTES
        let result = runner
            .run_command(
                &format!("head -c {} /dev/zero | tr '\\0' 'B'", MAX_OUTPUT_BYTES),
                &opts,
            )
            .await
            .unwrap();
        // At exactly the limit, the truncation marker IS shown (>= check)
        assert!(
            result.stdout.contains("[output capped at 10MB]"),
            "at-limit output should have truncation marker"
        );
    }
}
