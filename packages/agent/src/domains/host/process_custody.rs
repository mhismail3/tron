//! Bounded child-process I/O shared by fixed primitives and worker runners.
//!
//! Stdin writing and stdout/stderr draining are concurrent. Only the configured
//! prefix of each output pipe is retained while excess bytes continue to drain,
//! avoiding both pipe deadlocks and unbounded allocation. A child that ignores
//! typed stdin may close its pipe early; callers decide whether a broken pipe is
//! acceptable after inspecting its final status.
//!
//! On Unix, every child owns a process group whose id is exactly its positive
//! child PID. Timeout, cancellation, disable, stop-all, and shutdown kill that
//! group synchronously, preventing shells and background helpers from escaping.
//! Non-Unix targets retain Tokio's direct-child kill-on-drop behavior.

use std::collections::HashSet;
use std::ffi::{OsStr, OsString};
use std::io;
use std::path::{Path, PathBuf};
use std::process::ExitStatus;
use std::time::Duration;

use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::process::{Child, ChildStdin, Command};

pub(crate) const MAX_PROCESS_CAPTURE_BYTES: usize = 4 * 1_048_576;

/// Build the executable search path for trusted-local kernel and worker work.
///
/// macOS LaunchAgents receive a deliberately minimal `PATH`, which otherwise
/// makes host-installed package managers and language tools disappear when the
/// same operation moves from an interactive shell into the durable server.
/// Preserve the inherited order, then add conventional user/package-manager
/// locations and system locations. A worker-owned runtime bin, when supplied,
/// stays first so isolated dependencies take precedence.
pub(crate) fn trusted_local_command_path(
    worker_runtime_bin: Option<&Path>,
) -> Result<OsString, String> {
    build_trusted_local_command_path(
        worker_runtime_bin,
        std::env::var_os("PATH").as_deref(),
        std::env::var_os("HOME").as_deref().map(Path::new),
    )
}

fn build_trusted_local_command_path(
    worker_runtime_bin: Option<&Path>,
    inherited: Option<&OsStr>,
    user_home: Option<&Path>,
) -> Result<OsString, String> {
    let mut directories = Vec::new();
    let mut seen = HashSet::<PathBuf>::new();
    let mut append = |directory: PathBuf| {
        if seen.insert(directory.clone()) {
            directories.push(directory);
        }
    };
    if let Some(directory) = worker_runtime_bin {
        append(directory.to_path_buf());
    }
    if let Some(inherited) = inherited {
        for directory in std::env::split_paths(inherited) {
            append(directory);
        }
    }
    if let Some(home) = user_home {
        append(home.join(".local/bin"));
        append(home.join(".cargo/bin"));
    }
    for directory in [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ] {
        append(PathBuf::from(directory));
    }
    std::env::join_paths(directories)
        .map_err(|error| format!("construct trusted-local command PATH: {error}"))
}

/// A child whose descendants share an isolated process group on Unix.
///
/// `kill_on_drop` only guarantees termination of the immediate child. Worker
/// commands commonly launch shells, language runtimes, or background helpers,
/// so dropping an invocation must terminate the whole process tree. The group
/// is killed synchronously on drop to cover cancellation of the surrounding
/// async future; explicit shutdown additionally reaps the direct child.
pub(crate) struct ProcessTree {
    child: Child,
    #[cfg(unix)]
    process_group: rustix::process::Pid,
    armed: bool,
}

impl ProcessTree {
    pub(crate) fn spawn(command: &mut Command) -> io::Result<Self> {
        command.kill_on_drop(true);
        #[cfg(unix)]
        command.process_group(0);

        let child = command.spawn()?;
        #[cfg(unix)]
        let process_group = child
            .id()
            .and_then(|id| i32::try_from(id).ok())
            .and_then(rustix::process::Pid::from_raw)
            .ok_or_else(|| io::Error::other("spawned child did not expose a valid process id"))?;

        Ok(Self {
            child,
            #[cfg(unix)]
            process_group,
            armed: true,
        })
    }

    pub(crate) fn try_wait(&mut self) -> io::Result<Option<ExitStatus>> {
        self.child.try_wait()
    }

    /// Positive direct-child id. On Unix this is also the isolated process
    /// group id captured by durable workspace-process claims.
    pub(crate) fn id(&self) -> Option<u32> {
        self.child.id()
    }

    pub(crate) async fn terminate(&mut self) {
        self.kill_process_group();
        let _ = self.child.kill().await;
        let _ = self.child.wait().await;
        self.armed = false;
    }

    pub(crate) fn take_stdin(&mut self) -> Option<ChildStdin> {
        self.child.stdin.take()
    }

    pub(crate) fn take_stdout(&mut self) -> Option<tokio::process::ChildStdout> {
        self.child.stdout.take()
    }

    pub(crate) fn take_stderr(&mut self) -> Option<tokio::process::ChildStderr> {
        self.child.stderr.take()
    }

    pub(crate) async fn wait(&mut self) -> io::Result<ExitStatus> {
        self.child.wait().await
    }

    pub(crate) fn disarm_after_reap(&mut self) {
        self.armed = false;
    }

    fn kill_process_group(&self) {
        if !self.armed {
            return;
        }
        #[cfg(unix)]
        {
            // The group id is always the positive PID returned for a child
            // spawned with `process_group(0)`, never the caller's group or a
            // broad sentinel target.
            let _ = rustix::process::kill_process_group(
                self.process_group,
                rustix::process::Signal::KILL,
            );
        }
    }
}

impl Drop for ProcessTree {
    fn drop(&mut self) {
        self.kill_process_group();
    }
}

#[derive(Debug)]
pub(crate) struct BoundedProcessOutput {
    pub(crate) status: ExitStatus,
    pub(crate) stdout: Vec<u8>,
    pub(crate) stderr: Vec<u8>,
    pub(crate) stdout_truncated: bool,
    pub(crate) stderr_truncated: bool,
    pub(crate) input_error: Option<(io::ErrorKind, String)>,
}

/// Wait for a child while concurrently writing stdin and draining both output
/// pipes. Only the first `max_capture_bytes` bytes from each stream are kept;
/// the remainder is drained so a noisy child cannot block on a full pipe.
pub(crate) async fn wait_with_bounded_output(
    mut process: ProcessTree,
    input: Option<Vec<u8>>,
    timeout: Duration,
    timeout_message: String,
    max_capture_bytes: usize,
) -> Result<BoundedProcessOutput, String> {
    let stdin = process.child.stdin.take();
    let stdout = process
        .child
        .stdout
        .take()
        .ok_or_else(|| "child stdout was not piped".to_owned())?;
    let stderr = process
        .child
        .stderr
        .take()
        .ok_or_else(|| "child stderr was not piped".to_owned())?;
    let execution = async {
        let (status, stdout, stderr, input_result) = tokio::join!(
            process.child.wait(),
            drain_bounded(stdout, max_capture_bytes),
            drain_bounded(stderr, max_capture_bytes),
            write_input(stdin, input),
        );
        let status = status.map_err(|error| format!("wait for child process: {error}"))?;
        let (stdout, stdout_truncated) =
            stdout.map_err(|error| format!("read child stdout: {error}"))?;
        let (stderr, stderr_truncated) =
            stderr.map_err(|error| format!("read child stderr: {error}"))?;
        let input_error = input_result
            .err()
            .map(|error| (error.kind(), error.to_string()));
        // `Child::wait` reaped the direct child, so its former process-group id
        // is no longer ours to signal. Disarm before this value drops; an
        // immediate PID/PGID reuse must never receive a stale kill.
        process.disarm_after_reap();
        Ok(BoundedProcessOutput {
            status,
            stdout,
            stderr,
            stdout_truncated,
            stderr_truncated,
            input_error,
        })
    };

    match tokio::time::timeout(timeout, execution).await {
        Ok(result) => result,
        Err(_) => {
            process.terminate().await;
            Err(timeout_message)
        }
    }
}

async fn write_input(mut stdin: Option<ChildStdin>, input: Option<Vec<u8>>) -> io::Result<()> {
    if let (Some(stdin), Some(input)) = (&mut stdin, input) {
        stdin.write_all(&input).await?;
    }
    Ok(())
}

async fn drain_bounded(
    mut reader: impl AsyncRead + Unpin,
    max_capture_bytes: usize,
) -> io::Result<(Vec<u8>, bool)> {
    let mut captured = Vec::with_capacity(max_capture_bytes.min(64 * 1024));
    let mut truncated = false;
    let mut chunk = [0_u8; 16 * 1024];
    loop {
        let read = reader.read(&mut chunk).await?;
        if read == 0 {
            break;
        }
        let remaining = max_capture_bytes.saturating_sub(captured.len());
        let retained = remaining.min(read);
        captured.extend_from_slice(&chunk[..retained]);
        truncated |= retained < read;
    }
    Ok((captured, truncated))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Stdio;
    use tokio::process::Command;

    #[test]
    fn trusted_local_path_restores_host_tools_hidden_by_launchd() {
        let inherited = std::env::join_paths(["/usr/bin", "/bin"]).unwrap();
        let path = build_trusted_local_command_path(
            Some(Path::new("/worker/dependency-runtime/bin")),
            Some(&inherited),
            Some(Path::new("/profile/home")),
        )
        .unwrap();
        let directories = std::env::split_paths(&path).collect::<Vec<_>>();
        assert_eq!(
            directories.first().map(PathBuf::as_path),
            Some(Path::new("/worker/dependency-runtime/bin"))
        );
        assert!(directories.contains(&PathBuf::from("/profile/home/.local/bin")));
        assert!(directories.contains(&PathBuf::from("/profile/home/.cargo/bin")));
        assert!(directories.contains(&PathBuf::from("/opt/homebrew/bin")));
        assert!(directories.contains(&PathBuf::from("/usr/local/bin")));
        assert_eq!(
            directories
                .iter()
                .filter(|directory| directory.as_path() == Path::new("/usr/bin"))
                .count(),
            1
        );
    }

    #[tokio::test]
    async fn concurrent_bounded_drain_avoids_stdin_stdout_pipe_deadlock() {
        let mut command = Command::new("python3");
        command
            .args([
                "-c",
                "import sys; sys.stdout.write('x'*2000000); sys.stdout.flush(); data=sys.stdin.buffer.read(); sys.stderr.write(str(len(data)))",
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let child = ProcessTree::spawn(&mut command).unwrap();

        let output = wait_with_bounded_output(
            child,
            Some(vec![b'i'; 2_000_000]),
            Duration::from_secs(5),
            "test process timed out".to_owned(),
            64 * 1024,
        )
        .await
        .unwrap();

        assert!(output.status.success());
        assert_eq!(output.stdout.len(), 64 * 1024);
        assert!(output.stdout_truncated);
        assert_eq!(String::from_utf8(output.stderr).unwrap(), "2000000");
        assert!(!output.stderr_truncated);
        assert!(output.input_error.is_none());
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn timeout_kills_background_descendants_in_the_isolated_process_group() {
        let temporary = tempfile::tempdir().unwrap();
        let marker = temporary.path().join("descendant-survived");
        let mut command = Command::new("sh");
        command
            .args([
                "-c",
                "(sleep 0.4; printf survived > \"$1\") & wait",
                "worker-process-tree-test",
                marker.to_str().unwrap(),
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let child = ProcessTree::spawn(&mut command).unwrap();

        let error = wait_with_bounded_output(
            child,
            None,
            Duration::from_millis(75),
            "expected timeout".to_owned(),
            1024,
        )
        .await
        .unwrap_err();
        assert_eq!(error, "expected timeout");
        tokio::time::sleep(Duration::from_millis(500)).await;
        assert!(!marker.exists(), "background descendant survived timeout");
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn cancelling_the_wait_future_kills_background_descendants() {
        let temporary = tempfile::tempdir().unwrap();
        let marker = temporary.path().join("descendant-survived-cancel");
        let mut command = Command::new("sh");
        command
            .args([
                "-c",
                "(sleep 0.4; printf survived > \"$1\") & wait",
                "worker-process-tree-test",
                marker.to_str().unwrap(),
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let child = ProcessTree::spawn(&mut command).unwrap();
        let task = tokio::spawn(wait_with_bounded_output(
            child,
            None,
            Duration::from_secs(5),
            "unexpected timeout".to_owned(),
            1024,
        ));

        tokio::time::sleep(Duration::from_millis(75)).await;
        task.abort();
        assert!(task.await.unwrap_err().is_cancelled());
        tokio::time::sleep(Duration::from_millis(500)).await;
        assert!(
            !marker.exists(),
            "background descendant survived cancellation"
        );
    }
}
