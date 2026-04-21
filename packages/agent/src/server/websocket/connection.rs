//! WebSocket client connection state.
//!
//! ## Broadcast sequence
//!
//! Every outbound WebSocket frame carries a monotonic, per-connection
//! `broadcastSeq` field spliced as the first key of the top-level JSON
//! object by [`stamp_broadcast_seq`]. The sequence starts at 1 on a new
//! connection and advances on every successful enqueue — drops and closes
//! do NOT consume a sequence number, so a gap in the client-observed
//! values is a strict signal that the server actually sent (and
//! subsequently lost) a message.
//!
//! Clients detect gaps by comparing the received `broadcastSeq` against
//! the last one they saw. On a gap they call `events.getSince(lastEventSeq)`
//! to backfill missed session events via the event-log sequence. The
//! broadcast sequence is purely the gap DETECTION signal; the event-log
//! sequence drives the catch-up QUERY.

use std::collections::VecDeque;
use std::ops::Deref;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use metrics::{counter, histogram};
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
    /// Monotonic per-connection sequence number. The outbound forwarder
    /// splices `"broadcastSeq": N,` into the wire JSON so the client can
    /// detect gaps (dropped / reordered) messages and trigger a catch-up.
    pub broadcast_seq: u64,
}

impl Deref for OutboundMessage {
    type Target = str;

    fn deref(&self) -> &Self::Target {
        self.text.as_str()
    }
}

/// Produce the final wire JSON for `payload`, splicing `"broadcastSeq":N`
/// as the first key of the top-level object. Every tron wire message is a
/// JSON object, so the logic is deterministic:
///
/// - `{}` + seq=5 → `{"broadcastSeq":5}`
/// - `{"foo":1}` + seq=5 → `{"broadcastSeq":5,"foo":1}`
///
/// If `payload` is not a JSON object (no leading `{`), the function returns
/// it unchanged — this is a safety net; every real caller passes an object.
pub fn stamp_broadcast_seq(mut payload: String, seq: u64) -> String {
    let Some(open) = payload.find('{') else {
        debug_assert!(false, "outbound payload is not a JSON object");
        return payload;
    };
    let after_open = open + 1;
    let body_is_empty = payload[after_open..].trim_start().starts_with('}');
    let insertion = if body_is_empty {
        format!(r#""broadcastSeq":{seq}"#)
    } else {
        format!(r#""broadcastSeq":{seq},"#)
    };
    payload.insert_str(after_open, &insertion);
    payload
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
    /// Per-connection monotonic broadcast sequence. Advances on every
    /// successful `send`; never resets. Clients compare the received
    /// `broadcastSeq` against the last seen and trigger a catch-up if a
    /// gap appears (missed message). INVARIANT: strictly increasing by 1
    /// for every message that actually enters the outbound queue.
    next_broadcast_seq: AtomicU64,
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
            next_broadcast_seq: AtomicU64::new(1),
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
    ///
    /// Sequence semantics:
    /// - `Overloaded`: no seq is allocated; the client's gap detection
    ///   does not see a phantom gap for drops the server proactively
    ///   refused on the byte budget.
    /// - `Enqueued`: a fresh per-connection seq is attached.
    /// - `Closed`: the channel is gone (receiver dropped), so the
    ///   connection is terminal. We may have consumed a seq — that's
    ///   acceptable because the only client that could observe the gap
    ///   is this one, and it will never receive another frame on this
    ///   connection.
    pub fn send(&self, message: Arc<String>) -> SendOutcome {
        let size_bytes = message.len();
        if !self.reserve_bytes(size_bytes) {
            return SendOutcome::Overloaded(self.record_drop());
        }

        let broadcast_seq = self.next_broadcast_seq.fetch_add(1, Ordering::Relaxed);

        if self
            .tx
            .send(OutboundMessage {
                text: message,
                size_bytes,
                broadcast_seq,
            })
            .is_ok()
        {
            SendOutcome::Enqueued
        } else {
            self.release_bytes(size_bytes);
            SendOutcome::Closed
        }
    }

    /// Last sequence that will be assigned on the next send. Exposed for
    /// testing and metrics; reads as-of-now (not authoritative under concurrent sends).
    pub fn next_broadcast_seq(&self) -> u64 {
        self.next_broadcast_seq.load(Ordering::Relaxed)
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
        counter!("ws_connection_overloads_total").increment(1);
        histogram!("ws_connection_overload_pending_bytes").record(self.pending_bytes() as f64);
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
            counter!("ws_connection_close_requests_total").increment(1);
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

    // ── Per-connection broadcast sequence + stamping ─────────────────────

    #[tokio::test]
    async fn send_assigns_monotonic_broadcast_seq() {
        let (conn, mut rx) = make_connection();

        for _ in 0..3 {
            assert_eq!(
                conn.send(Arc::new(r#"{"type":"x"}"#.to_string())),
                SendOutcome::Enqueued
            );
        }

        let m1 = rx.recv().await.unwrap();
        let m2 = rx.recv().await.unwrap();
        let m3 = rx.recv().await.unwrap();
        assert_eq!(m1.broadcast_seq, 1);
        assert_eq!(m2.broadcast_seq, 2);
        assert_eq!(m3.broadcast_seq, 3);
        for m in [m1, m2, m3] {
            conn.complete_send(m.size_bytes);
        }
    }

    #[tokio::test]
    async fn broadcast_seq_is_per_connection() {
        let (c1, mut r1) = make_connection();
        let (tx2, mut r2) = mpsc::unbounded_channel();
        let c2 = ClientConnection::new("conn_2".into(), tx2);

        let _ = c1.send(Arc::new(r#"{"a":1}"#.to_string()));
        let _ = c2.send(Arc::new(r#"{"b":2}"#.to_string()));
        let _ = c1.send(Arc::new(r#"{"a":3}"#.to_string()));

        let c1_m1 = r1.recv().await.unwrap();
        let c1_m2 = r1.recv().await.unwrap();
        let c2_m1 = r2.recv().await.unwrap();

        assert_eq!(c1_m1.broadcast_seq, 1);
        assert_eq!(c1_m2.broadcast_seq, 2);
        assert_eq!(
            c2_m1.broadcast_seq, 1,
            "second connection must start its own sequence at 1"
        );
    }

    /// A send on a closed channel returns `Closed` without panicking,
    /// even though a seq was allocated internally. Closed is terminal,
    /// the gap is not observable by any client.
    #[tokio::test]
    async fn send_on_closed_channel_returns_closed_not_panic() {
        let (tx, rx) = mpsc::unbounded_channel();
        let conn = ClientConnection::new("dead".into(), tx);
        drop(rx); // simulate receiver going away

        let outcome = conn.send(Arc::new(r#"{"type":"x"}"#.to_string()));
        assert_eq!(outcome, SendOutcome::Closed);

        // Reserved bytes must be released — otherwise a closed connection
        // would still show pending_bytes pressure in diagnostics.
        assert_eq!(
            conn.pending_bytes(),
            0,
            "reserved bytes must be released on Closed"
        );
    }

    #[tokio::test]
    async fn drop_does_not_advance_broadcast_seq() {
        let (conn, mut rx) = make_limited_connection(ConnectionLimits {
            // 10-byte budget so the first ~10-byte message fits; the second
            // would push over and is rejected without ever being queued.
            max_pending_bytes: 10,
            drop_window: Duration::from_secs(60),
            max_recent_drops: 100,
        });

        assert_eq!(
            conn.send(Arc::new(r#"{"k":"v"}"#.to_string())),
            SendOutcome::Enqueued
        );
        let first = rx.recv().await.unwrap();
        conn.complete_send(first.size_bytes);
        assert_eq!(first.broadcast_seq, 1);

        // Queue is drained; second would fit. Instead, a payload that over-
        // flows the byte budget is rejected and MUST NOT advance the seq.
        let big = Arc::new("x".repeat(20));
        let outcome = conn.send(big);
        assert!(matches!(outcome, SendOutcome::Overloaded(_)));

        // Next successful send should be seq=2, not seq=3.
        assert_eq!(
            conn.send(Arc::new(r#"{"k":"w"}"#.to_string())),
            SendOutcome::Enqueued
        );
        let second = rx.recv().await.unwrap();
        assert_eq!(second.broadcast_seq, 2, "drops must not consume a sequence");
        conn.complete_send(second.size_bytes);
    }

    #[test]
    fn stamp_broadcast_seq_splices_into_object() {
        let out = stamp_broadcast_seq(r#"{"foo":"bar"}"#.to_string(), 42);
        assert_eq!(out, r#"{"broadcastSeq":42,"foo":"bar"}"#);
    }

    #[test]
    fn stamp_broadcast_seq_handles_empty_object() {
        let out = stamp_broadcast_seq("{}".to_string(), 5);
        assert_eq!(out, r#"{"broadcastSeq":5}"#);
    }

    #[test]
    fn stamp_broadcast_seq_preserves_whitespace_in_empty_body() {
        // Unlikely in practice (serde_json emits compact JSON), but we still
        // want well-formed output.
        let out = stamp_broadcast_seq("{ }".to_string(), 7);
        assert!(out.starts_with(r#"{"broadcastSeq":7"#));
        let parsed: serde_json::Value = serde_json::from_str(&out).expect("valid JSON");
        assert_eq!(parsed["broadcastSeq"], 7);
    }

    #[test]
    fn stamp_broadcast_seq_result_is_valid_json() {
        let base = serde_json::json!({
            "type": "agent.text_delta",
            "sessionId": "s1",
            "data": {"text": "hi"},
        });
        let serialized = serde_json::to_string(&base).unwrap();
        let stamped = stamp_broadcast_seq(serialized, 99);
        let parsed: serde_json::Value = serde_json::from_str(&stamped).expect("valid JSON");
        assert_eq!(parsed["broadcastSeq"], 99);
        assert_eq!(parsed["type"], "agent.text_delta");
        assert_eq!(parsed["data"]["text"], "hi");
    }
}
