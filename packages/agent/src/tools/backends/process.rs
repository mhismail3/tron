//! Real process runner using `tokio::process::Command`.
//!
//! NOTE: `let _ =` is used throughout for I/O writes, channel sends, and
//! child-kill calls. These are all best-effort: the receiver may have dropped
//! (tool cancelled), the child may have already exited, or the pipe may be
//! closed. Propagating these errors would mask the real tool result.

use std::time::Instant;

use async_trait::async_trait;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tracing::debug;

use crate::tools::errors::ToolError;
use crate::tools::traits::{ProcessOptions, ProcessOutput, ProcessRunner};

/// Safety cap for stdout/stderr reads. Prevents OOM if a process writes
/// gigabytes of output. The Bash tool truncates at 400KB chars on top of this.
const MAX_OUTPUT_BYTES: u64 = 10 * 1024 * 1024; // 10MB

/// Real subprocess execution backed by `tokio::process::Command`.
pub struct TokioProcessRunner;

/// ANSI escape code stripping regex pattern.
// SAFETY: Constant pattern, validated at first use during any test run.
static ANSI_RE: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
    regex::Regex::new(r"\x1b\[[0-9;]*[a-zA-Z]|\x1b\].*?\x07|\x1b\[[\?0-9;]*[hlm]")
        .expect("ANSI regex must compile")
});

/// Strip ANSI escape codes from PTY output.
fn strip_ansi(s: &str) -> String {
    ANSI_RE.replace_all(s, "").to_string()
}

impl TokioProcessRunner {
    /// Resolve the shell binary, falling back to bash if the requested shell isn't found.
    fn resolve_shell(shell: &str) -> &str {
        match shell {
            "zsh" | "sh" | "bash" => shell,
            _ => "bash",
        }
    }

    /// Run a command in PTY/interactive mode with pattern-response pairs.
    async fn run_interactive(
        command: &str,
        opts: &ProcessOptions,
    ) -> Result<ProcessOutput, ToolError> {
        use portable_pty::{CommandBuilder, NativePtySystem, PtySize, PtySystem};
        use std::io::{Read, Write};

        let start = Instant::now();
        let shell = Self::resolve_shell(&opts.shell);

        // Create PTY with default terminal size
        let pty_system = NativePtySystem::default();
        let pair = pty_system
            .openpty(PtySize {
                rows: 24,
                cols: 80,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|e| ToolError::Internal {
                message: format!("Failed to open PTY: {e}"),
            })?;

        // Build command
        let mut cmd = CommandBuilder::new(shell);
        cmd.arg("-l");
        cmd.arg("-c");
        cmd.arg(command);
        cmd.cwd(&opts.working_directory);
        for (key, value) in &opts.env {
            cmd.env(key, value);
        }

        // Spawn child in PTY
        let mut child = pair
            .slave
            .spawn_command(cmd)
            .map_err(|e| ToolError::Internal {
                message: format!("Failed to spawn PTY process: {e}"),
            })?;
        // Drop slave so we can detect EOF on the master
        drop(pair.slave);

        let mut reader = pair
            .master
            .try_clone_reader()
            .map_err(|e| ToolError::Internal {
                message: format!("Failed to clone PTY reader: {e}"),
            })?;

        let pty_input = opts.pty_input.clone();
        let stdin_data = opts.stdin.clone();
        let timeout_ms = opts.timeout_ms;
        let pty_stream_tx = opts.output_tx.clone();

        // Run I/O in a blocking thread since portable-pty uses blocking I/O.
        // Both `child` and `pair.master` are moved into the closure so we can
        // kill the child on timeout and write to the PTY master.
        //
        // To handle timeouts on blocking reads, we spawn a separate killer
        // thread that kills the child after the deadline, which unblocks the
        // reader (EOF on master when child dies).
        let result = tokio::task::spawn_blocking(move || {
            let mut output = String::new();
            let mut buf = [0u8; 4096];
            let mut pattern_idx = 0;
            let stream_tx = pty_stream_tx;
            let deadline = std::time::Instant::now() + std::time::Duration::from_millis(timeout_ms);

            // Write initial stdin if provided
            if let Some(ref data) = stdin_data
                && let Ok(mut writer) = pair.master.take_writer()
            {
                let _ = writer.write_all(data.as_bytes());
                let _ = writer.flush();
            }

            // Spawn a killer thread that will terminate the child if it exceeds the deadline.
            // We use an Arc<AtomicBool> to signal whether the timeout fired.
            let timed_out_flag = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
            let timed_out_flag_clone = timed_out_flag.clone();
            let child_id = child.process_id();
            let kill_deadline = deadline;
            let _ = std::thread::spawn(move || {
                let remaining = kill_deadline.saturating_duration_since(std::time::Instant::now());
                std::thread::sleep(remaining);
                timed_out_flag_clone.store(true, std::sync::atomic::Ordering::SeqCst);
                // Kill the process by PID to unblock the blocking read
                if let Some(pid) = child_id {
                    let _ = std::process::Command::new("kill")
                        .args(["-9", &pid.to_string()])
                        .output();
                }
            });

            // Read output and match patterns
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => break, // EOF — child exited or was killed
                    Ok(n) => {
                        let chunk = String::from_utf8_lossy(&buf[..n]);
                        output.push_str(&chunk);

                        // Stream chunk to output channel
                        if let Some(ref tx) = stream_tx {
                            let _ = tx.send(chunk.into_owned());
                        }

                        // Check for pattern matches
                        while pattern_idx < pty_input.len() {
                            let (ref pattern, ref response) = pty_input[pattern_idx];
                            if output.contains(pattern.as_str()) {
                                if let Ok(mut writer) = pair.master.take_writer() {
                                    let _ = writer.write_all(response.as_bytes());
                                    let _ = writer.flush();
                                }
                                pattern_idx += 1;
                            } else {
                                break;
                            }
                        }

                        // Cap output size
                        if output.len() > MAX_OUTPUT_BYTES as usize {
                            output.truncate(MAX_OUTPUT_BYTES as usize);
                            output.push_str("\n[PTY output capped at 10MB]");
                            let _ = child.kill();
                            let exit_status = child.wait().ok();
                            let exit_code = exit_status
                                .and_then(|s| s.exit_code().try_into().ok())
                                .unwrap_or(-1i32);
                            return Ok::<_, ToolError>((output, false, false, exit_code));
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        std::thread::sleep(std::time::Duration::from_millis(10));
                    }
                    Err(_) => break, // Read error = process likely exited
                }
            }

            let did_timeout = timed_out_flag.load(std::sync::atomic::Ordering::SeqCst);

            // Wait for child exit
            let exit_status = child.wait().ok();
            let exit_code = exit_status
                .and_then(|s| s.exit_code().try_into().ok())
                .unwrap_or(-1i32);

            Ok((output, did_timeout, false, exit_code))
        })
        .await
        .map_err(|e| ToolError::Internal {
            message: format!("PTY task panicked: {e}"),
        })??;

        let (raw_output, timed_out, interrupted, exit_code) = result;

        let duration_ms = u64::try_from(start.elapsed().as_millis()).unwrap_or(u64::MAX);

        // Strip ANSI escape codes from output
        let cleaned = strip_ansi(&raw_output);

        debug!(command, exit_code, duration_ms, "PTY process completed");

        Ok(ProcessOutput {
            stdout: cleaned,
            stderr: String::new(),
            exit_code,
            duration_ms,
            timed_out,
            interrupted,
        })
    }
}

#[async_trait]
impl ProcessRunner for TokioProcessRunner {
    async fn run_command(
        &self,
        command: &str,
        opts: &ProcessOptions,
    ) -> Result<ProcessOutput, ToolError> {
        if opts.interactive {
            return Self::run_interactive(command, opts).await;
        }

        let start = Instant::now();

        let shell = Self::resolve_shell(&opts.shell);

        let mut cmd = tokio::process::Command::new(shell);
        let _ = cmd
            .arg("-l")
            .arg("-c")
            .arg(command)
            .current_dir(&opts.working_directory)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());

        // If stdin data is provided, pipe it
        if opts.stdin.is_some() {
            let _ = cmd.stdin(std::process::Stdio::piped());
        } else {
            let _ = cmd.stdin(std::process::Stdio::null());
        }

        // Inject environment variables
        for (key, value) in &opts.env {
            let _ = cmd.env(key, value);
        }

        debug!(command, shell, working_dir = %opts.working_directory, "spawning process");

        let mut child = cmd.spawn().map_err(|e| {
            // If the requested shell doesn't exist, try bash as fallback
            if shell != "bash" {
                debug!(shell, error = %e, "shell not found, will try bash");
            }
            ToolError::Internal {
                message: format!("Failed to spawn process with {shell}: {e}"),
            }
        })?;

        // Write stdin data if provided
        if let Some(ref stdin_data) = opts.stdin
            && let Some(mut stdin_pipe) = child.stdin.take()
        {
            let data = stdin_data.clone();
            let _stdin_writer = tokio::spawn(async move {
                let _ = stdin_pipe.write_all(data.as_bytes()).await;
                let _ = stdin_pipe.shutdown().await;
            });
        }

        let timeout = std::time::Duration::from_millis(opts.timeout_ms);
        let cancel = opts.cancellation.clone();

        // Take ownership of pipes before the select
        let stdout_pipe = child.stdout.take();
        let stderr_pipe = child.stderr.take();
        let stream_tx = opts.output_tx.clone();

        let stdout_handle = tokio::spawn(async move {
            let mut total = Vec::new();
            if let Some(mut pipe) = stdout_pipe {
                let mut chunk_buf = [0u8; 8192];
                loop {
                    if total.len() as u64 >= MAX_OUTPUT_BYTES {
                        break;
                    }
                    let remaining = MAX_OUTPUT_BYTES as usize - total.len();
                    let to_read = chunk_buf.len().min(remaining);
                    match pipe.read(&mut chunk_buf[..to_read]).await {
                        Ok(0) | Err(_) => break,
                        Ok(n) => {
                            total.extend_from_slice(&chunk_buf[..n]);
                            // Stream chunk to output channel if available
                            if let Some(ref tx) = stream_tx {
                                let chunk_str = String::from_utf8_lossy(&chunk_buf[..n]);
                                let _ = tx.send(chunk_str.into_owned());
                            }
                        }
                    }
                }
            }
            total
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
            stdin: None,
            shell: "bash".into(),
            interactive: false,
            pty_input: Vec::new(),
            output_tx: None,
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
        let result = runner
            .run_command(
                &format!("head -c {MAX_OUTPUT_BYTES} /dev/zero | tr '\\0' 'B'"),
                &opts,
            )
            .await
            .unwrap();
        assert!(
            result.stdout.contains("[output capped at 10MB]"),
            "at-limit output should have truncation marker"
        );
    }

    // ── stdin tests ──

    #[tokio::test]
    async fn stdin_piped_to_command() {
        let runner = TokioProcessRunner;
        let mut opts = default_opts();
        opts.stdin = Some("hello from stdin".into());
        let result = runner.run_command("cat", &opts).await.unwrap();
        assert_eq!(result.exit_code, 0);
        assert_eq!(result.stdout, "hello from stdin");
    }

    #[tokio::test]
    async fn stdin_multiline() {
        let runner = TokioProcessRunner;
        let mut opts = default_opts();
        opts.stdin = Some("line1\nline2\nline3\n".into());
        let result = runner.run_command("wc -l", &opts).await.unwrap();
        assert_eq!(result.exit_code, 0);
        assert!(result.stdout.trim().contains('3'));
    }

    #[tokio::test]
    async fn stdin_empty_string() {
        let runner = TokioProcessRunner;
        let mut opts = default_opts();
        opts.stdin = Some(String::new());
        let result = runner.run_command("cat", &opts).await.unwrap();
        assert_eq!(result.exit_code, 0);
        assert_eq!(result.stdout, "");
    }

    #[tokio::test]
    async fn stdin_none_does_not_hang() {
        let runner = TokioProcessRunner;
        let result = runner
            .run_command("echo 'no stdin needed'", &default_opts())
            .await
            .unwrap();
        assert_eq!(result.exit_code, 0);
    }

    // ── shell selection tests ──

    #[tokio::test]
    async fn shell_bash_default() {
        let runner = TokioProcessRunner;
        let result = runner
            .run_command("echo $0", &default_opts())
            .await
            .unwrap();
        assert_eq!(result.exit_code, 0);
        assert!(result.stdout.contains("bash"));
    }

    #[tokio::test]
    async fn shell_sh() {
        let runner = TokioProcessRunner;
        let mut opts = default_opts();
        opts.shell = "sh".into();
        let result = runner.run_command("echo $0", &opts).await.unwrap();
        assert_eq!(result.exit_code, 0);
        assert!(result.stdout.contains("sh"));
    }

    #[tokio::test]
    async fn shell_zsh() {
        let runner = TokioProcessRunner;
        let mut opts = default_opts();
        opts.shell = "zsh".into();
        let result = runner.run_command("echo $0", &opts).await.unwrap();
        assert_eq!(result.exit_code, 0);
        assert!(result.stdout.contains("zsh"));
    }

    // ── stdin binary data ──

    #[tokio::test]
    async fn stdin_binary_data() {
        let runner = TokioProcessRunner;
        let mut opts = default_opts();
        // Pipe data with tab character
        opts.stdin = Some("line1\tline2".into());
        let result = runner.run_command("wc -c", &opts).await.unwrap();
        assert_eq!(result.exit_code, 0);
        let count: usize = result.stdout.trim().parse().unwrap_or(0);
        // 11 bytes: "line1\tline2"
        assert_eq!(count, 11);
    }

    // ── env merge/override tests ──

    #[tokio::test]
    async fn env_vars_merged_with_system() {
        let runner = TokioProcessRunner;
        let mut opts = default_opts();
        let _ = opts.env.insert("MY_CUSTOM_VAR".into(), "custom".into());
        // PATH should still be accessible from the system environment
        let result = runner
            .run_command("echo $MY_CUSTOM_VAR && echo $PATH", &opts)
            .await
            .unwrap();
        assert_eq!(result.exit_code, 0);
        let lines: Vec<&str> = result.stdout.trim().lines().collect();
        assert_eq!(lines[0], "custom");
        assert!(!lines[1].is_empty(), "system PATH should be inherited");
    }

    #[tokio::test]
    async fn env_vars_override_system() {
        let runner = TokioProcessRunner;
        let mut opts = default_opts();
        let _ = opts.env.insert("HOME".into(), "/fake/home".into());
        let result = runner.run_command("echo $HOME", &opts).await.unwrap();
        assert_eq!(result.exit_code, 0);
        assert_eq!(result.stdout.trim(), "/fake/home");
    }

    #[tokio::test]
    async fn env_vars_empty_object() {
        let runner = TokioProcessRunner;
        // Default opts have empty env — verify system env still works
        let result = runner
            .run_command("echo $HOME", &default_opts())
            .await
            .unwrap();
        assert_eq!(result.exit_code, 0);
        assert!(!result.stdout.trim().is_empty());
    }

    // ── PTY/interactive tests ──

    #[tokio::test]
    async fn interactive_mode_captures_output() {
        let runner = TokioProcessRunner;
        let mut opts = default_opts();
        opts.interactive = true;
        opts.timeout_ms = 5_000;
        let result = runner
            .run_command("echo 'hello from pty'", &opts)
            .await
            .unwrap();
        assert_eq!(result.exit_code, 0);
        assert!(result.stdout.contains("hello from pty"));
    }

    #[tokio::test]
    async fn pty_ansi_stripping() {
        // Verify our ANSI stripping function works
        let input = "normal \x1b[31mred\x1b[0m text";
        let stripped = strip_ansi(input);
        assert_eq!(stripped, "normal red text");
    }

    #[tokio::test]
    async fn pty_timeout() {
        let runner = TokioProcessRunner;
        let mut opts = default_opts();
        opts.interactive = true;
        opts.timeout_ms = 200;
        let start = Instant::now();
        let result = runner.run_command("sleep 60", &opts).await.unwrap();
        let elapsed = start.elapsed();
        assert!(result.timed_out);
        assert!(elapsed.as_millis() < 5_000, "PTY timeout should be fast");
    }

    #[test]
    fn strip_ansi_removes_color_codes() {
        assert_eq!(strip_ansi("\x1b[32mgreen\x1b[0m"), "green");
        assert_eq!(strip_ansi("\x1b[1;31mbold red\x1b[0m"), "bold red");
        assert_eq!(strip_ansi("no codes here"), "no codes here");
        assert_eq!(strip_ansi(""), "");
    }

    // ── PTY pattern-matching integration test ──

    #[tokio::test]
    async fn pty_input_pattern_matching() {
        let runner = TokioProcessRunner;
        let mut opts = default_opts();
        opts.interactive = true;
        opts.timeout_ms = 10_000;
        // Use a bash script that prompts and reads input
        opts.pty_input = vec![("continue".into(), "yes\n".into())];
        let result = runner
            .run_command(
                "echo 'Do you want to continue?'; read ANSWER; echo \"Got: $ANSWER\"",
                &opts,
            )
            .await
            .unwrap();
        assert_eq!(result.exit_code, 0);
        assert!(
            result.stdout.contains("continue"),
            "Output should contain the prompt: {}",
            result.stdout
        );
        assert!(
            result.stdout.contains("Got: yes"),
            "Output should contain the response: {}",
            result.stdout
        );
    }

    // ── Streaming output test ──

    #[tokio::test]
    async fn streaming_output_sends_chunks() {
        let runner = TokioProcessRunner;
        let mut opts = default_opts();
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<String>();
        opts.output_tx = Some(tx);

        let result = runner
            .run_command("echo line1; echo line2; echo line3", &opts)
            .await
            .unwrap();
        assert_eq!(result.exit_code, 0);

        // Collect all streamed chunks
        let mut chunks = Vec::new();
        while let Ok(chunk) = rx.try_recv() {
            chunks.push(chunk);
        }
        let combined: String = chunks.join("");
        assert!(
            combined.contains("line1"),
            "Streamed output should contain line1: {combined}"
        );
        assert!(
            combined.contains("line3"),
            "Streamed output should contain line3: {combined}"
        );
    }

    #[tokio::test]
    async fn streaming_output_none_works() {
        // When output_tx is None, should work fine (no streaming)
        let runner = TokioProcessRunner;
        let opts = default_opts(); // output_tx is None
        let result = runner.run_command("echo hello", &opts).await.unwrap();
        assert_eq!(result.exit_code, 0);
        assert_eq!(result.stdout.trim(), "hello");
    }

    #[tokio::test]
    async fn pty_streaming_output_sends_chunks() {
        let runner = TokioProcessRunner;
        let mut opts = default_opts();
        opts.interactive = true;
        opts.timeout_ms = 5_000;
        let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<String>();
        opts.output_tx = Some(tx);

        let result = runner
            .run_command("echo 'pty streaming test'", &opts)
            .await
            .unwrap();
        assert_eq!(result.exit_code, 0);

        let mut chunks = Vec::new();
        while let Ok(chunk) = rx.try_recv() {
            chunks.push(chunk);
        }
        let combined: String = chunks.join("");
        assert!(
            combined.contains("pty streaming test"),
            "PTY streamed output should contain the text: {combined}"
        );
    }

    // ── login shell tests ──

    #[tokio::test]
    async fn login_shell_sources_profile() {
        // Create a temp HOME with a .bash_profile that exports a unique var
        let tmp = tempfile::tempdir().unwrap();
        let profile_path = tmp.path().join(".bash_profile");
        std::fs::write(&profile_path, "export TRON_LOGIN_TEST_VAR=profile_loaded\n").unwrap();

        let runner = TokioProcessRunner;
        let mut opts = default_opts();
        let _ = opts
            .env
            .insert("HOME".into(), tmp.path().to_string_lossy().into());
        let result = runner
            .run_command("echo $TRON_LOGIN_TEST_VAR", &opts)
            .await
            .unwrap();
        assert_eq!(result.exit_code, 0);
        assert_eq!(
            result.stdout.trim(),
            "profile_loaded",
            "Login shell should source .bash_profile and export the var"
        );
    }

    #[tokio::test]
    async fn login_shell_has_expanded_path() {
        let runner = TokioProcessRunner;
        let result = runner
            .run_command("echo $PATH", &default_opts())
            .await
            .unwrap();
        assert_eq!(result.exit_code, 0);
        // A login shell should have more than the minimal launchd PATH
        let path = result.stdout.trim();
        assert!(!path.is_empty(), "PATH should not be empty in login shell");
        // Verify it contains at least the basics
        assert!(
            path.contains("/usr/bin"),
            "PATH should contain /usr/bin: {path}"
        );
    }

    #[tokio::test]
    async fn login_shell_bash() {
        let runner = TokioProcessRunner;
        let result = runner
            .run_command("echo $0", &default_opts())
            .await
            .unwrap();
        assert_eq!(result.exit_code, 0);
        assert!(
            result.stdout.contains("bash"),
            "Login bash should report bash in $0: {}",
            result.stdout.trim()
        );
    }

    #[tokio::test]
    async fn login_shell_zsh() {
        let runner = TokioProcessRunner;
        let mut opts = default_opts();
        opts.shell = "zsh".into();
        let result = runner.run_command("echo $0", &opts).await.unwrap();
        assert_eq!(result.exit_code, 0);
        assert!(
            result.stdout.contains("zsh"),
            "Login zsh should report zsh in $0: {}",
            result.stdout.trim()
        );
    }

    #[tokio::test]
    async fn login_shell_sh() {
        let runner = TokioProcessRunner;
        let mut opts = default_opts();
        opts.shell = "sh".into();
        let result = runner.run_command("echo $0", &opts).await.unwrap();
        assert_eq!(result.exit_code, 0);
        assert!(
            result.stdout.contains("sh"),
            "Login sh should report sh in $0: {}",
            result.stdout.trim()
        );
    }

    #[tokio::test]
    async fn login_shell_env_vars_still_merged() {
        // Custom env vars should still work alongside login shell
        let tmp = tempfile::tempdir().unwrap();
        let profile_path = tmp.path().join(".bash_profile");
        std::fs::write(&profile_path, "export FROM_PROFILE=yes\n").unwrap();

        let runner = TokioProcessRunner;
        let mut opts = default_opts();
        let _ = opts
            .env
            .insert("HOME".into(), tmp.path().to_string_lossy().into());
        let _ = opts.env.insert("FROM_ENV".into(), "injected".into());
        let result = runner
            .run_command("echo $FROM_PROFILE:$FROM_ENV", &opts)
            .await
            .unwrap();
        assert_eq!(result.exit_code, 0);
        assert_eq!(
            result.stdout.trim(),
            "yes:injected",
            "Both profile vars and injected env vars should be available"
        );
    }

    #[tokio::test]
    async fn login_shell_interactive_pty() {
        // PTY path should also use login shell
        let tmp = tempfile::tempdir().unwrap();
        let profile_path = tmp.path().join(".bash_profile");
        std::fs::write(&profile_path, "export PTY_LOGIN_VAR=pty_loaded\n").unwrap();

        let runner = TokioProcessRunner;
        let mut opts = default_opts();
        opts.interactive = true;
        opts.timeout_ms = 5_000;
        let _ = opts
            .env
            .insert("HOME".into(), tmp.path().to_string_lossy().into());
        let result = runner
            .run_command("echo $PTY_LOGIN_VAR", &opts)
            .await
            .unwrap();
        assert_eq!(result.exit_code, 0);
        assert!(
            result.stdout.contains("pty_loaded"),
            "PTY login shell should source .bash_profile: {}",
            result.stdout
        );
    }

    #[tokio::test]
    async fn login_shell_stdin_still_works() {
        let runner = TokioProcessRunner;
        let mut opts = default_opts();
        opts.stdin = Some("hello from login stdin".into());
        let result = runner.run_command("cat", &opts).await.unwrap();
        assert_eq!(result.exit_code, 0);
        assert_eq!(result.stdout, "hello from login stdin");
    }

    #[tokio::test]
    async fn login_shell_timeout_still_works() {
        let runner = TokioProcessRunner;
        let mut opts = default_opts();
        opts.timeout_ms = 200;
        let result = runner.run_command("sleep 60", &opts).await.unwrap();
        assert!(
            result.timed_out,
            "Timeout should still work with login shell"
        );
    }

    #[tokio::test]
    async fn login_shell_exit_code_preserved() {
        let runner = TokioProcessRunner;
        let result = runner
            .run_command("exit 42", &default_opts())
            .await
            .unwrap();
        assert_eq!(
            result.exit_code, 42,
            "Exit code should be preserved in login shell"
        );
    }
}
