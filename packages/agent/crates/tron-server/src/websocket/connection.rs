//! WebSocket client connection state.

use std::collections::VecDeque;
use std::ops::Deref;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use parking_lot::RwLock;
use tokio::sync::{Notify, mpsc};

/// Default maximum number of queued outbound bytes per connection.
pub const DEFAULT_MAX_PENDING_BYTES: usize = 4 * 1024 * 1024;
/// Default recent-overload window for deciding whether a client is persistently slow.
pub const DEFAULT_DROP_WINDOW: Duration = Duration::from_secs(10);
/// Default number of drops allowed inside the recent window before disconnecting.
pub const DEFAULT_MAX_RECENT_DROPS: usize = 64;

/// Serialized outbound WebSocket payload tracked with its queue footprint.
#[derive(Debug)]
pub struct OutboundMessage {
    /// Serialized JSON payload to write to the socket.
    pub text: Arc<String>,
    /// Number of bytes currently reserved in the per-connection queue budget.
    pub size_bytes: usize,
}

impl Deref for OutboundMessage {
    type Target = str;

    fn deref(&self) -> &Self::Target {
        self.text.as_str()
    }
}

/// Per-connection queue and overload limits.
#[derive(Clone, Copy, Debug)]
pub struct ConnectionLimits {
    /// Maximum queued outbound bytes allowed at once for this connection.
    pub max_pending_bytes: usize,
    /// Time window used to measure recent enqueue drops.
    pub drop_window: Duration,
    /// Drop count inside `drop_window` that forces the connection to close.
    pub max_recent_drops: usize,
}

impl Default for ConnectionLimits {
    fn default() -> Self {
        Self {
            max_pending_bytes: DEFAULT_MAX_PENDING_BYTES,
            drop_window: DEFAULT_DROP_WINDOW,
            max_recent_drops: DEFAULT_MAX_RECENT_DROPS,
        }
    }
}

/// Snapshot of the recent drop window after a failed enqueue.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DropHealth {
    /// Drops still inside the active recent-overload window.
    pub recent_drops: usize,
    /// Lifetime number of dropped messages for this connection.
    pub total_drops: u64,
    /// Whether the connection should be disconnected for sustained overload.
    pub should_disconnect: bool,
}

/// Result of attempting to enqueue an outbound WebSocket message.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SendOutcome {
    /// The payload was accepted into the outbound queue.
    Enqueued,
    /// The writer task has already gone away.
    Closed,
    /// The connection exceeded its queue budget or overload threshold.
    Overloaded(DropHealth),
}

#[derive(Debug)]
struct DropWindowState {
    events: VecDeque<Instant>,
}

impl DropWindowState {
    fn new() -> Self {
        Self {
            events: VecDeque::new(),
        }
    }

    fn record_drop(
        &mut self,
        now: Instant,
        limits: ConnectionLimits,
        total_drops: u64,
    ) -> DropHealth {
        let cutoff = now.checked_sub(limits.drop_window).unwrap_or(now);
        while self.events.front().is_some_and(|instant| *instant < cutoff) {
            let _ = self.events.pop_front();
        }
        self.events.push_back(now);
        let recent_drops = self.events.len();
        DropHealth {
            recent_drops,
            total_drops,
            should_disconnect: recent_drops >= limits.max_recent_drops,
        }
    }

    fn recent_drops(&mut self, now: Instant, window: Duration) -> usize {
        let cutoff = now.checked_sub(window).unwrap_or(now);
        while self.events.front().is_some_and(|instant| *instant < cutoff) {
            let _ = self.events.pop_front();
        }
        self.events.len()
    }
}

/// Represents a connected WebSocket client.
pub struct ClientConnection {
    /// Unique connection ID.
    pub id: String,
    /// Bound session ID (set after `session.create` / `session.resume`).
    session_id: RwLock<Option<Arc<str>>>,
    /// Send channel to the client's WebSocket write task.
    tx: mpsc::UnboundedSender<OutboundMessage>,
    /// When this connection was established.
    pub connected_at: Instant,
    /// Whether the client has responded to the last ping.
    pub is_alive: AtomicBool,
    /// When the last Pong (or any activity) was received.
    last_pong: parking_lot::Mutex<Instant>,
    /// Current queued outbound bytes waiting to reach the socket.
    pending_bytes: AtomicUsize,
    /// Monotonically increasing count of dropped messages.
    dropped_messages_total: AtomicU64,
    /// Recent-drop window used to disconnect only persistently overloaded clients.
    drop_window: parking_lot::Mutex<DropWindowState>,
    /// Queue/drop thresholds for this connection.
    limits: ConnectionLimits,
    /// Raised when the connection should close due to sustained overload.
    close_requested: AtomicBool,
    /// Notifies the session loop and writer task that the connection should close.
    close_notify: Notify,
}

impl ClientConnection {
    /// Create a new connection.
    pub fn new(id: String, tx: mpsc::UnboundedSender<OutboundMessage>) -> Self {
        Self::new_with_limits(id, tx, ConnectionLimits::default())
    }

    /// Create a new connection with explicit queue/drop limits.
    pub fn new_with_limits(
        id: String,
        tx: mpsc::UnboundedSender<OutboundMessage>,
        limits: ConnectionLimits,
    ) -> Self {
        let now = Instant::now();
        Self {
            id,
            session_id: RwLock::new(None),
            tx,
            connected_at: now,
            is_alive: AtomicBool::new(true),
            last_pong: parking_lot::Mutex::new(now),
            pending_bytes: AtomicUsize::new(0),
            dropped_messages_total: AtomicU64::new(0),
            drop_window: parking_lot::Mutex::new(DropWindowState::new()),
            limits,
            close_requested: AtomicBool::new(false),
            close_notify: Notify::new(),
        }
    }

    /// Bind this connection to a session.
    pub fn bind_session(&self, session_id: &str) {
        *self.session_id.write() = Some(Arc::from(session_id));
    }

    /// Get the current bound session ID.
    pub fn session_id(&self) -> Option<Arc<str>> {
        self.session_id.read().clone()
    }

    /// Send a text message to the client.
    ///
    /// Returns whether the message was queued, the queue was closed, or the
    /// connection is overloaded beyond its byte budget.
    pub fn send(&self, message: Arc<String>) -> SendOutcome {
        let size_bytes = message.len();
        if !self.reserve_bytes(size_bytes) {
            return SendOutcome::Overloaded(self.record_drop());
        }

        if self
            .tx
            .send(OutboundMessage {
                text: message,
                size_bytes,
            })
            .is_ok()
        {
            SendOutcome::Enqueued
        } else {
            self.release_bytes(size_bytes);
            SendOutcome::Closed
        }
    }

    fn reserve_bytes(&self, size_bytes: usize) -> bool {
        if size_bytes > self.limits.max_pending_bytes {
            return false;
        }
        let mut current = self.pending_bytes.load(Ordering::Relaxed);
        loop {
            let Some(next) = current.checked_add(size_bytes) else {
                return false;
            };
            if next > self.limits.max_pending_bytes {
                return false;
            }
            match self.pending_bytes.compare_exchange_weak(
                current,
                next,
                Ordering::SeqCst,
                Ordering::Relaxed,
            ) {
                Ok(_) => return true,
                Err(observed) => current = observed,
            }
        }
    }

    /// Serialize a JSON value and send it to the client.
    pub fn send_json(&self, value: &serde_json::Value) -> SendOutcome {
        match serde_json::to_string(value) {
            Ok(json) => self.send(Arc::new(json)),
            Err(_) => SendOutcome::Closed,
        }
    }

    fn release_bytes(&self, size_bytes: usize) {
        let _ = self
            .pending_bytes
            .fetch_update(Ordering::SeqCst, Ordering::Relaxed, |current| {
                Some(current.saturating_sub(size_bytes))
            });
    }

    fn record_drop(&self) -> DropHealth {
        let total_drops = self.dropped_messages_total.fetch_add(1, Ordering::Relaxed) + 1;
        let health = self
            .drop_window
            .lock()
            .record_drop(Instant::now(), self.limits, total_drops);
        tracing::warn!(
            connection_id = %self.id,
            recent_drops = health.recent_drops,
            total_drops = health.total_drops,
            pending_bytes = self.pending_bytes(),
            "WebSocket outbound queue rejected message"
        );
        health
    }

    /// Mark a queued outbound message as fully written to the socket.
    pub fn complete_send(&self, size_bytes: usize) {
        self.release_bytes(size_bytes);
    }

    /// Current queued outbound byte count.
    pub fn pending_bytes(&self) -> usize {
        self.pending_bytes.load(Ordering::Relaxed)
    }

    /// Total dropped messages across the life of the connection.
    pub fn total_drop_count(&self) -> u64 {
        self.dropped_messages_total.load(Ordering::Relaxed)
    }

    /// Number of drops still inside the recent overload window.
    pub fn recent_drop_count(&self) -> usize {
        self.drop_window
            .lock()
            .recent_drops(Instant::now(), self.limits.drop_window)
    }

    /// Request that the session close this connection.
    pub fn request_close(&self) {
        if !self.close_requested.swap(true, Ordering::SeqCst) {
            self.close_notify.notify_waiters();
        }
    }

    /// Whether the connection has been marked for closure.
    pub fn should_close(&self) -> bool {
        self.close_requested.load(Ordering::SeqCst)
    }

    /// Wait until the connection is marked for closure.
    pub async fn close_requested(&self) {
        if self.should_close() {
            return;
        }
        self.close_notify.notified().await;
    }

    /// Mark the connection as alive (pong received).
    pub fn mark_alive(&self) {
        self.is_alive.store(true, Ordering::Relaxed);
        *self.last_pong.lock() = Instant::now();
    }

    /// Duration since the last pong (or connection establishment).
    pub fn last_pong_elapsed(&self) -> Duration {
        self.last_pong.lock().elapsed()
    }

    /// Check and reset the alive flag for heartbeat.
    ///
    /// Returns `true` if the connection was alive since the last check.
    pub fn check_alive(&self) -> bool {
        self.is_alive.swap(false, Ordering::Relaxed)
    }

    /// Connection age.
    pub fn age(&self) -> Duration {
        self.connected_at.elapsed()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_connection() -> (ClientConnection, mpsc::UnboundedReceiver<OutboundMessage>) {
        let (tx, rx) = mpsc::unbounded_channel();
        let conn = ClientConnection::new("conn_1".into(), tx);
        (conn, rx)
    }

    fn make_limited_connection(
        limits: ConnectionLimits,
    ) -> (ClientConnection, mpsc::UnboundedReceiver<OutboundMessage>) {
        let (tx, rx) = mpsc::unbounded_channel();
        (
            ClientConnection::new_with_limits("conn_1".into(), tx, limits),
            rx,
        )
    }

    #[test]
    fn create_connection() {
        let (conn, _rx) = make_connection();
        assert_eq!(conn.id, "conn_1");
        assert!(conn.session_id().is_none());
        assert!(conn.is_alive.load(Ordering::Relaxed));
    }

    #[tokio::test]
    async fn send_message_success() {
        let (conn, mut rx) = make_connection();
        let sent = conn.send(Arc::new("hello".into()));
        assert_eq!(sent, SendOutcome::Enqueued);
        let msg = rx.recv().await.unwrap();
        assert_eq!(&*msg.text, "hello");
        conn.complete_send(msg.size_bytes);
    }

    #[tokio::test]
    async fn send_to_closed_channel_returns_false() {
        let (tx, rx) = mpsc::unbounded_channel();
        let conn = ClientConnection::new("conn_2".into(), tx);
        drop(rx);
        let sent = conn.send(Arc::new("hello".into()));
        assert_eq!(sent, SendOutcome::Closed);
    }

    #[tokio::test]
    async fn send_rejects_when_byte_budget_exceeded() {
        let (conn, _rx) = make_limited_connection(ConnectionLimits {
            max_pending_bytes: 8,
            drop_window: Duration::from_secs(60),
            max_recent_drops: 4,
        });
        let second = conn.send(Arc::new("123456789".into()));
        assert!(matches!(second, SendOutcome::Overloaded(_)));
    }

    #[test]
    fn bind_session() {
        let (conn, _rx) = make_connection();
        assert!(conn.session_id().is_none());
        conn.bind_session("sess_42");
        assert_eq!(conn.session_id().as_deref(), Some("sess_42"));
    }

    #[test]
    fn mark_alive_and_check() {
        let (conn, _rx) = make_connection();
        // Initially alive
        assert!(conn.check_alive());
        // After check, no longer alive
        assert!(!conn.check_alive());
        // Mark alive again
        conn.mark_alive();
        assert!(conn.check_alive());
    }

    #[test]
    fn check_alive_resets_flag() {
        let (conn, _rx) = make_connection();
        conn.mark_alive();
        assert!(conn.check_alive());
        // Second check returns false because flag was reset
        assert!(!conn.check_alive());
    }

    #[tokio::test]
    async fn send_json_serializes() {
        let (conn, mut rx) = make_connection();
        let value = serde_json::json!({"key": "value"});
        let sent = conn.send_json(&value);
        assert_eq!(sent, SendOutcome::Enqueued);
        let msg = rx.recv().await.unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&msg.text).unwrap();
        assert_eq!(parsed["key"], "value");
        conn.complete_send(msg.size_bytes);
    }

    #[tokio::test]
    async fn send_json_to_closed_channel() {
        let (tx, rx) = mpsc::unbounded_channel();
        let conn = ClientConnection::new("conn_4".into(), tx);
        drop(rx);
        let value = serde_json::json!({"test": true});
        let sent = conn.send_json(&value);
        assert_eq!(sent, SendOutcome::Closed);
    }

    #[test]
    fn connection_age_increases() {
        let (conn, _rx) = make_connection();
        let age1 = conn.age();
        std::thread::sleep(std::time::Duration::from_millis(10));
        let age2 = conn.age();
        assert!(age2 > age1);
    }

    #[test]
    fn rebind_session() {
        let (conn, _rx) = make_connection();
        conn.bind_session("sess_1");
        assert_eq!(conn.session_id().as_deref(), Some("sess_1"));
        conn.bind_session("sess_2");
        assert_eq!(conn.session_id().as_deref(), Some("sess_2"));
    }

    #[tokio::test]
    async fn send_multiple_messages() {
        let (conn, mut rx) = make_connection();
        for i in 0..5 {
            let sent = conn.send(Arc::new(format!("msg_{i}")));
            assert_eq!(sent, SendOutcome::Enqueued);
        }
        for i in 0..5 {
            let msg = rx.recv().await.unwrap();
            assert_eq!(&*msg.text, &format!("msg_{i}"));
            conn.complete_send(msg.size_bytes);
        }
    }

    #[test]
    fn new_connection_id() {
        let (tx, _rx) = mpsc::unbounded_channel();
        let conn = ClientConnection::new("custom_id_123".into(), tx);
        assert_eq!(conn.id, "custom_id_123");
    }

    #[tokio::test]
    async fn send_empty_string() {
        let (conn, mut rx) = make_connection();
        let sent = conn.send(Arc::new(String::new()));
        assert_eq!(sent, SendOutcome::Enqueued);
        let msg = rx.recv().await.unwrap();
        assert!(msg.text.is_empty());
        conn.complete_send(msg.size_bytes);
    }

    #[test]
    fn session_id_returns_arc_str() {
        let (conn, _rx) = make_connection();
        conn.bind_session("sess_arc");
        let id1 = conn.session_id().unwrap();
        let id2 = conn.session_id().unwrap();
        assert_eq!(&*id1, "sess_arc");
        // Cheap clone — both point to the same allocation
        assert_eq!(Arc::strong_count(&id1), 3); // id1 + id2 + field
        drop(id2);
        assert_eq!(Arc::strong_count(&id1), 2);
    }

    #[tokio::test]
    async fn complete_send_releases_pending_bytes() {
        let (conn, mut rx) = make_connection();
        assert_eq!(conn.send(Arc::new("payload".into())), SendOutcome::Enqueued);
        assert_eq!(conn.pending_bytes(), "payload".len());
        let message = rx.recv().await.unwrap();
        conn.complete_send(message.size_bytes);
        assert_eq!(conn.pending_bytes(), 0);
    }

    #[test]
    fn total_drop_count_starts_at_zero() {
        let (conn, _rx) = make_connection();
        assert_eq!(conn.total_drop_count(), 0);
        assert_eq!(conn.recent_drop_count(), 0);
    }

    #[test]
    fn recent_drop_window_disconnects_only_after_threshold() {
        let (conn, _rx) = make_limited_connection(ConnectionLimits {
            max_pending_bytes: 1,
            drop_window: Duration::from_secs(60),
            max_recent_drops: 3,
        });

        let first = conn.send(Arc::new("12".into()));
        let second = conn.send(Arc::new("12".into()));
        let third = conn.send(Arc::new("12".into()));

        assert!(matches!(
            first,
            SendOutcome::Overloaded(DropHealth {
                should_disconnect: false,
                ..
            })
        ));
        assert!(matches!(
            second,
            SendOutcome::Overloaded(DropHealth {
                should_disconnect: false,
                ..
            })
        ));
        assert!(matches!(
            third,
            SendOutcome::Overloaded(DropHealth {
                should_disconnect: true,
                ..
            })
        ));
        assert_eq!(conn.total_drop_count(), 3);
        assert_eq!(conn.recent_drop_count(), 3);
    }

    #[test]
    fn request_close_sets_flag() {
        let (conn, _rx) = make_connection();
        assert!(!conn.should_close());
        conn.request_close();
        assert!(conn.should_close());
    }
}
