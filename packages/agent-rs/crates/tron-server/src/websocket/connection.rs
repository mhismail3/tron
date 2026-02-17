//! WebSocket client connection state.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

use parking_lot::Mutex;
use tokio::sync::mpsc;

/// Represents a connected WebSocket client.
pub struct ClientConnection {
    /// Unique connection ID.
    pub id: String,
    /// Bound session ID (set after `session.create` / `session.resume`).
    session_id: Mutex<Option<String>>,
    /// Send channel to the client's WebSocket write task.
    tx: mpsc::Sender<Arc<String>>,
    /// When this connection was established.
    pub connected_at: Instant,
    /// Whether the client has responded to the last ping.
    pub is_alive: AtomicBool,
    /// When the last Pong (or any activity) was received.
    last_pong: Mutex<Instant>,
    /// Count of messages dropped due to full channel.
    pub dropped_messages: AtomicU64,
}

impl ClientConnection {
    /// Create a new connection.
    pub fn new(id: String, tx: mpsc::Sender<Arc<String>>) -> Self {
        let now = Instant::now();
        Self {
            id,
            session_id: Mutex::new(None),
            tx,
            connected_at: now,
            is_alive: AtomicBool::new(true),
            last_pong: Mutex::new(now),
            dropped_messages: AtomicU64::new(0),
        }
    }

    /// Bind this connection to a session.
    pub fn bind_session(&self, session_id: String) {
        *self.session_id.lock() = Some(session_id);
    }

    /// Get the current bound session ID.
    pub fn session_id(&self) -> Option<String> {
        self.session_id.lock().clone()
    }

    /// Send a text message to the client.
    ///
    /// Returns `false` if the channel is full or closed, and increments
    /// the dropped message counter.
    pub fn send(&self, message: Arc<String>) -> bool {
        if self.tx.try_send(message).is_ok() {
            true
        } else {
            let _ = self.dropped_messages.fetch_add(1, Ordering::Relaxed);
            false
        }
    }

    /// Total messages dropped for this connection.
    pub fn drop_count(&self) -> u64 {
        self.dropped_messages.load(Ordering::Relaxed)
    }

    /// Serialize a JSON value and send it to the client.
    pub fn send_json(&self, value: &serde_json::Value) -> bool {
        match serde_json::to_string(value) {
            Ok(json) => self.send(Arc::new(json)),
            Err(_) => false,
        }
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

    fn make_connection() -> (ClientConnection, mpsc::Receiver<Arc<String>>) {
        let (tx, rx) = mpsc::channel(32);
        let conn = ClientConnection::new("conn_1".into(), tx);
        (conn, rx)
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
        assert!(sent);
        let msg = rx.recv().await.unwrap();
        assert_eq!(&*msg, "hello");
    }

    #[tokio::test]
    async fn send_to_closed_channel_returns_false() {
        let (tx, rx) = mpsc::channel(32);
        let conn = ClientConnection::new("conn_2".into(), tx);
        drop(rx);
        let sent = conn.send(Arc::new("hello".into()));
        assert!(!sent);
    }

    #[tokio::test]
    async fn send_to_full_channel_returns_false() {
        let (tx, _rx) = mpsc::channel(1);
        let conn = ClientConnection::new("conn_3".into(), tx);
        // Fill the channel
        let first = conn.send(Arc::new("msg1".into()));
        assert!(first);
        // Channel is now full
        let second = conn.send(Arc::new("msg2".into()));
        assert!(!second);
    }

    #[test]
    fn bind_session() {
        let (conn, _rx) = make_connection();
        assert!(conn.session_id().is_none());
        conn.bind_session("sess_42".into());
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
        assert!(sent);
        let msg = rx.recv().await.unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&*msg).unwrap();
        assert_eq!(parsed["key"], "value");
    }

    #[tokio::test]
    async fn send_json_to_closed_channel() {
        let (tx, rx) = mpsc::channel(32);
        let conn = ClientConnection::new("conn_4".into(), tx);
        drop(rx);
        let value = serde_json::json!({"test": true});
        let sent = conn.send_json(&value);
        assert!(!sent);
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
        conn.bind_session("sess_1".into());
        assert_eq!(conn.session_id().as_deref(), Some("sess_1"));
        conn.bind_session("sess_2".into());
        assert_eq!(conn.session_id().as_deref(), Some("sess_2"));
    }

    #[tokio::test]
    async fn send_multiple_messages() {
        let (conn, mut rx) = make_connection();
        for i in 0..5 {
            let sent = conn.send(Arc::new(format!("msg_{i}")));
            assert!(sent);
        }
        for i in 0..5 {
            let msg = rx.recv().await.unwrap();
            assert_eq!(&*msg, &format!("msg_{i}"));
        }
    }

    #[test]
    fn new_connection_id() {
        let (tx, _rx) = mpsc::channel(32);
        let conn = ClientConnection::new("custom_id_123".into(), tx);
        assert_eq!(conn.id, "custom_id_123");
    }

    #[tokio::test]
    async fn send_empty_string() {
        let (conn, mut rx) = make_connection();
        let sent = conn.send(Arc::new(String::new()));
        assert!(sent);
        let msg = rx.recv().await.unwrap();
        assert!(msg.is_empty());
    }
}
