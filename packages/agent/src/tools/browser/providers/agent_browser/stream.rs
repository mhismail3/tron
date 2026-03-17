//! WebSocket frame bridge: agent-browser viewport stream → `BrowserEvent`.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use parking_lot::RwLock;
use serde::Deserialize;
use tokio::sync::broadcast;
use tokio::task::JoinHandle;
use tokio_util::sync::CancellationToken;

use crate::tools::browser::types::{BrowserEvent, BrowserFrame, FrameMetadata};

fn default_width() -> u32 {
    1280
}
fn default_height() -> u32 {
    960
}
fn default_scale() -> f64 {
    1.0
}

/// WebSocket message format from agent-browser.
#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum StreamMessage {
    #[serde(rename = "frame")]
    Frame {
        data: String,
        #[serde(default = "default_width")]
        device_width: u32,
        #[serde(default = "default_height")]
        device_height: u32,
        #[serde(default = "default_scale")]
        page_scale_factor: f64,
        #[serde(default)]
        offset_top: f64,
        #[serde(default)]
        scroll_offset_x: f64,
        #[serde(default)]
        scroll_offset_y: f64,
    },
}

/// Bridges agent-browser's WebSocket viewport stream to `BrowserEvent`.
pub struct StreamBridge {
    port: u16,
    frame_tx: broadcast::Sender<BrowserEvent>,
    streaming_session: Arc<RwLock<Option<String>>>,
    frame_counter: Arc<AtomicU64>,
    cancel: CancellationToken,
    handle: parking_lot::Mutex<Option<JoinHandle<()>>>,
}

impl StreamBridge {
    /// Create a new stream bridge.
    pub fn new(port: u16, frame_tx: broadcast::Sender<BrowserEvent>) -> Self {
        Self {
            port,
            frame_tx,
            streaming_session: Arc::new(RwLock::new(None)),
            frame_counter: Arc::new(AtomicU64::new(0)),
            cancel: CancellationToken::new(),
            handle: parking_lot::Mutex::new(None),
        }
    }

    /// Start streaming frames for a session.
    /// Only one session streams at a time.
    pub fn start_stream(&self, session_id: &str) {
        *self.streaming_session.write() = Some(session_id.to_string());
        self.ensure_ws_client();
    }

    /// Stop streaming frames for a session.
    pub fn stop_stream(&self, session_id: &str) {
        let mut guard = self.streaming_session.write();
        if guard.as_deref() == Some(session_id) {
            *guard = None;
        }
    }

    /// Emit a `BrowserEvent::Closed` and clear streaming state.
    pub fn close_session(&self, session_id: &str) {
        self.stop_stream(session_id);
        let _ = self.frame_tx.send(BrowserEvent::Closed {
            session_id: session_id.to_string(),
        });
    }

    /// Whether a session is currently streaming.
    pub fn is_streaming(&self, session_id: &str) -> bool {
        self.streaming_session.read().as_deref() == Some(session_id)
    }

    /// Subscribe to browser events.
    pub fn subscribe(&self) -> broadcast::Receiver<BrowserEvent> {
        self.frame_tx.subscribe()
    }

    /// Shutdown the WebSocket client task.
    pub fn shutdown(&self) {
        self.cancel.cancel();
    }

    fn ensure_ws_client(&self) {
        let mut guard = self.handle.lock();
        // If there's already a running task, don't spawn another
        if let Some(ref h) = *guard && !h.is_finished() {
            return;
        }

        let port = self.port;
        let tx = self.frame_tx.clone();
        let session = self.streaming_session.clone();
        let counter = self.frame_counter.clone();
        let cancel = self.cancel.clone();

        let handle = tokio::spawn(async move {
            ws_client_loop(port, tx, session, counter, cancel).await;
        });
        *guard = Some(handle);
    }
}

async fn ws_client_loop(
    port: u16,
    tx: broadcast::Sender<BrowserEvent>,
    session: Arc<RwLock<Option<String>>>,
    counter: Arc<AtomicU64>,
    cancel: CancellationToken,
) {
    let mut backoff = Duration::from_millis(100);
    let max_backoff = Duration::from_secs(5);

    loop {
        if cancel.is_cancelled() {
            break;
        }

        let url = format!("ws://127.0.0.1:{port}");
        match tokio_tungstenite::connect_async(&url).await {
            Ok((ws_stream, _)) => {
                backoff = Duration::from_millis(100); // reset on success
                handle_ws_stream(ws_stream, &tx, &session, &counter, &cancel).await;
            }
            Err(e) => {
                tracing::debug!(error = %e, port, "WebSocket connection failed, will retry");
            }
        }

        if cancel.is_cancelled() {
            break;
        }

        tokio::select! {
            () = cancel.cancelled() => break,
            () = tokio::time::sleep(backoff) => {}
        }

        backoff = (backoff * 2).min(max_backoff);
        metrics::counter!("browser_stream_reconnects").increment(1);
    }
}

async fn handle_ws_stream(
    ws_stream: tokio_tungstenite::WebSocketStream<
        tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
    >,
    tx: &broadcast::Sender<BrowserEvent>,
    session: &Arc<RwLock<Option<String>>>,
    counter: &Arc<AtomicU64>,
    cancel: &CancellationToken,
) {
    use futures::StreamExt;
    use tokio_tungstenite::tungstenite::Message;

    let (_, mut read) = ws_stream.split();

    loop {
        tokio::select! {
            () = cancel.cancelled() => break,
            msg = read.next() => {
                match msg {
                    Some(Ok(Message::Text(text))) => {
                        handle_text_message(&text, tx, session, counter);
                    }
                    Some(Ok(Message::Close(_))) | None => break,
                    Some(Ok(_)) => {} // binary, ping, pong — ignore
                    Some(Err(e)) => {
                        tracing::debug!(error = %e, "WebSocket read error");
                        break;
                    }
                }
            }
        }
    }
}

fn handle_text_message(
    text: &str,
    tx: &broadcast::Sender<BrowserEvent>,
    session: &Arc<RwLock<Option<String>>>,
    counter: &Arc<AtomicU64>,
) {
    let msg: StreamMessage = match serde_json::from_str(text) {
        Ok(m) => m,
        Err(e) => {
            tracing::debug!(error = %e, "malformed stream message, skipping");
            return;
        }
    };

    let StreamMessage::Frame {
        data,
        device_width,
        device_height,
        page_scale_factor,
        offset_top,
        scroll_offset_x,
        scroll_offset_y,
    } = msg;

    let Some(session_id) = session.read().clone() else {
        return; // no streaming session, drop frame
    };

    let frame_id = counter.fetch_add(1, Ordering::Relaxed);
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;

    let frame = BrowserFrame {
        session_id: session_id.clone(),
        data,
        frame_id,
        timestamp,
        metadata: Some(FrameMetadata {
            offset_top,
            page_scale_factor,
            device_width,
            device_height,
            scroll_offset_x,
            scroll_offset_y,
        }),
    };

    let _ = tx.send(BrowserEvent::Frame {
        session_id,
        frame,
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_bridge() -> (StreamBridge, broadcast::Receiver<BrowserEvent>) {
        let (tx, rx) = broadcast::channel(64);
        let bridge = StreamBridge::new(0, tx);
        (bridge, rx)
    }

    #[tokio::test]
    async fn start_stream_sets_session() {
        let (bridge, _rx) = make_bridge();
        bridge.start_stream("s1");
        assert!(bridge.is_streaming("s1"));
    }

    #[tokio::test]
    async fn stop_stream_clears_session() {
        let (bridge, _rx) = make_bridge();
        bridge.start_stream("s1");
        bridge.stop_stream("s1");
        assert!(!bridge.is_streaming("s1"));
    }

    #[tokio::test]
    async fn stop_stream_ignores_different_session() {
        let (bridge, _rx) = make_bridge();
        bridge.start_stream("s1");
        bridge.stop_stream("s2");
        assert!(bridge.is_streaming("s1"));
    }

    #[tokio::test]
    async fn close_session_emits_closed_event() {
        let (bridge, mut rx) = make_bridge();
        bridge.start_stream("s1");
        bridge.close_session("s1");
        let event = rx.try_recv().unwrap();
        assert!(matches!(event, BrowserEvent::Closed { session_id } if session_id == "s1"));
    }

    #[tokio::test]
    async fn close_session_clears_streaming_session() {
        let (bridge, _rx) = make_bridge();
        bridge.start_stream("s1");
        bridge.close_session("s1");
        assert!(!bridge.is_streaming("s1"));
    }

    #[test]
    fn cancel_token_available() {
        let (bridge, _rx) = make_bridge();
        bridge.shutdown();
        assert!(bridge.cancel.is_cancelled());
    }

    #[test]
    fn subscribe_returns_receiver() {
        let (bridge, _rx) = make_bridge();
        let _rx2 = bridge.subscribe();
    }

    #[test]
    fn handle_text_message_emits_frame() {
        let (tx, mut rx) = broadcast::channel(16);
        let session = Arc::new(RwLock::new(Some("s1".to_string())));
        let counter = Arc::new(AtomicU64::new(0));

        let msg = r#"{"type":"frame","data":"AAAA","deviceWidth":1280,"deviceHeight":960,"pageScaleFactor":1.0}"#;
        handle_text_message(msg, &tx, &session, &counter);

        let event = rx.try_recv().unwrap();
        match event {
            BrowserEvent::Frame { session_id, frame } => {
                assert_eq!(session_id, "s1");
                assert_eq!(frame.data, "AAAA");
                assert_eq!(frame.frame_id, 0);
                assert!(frame.timestamp > 0);
                let meta = frame.metadata.unwrap();
                assert_eq!(meta.device_width, 1280);
                assert_eq!(meta.device_height, 960);
            }
            _ => panic!("expected Frame"),
        }
    }

    #[test]
    fn frame_id_increments() {
        let (tx, _rx) = broadcast::channel(16);
        let session = Arc::new(RwLock::new(Some("s1".to_string())));
        let counter = Arc::new(AtomicU64::new(0));

        let msg = r#"{"type":"frame","data":"A"}"#;
        handle_text_message(msg, &tx, &session, &counter);
        handle_text_message(msg, &tx, &session, &counter);

        assert_eq!(counter.load(Ordering::Relaxed), 2);
    }

    #[test]
    fn frames_dropped_when_no_streaming_session() {
        let (tx, mut rx) = broadcast::channel(16);
        let session = Arc::new(RwLock::new(None));
        let counter = Arc::new(AtomicU64::new(0));

        let msg = r#"{"type":"frame","data":"A"}"#;
        handle_text_message(msg, &tx, &session, &counter);

        assert!(rx.try_recv().is_err());
    }

    #[test]
    fn malformed_json_ignored() {
        let (tx, mut rx) = broadcast::channel(16);
        let session = Arc::new(RwLock::new(Some("s1".to_string())));
        let counter = Arc::new(AtomicU64::new(0));

        handle_text_message("not json", &tx, &session, &counter);
        assert!(rx.try_recv().is_err());
    }

    #[test]
    fn metadata_defaults_when_fields_missing() {
        let (tx, mut rx) = broadcast::channel(16);
        let session = Arc::new(RwLock::new(Some("s1".to_string())));
        let counter = Arc::new(AtomicU64::new(0));

        let msg = r#"{"type":"frame","data":"A"}"#;
        handle_text_message(msg, &tx, &session, &counter);

        let event = rx.try_recv().unwrap();
        match event {
            BrowserEvent::Frame { frame, .. } => {
                let meta = frame.metadata.unwrap();
                assert_eq!(meta.device_width, 1280);
                assert_eq!(meta.device_height, 960);
                assert!((meta.page_scale_factor - 1.0).abs() < f64::EPSILON);
            }
            _ => panic!("expected Frame"),
        }
    }

    #[test]
    fn empty_data_field_still_emits_frame() {
        let (tx, mut rx) = broadcast::channel(16);
        let session = Arc::new(RwLock::new(Some("s1".to_string())));
        let counter = Arc::new(AtomicU64::new(0));

        let msg = r#"{"type":"frame","data":""}"#;
        handle_text_message(msg, &tx, &session, &counter);

        let event = rx.try_recv().unwrap();
        match event {
            BrowserEvent::Frame { frame, .. } => assert_eq!(frame.data, ""),
            _ => panic!("expected Frame"),
        }
    }
}
