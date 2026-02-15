use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use axum::extract::ws::{Message as WsMessage, WebSocket};
use dashmap::DashMap;
use futures::{SinkExt, StreamExt};
use tokio::sync::{mpsc, Mutex};
use tron_core::ids::SessionId;
use uuid::Uuid;

const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(30);
const CLIENT_TIMEOUT: Duration = Duration::from_secs(90);

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

/// A connected WebSocket client.
pub struct Client {
    pub id: ClientId,
    pub session_id: Option<SessionId>,
    pub tx: mpsc::Sender<String>,
    pub connected: AtomicBool,
    pub last_pong: std::sync::atomic::AtomicU64,
}

impl Client {
    fn new(id: ClientId, tx: mpsc::Sender<String>) -> Self {
        let now = now_secs();
        Self {
            id,
            session_id: None,
            tx,
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

/// Registry of all connected WebSocket clients.
pub struct ClientRegistry {
    clients: DashMap<ClientId, Arc<Mutex<Client>>>,
    max_send_queue: usize,
}

impl ClientRegistry {
    pub fn new(max_send_queue: usize) -> Self {
        Self {
            clients: DashMap::new(),
            max_send_queue,
        }
    }

    /// Register a new client and return its ID + sender.
    pub fn register(&self) -> (ClientId, mpsc::Receiver<String>) {
        let id = ClientId::new();
        let (tx, rx) = mpsc::channel(self.max_send_queue);
        let client = Arc::new(Mutex::new(Client::new(id.clone(), tx)));
        self.clients.insert(id.clone(), client);
        (id, rx)
    }

    /// Remove a client by ID.
    pub fn unregister(&self, id: &ClientId) {
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

    /// Send a message to a specific client. Drops oldest message if queue is full.
    pub async fn send_to(&self, client_id: &ClientId, message: String) -> bool {
        if let Some(client) = self.clients.get(client_id) {
            let tx = client.lock().await.tx.clone();
            match tx.try_send(message) {
                Ok(()) => true,
                Err(mpsc::error::TrySendError::Full(msg)) => {
                    // Backpressure: the channel is full.
                    // We can't drop oldest from mpsc, so we drop this message and log.
                    tracing::warn!(
                        client_id = %client_id,
                        msg_len = msg.len(),
                        "Send queue full, dropping message"
                    );
                    false
                }
                Err(mpsc::error::TrySendError::Closed(_)) => false,
            }
        } else {
            false
        }
    }

    /// Broadcast a message to all clients watching a specific session.
    pub fn broadcast_to_session(&self, session_id: &SessionId, message: &str) {
        for entry in self.clients.iter() {
            if let Ok(client) = entry.value().try_lock() {
                if client.session_id.as_ref() == Some(session_id) && client.is_connected() {
                    let _ = client.tx.try_send(message.to_string());
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

/// Handle a WebSocket connection: split into reader/writer, manage lifecycle with heartbeat.
pub async fn handle_ws_connection(
    socket: WebSocket,
    client_id: ClientId,
    mut rx: mpsc::Receiver<String>,
    registry: Arc<ClientRegistry>,
    on_message: mpsc::Sender<(ClientId, String)>,
) {
    let (mut ws_tx, mut ws_rx) = socket.split();

    // Writer task: forward messages from channel to WebSocket + periodic ping
    let writer_cid = client_id.clone();
    let writer_registry = Arc::clone(&registry);
    let writer = tokio::spawn(async move {
        let mut ping_interval = tokio::time::interval(HEARTBEAT_INTERVAL);
        ping_interval.tick().await; // consume first immediate tick

        loop {
            tokio::select! {
                msg = rx.recv() => {
                    match msg {
                        Some(text) => {
                            if ws_tx.send(WsMessage::Text(text.into())).await.is_err() {
                                break;
                            }
                        }
                        None => break,
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
        if let Some(client) = writer_registry.clients.get(&writer_cid) {
            if let Ok(c) = client.try_lock() {
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
                WsMessage::Pong(_) => {
                    // Record pong for liveness detection
                    if let Some(client) = reader_registry.clients.get(&reader_cid) {
                        if let Ok(c) = client.try_lock() {
                            c.record_pong();
                        }
                    }
                }
                WsMessage::Close(_) => break,
                WsMessage::Ping(_) => {} // axum handles pong automatically
                _ => {}
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn client_id_unique() {
        let a = ClientId::new();
        let b = ClientId::new();
        assert_ne!(a, b);
        assert!(a.0.starts_with("client_"));
    }

    #[test]
    fn registry_register_and_unregister() {
        let registry = ClientRegistry::new(32);
        assert_eq!(registry.count(), 0);

        let (id1, _rx1) = registry.register();
        let (id2, _rx2) = registry.register();
        assert_eq!(registry.count(), 2);

        registry.unregister(&id1);
        assert_eq!(registry.count(), 1);

        registry.unregister(&id2);
        assert_eq!(registry.count(), 0);
    }

    #[tokio::test]
    async fn registry_set_session() {
        let registry = ClientRegistry::new(32);
        let (id, _rx) = registry.register();
        let session_id = SessionId::new();

        registry.set_session(&id, session_id.clone()).await;

        let clients = registry.clients_for_session(&session_id).await;
        assert_eq!(clients.len(), 1);
        assert_eq!(clients[0], id);
    }

    #[test]
    fn registry_broadcast_to_session() {
        let registry = ClientRegistry::new(32);
        let (id1, mut rx1) = registry.register();
        let (id2, mut rx2) = registry.register();
        let (_id3, mut rx3) = registry.register();

        let session = SessionId::new();
        {
            let entry = registry.clients.get(&id1).unwrap();
            entry.try_lock().unwrap().set_session(session.clone());
        }
        {
            let entry = registry.clients.get(&id2).unwrap();
            entry.try_lock().unwrap().set_session(session.clone());
        }

        registry.broadcast_to_session(&session, "hello");

        assert!(rx1.try_recv().is_ok());
        assert!(rx2.try_recv().is_ok());
        assert!(rx3.try_recv().is_err());
    }

    #[tokio::test]
    async fn send_to_specific_client() {
        let registry = ClientRegistry::new(32);
        let (id, mut rx) = registry.register();

        let sent = registry.send_to(&id, "test message".into()).await;
        assert!(sent);

        let msg = rx.recv().await.unwrap();
        assert_eq!(msg, "test message");
    }

    #[tokio::test]
    async fn send_to_nonexistent_client() {
        let registry = ClientRegistry::new(32);
        let fake = ClientId::new();
        let sent = registry.send_to(&fake, "test".into()).await;
        assert!(!sent);
    }

    #[tokio::test]
    async fn send_to_full_queue_drops() {
        let registry = ClientRegistry::new(2); // tiny queue
        let (id, _rx) = registry.register();

        // Fill the queue
        let sent1 = registry.send_to(&id, "msg1".into()).await;
        let sent2 = registry.send_to(&id, "msg2".into()).await;
        assert!(sent1);
        assert!(sent2);

        // Queue is full — this should be dropped
        let sent3 = registry.send_to(&id, "msg3".into()).await;
        assert!(!sent3);
    }

    #[test]
    fn client_pong_tracking() {
        let (tx, _rx) = mpsc::channel(1);
        let client = Client::new(ClientId::new(), tx);
        assert!(client.is_alive());

        client.record_pong();
        assert!(client.is_alive());
    }

    #[test]
    fn cleanup_dead_clients_removes_expired() {
        let registry = ClientRegistry::new(32);
        let (id, _rx) = registry.register();
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
}
