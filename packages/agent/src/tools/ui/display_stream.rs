//! Screen capture frame producer for Display tool streaming.
//!
//! Polls `screencapture` at a configurable interval (~3 FPS default) and emits
//! `DisplayFrame` events via a broadcast channel. The producer runs as a
//! background tokio task and stops when its cancellation token is triggered.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use base64::Engine;
use parking_lot::Mutex;
use tokio::sync::broadcast;
use tokio_util::sync::CancellationToken;
use tracing::{debug, warn};

use crate::core::events::{BaseEvent, TronEvent};

/// Registry of active display streams, keyed by stream ID.
///
/// Shared between the `DisplayTool` (which inserts/removes entries) and
/// the `display.stopStream` canonical capability function (which cancels streams on demand).
#[derive(Clone, Default)]
pub struct ActiveStreamRegistry {
    inner: Arc<Mutex<HashMap<String, CancellationToken>>>,
}

impl ActiveStreamRegistry {
    /// Create an empty registry.
    pub fn new() -> Self {
        Self::default()
    }

    /// Register a stream with its cancellation token.
    pub fn insert(&self, stream_id: &str, token: CancellationToken) {
        let _ = self.inner.lock().insert(stream_id.to_owned(), token);
    }

    /// Remove a stream from the registry.
    pub fn remove(&self, stream_id: &str) {
        let _ = self.inner.lock().remove(stream_id);
    }

    /// Cancel and remove a stream. Returns `true` if the stream existed.
    pub fn cancel(&self, stream_id: &str) -> bool {
        if let Some(token) = self.inner.lock().remove(stream_id) {
            token.cancel();
            true
        } else {
            false
        }
    }
}

/// Default capture interval (~3 FPS).
pub const DEFAULT_INTERVAL_MS: u64 = 333;

/// Max dimension for streamed frames (resized via sips).
pub const MAX_STREAM_DIMENSION: u32 = 1280;

/// Maximum consecutive capture failures before giving up.
pub const MAX_CONSECUTIVE_FAILURES: u32 = 10;

/// Configuration for a screen capture stream.
pub struct StreamConfig {
    /// Capture interval.
    pub interval: Duration,
    /// Session ID for the events.
    pub session_id: String,
    /// Unique stream identifier.
    pub stream_id: String,
    /// Tool call that initiated the stream.
    pub tool_call_id: String,
}

/// Run the screen capture loop, emitting `DisplayFrame` events until cancelled.
///
/// Returns the raw bytes of the last successfully captured frame (for blob storage),
/// or `None` if no frames were captured.
pub async fn screen_capture_loop(
    event_tx: broadcast::Sender<TronEvent>,
    config: StreamConfig,
    cancel: CancellationToken,
) -> Option<Vec<u8>> {
    let tmp_path = format!("/tmp/tron-stream-{}.jpg", uuid::Uuid::now_v7());
    let mut frame_id: u64 = 0;
    let mut consecutive_failures: u32 = 0;
    let mut last_frame_data: Option<Vec<u8>> = None;

    debug!(
        stream_id = %config.stream_id,
        interval_ms = config.interval.as_millis() as u64,
        "Starting screen capture loop"
    );

    loop {
        tokio::select! {
            _ = cancel.cancelled() => {
                debug!(stream_id = %config.stream_id, frames = frame_id, "Stream cancelled");
                break;
            }
            _ = tokio::time::sleep(config.interval) => {}
        }

        // Capture screenshot as JPEG
        let capture_result = tokio::process::Command::new("screencapture")
            .args(["-x", "-t", "jpg", &tmp_path])
            .output()
            .await;

        let output = match capture_result {
            Ok(o) if o.status.success() => o,
            Ok(o) => {
                consecutive_failures += 1;
                warn!(
                    stream_id = %config.stream_id,
                    exit_code = o.status.code(),
                    failures = consecutive_failures,
                    "screencapture failed"
                );
                if consecutive_failures >= MAX_CONSECUTIVE_FAILURES {
                    warn!(stream_id = %config.stream_id, "Too many failures, stopping stream");
                    break;
                }
                continue;
            }
            Err(e) => {
                consecutive_failures += 1;
                warn!(
                    stream_id = %config.stream_id,
                    error = %e,
                    failures = consecutive_failures,
                    "screencapture spawn error"
                );
                if consecutive_failures >= MAX_CONSECUTIVE_FAILURES {
                    break;
                }
                continue;
            }
        };
        drop(output);

        // Resize for streaming bandwidth
        let _ = tokio::process::Command::new("sips")
            .args([
                "--resampleHeightWidthMax",
                &MAX_STREAM_DIMENSION.to_string(),
                &tmp_path,
            ])
            .output()
            .await;

        // Read the frame
        let data = match tokio::fs::read(&tmp_path).await {
            Ok(d) if !d.is_empty() => d,
            Ok(_) => {
                // Empty file — skip this frame
                continue;
            }
            Err(e) => {
                warn!(stream_id = %config.stream_id, error = %e, "Failed to read frame");
                continue;
            }
        };

        // Reset failure counter on success
        consecutive_failures = 0;

        // Parse JPEG dimensions (SOF0 marker)
        let (width, height) = jpeg_dimensions(&data).unwrap_or((0, 0));

        // Encode and emit
        let b64 = base64::engine::general_purpose::STANDARD.encode(&data);
        last_frame_data = Some(data);
        frame_id += 1;

        let _ = event_tx.send(TronEvent::DisplayFrame {
            base: BaseEvent::now(&config.session_id),
            stream_id: config.stream_id.clone(),
            tool_call_id: config.tool_call_id.clone(),
            data: b64,
            frame_id,
            width,
            height,
        });
    }

    // Cleanup temp file
    let _ = tokio::fs::remove_file(&tmp_path).await;

    debug!(
        stream_id = %config.stream_id,
        total_frames = frame_id,
        "Screen capture loop ended"
    );

    last_frame_data
}

/// Extract width and height from JPEG data by scanning for SOF0 marker (0xFFC0).
fn jpeg_dimensions(data: &[u8]) -> Option<(u32, u32)> {
    // Scan for SOF0 marker (0xFF 0xC0) or SOF2 (0xFF 0xC2)
    let mut i = 0;
    while i + 1 < data.len() {
        if data[i] == 0xFF && (data[i + 1] == 0xC0 || data[i + 1] == 0xC2) {
            // SOF marker found — dimensions at offset +5 (height) and +7 (width)
            if i + 8 < data.len() {
                let height = u16::from_be_bytes([data[i + 5], data[i + 6]]) as u32;
                let width = u16::from_be_bytes([data[i + 7], data[i + 8]]) as u32;
                return Some((width, height));
            }
        }
        i += 1;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── ActiveStreamRegistry ──────────────────────────────────

    #[test]
    fn registry_cancel_returns_true_for_existing() {
        let reg = ActiveStreamRegistry::new();
        let token = CancellationToken::new();
        reg.insert("s1", token.clone());
        assert!(reg.cancel("s1"));
        assert!(token.is_cancelled());
    }

    #[test]
    fn registry_cancel_returns_false_for_missing() {
        let reg = ActiveStreamRegistry::new();
        assert!(!reg.cancel("nonexistent"));
    }

    #[test]
    fn registry_remove_cleans_up() {
        let reg = ActiveStreamRegistry::new();
        let token = CancellationToken::new();
        reg.insert("s1", token.clone());
        reg.remove("s1");
        assert!(!reg.cancel("s1"));
        assert!(!token.is_cancelled());
    }

    // ── JPEG dimensions ───────────────────────────────────────

    #[test]
    fn jpeg_dimensions_parses_sof0() {
        // Minimal JPEG with SOF0 marker: FF C0, length, precision, height, width
        let mut data = vec![0xFF, 0xD8]; // SOI
        data.extend_from_slice(&[0xFF, 0xC0]); // SOF0
        data.extend_from_slice(&[0x00, 0x11]); // length
        data.push(0x08); // precision
        data.extend_from_slice(&[0x02, 0xD0]); // height = 720
        data.extend_from_slice(&[0x05, 0x00]); // width = 1280
        assert_eq!(jpeg_dimensions(&data), Some((1280, 720)));
    }

    #[test]
    fn jpeg_dimensions_returns_none_for_non_jpeg() {
        assert_eq!(jpeg_dimensions(&[0x00, 0x01, 0x02]), None);
    }

    #[test]
    fn jpeg_dimensions_returns_none_for_empty() {
        assert_eq!(jpeg_dimensions(&[]), None);
    }

    #[tokio::test]
    async fn producer_stops_on_cancel() {
        let (tx, _rx) = broadcast::channel::<TronEvent>(16);
        let cancel = CancellationToken::new();
        let cancel_clone = cancel.clone();

        let config = StreamConfig {
            interval: Duration::from_millis(100),
            session_id: "test".into(),
            stream_id: "s1".into(),
            tool_call_id: "t1".into(),
        };

        // Cancel immediately
        cancel_clone.cancel();

        let handle = tokio::spawn(screen_capture_loop(tx, config, cancel));
        let result = tokio::time::timeout(Duration::from_secs(5), handle)
            .await
            .expect("should not timeout")
            .expect("task should not panic");

        // Should return None since cancelled before any frames
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn producer_emits_frames_then_stops() {
        let (tx, mut rx) = broadcast::channel::<TronEvent>(64);
        let cancel = CancellationToken::new();
        let cancel_clone = cancel.clone();

        let config = StreamConfig {
            interval: Duration::from_millis(200),
            session_id: "test".into(),
            stream_id: "s1".into(),
            tool_call_id: "t1".into(),
        };

        let handle = tokio::spawn(screen_capture_loop(tx, config, cancel));

        // Wait for at least 2 frames (or timeout)
        let mut frame_count = 0u64;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
        while tokio::time::Instant::now() < deadline && frame_count < 2 {
            match tokio::time::timeout(Duration::from_secs(1), rx.recv()).await {
                Ok(Ok(TronEvent::DisplayFrame { frame_id, .. })) => {
                    frame_count = frame_id;
                }
                _ => break,
            }
        }

        cancel_clone.cancel();
        let last_frame = tokio::time::timeout(Duration::from_secs(5), handle)
            .await
            .expect("should not timeout")
            .expect("task should not panic");

        // On macOS with screencapture available, we should have frames
        // On CI (no display), frame_count may be 0 — that's OK
        if frame_count > 0 {
            assert!(last_frame.is_some(), "last frame should be captured");
        }
    }

    #[tokio::test]
    async fn producer_increments_frame_ids() {
        let (tx, mut rx) = broadcast::channel::<TronEvent>(64);
        let cancel = CancellationToken::new();
        let cancel_clone = cancel.clone();

        let config = StreamConfig {
            interval: Duration::from_millis(200),
            session_id: "test".into(),
            stream_id: "s1".into(),
            tool_call_id: "t1".into(),
        };

        let handle = tokio::spawn(screen_capture_loop(tx, config, cancel));

        let mut ids = Vec::new();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
        while tokio::time::Instant::now() < deadline && ids.len() < 3 {
            match tokio::time::timeout(Duration::from_secs(1), rx.recv()).await {
                Ok(Ok(TronEvent::DisplayFrame { frame_id, .. })) => {
                    ids.push(frame_id);
                }
                _ => break,
            }
        }

        cancel_clone.cancel();
        let _ = handle.await;

        // Frame IDs should be strictly increasing
        if ids.len() >= 2 {
            for w in ids.windows(2) {
                assert!(w[1] > w[0], "frame IDs should be monotonically increasing");
            }
        }
    }

    #[test]
    fn stream_config_fields() {
        let config = StreamConfig {
            interval: Duration::from_millis(333),
            session_id: "s1".into(),
            stream_id: "stream-1".into(),
            tool_call_id: "tool-1".into(),
        };
        assert_eq!(config.interval, Duration::from_millis(333));
        assert_eq!(config.session_id, "s1");
        assert_eq!(config.stream_id, "stream-1");
        assert_eq!(config.tool_call_id, "tool-1");
    }
}
