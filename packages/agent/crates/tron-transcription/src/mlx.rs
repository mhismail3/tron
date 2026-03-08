//! MLX-based transcription engine using a parakeet-mlx Python sidecar.
//!
//! Communicates with `worker.py` via stdin/stdout JSON lines.
//! Lifecycle is tied to the Rust server — worker exits when stdin closes.

use std::path::PathBuf;
use std::sync::Arc;

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::Mutex;
use tracing::{debug, info, warn};

use crate::types::{TranscriptionError, TranscriptionResult};
use crate::venv;

/// RAII guard that removes a temp file on drop.
struct TempFile(PathBuf);

impl Drop for TempFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

/// Internal state for the running Python worker.
struct WorkerState {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

/// MLX transcription engine backed by a parakeet-mlx Python sidecar.
pub struct MlxEngine {
    worker: Mutex<Option<WorkerState>>,
    python_path: PathBuf,
    worker_script: PathBuf,
}

impl MlxEngine {
    /// Set up the venv, spawn the worker, and wait for it to become ready.
    ///
    /// On first run this may take 30-120s (venv creation + pip install).
    /// The worker prints `{"status":"loading"}` then `{"status":"ready"}` on startup.
    pub async fn new() -> Result<Arc<Self>, TranscriptionError> {
        let python_path = venv::ensure_venv().await?;
        let worker_script = venv::worker_script();

        if !worker_script.exists() {
            return Err(TranscriptionError::Setup(format!(
                "worker.py not found at {}",
                worker_script.display()
            )));
        }

        let engine = Arc::new(Self {
            worker: Mutex::new(None),
            python_path,
            worker_script,
        });

        engine.spawn_worker().await?;
        Ok(engine)
    }

    /// Spawn the Python worker process and wait for the "ready" status.
    async fn spawn_worker(&self) -> Result<(), TranscriptionError> {
        info!("spawning transcription worker");

        let hf_home = venv::sidecar_dir()
            .join("models/hf")
            .to_string_lossy()
            .to_string();

        let mut child = Command::new(&self.python_path)
            .arg(&self.worker_script)
            .env("HF_HOME", &hf_home)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::inherit())
            .kill_on_drop(true)
            .spawn()
            .map_err(TranscriptionError::Io)?;

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| TranscriptionError::Sidecar("failed to capture stdin".into()))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| TranscriptionError::Sidecar("failed to capture stdout".into()))?;

        let mut reader = BufReader::new(stdout);

        // Wait for "ready" status (timeout: 300s for first-run model download)
        let ready = tokio::time::timeout(std::time::Duration::from_secs(300), async {
            let mut line = String::new();
            loop {
                line.clear();
                let n = reader
                    .read_line(&mut line)
                    .await
                    .map_err(TranscriptionError::Io)?;
                if n == 0 {
                    return Err(TranscriptionError::Sidecar(
                        "worker exited during startup".into(),
                    ));
                }
                debug!("worker startup: {}", line.trim());
                if let Ok(val) = serde_json::from_str::<serde_json::Value>(line.trim())
                    && val.get("status").and_then(|s| s.as_str()) == Some("ready") {
                        return Ok(());
                    }
            }
        })
        .await;

        match ready {
            Ok(Ok(())) => {
                info!("transcription worker ready");
                let mut guard = self.worker.lock().await;
                if guard.is_some() {
                    // Another caller already restarted the worker — discard ours.
                    let _ = child.kill().await;
                } else {
                    *guard = Some(WorkerState {
                        child,
                        stdin,
                        stdout: reader,
                    });
                }
                Ok(())
            }
            Ok(Err(e)) => {
                let _ = child.kill().await;
                Err(e)
            }
            Err(_) => {
                let _ = child.kill().await;
                Err(TranscriptionError::Sidecar(
                    "worker startup timed out (300s)".into(),
                ))
            }
        }
    }

    /// Transcribe audio bytes, returning the recognized text.
    ///
    /// Writes audio to a temp file, sends a JSON request to the worker,
    /// and reads the JSON response. Concurrent calls are serialized.
    pub async fn transcribe(
        &self,
        audio_bytes: &[u8],
        mime_type: &str,
    ) -> Result<TranscriptionResult, TranscriptionError> {
        let ext = match mime_type {
            t if t.contains("wav") => "wav",
            t if t.contains("m4a") || t.contains("mp4") || t.contains("aac") => "m4a",
            _ => "wav",
        };

        // Write audio to temp file (guard ensures cleanup even on error)
        let tmp_path = std::env::temp_dir().join(format!("tron-{}.{ext}", uuid::Uuid::now_v7()));
        let _guard = TempFile(tmp_path.clone());
        std::fs::write(&tmp_path, audio_bytes).map_err(TranscriptionError::Io)?;

        let request_id = uuid::Uuid::now_v7().to_string();
        let request = serde_json::json!({
            "id": request_id,
            "audio_path": tmp_path.to_string_lossy(),
        });
        let mut request_line = serde_json::to_string(&request)
            .map_err(|e| TranscriptionError::Sidecar(format!("serialize request: {e}")))?;
        request_line.push('\n');

        // Try up to 2 times (initial + 1 retry after restart)
        for attempt in 0..2 {
            let result = self.send_request(&request_line, &request_id).await;
            match result {
                Ok(r) => return Ok(r),
                Err(TranscriptionError::Sidecar(ref msg))
                    if msg.contains("broken pipe") || msg.contains("worker not running") =>
                {
                    if attempt == 0 {
                        warn!("worker appears dead, restarting...");
                        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
                        if let Err(e) = self.spawn_worker().await {
                            return Err(TranscriptionError::Sidecar(format!(
                                "worker restart failed: {e}"
                            )));
                        }
                        continue;
                    }
                    return result;
                }
                Err(e) => return Err(e),
            }
        }

        Err(TranscriptionError::Sidecar(
            "exhausted retry attempts".into(),
        ))
    }

    /// Send a single request to the worker and read the response.
    async fn send_request(
        &self,
        request_line: &str,
        request_id: &str,
    ) -> Result<TranscriptionResult, TranscriptionError> {
        let mut guard = self.worker.lock().await;
        let worker = guard
            .as_mut()
            .ok_or_else(|| TranscriptionError::Sidecar("worker not running".into()))?;

        // Write request
        if let Err(e) = worker.stdin.write_all(request_line.as_bytes()).await {
            *guard = None;
            return Err(TranscriptionError::Sidecar(format!("broken pipe: {e}")));
        }
        if let Err(e) = worker.stdin.flush().await {
            *guard = None;
            return Err(TranscriptionError::Sidecar(format!("broken pipe: {e}")));
        }

        // Read response (timeout: 120s)
        let mut line = String::new();
        let read_result = tokio::time::timeout(
            std::time::Duration::from_secs(120),
            worker.stdout.read_line(&mut line),
        )
        .await;

        match read_result {
            Ok(Ok(0)) => {
                *guard = None;
                Err(TranscriptionError::Sidecar("worker closed stdout".into()))
            }
            Ok(Ok(_)) => {
                let resp: serde_json::Value =
                    serde_json::from_str(line.trim()).map_err(|e| {
                        TranscriptionError::Sidecar(format!(
                            "bad JSON from worker: {e}: {}",
                            line.trim()
                        ))
                    })?;

                if let Some(err) = resp.get("error").and_then(|e| e.as_str()) {
                    return Err(TranscriptionError::Sidecar(format!("worker error: {err}")));
                }

                let resp_id = resp.get("id").and_then(|v| v.as_str()).unwrap_or("");
                if resp_id != request_id {
                    warn!(expected = request_id, got = resp_id, "response id mismatch");
                }

                Ok(TranscriptionResult {
                    text: resp
                        .get("text")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string(),
                    language: resp
                        .get("language")
                        .and_then(|v| v.as_str())
                        .unwrap_or("en")
                        .to_string(),
                    duration_seconds: resp
                        .get("duration_seconds")
                        .and_then(serde_json::Value::as_f64)
                        .unwrap_or(0.0),
                })
            }
            Ok(Err(e)) => {
                *guard = None;
                Err(TranscriptionError::Sidecar(format!("broken pipe: {e}")))
            }
            Err(_) => {
                // Timeout — kill worker
                if let Some(mut w) = guard.take() {
                    let _ = w.child.kill().await;
                }
                Err(TranscriptionError::Sidecar(
                    "transcription timed out (120s)".into(),
                ))
            }
        }
    }
}

impl Drop for MlxEngine {
    fn drop(&mut self) {
        // Closing stdin triggers worker shutdown via EOF.
        // kill_on_drop on the Child handles the case where it doesn't exit.
        let _ = self.worker.get_mut().take();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn temp_file_cleaned_up_on_drop() {
        let path = std::env::temp_dir().join(format!("tron-test-{}", uuid::Uuid::now_v7()));
        std::fs::write(&path, b"test").unwrap();
        assert!(path.exists());
        {
            let _guard = TempFile(path.clone());
        }
        assert!(!path.exists());
    }

    #[test]
    fn temp_file_no_panic_if_already_deleted() {
        let path = std::env::temp_dir().join("tron-test-nonexistent-12345");
        let _guard = TempFile(path);
    }
}
