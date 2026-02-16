use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::extract::ws::{Message as WsMessage, WebSocket};
use dashmap::DashMap;
use futures::{SinkExt, StreamExt};
use tokio::sync::{mpsc, Mutex};
use tron_core::ids::SessionId;
use uuid::Uuid;

const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(30);
const CLIENT_TIMEOUT: Duration = Duration::from_secs(90);

// ---------------------------------------------------------------------------
// MessagePriority
// ---------------------------------------------------------------------------

/// Message priority for queue management.
/// When the queue is full, the lowest-priority oldest message is evicted.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum MessagePriority {
    /// Progress updates, diagnostics.
    Low = 0,
    /// Text deltas, tool events, turn events.
    Normal = 1,
    /// RPC responses, agent.ready, agent.complete, connection.established.
    Critical = 2,
}

/// Classify a serialized JSON message's priority based on its content.
pub fn classify_message(json: &str) -> MessagePriority {
    // RPC responses contain "id" + ("result" or "error")
    if json.contains("\"result\"") || json.contains("\"error\"") {
        return MessagePriority::Critical;
    }
    // Agent lifecycle events (dot-prefixed wire format)
    if json.contains("\"agent.ready\"")
        || json.contains("\"agent.complete\"")
        || json.contains("\"agent.error\"")
    {
        return MessagePriority::Critical;
    }
    // Connection established
    if json.contains("\"connection.established\"") {
        return MessagePriority::Critical;
    }
    MessagePriority::Normal
}

// ---------------------------------------------------------------------------
// PriorityQueue
// ---------------------------------------------------------------------------

/// Priority-aware bounded message queue.
///
/// When the queue is full and a new message arrives, the lowest-priority
/// oldest message is evicted to make room — unless the new message is
/// strictly lower priority than everything in the queue, in which case
/// the new message itself is dropped.
pub struct PriorityQueue {
    inner: std::sync::Mutex<PriorityQueueInner>,
    notify: tokio::sync::Notify,
}

struct PriorityQueueInner {
    buffer: VecDeque<(MessagePriority, String)>,
    capacity: usize,
    dropped: u64,
    closed: bool,
}

impl PriorityQueue {
    pub fn new(capacity: usize) -> Self {
        Self {
            inner: std::sync::Mutex::new(PriorityQueueInner {
                buffer: VecDeque::with_capacity(capacity),
                capacity,
                dropped: 0,
                closed: false,
            }),
            notify: tokio::sync::Notify::new(),
        }
    }

    /// Enqueue a message with the given priority.
    /// Returns `true` if the message was enqueued, `false` if it was dropped.
    pub fn send(&self, priority: MessagePriority, message: String) -> bool {
        let mut inner = self.inner.lock().unwrap();
        if inner.closed {
            return false;
        }

        if inner.buffer.len() < inner.capacity {
            inner.buffer.push_back((priority, message));
            drop(inner);
            self.notify.notify_one();
            return true;
        }

        // Buffer full — find the lowest-priority oldest message to evict.
        let lowest_idx = inner
            .buffer
            .iter()
            .enumerate()
            .min_by_key(|(_, (p, _))| *p)
            .map(|(i, (p, _))| (i, *p));

        if let Some((idx, lowest_prio)) = lowest_idx {
            if priority >= lowest_prio {
                let evicted_prio = inner.buffer[idx].0;
                inner.buffer.remove(idx);
                inner.buffer.push_back((priority, message));
                inner.dropped += 1;
                tracing::debug!(
                    evicted_priority = ?evicted_prio,
                    new_priority = ?priority,
                    "Priority queue evicted message"
                );
                drop(inner);
                self.notify.notify_one();
                return true;
            }
        }

        // New message is strictly lower priority than everything in the buffer.
        inner.dropped += 1;
        false
    }

    /// Wait for and receive the next message.
    /// Returns `None` when the queue is closed and drained.
    pub async fn recv(&self) -> Option<String> {
        loop {
            {
                let mut inner = self.inner.lock().unwrap();
                if let Some((_, msg)) = inner.buffer.pop_front() {
                    return Some(msg);
                }
                if inner.closed {
                    return None;
                }
            }
            self.notify.notified().await;
        }
    }

    /// Close the queue. Subsequent `send()` calls return false.
    /// `recv()` drains remaining messages, then returns `None`.
    pub fn close(&self) {
        let mut inner = self.inner.lock().unwrap();
        inner.closed = true;
        drop(inner);
        self.notify.notify_waiters();
    }

    /// Try to receive a message without blocking.
    /// Returns `None` if the queue is empty.
    pub fn try_recv(&self) -> Option<String> {
        let mut inner = self.inner.lock().unwrap();
        inner.buffer.pop_front().map(|(_, msg)| msg)
    }

    /// Number of messages currently in the queue.
    pub fn len(&self) -> usize {
        self.inner.lock().unwrap().buffer.len()
    }

    /// Whether the queue is empty.
    pub fn is_empty(&self) -> bool {
        self.inner.lock().unwrap().buffer.is_empty()
    }

    /// Number of messages dropped due to capacity since creation.
    pub fn dropped(&self) -> u64 {
        self.inner.lock().unwrap().dropped
    }
}

// ---------------------------------------------------------------------------
// RateLimiter
// ---------------------------------------------------------------------------

/// Token-bucket rate limiter keyed by ClientId.
pub struct RateLimiter {
    buckets: DashMap<ClientId, std::sync::Mutex<TokenBucket>>,
    max_tokens: u32,
    refill_rate: f64,
}

struct TokenBucket {
    tokens: f64,
    last_refill: Instant,
}

impl RateLimiter {
    /// Create a new rate limiter.
    ///
    /// * `max_tokens` — burst capacity per client.
    /// * `refill_rate` — tokens restored per second.
    pub fn new(max_tokens: u32, refill_rate: f64) -> Self {
        Self {
            buckets: DashMap::new(),
            max_tokens,
            refill_rate,
        }
    }

    /// Try to consume one token for `client_id`. Returns `true` if allowed.
    pub fn check(&self, client_id: &ClientId) -> bool {
        let max = self.max_tokens;
        let rate = self.refill_rate;
        let entry = self
            .buckets
            .entry(client_id.clone())
            .or_insert_with(|| {
                std::sync::Mutex::new(TokenBucket {
                    tokens: max as f64,
                    last_refill: Instant::now(),
                })
            });

        let mut bucket = entry.value().lock().unwrap();
        let now = Instant::now();
        let elapsed = now.duration_since(bucket.last_refill).as_secs_f64();
        bucket.tokens = (bucket.tokens + elapsed * rate).min(max as f64);
        bucket.last_refill = now;

        if bucket.tokens >= 1.0 {
            bucket.tokens -= 1.0;
            true
        } else {
            false
        }
    }

    /// Remove a client's bucket (called on disconnect).
    pub fn remove(&self, client_id: &ClientId) {
        self.buckets.remove(client_id);
    }
}

// ---------------------------------------------------------------------------
// ClientId
// ---------------------------------------------------------------------------

/// Unique client identifier.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct ClientId(pub String);

impl Default for ClientId {
    fn default() -> Self {
        Self(format!("client_{}", Uuid::now_v7()))
    }
}

impl ClientId {
    pub fn new() -> Self {
        Self::default()
    }
}

impl std::fmt::Display for ClientId {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

/// A connected WebSocket client.
pub struct Client {
    pub id: ClientId,
    pub session_id: Option<SessionId>,
    pub connected: AtomicBool,
    pub last_pong: std::sync::atomic::AtomicU64,
}

impl Client {
    fn new(id: ClientId) -> Self {
        let now = now_secs();
        Self {
            id,
            session_id: None,
            connected: AtomicBool::new(true),
            last_pong: std::sync::atomic::AtomicU64::new(now),
        }
    }

    pub fn is_connected(&self) -> bool {
        self.connected.load(Ordering::Relaxed)
    }

    pub fn set_session(&mut self, session_id: SessionId) {
        self.session_id = Some(session_id);
    }

    pub fn record_pong(&self) {
        self.last_pong.store(now_secs(), Ordering::Relaxed);
    }

    pub fn is_alive(&self) -> bool {
        let last = self.last_pong.load(Ordering::Relaxed);
        now_secs().saturating_sub(last) < CLIENT_TIMEOUT.as_secs()
    }
}

fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

// ---------------------------------------------------------------------------
// ClientRegistry
// ---------------------------------------------------------------------------

/// Registry of all connected WebSocket clients.
pub struct ClientRegistry {
    clients: DashMap<ClientId, Arc<Mutex<Client>>>,
    queues: DashMap<ClientId, Arc<PriorityQueue>>,
    max_send_queue: usize,
}

impl ClientRegistry {
    pub fn new(max_send_queue: usize) -> Self {
        Self {
            clients: DashMap::new(),
            queues: DashMap::new(),
            max_send_queue,
        }
    }

    /// Register a new client. Returns the client ID and its message queue.
    pub fn register(&self) -> (ClientId, Arc<PriorityQueue>) {
        let id = ClientId::new();
        let queue = Arc::new(PriorityQueue::new(self.max_send_queue));
        let client = Arc::new(Mutex::new(Client::new(id.clone())));
        self.clients.insert(id.clone(), client);
        self.queues.insert(id.clone(), Arc::clone(&queue));
        (id, queue)
    }

    /// Remove a client by ID, closing its message queue.
    pub fn unregister(&self, id: &ClientId) {
        if let Some((_, queue)) = self.queues.remove(id) {
            queue.close();
        }
        if let Some((_, client)) = self.clients.remove(id) {
            if let Ok(c) = client.try_lock() {
                c.connected.store(false, Ordering::Relaxed);
            }
        }
    }

    /// Set the session ID for a client.
    pub async fn set_session(&self, client_id: &ClientId, session_id: SessionId) {
        if let Some(client) = self.clients.get(client_id) {
            client.lock().await.set_session(session_id);
        }
    }

    /// Send a message to a specific client. Priority is auto-classified.
    /// Returns `true` if enqueued, `false` if dropped or client not found.
    pub fn send_to(&self, client_id: &ClientId, message: String) -> bool {
        if let Some(queue) = self.queues.get(client_id) {
            let priority = classify_message(&message);
            queue.send(priority, message)
        } else {
            false
        }
    }

    /// Broadcast a message to all clients watching a specific session.
    pub fn broadcast_to_session(&self, session_id: &SessionId, message: &str) {
        let priority = classify_message(message);
        for entry in self.clients.iter() {
            if let Ok(client) = entry.value().try_lock() {
                if client.session_id.as_ref() == Some(session_id) && client.is_connected() {
                    if let Some(queue) = self.queues.get(&client.id) {
                        queue.send(priority, message.to_string());
                    }
                }
            }
        }
    }

    /// Number of connected clients.
    pub fn count(&self) -> usize {
        self.clients.len()
    }

    /// Get all client IDs for a session.
    pub async fn clients_for_session(&self, session_id: &SessionId) -> Vec<ClientId> {
        let mut result = Vec::new();
        for entry in self.clients.iter() {
            let client = entry.value().lock().await;
            if client.session_id.as_ref() == Some(session_id) {
                result.push(client.id.clone());
            }
        }
        result
    }

    /// Remove clients that haven't responded to pings within the timeout.
    pub fn cleanup_dead_clients(&self) -> usize {
        let mut removed = 0;
        let dead: Vec<ClientId> = self
            .clients
            .iter()
            .filter_map(|entry| {
                if let Ok(client) = entry.value().try_lock() {
                    if !client.is_alive() {
                        return Some(client.id.clone());
                    }
                }
                None
            })
            .collect();

        for id in dead {
            self.unregister(&id);
            removed += 1;
            tracing::info!(client_id = %id, "Cleaned up dead client");
        }
        removed
    }
}

// ---------------------------------------------------------------------------
// WebSocket connection handler
// ---------------------------------------------------------------------------

/// Handle a WebSocket connection: split into reader/writer, manage lifecycle.
pub async fn handle_ws_connection(
    socket: WebSocket,
    client_id: ClientId,
    queue: Arc<PriorityQueue>,
    registry: Arc<ClientRegistry>,
    on_message: mpsc::Sender<(ClientId, String)>,
) {
    let (mut ws_tx, mut ws_rx) = socket.split();

    // Writer task: forward messages from priority queue to WebSocket + periodic ping
    let writer_cid = client_id.clone();
    let writer_registry = Arc::clone(&registry);
    let writer_queue = queue;
    let writer = tokio::spawn(async move {
        let mut ping_interval = tokio::time::interval(HEARTBEAT_INTERVAL);
        ping_interval.tick().await; // consume first immediate tick

        loop {
            tokio::select! {
                msg = writer_queue.recv() => {
                    match msg {
                        Some(text) => {
                            if ws_tx.send(WsMessage::Text(text.into())).await.is_err() {
                                break;
                            }
                        }
                        None => break, // Queue closed
                    }
                }
                _ = ping_interval.tick() => {
                    if ws_tx.send(WsMessage::Ping(vec![].into())).await.is_err() {
                        break;
                    }
                    tracing::trace!(client_id = %writer_cid, "Sent ping");
                }
            }
        }

        // Mark as disconnected
        if let Some(entry) = writer_registry.clients.get(&writer_cid) {
            if let Ok(c) = entry.value().try_lock() {
                c.connected.store(false, Ordering::Relaxed);
            }
        }
    });

    // Reader task: forward WebSocket messages to handler, track pongs
    let reader_cid = client_id.clone();
    let reader_registry = Arc::clone(&registry);
    let reader = tokio::spawn(async move {
        while let Some(Ok(msg)) = ws_rx.next().await {
            match msg {
                WsMessage::Text(text) => {
                    let _ = on_message.send((reader_cid.clone(), text.to_string())).await;
                }
                WsMessage::Binary(bytes) => {
                    // iOS sends RPC requests as binary WebSocket frames
                    if let Ok(text) = String::from_utf8(bytes.to_vec()) {
                        let _ = on_message.send((reader_cid.clone(), text)).await;
                    }
                }
                WsMessage::Pong(_) => {
                    if let Some(entry) = reader_registry.clients.get(&reader_cid) {
                        if let Ok(c) = entry.value().try_lock() {
                            c.record_pong();
                        }
                    }
                }
                WsMessage::Close(_) => break,
                WsMessage::Ping(_) => {} // axum handles pong automatically
            }
        }
    });

    // Wait for either task to finish
    tokio::select! {
        _ = writer => {},
        _ = reader => {},
    }

    registry.unregister(&client_id);
}

/// Start a background task that periodically cleans up dead clients.
pub fn start_cleanup_task(
    registry: Arc<ClientRegistry>,
    interval: Duration,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut ticker = tokio::time::interval(interval);
        loop {
            ticker.tick().await;
            let removed = registry.cleanup_dead_clients();
            if removed > 0 {
                tracing::info!(removed = removed, "Dead client cleanup");
            }
        }
    })
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    // -- ClientId --

    #[test]
    fn client_id_unique() {
        let a = ClientId::new();
        let b = ClientId::new();
        assert_ne!(a, b);
        assert!(a.0.starts_with("client_"));
    }

    // -- PriorityQueue --

    #[tokio::test]
    async fn priority_queue_send_recv() {
        let queue = PriorityQueue::new(8);
        assert!(queue.send(MessagePriority::Normal, "hello".into()));
        assert!(queue.send(MessagePriority::Critical, "world".into()));
        assert_eq!(queue.len(), 2);

        // FIFO order
        assert_eq!(queue.recv().await.unwrap(), "hello");
        assert_eq!(queue.recv().await.unwrap(), "world");
        assert_eq!(queue.len(), 0);
    }

    #[tokio::test]
    async fn priority_queue_evicts_lowest_priority() {
        let queue = PriorityQueue::new(3);
        queue.send(MessagePriority::Normal, "a".into());
        queue.send(MessagePriority::Critical, "b".into());
        queue.send(MessagePriority::Normal, "c".into());
        assert_eq!(queue.len(), 3);

        // Full — sending Critical should evict oldest Normal ("a")
        let enqueued = queue.send(MessagePriority::Critical, "d".into());
        assert!(enqueued);
        assert_eq!(queue.len(), 3);
        assert_eq!(queue.dropped(), 1);

        // Remaining: "b" (Critical), "c" (Normal), "d" (Critical)
        assert_eq!(queue.recv().await.unwrap(), "b");
        assert_eq!(queue.recv().await.unwrap(), "c");
        assert_eq!(queue.recv().await.unwrap(), "d");
    }

    #[test]
    fn priority_queue_drops_lowest_new() {
        // Queue full of Critical messages
        let queue = PriorityQueue::new(2);
        queue.send(MessagePriority::Critical, "a".into());
        queue.send(MessagePriority::Critical, "b".into());

        // Sending Normal when all Critical — evicts oldest Critical (equal priority doesn't block)
        // Actually: Normal < Critical, so Normal cannot evict Critical → dropped
        let enqueued = queue.send(MessagePriority::Low, "c".into());
        assert!(!enqueued);
        assert_eq!(queue.dropped(), 1);
        assert_eq!(queue.len(), 2);
    }

    #[test]
    fn priority_queue_equal_priority_evicts() {
        let queue = PriorityQueue::new(2);
        queue.send(MessagePriority::Normal, "a".into());
        queue.send(MessagePriority::Normal, "b".into());

        // Same priority: evicts oldest ("a"), keeps "b" and adds "c"
        let enqueued = queue.send(MessagePriority::Normal, "c".into());
        assert!(enqueued);
        assert_eq!(queue.dropped(), 1);
    }

    #[tokio::test]
    async fn priority_queue_close_stops_recv() {
        let queue = Arc::new(PriorityQueue::new(8));
        queue.send(MessagePriority::Normal, "last".into());
        queue.close();

        // Drains remaining messages first
        assert_eq!(queue.recv().await.unwrap(), "last");
        // Then returns None
        assert!(queue.recv().await.is_none());
    }

    #[tokio::test]
    async fn priority_queue_close_rejects_send() {
        let queue = PriorityQueue::new(8);
        queue.close();
        assert!(!queue.send(MessagePriority::Critical, "nope".into()));
    }

    #[tokio::test]
    async fn priority_queue_recv_waits_for_send() {
        let queue = Arc::new(PriorityQueue::new(8));
        let queue_clone = Arc::clone(&queue);

        let handle = tokio::spawn(async move {
            queue_clone.recv().await
        });

        // Give the recv task a moment to start waiting
        tokio::time::sleep(Duration::from_millis(10)).await;
        queue.send(MessagePriority::Normal, "delayed".into());

        let msg = tokio::time::timeout(Duration::from_secs(1), handle)
            .await
            .expect("timeout")
            .expect("join")
            .unwrap();
        assert_eq!(msg, "delayed");
    }

    // -- classify_message --

    #[test]
    fn classify_rpc_response_critical() {
        let rpc = r#"{"id":1,"result":{"ok":true}}"#;
        assert_eq!(classify_message(rpc), MessagePriority::Critical);
    }

    #[test]
    fn classify_rpc_error_critical() {
        let rpc = r#"{"id":1,"error":{"code":-32600,"message":"bad"}}"#;
        assert_eq!(classify_message(rpc), MessagePriority::Critical);
    }

    #[test]
    fn classify_agent_ready_critical() {
        let event = r#"{"type":"agent.ready","sessionId":"sess_123","timestamp":"t","data":{}}"#;
        assert_eq!(classify_message(event), MessagePriority::Critical);
    }

    #[test]
    fn classify_agent_complete_critical() {
        let event = r#"{"type":"agent.complete","sessionId":"sess_123","timestamp":"t","data":{}}"#;
        assert_eq!(classify_message(event), MessagePriority::Critical);
    }

    #[test]
    fn classify_connection_established_critical() {
        let event = r#"{"type":"connection.established","data":{}}"#;
        assert_eq!(classify_message(event), MessagePriority::Critical);
    }

    #[test]
    fn classify_text_delta_normal() {
        let event = r#"{"type":"agent.text_delta","sessionId":"s","timestamp":"t","data":{"delta":"hello"}}"#;
        assert_eq!(classify_message(event), MessagePriority::Normal);
    }

    // -- RateLimiter --

    #[test]
    fn rate_limiter_allows_within_limit() {
        let limiter = RateLimiter::new(5, 5.0);
        let client = ClientId::new();

        for _ in 0..5 {
            assert!(limiter.check(&client));
        }
    }

    #[test]
    fn rate_limiter_rejects_over_limit() {
        let limiter = RateLimiter::new(3, 1.0);
        let client = ClientId::new();

        // Exhaust all tokens
        assert!(limiter.check(&client));
        assert!(limiter.check(&client));
        assert!(limiter.check(&client));

        // Next should be rejected
        assert!(!limiter.check(&client));
    }

    #[test]
    fn rate_limiter_refills_over_time() {
        let limiter = RateLimiter::new(2, 1000.0); // fast refill for testing
        let client = ClientId::new();

        // Exhaust
        assert!(limiter.check(&client));
        assert!(limiter.check(&client));
        assert!(!limiter.check(&client));

        // Wait a tiny bit for refill (1000 tokens/sec = 1 token per ms)
        std::thread::sleep(Duration::from_millis(5));

        assert!(limiter.check(&client));
    }

    #[test]
    fn rate_limiter_independent_clients() {
        let limiter = RateLimiter::new(1, 0.0); // no refill
        let a = ClientId::new();
        let b = ClientId::new();

        assert!(limiter.check(&a));
        assert!(!limiter.check(&a));

        // Client B has its own bucket
        assert!(limiter.check(&b));
        assert!(!limiter.check(&b));
    }

    #[test]
    fn rate_limiter_remove_client() {
        let limiter = RateLimiter::new(1, 0.0);
        let client = ClientId::new();

        assert!(limiter.check(&client));
        assert!(!limiter.check(&client));

        limiter.remove(&client);

        // Fresh bucket after removal
        assert!(limiter.check(&client));
    }

    // -- ClientRegistry --

    #[test]
    fn registry_register_and_unregister() {
        let registry = ClientRegistry::new(32);
        assert_eq!(registry.count(), 0);

        let (id1, _q1) = registry.register();
        let (id2, _q2) = registry.register();
        assert_eq!(registry.count(), 2);

        registry.unregister(&id1);
        assert_eq!(registry.count(), 1);

        registry.unregister(&id2);
        assert_eq!(registry.count(), 0);
    }

    #[tokio::test]
    async fn registry_set_session() {
        let registry = ClientRegistry::new(32);
        let (id, _q) = registry.register();
        let session_id = SessionId::new();

        registry.set_session(&id, session_id.clone()).await;

        let clients = registry.clients_for_session(&session_id).await;
        assert_eq!(clients.len(), 1);
        assert_eq!(clients[0], id);
    }

    #[test]
    fn registry_broadcast_to_session() {
        let registry = ClientRegistry::new(32);
        let (id1, q1) = registry.register();
        let (id2, q2) = registry.register();
        let (_id3, q3) = registry.register();

        let session = SessionId::new();
        {
            let entry = registry.clients.get(&id1).unwrap();
            entry.try_lock().unwrap().set_session(session.clone());
        }
        {
            let entry = registry.clients.get(&id2).unwrap();
            entry.try_lock().unwrap().set_session(session.clone());
        }

        registry.broadcast_to_session(&session, r#"{"type":"text_delta","delta":"hi"}"#);

        assert_eq!(q1.len(), 1);
        assert_eq!(q2.len(), 1);
        assert_eq!(q3.len(), 0);
    }

    #[test]
    fn send_to_specific_client() {
        let registry = ClientRegistry::new(32);
        let (id, queue) = registry.register();

        let sent = registry.send_to(&id, "test message".into());
        assert!(sent);
        assert_eq!(queue.len(), 1);
    }

    #[test]
    fn send_to_nonexistent_client() {
        let registry = ClientRegistry::new(32);
        let fake = ClientId::new();
        let sent = registry.send_to(&fake, "test".into());
        assert!(!sent);
    }

    #[tokio::test]
    async fn send_to_full_queue_evicts() {
        let registry = ClientRegistry::new(2); // tiny queue
        let (id, queue) = registry.register();

        // Fill with Normal priority
        registry.send_to(&id, r#"{"type":"text_delta","delta":"a"}"#.into());
        registry.send_to(&id, r#"{"type":"text_delta","delta":"b"}"#.into());
        assert_eq!(queue.len(), 2);

        // Send Critical — should evict oldest Normal
        let sent = registry.send_to(&id, r#"{"id":1,"result":{"ok":true}}"#.into());
        assert!(sent);
        assert_eq!(queue.len(), 2);
        assert_eq!(queue.dropped(), 1);

        // Remaining: "b" (Normal), RPC response (Critical)
        let msg1 = queue.recv().await.unwrap();
        assert!(msg1.contains("delta"));
        assert!(msg1.contains("\"b\""));
        let msg2 = queue.recv().await.unwrap();
        assert!(msg2.contains("result"));
    }

    #[test]
    fn client_pong_tracking() {
        let client = Client::new(ClientId::new());
        assert!(client.is_alive());

        client.record_pong();
        assert!(client.is_alive());
    }

    #[test]
    fn cleanup_dead_clients_removes_expired() {
        let registry = ClientRegistry::new(32);
        let (id, _q) = registry.register();
        assert_eq!(registry.count(), 1);

        // Manually set last_pong to far in the past
        if let Some(client) = registry.clients.get(&id) {
            if let Ok(c) = client.try_lock() {
                c.last_pong.store(0, Ordering::Relaxed);
            }
        }

        let removed = registry.cleanup_dead_clients();
        assert_eq!(removed, 1);
        assert_eq!(registry.count(), 0);
    }

    #[tokio::test]
    async fn unregister_closes_queue() {
        let registry = ClientRegistry::new(32);
        let (id, queue) = registry.register();

        queue.send(MessagePriority::Normal, "before".into());
        registry.unregister(&id);

        // Drain remaining
        assert_eq!(queue.recv().await.unwrap(), "before");
        // Then None
        assert!(queue.recv().await.is_none());
    }
}
