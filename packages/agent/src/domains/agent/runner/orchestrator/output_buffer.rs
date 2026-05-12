//! Shared output buffer for real-time process output streaming.
//!
//! Every managed process gets a `SharedOutputBuffer` that captures stdout/stderr
//! chunks as they arrive. Subscribers (e.g., iOS detail sheets) can tap into
//! the buffer on demand to receive both historical and live output.
//!
//! ## Design
//!
//! - **Always-capture**: Output is buffered regardless of whether anyone is
//!   subscribed. This separates capture (cheap, in-memory) from delivery
//!   (on-demand, over WebSocket).
//! - **Capped at `MAX_BUFFER_BYTES`**: Once the cap is reached, oldest chunks
//!   are dropped. A dropped-chunk counter tracks how many were evicted.
//! - **Subscribe with replay**: Subscribers specify an offset and receive all
//!   chunks from that point forward, then live-tail new chunks via `Notify`.
//! - **Close semantics**: When the process completes, `close()` is called.
//!   Subsequent `push()` calls are no-ops. Subscribers see `is_closed()` and
//!   drain remaining chunks before exiting.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

use dashmap::DashMap;
use parking_lot::Mutex;
use tokio::sync::Notify;

/// Maximum bytes retained per buffer before oldest chunks are evicted.
const MAX_BUFFER_BYTES: usize = 512 * 1024; // 512 KB

// =============================================================================
// SharedOutputBuffer
// =============================================================================

/// Thread-safe, append-only buffer for process output chunks.
///
/// Writers call `push()` from the process runner's stdout reader task.
/// Subscribers call `subscribe()` to replay history and tail new output.
pub struct SharedOutputBuffer {
    chunks: Mutex<Vec<String>>,
    total_bytes: AtomicUsize,
    dropped_chunks: AtomicUsize,
    notify: Notify,
    closed: AtomicBool,
}

impl SharedOutputBuffer {
    /// Create a new empty buffer.
    pub fn new() -> Self {
        Self {
            chunks: Mutex::new(Vec::new()),
            total_bytes: AtomicUsize::new(0),
            dropped_chunks: AtomicUsize::new(0),
            notify: Notify::new(),
            closed: AtomicBool::new(false),
        }
    }

    /// Append a chunk to the buffer.
    ///
    /// No-op if the buffer is closed or the chunk is empty.
    /// If appending would exceed `MAX_BUFFER_BYTES`, oldest chunks are evicted.
    pub fn push(&self, chunk: String) {
        if chunk.is_empty() || self.closed.load(Ordering::Acquire) {
            return;
        }

        let chunk_len = chunk.len();
        let mut chunks = self.chunks.lock();

        chunks.push(chunk);
        let new_total = self.total_bytes.fetch_add(chunk_len, Ordering::Relaxed) + chunk_len;

        // Evict oldest chunks if over capacity.
        if new_total > MAX_BUFFER_BYTES {
            let mut current = new_total;
            while current > MAX_BUFFER_BYTES && !chunks.is_empty() {
                let removed = chunks.remove(0);
                current -= removed.len();
                let _ = self.dropped_chunks.fetch_add(1, Ordering::Relaxed);
            }
            self.total_bytes.store(current, Ordering::Relaxed);
        }

        drop(chunks);
        self.notify.notify_waiters();
    }

    /// Read chunks starting from `offset`, returning the chunks and the new offset.
    ///
    /// Callers should track the returned offset and pass it back on subsequent
    /// calls to avoid re-reading chunks.
    pub fn read_from(&self, offset: usize) -> (Vec<String>, usize) {
        let chunks = self.chunks.lock();
        if offset >= chunks.len() {
            return (Vec::new(), chunks.len());
        }
        let slice = chunks[offset..].to_vec();
        let new_offset = chunks.len();
        (slice, new_offset)
    }

    /// Concatenate all buffered chunks into a single string.
    pub fn snapshot(&self) -> String {
        let chunks = self.chunks.lock();
        chunks.join("")
    }

    /// Total bytes currently buffered (after eviction).
    pub fn total_bytes(&self) -> usize {
        self.total_bytes.load(Ordering::Relaxed)
    }

    /// Number of chunks that were dropped due to capacity limits.
    pub fn dropped_chunks(&self) -> usize {
        self.dropped_chunks.load(Ordering::Relaxed)
    }

    /// Whether the buffer has been closed (process completed).
    pub fn is_closed(&self) -> bool {
        self.closed.load(Ordering::Acquire)
    }

    /// Mark the buffer as closed. Wakes all subscribers.
    ///
    /// After closing, `push()` calls are no-ops.
    pub fn close(&self) {
        self.closed.store(true, Ordering::Release);
        self.notify.notify_waiters();
    }

    /// Get a reference to the internal `Notify` for subscriber tasks.
    pub fn notifier(&self) -> &Notify {
        &self.notify
    }
}

impl Default for SharedOutputBuffer {
    fn default() -> Self {
        Self::new()
    }
}

// =============================================================================
// OutputBufferRegistry
// =============================================================================

/// Registry mapping job IDs to their output buffers.
///
/// Process capabilities register buffers after spawning managed processes.
/// Job capabilities look up buffers to subscribe to output streaming.
pub struct OutputBufferRegistry {
    /// Maps job_id → (buffer, tool_call_id).
    buffers: DashMap<String, (Arc<SharedOutputBuffer>, String)>,
}

impl OutputBufferRegistry {
    /// Create a new empty registry.
    pub fn new() -> Self {
        Self {
            buffers: DashMap::new(),
        }
    }

    /// Register a buffer for a job.
    pub fn register(&self, job_id: &str, tool_call_id: &str, buffer: Arc<SharedOutputBuffer>) {
        let _ = self
            .buffers
            .insert(job_id.to_owned(), (buffer, tool_call_id.to_owned()));
    }

    /// Look up a buffer by job ID.
    pub fn get(&self, job_id: &str) -> Option<(Arc<SharedOutputBuffer>, String)> {
        self.buffers.get(job_id).map(|entry| entry.value().clone())
    }

    /// Remove a buffer entry.
    pub fn remove(&self, job_id: &str) {
        let _ = self.buffers.remove(job_id);
    }
}

impl Default for OutputBufferRegistry {
    fn default() -> Self {
        Self::new()
    }
}

// =============================================================================
// Tests
// =============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    // -------------------------------------------------------------------------
    // SharedOutputBuffer tests
    // -------------------------------------------------------------------------

    #[test]
    fn test_push_stores_chunk() {
        let buf = SharedOutputBuffer::new();
        buf.push("hello".into());
        assert_eq!(buf.snapshot(), "hello");
    }

    #[test]
    fn test_push_multiple_chunks_accumulates() {
        let buf = SharedOutputBuffer::new();
        buf.push("a".into());
        buf.push("b".into());
        assert_eq!(buf.snapshot(), "ab");
    }

    #[test]
    fn test_push_updates_total_bytes() {
        let buf = SharedOutputBuffer::new();
        buf.push("hello".into());
        assert_eq!(buf.total_bytes(), 5);
        buf.push(" world".into());
        assert_eq!(buf.total_bytes(), 11);
    }

    #[test]
    fn test_read_from_replays_existing_chunks() {
        let buf = SharedOutputBuffer::new();
        buf.push("a".into());
        buf.push("b".into());
        let (chunks, offset) = buf.read_from(0);
        assert_eq!(chunks, vec!["a", "b"]);
        assert_eq!(offset, 2);
    }

    #[test]
    fn test_read_from_offset_skips_earlier() {
        let buf = SharedOutputBuffer::new();
        buf.push("a".into());
        buf.push("b".into());
        buf.push("c".into());
        let (chunks, offset) = buf.read_from(1);
        assert_eq!(chunks, vec!["b", "c"]);
        assert_eq!(offset, 3);
    }

    #[test]
    fn test_read_from_at_end_returns_empty() {
        let buf = SharedOutputBuffer::new();
        buf.push("a".into());
        let (chunks, offset) = buf.read_from(1);
        assert!(chunks.is_empty());
        assert_eq!(offset, 1);
    }

    #[tokio::test]
    async fn test_subscribe_receives_future_chunks() {
        let buf = Arc::new(SharedOutputBuffer::new());
        let buf2 = buf.clone();

        // Subscriber waits for notification, then reads.
        let handle = tokio::spawn(async move {
            buf2.notifier().notified().await;
            buf2.read_from(0)
        });

        // Push after subscriber is waiting.
        tokio::task::yield_now().await;
        buf.push("late".into());

        let (chunks, _) = handle.await.unwrap();
        assert_eq!(chunks, vec!["late"]);
    }

    #[tokio::test]
    async fn test_close_wakes_all_subscribers() {
        let buf = Arc::new(SharedOutputBuffer::new());
        let buf2 = buf.clone();

        let handle = tokio::spawn(async move {
            buf2.notifier().notified().await;
            buf2.is_closed()
        });

        tokio::task::yield_now().await;
        buf.close();

        let closed = handle.await.unwrap();
        assert!(closed);
    }

    #[test]
    fn test_close_idempotent() {
        let buf = SharedOutputBuffer::new();
        buf.close();
        buf.close(); // no panic
        assert!(buf.is_closed());
    }

    #[test]
    fn test_push_after_close_is_noop() {
        let buf = SharedOutputBuffer::new();
        buf.push("before".into());
        buf.close();
        buf.push("after".into());
        assert_eq!(buf.total_bytes(), 6); // "before" only
        assert_eq!(buf.snapshot(), "before");
    }

    #[test]
    fn test_cap_drops_oldest_chunks_beyond_limit() {
        let buf = SharedOutputBuffer::new();
        // Push chunks that exceed MAX_BUFFER_BYTES.
        let big_chunk = "x".repeat(MAX_BUFFER_BYTES / 2 + 1);
        buf.push(big_chunk.clone()); // ~256KB + 1
        buf.push(big_chunk.clone()); // total ~512KB + 2 — at limit
        buf.push(big_chunk.clone()); // total ~768KB + 3 — over limit, evict first

        assert!(buf.total_bytes() <= MAX_BUFFER_BYTES);
        assert!(buf.dropped_chunks() > 0);
    }

    #[test]
    fn test_cap_tracks_dropped_count() {
        let buf = SharedOutputBuffer::new();
        // Fill with many small chunks, then push a huge one.
        for i in 0..10 {
            buf.push(format!("chunk-{i}"));
        }
        // Push a massive chunk that forces eviction of all small ones.
        buf.push("x".repeat(MAX_BUFFER_BYTES));

        assert!(buf.dropped_chunks() > 0);
    }

    #[tokio::test]
    async fn test_concurrent_push_and_read() {
        let buf = Arc::new(SharedOutputBuffer::new());
        let mut handles = Vec::new();

        // Spawn 3 writers.
        for i in 0..3 {
            let buf_c = buf.clone();
            handles.push(tokio::spawn(async move {
                for j in 0..100 {
                    buf_c.push(format!("w{i}-{j}\n"));
                    tokio::task::yield_now().await;
                }
            }));
        }

        // Wait for all writers.
        for h in handles {
            h.await.unwrap();
        }

        // Verify: 300 chunks written, snapshot is non-empty.
        let snap = buf.snapshot();
        assert!(!snap.is_empty());
        // All 300 chunks should be present (total is well under 512KB).
        let (chunks, offset) = buf.read_from(0);
        assert_eq!(chunks.len(), 300);
        assert_eq!(offset, 300);
    }

    #[test]
    fn test_subscriber_dropped_before_close() {
        let buf = SharedOutputBuffer::new();
        // Simulate: subscribe (read_from), drop result, push more — no panic.
        let _ = buf.read_from(0);
        buf.push("more data".into());
        assert_eq!(buf.total_bytes(), 9);
    }

    #[test]
    fn test_multiple_reads_independent() {
        let buf = SharedOutputBuffer::new();
        buf.push("a".into());
        buf.push("b".into());
        buf.push("c".into());

        let (chunks1, _) = buf.read_from(0);
        let (chunks2, _) = buf.read_from(2);

        assert_eq!(chunks1, vec!["a", "b", "c"]);
        assert_eq!(chunks2, vec!["c"]);
    }

    #[test]
    fn test_empty_push_is_noop() {
        let buf = SharedOutputBuffer::new();
        buf.push(String::new());
        assert_eq!(buf.total_bytes(), 0);
        assert!(buf.snapshot().is_empty());
    }

    // -------------------------------------------------------------------------
    // OutputBufferRegistry tests
    // -------------------------------------------------------------------------

    #[test]
    fn test_register_and_get() {
        let registry = OutputBufferRegistry::new();
        let buf = Arc::new(SharedOutputBuffer::new());
        registry.register("proc-1", "tc-1", buf.clone());

        let result = registry.get("proc-1");
        assert!(result.is_some());
        let (got_buf, got_tc) = result.unwrap();
        assert!(Arc::ptr_eq(&got_buf, &buf));
        assert_eq!(got_tc, "tc-1");
    }

    #[test]
    fn test_get_nonexistent_returns_none() {
        let registry = OutputBufferRegistry::new();
        assert!(registry.get("proc-999").is_none());
    }

    #[test]
    fn test_remove_clears_entry() {
        let registry = OutputBufferRegistry::new();
        let buf = Arc::new(SharedOutputBuffer::new());
        registry.register("proc-1", "tc-1", buf);

        registry.remove("proc-1");
        assert!(registry.get("proc-1").is_none());
    }

    #[test]
    fn test_remove_nonexistent_no_panic() {
        let registry = OutputBufferRegistry::new();
        registry.remove("nope"); // no panic
    }

    #[test]
    fn test_overwrite_existing_entry() {
        let registry = OutputBufferRegistry::new();
        let buf1 = Arc::new(SharedOutputBuffer::new());
        let buf2 = Arc::new(SharedOutputBuffer::new());

        registry.register("proc-1", "tc-1", buf1);
        registry.register("proc-1", "tc-2", buf2.clone());

        let (got_buf, got_tc) = registry.get("proc-1").unwrap();
        assert!(Arc::ptr_eq(&got_buf, &buf2));
        assert_eq!(got_tc, "tc-2");
    }

    #[tokio::test]
    async fn test_concurrent_register_and_get() {
        let registry = Arc::new(OutputBufferRegistry::new());
        let mut handles = Vec::new();

        for i in 0..10 {
            let reg = registry.clone();
            handles.push(tokio::spawn(async move {
                let buf = Arc::new(SharedOutputBuffer::new());
                let id = format!("proc-{i}");
                reg.register(&id, &format!("tc-{i}"), buf);
                assert!(reg.get(&id).is_some());
            }));
        }

        for h in handles {
            h.await.unwrap();
        }
    }
}
