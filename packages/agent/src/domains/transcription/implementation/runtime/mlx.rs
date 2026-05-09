//! MLX-based transcription engine using a parakeet-mlx Python sidecar.
//!
//! Communicates with a pool of `worker.py` sidecars via stdin/stdout JSON lines.
//! Lifecycle is tied to the Rust server — workers exit when stdin closes.
//!
//! # Concurrency model
//!
//! A [`SlotPool`] bounds concurrent transcribes to [`DEFAULT_POOL_SIZE`] and
//! hands each caller an exclusive slot index. Each slot owns its own
//! [`WorkerState`] behind a per-slot mutex, so a hung or slow worker only
//! blocks its own lease — other callers continue to use the remaining slots.
//!
//! INVARIANT: every path that mutates `slots[i]` holds a [`SlotLease`] for
//! that `i` (except engine construction, which runs before any lease can be
//! acquired). This gives us lock-free exclusive access to the per-slot
//! `WorkerState` while the lease is alive.

use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::{Arc, Mutex as StdMutex};

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::{Mutex, OwnedSemaphorePermit, Semaphore};
use tracing::{debug, info, warn};

use crate::domains::transcription::types::{TranscriptionError, TranscriptionResult};
use crate::domains::transcription::venv;
use crate::shared::paths;

/// Default number of parallel worker processes. Two lets a second recording
/// start transcribing while the first is still running, without materially
/// multiplying RAM usage on typical dev machines.
///
/// INVARIANT: each worker loads the ~600 MB parakeet-mlx model into memory.
/// If this ever becomes user-tunable, expose it via settings + iOS parity.
const DEFAULT_POOL_SIZE: usize = 2;

/// RAII guard that removes a temp file on drop.
struct TempFile(PathBuf);

impl Drop for TempFile {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

/// Internal state for a single running Python worker.
struct WorkerState {
    child: Child,
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
}

/// Bounded lease-based slot index pool.
///
/// Callers `acquire()` a [`SlotLease`] which pins one slot index for the
/// lifetime of the lease. When all slots are leased, further callers wait
/// FIFO on the internal semaphore. Dropping a lease makes the slot available
/// again and wakes the next waiter.
struct SlotPool {
    permits: Arc<Semaphore>,
    free: Arc<StdMutex<VecDeque<usize>>>,
    #[cfg(test)]
    size: usize,
}

impl SlotPool {
    fn new(size: usize) -> Self {
        assert!(size > 0, "pool size must be >= 1");
        let free: VecDeque<usize> = (0..size).collect();
        Self {
            permits: Arc::new(Semaphore::new(size)),
            free: Arc::new(StdMutex::new(free)),
            #[cfg(test)]
            size,
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
            .expect("INVARIANT: permit held implies at least one free slot");
        SlotLease {
            idx,
            _permit: permit,
            free: Arc::clone(&self.free),
        }
    }

    #[cfg(test)]
    fn size(&self) -> usize {
        self.size
    }
}

/// Exclusive lease on one slot index. Drop returns the index to the pool.
struct SlotLease {
    idx: usize,
    _permit: OwnedSemaphorePermit,
    free: Arc<StdMutex<VecDeque<usize>>>,
}

impl SlotLease {
    fn idx(&self) -> usize {
        self.idx
    }
}

impl Drop for SlotLease {
    fn drop(&mut self) {
        if let Ok(mut q) = self.free.lock() {
            q.push_back(self.idx);
        }
    }
}

/// MLX transcription engine backed by a pool of parakeet-mlx Python sidecars.
pub struct MlxEngine {
    slots: Vec<Arc<Mutex<Option<WorkerState>>>>,
    pool: SlotPool,
    python_path: PathBuf,
    worker_script: PathBuf,
}

impl MlxEngine {
    /// Set up the venv, spawn workers, and wait for each to become ready.
    ///
    /// On first run this may take 30-120s per worker (venv creation +
    /// pip install + model download on the first worker; subsequent workers
    /// share the cache and start quickly).
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

    /// Spawn a Python worker for `slot_idx`, wait for ready, write into the slot.
    ///
    /// Safe to call concurrently with transcribe requests on *other* slots,
    /// but the caller must either hold a lease for `slot_idx` or be calling
    /// during engine construction (no leases yet).
    async fn spawn_worker_at(&self, slot_idx: usize) -> Result<(), TranscriptionError> {
        info!(slot = slot_idx, "spawning transcription worker");

        let hf_home = paths::transcription_hf_cache_dir()
            .to_string_lossy()
            .to_string();

        // Ensure PATH includes Homebrew so the worker can find ffmpeg
        // (launchd provides only /usr/bin:/bin:/usr/sbin:/sbin).
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

        // Wait for "ready" status (timeout: 300s for first-run model download).
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
                info!(slot = slot_idx, "transcription worker ready");
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

    /// Transcribe audio bytes, returning the recognized text.
    ///
    /// Concurrent calls run in parallel up to the pool size; excess callers
    /// wait FIFO. If the assigned worker's pipe is broken or it's marked
    /// "not running", the caller respawns that one slot and retries once
    /// without blocking other slots.
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
        let slot_idx = lease.idx();

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
                        warn!(slot = slot_idx, "worker appears dead, restarting");
                        tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                        if let Err(e) = self.spawn_worker_at(slot_idx).await {
                            return Err(TranscriptionError::Sidecar(format!(
                                "worker restart on slot {slot_idx} failed: {e}"
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

    /// Send a single request to the worker at `slot_idx` and read the response.
    ///
    /// The caller must hold a [`SlotLease`] for `slot_idx`; the inner mutex
    /// is a belt-and-suspenders check and is never contended in practice.
    async fn send_request_on(
        &self,
        slot_idx: usize,
        request_line: &str,
        request_id: &str,
    ) -> Result<TranscriptionResult, TranscriptionError> {
        let slot = &self.slots[slot_idx];
        let mut guard = slot.lock().await;
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

        // Read response (timeout: 300s — 15-min audio at ~10-20x realtime ≈ 45-90s processing).
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
                if let Some(mut w) = guard.take() {
                    let _ = w.child.kill().await;
                }
                Err(TranscriptionError::Sidecar(
                    "transcription timed out (300s)".into(),
                ))
            }
        }
    }
}

impl Drop for MlxEngine {
    fn drop(&mut self) {
        // Closing stdin triggers worker shutdown via EOF on each slot;
        // kill_on_drop on each Child handles the case where it doesn't exit.
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

    #[test]
    fn temp_file_no_panic_if_already_deleted() {
        let path = std::env::temp_dir().join("tron-test-nonexistent-12345");
        let _guard = TempFile(path);
    }
}

// ── Slot-pool tests ─────────────────────────────────────────────────────────
//
// These exercise the pool primitives in isolation. Python worker lifecycle
// tests live in the transcription integration suite (they need a real venv).

#[cfg(test)]
mod pool_tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::time::Duration;

    #[tokio::test]
    async fn dispenses_unique_indices_up_to_size() {
        let pool = SlotPool::new(3);
        let a = pool.acquire().await;
        let b = pool.acquire().await;
        let c = pool.acquire().await;
        let mut seen = [a.idx(), b.idx(), c.idx()];
        seen.sort_unstable();
        assert_eq!(seen, [0, 1, 2]);
    }

    #[tokio::test]
    async fn concurrent_requests_parallelize_up_to_size() {
        // Two concurrent acquires under a pool size of 2 must both succeed
        // without either blocking. The guard is the tokio timeout.
        let pool = Arc::new(SlotPool::new(2));
        let p1 = Arc::clone(&pool);
        let p2 = Arc::clone(&pool);
        let held = Arc::new(AtomicUsize::new(0));
        let h1 = Arc::clone(&held);
        let h2 = Arc::clone(&held);

        let fut = async {
            let t1 = tokio::spawn(async move {
                let _lease = p1.acquire().await;
                h1.fetch_add(1, Ordering::SeqCst);
                tokio::time::sleep(Duration::from_millis(50)).await;
            });
            let t2 = tokio::spawn(async move {
                let _lease = p2.acquire().await;
                h2.fetch_add(1, Ordering::SeqCst);
                tokio::time::sleep(Duration::from_millis(50)).await;
            });
            t1.await.unwrap();
            t2.await.unwrap();
        };
        tokio::time::timeout(Duration::from_secs(2), fut)
            .await
            .expect("both tasks should run in parallel");
        assert_eq!(held.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn saturated_pool_blocks_next_caller_until_release() {
        let pool = Arc::new(SlotPool::new(1));
        let lease = pool.acquire().await;

        let probe = Arc::new(AtomicUsize::new(0));
        let probe_w = Arc::clone(&probe);
        let p = Arc::clone(&pool);
        let waiter = tokio::spawn(async move {
            let _l = p.acquire().await;
            probe_w.store(1, Ordering::SeqCst);
        });

        // Waiter should still be blocked.
        tokio::time::sleep(Duration::from_millis(30)).await;
        assert_eq!(probe.load(Ordering::SeqCst), 0, "waiter ran before release");

        drop(lease);
        tokio::time::timeout(Duration::from_secs(2), waiter)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(probe.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn hung_slot_does_not_block_other_slots() {
        // A lease that is never dropped simulates a hung worker. Other slots
        // must remain available to new callers.
        let pool = Arc::new(SlotPool::new(2));
        let stuck = pool.acquire().await; // simulate hung worker on this slot
        let live = pool.acquire().await; // second slot still available

        assert_ne!(stuck.idx(), live.idx());
        drop(live);

        // After releasing the live one, another caller immediately gets it
        // while the stuck lease still sits on its slot.
        let third = tokio::time::timeout(Duration::from_secs(1), pool.acquire())
            .await
            .expect("non-stuck slot must be acquirable while the other is held");
        assert_ne!(third.idx(), stuck.idx());
    }

    #[tokio::test]
    async fn lease_drop_returns_index_to_pool() {
        let pool = SlotPool::new(1);
        let first = pool.acquire().await;
        let idx = first.idx();
        drop(first);

        let second = tokio::time::timeout(Duration::from_millis(50), pool.acquire())
            .await
            .expect("released slot should be immediately acquirable");
        assert_eq!(second.idx(), idx, "single-slot pool must reuse index");
    }

    #[tokio::test]
    async fn many_concurrent_waiters_all_complete() {
        let pool = Arc::new(SlotPool::new(2));
        let done = Arc::new(AtomicUsize::new(0));

        let mut handles = Vec::new();
        for _ in 0..8 {
            let p = Arc::clone(&pool);
            let d = Arc::clone(&done);
            handles.push(tokio::spawn(async move {
                let _l = p.acquire().await;
                tokio::time::sleep(Duration::from_millis(10)).await;
                d.fetch_add(1, Ordering::SeqCst);
            }));
        }
        for h in handles {
            tokio::time::timeout(Duration::from_secs(3), h)
                .await
                .unwrap()
                .unwrap();
        }
        assert_eq!(done.load(Ordering::SeqCst), 8);
    }

    #[test]
    #[should_panic(expected = "pool size must be >= 1")]
    fn zero_size_pool_is_rejected() {
        let _ = SlotPool::new(0);
    }

    #[test]
    fn size_reports_configured_value() {
        assert_eq!(SlotPool::new(1).size(), 1);
        assert_eq!(SlotPool::new(7).size(), 7);
    }
}
