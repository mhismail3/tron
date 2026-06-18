//! MLX-based transcription engine using a Parakeet Python sidecar.

use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::{Arc, Mutex as StdMutex};

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::{Mutex, OwnedSemaphorePermit, Semaphore};
use tracing::{debug, info, warn};

use super::venv;
use crate::domains::transcription::{TranscriptionEngine, TranscriptionError, TranscriptionResult};
use crate::shared::foundation::paths;

const DEFAULT_POOL_SIZE: usize = 1;

struct TempFile(PathBuf);

impl Drop for TempFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

struct WorkerState {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

struct SlotPool {
    permits: Arc<Semaphore>,
    free: Arc<StdMutex<VecDeque<usize>>>,
}

impl SlotPool {
    fn new(size: usize) -> Self {
        assert!(size > 0, "pool size must be >= 1");
        let free: VecDeque<usize> = (0..size).collect();
        Self {
            permits: Arc::new(Semaphore::new(size)),
            free: Arc::new(StdMutex::new(free)),
        }
    }

    async fn acquire(&self) -> SlotLease {
        let permit = Arc::clone(&self.permits)
            .acquire_owned()
            .await
            .expect("pool semaphore is never closed during engine lifetime");
        let idx = self
            .free
            .lock()
            .expect("slot pool free queue poisoned")
            .pop_front()
            .expect("permit held implies at least one free slot");
        SlotLease {
            idx,
            _permit: permit,
            free: Arc::clone(&self.free),
        }
    }
}

struct SlotLease {
    idx: usize,
    _permit: OwnedSemaphorePermit,
    free: Arc<StdMutex<VecDeque<usize>>>,
}

impl Drop for SlotLease {
    fn drop(&mut self) {
        if let Ok(mut q) = self.free.lock() {
            q.push_back(self.idx);
        }
    }
}

/// Parakeet MLX sidecar pool for local composer transcription.
pub struct MlxEngine {
    slots: Vec<Arc<Mutex<Option<WorkerState>>>>,
    pool: SlotPool,
    python_path: PathBuf,
    worker_script: PathBuf,
}

impl MlxEngine {
    /// Create the default worker pool, including venv/model setup.
    pub async fn new() -> Result<Arc<Self>, TranscriptionError> {
        Self::with_pool_size(DEFAULT_POOL_SIZE).await
    }

    async fn with_pool_size(size: usize) -> Result<Arc<Self>, TranscriptionError> {
        let python_path = venv::ensure_venv().await?;
        let worker_script = paths::transcription_worker_script();

        if !worker_script.exists() {
            return Err(TranscriptionError::Setup(format!(
                "worker.py not found at {}",
                worker_script.display()
            )));
        }

        let slots: Vec<_> = (0..size).map(|_| Arc::new(Mutex::new(None))).collect();
        let engine = Arc::new(Self {
            slots,
            pool: SlotPool::new(size),
            python_path,
            worker_script,
        });

        for idx in 0..size {
            engine.spawn_worker_at(idx).await?;
        }
        Ok(engine)
    }

    async fn spawn_worker_at(&self, slot_idx: usize) -> Result<(), TranscriptionError> {
        info!(slot = slot_idx, "spawning transcription worker");

        let hf_home = paths::transcription_hf_cache_dir()
            .to_string_lossy()
            .to_string();
        let path = std::env::var("PATH").unwrap_or_default();
        let augmented_path = if path.contains("/opt/homebrew/bin") {
            path
        } else {
            format!("/opt/homebrew/bin:{path}")
        };

        let mut child = Command::new(&self.python_path)
            .arg(&self.worker_script)
            .env("HF_HOME", &hf_home)
            .env("PATH", &augmented_path)
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
                debug!(slot = slot_idx, "worker startup: {}", line.trim());
                if let Ok(val) = serde_json::from_str::<serde_json::Value>(line.trim())
                    && val.get("status").and_then(|s| s.as_str()) == Some("ready")
                {
                    return Ok(());
                }
            }
        })
        .await;

        match ready {
            Ok(Ok(())) => {
                let mut guard = self.slots[slot_idx].lock().await;
                if let Some(mut prev) = guard.take() {
                    let _ = prev.child.kill().await;
                }
                *guard = Some(WorkerState {
                    child,
                    stdin,
                    stdout: reader,
                });
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

    /// Send one audio payload through a sidecar worker.
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

        let lease = self.pool.acquire().await;
        let slot_idx = lease.idx;

        for attempt in 0..2 {
            let result = self
                .send_request_on(slot_idx, &request_line, &request_id)
                .await;
            match result {
                Ok(r) => return Ok(r),
                Err(TranscriptionError::Sidecar(ref msg))
                    if msg.contains("broken pipe") || msg.contains("worker not running") =>
                {
                    if attempt == 0 {
                        warn!(
                            slot = slot_idx,
                            "transcription worker appears dead; restarting"
                        );
                        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                        self.spawn_worker_at(slot_idx).await?;
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

    async fn send_request_on(
        &self,
        slot_idx: usize,
        request_line: &str,
        request_id: &str,
    ) -> Result<TranscriptionResult, TranscriptionError> {
        let mut guard = self.slots[slot_idx].lock().await;
        let worker = guard
            .as_mut()
            .ok_or_else(|| TranscriptionError::Sidecar("worker not running".into()))?;

        if let Err(e) = worker.stdin.write_all(request_line.as_bytes()).await {
            *guard = None;
            return Err(TranscriptionError::Sidecar(format!("broken pipe: {e}")));
        }
        if let Err(e) = worker.stdin.flush().await {
            *guard = None;
            return Err(TranscriptionError::Sidecar(format!("broken pipe: {e}")));
        }

        let mut line = String::new();
        let read_result = tokio::time::timeout(
            std::time::Duration::from_secs(300),
            worker.stdout.read_line(&mut line),
        )
        .await;

        match read_result {
            Ok(Ok(0)) => {
                *guard = None;
                Err(TranscriptionError::Sidecar("worker closed stdout".into()))
            }
            Ok(Ok(_)) => {
                let resp: serde_json::Value = serde_json::from_str(line.trim()).map_err(|e| {
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
                if let Some(mut worker) = guard.take() {
                    let _ = worker.child.kill().await;
                }
                Err(TranscriptionError::Sidecar(
                    "transcription timed out (300s)".into(),
                ))
            }
        }
    }
}

#[async_trait::async_trait]
impl TranscriptionEngine for MlxEngine {
    async fn transcribe(
        &self,
        audio_bytes: &[u8],
        mime_type: &str,
    ) -> Result<TranscriptionResult, TranscriptionError> {
        MlxEngine::transcribe(self, audio_bytes, mime_type).await
    }
}

impl Drop for MlxEngine {
    fn drop(&mut self) {
        for slot in &self.slots {
            if let Ok(mut guard) = slot.try_lock() {
                let _ = guard.take();
            }
        }
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
}
