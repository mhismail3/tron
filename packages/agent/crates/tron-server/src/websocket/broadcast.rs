//! Event fan-out to connected WebSocket clients.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use crate::rpc::types::RpcEvent;
use metrics::counter;
use tokio::sync::RwLock;
use tracing::{debug, warn};

use super::connection::ClientConnection;

/// Maximum total lifetime message drops before forcibly disconnecting a slow client.
const MAX_TOTAL_DROPS: u64 = 100;

/// Manages event broadcasting to connected clients.
pub struct BroadcastManager {
    /// Connected clients indexed by connection ID.
    connections: RwLock<HashMap<String, Arc<ClientConnection>>>,
    /// Atomic counter tracking total connections (avoids read-locking for count queries).
    active_count: AtomicUsize,
}

impl BroadcastManager {
    /// Create a new broadcast manager.
    pub fn new() -> Self {
        Self {
            connections: RwLock::new(HashMap::new()),
            active_count: AtomicUsize::new(0),
        }
    }

    /// Add a connection.
    pub async fn add(&self, connection: Arc<ClientConnection>) {
        let mut conns = self.connections.write().await;
        if conns.insert(connection.id.clone(), connection).is_none() {
            let _ = self.active_count.fetch_add(1, Ordering::Relaxed);
        }
    }

    /// Remove a connection by ID.
    pub async fn remove(&self, connection_id: &str) {
        let mut conns = self.connections.write().await;
        if conns.remove(connection_id).is_some() {
            let _ = self.active_count.fetch_sub(1, Ordering::Relaxed);
        }
    }

    /// Broadcast an event to all connections bound to the given session.
    pub async fn broadcast_to_session(&self, session_id: &str, event: &RpcEvent) {
        self.broadcast_to(
            |c| c.session_id().as_deref() == Some(session_id),
            event,
            session_id,
        )
        .await;
    }

    /// Broadcast an event to all connections.
    pub async fn broadcast_all(&self, event: &RpcEvent) {
        self.broadcast_to(|_| true, event, "all").await;
    }

    /// Serialize event, fan out to matching clients, remove slow clients.
    async fn broadcast_to(
        &self,
        filter: impl Fn(&ClientConnection) -> bool,
        event: &RpcEvent,
        label: &str,
    ) {
        let json = match serde_json::to_string(event) {
            Ok(j) => Arc::new(j),
            Err(e) => {
                warn!(event_type = event.event_type, error = %e, "failed to serialize event");
                return;
            }
        };
        let mut to_remove = Vec::new();
        {
            let conns = self.connections.read().await;
            let mut recipients = 0u32;
            for conn in conns.values() {
                if filter(conn) {
                    recipients += 1;
                    if !conn.send(Arc::clone(&json)) {
                        counter!("ws_broadcast_drops_total").increment(1);
                        let drops = conn.drop_count();
                        if drops >= MAX_TOTAL_DROPS {
                            warn!(conn_id = %conn.id, label, drops, "disconnecting slow client");
                            to_remove.push(conn.id.clone());
                        } else {
                            warn!(conn_id = %conn.id, label, total_drops = drops, "failed to send event to client (channel full)");
                        }
                    }
                }
            }
            debug!(
                event_type = event.event_type,
                label, recipients, "broadcast event"
            );
        }
        if !to_remove.is_empty() {
            let mut conns = self.connections.write().await;
            for id in &to_remove {
                if conns.remove(id).is_some() {
                    let _ = self.active_count.fetch_sub(1, Ordering::Relaxed);
                }
            }
        }
    }

    /// Number of active connections.
    pub fn connection_count(&self) -> usize {
        self.active_count.load(Ordering::Relaxed)
    }

    /// Get connections bound to a specific session.
    pub async fn session_connections(&self, session_id: &str) -> Vec<Arc<ClientConnection>> {
        let conns = self.connections.read().await;
        conns
            .values()
            .filter(|c| c.session_id().as_deref() == Some(session_id))
            .cloned()
            .collect()
    }
}

impl Default for BroadcastManager {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::sync::mpsc;

    fn make_connection_with_rx(
        id: &str,
        session: Option<&str>,
    ) -> (Arc<ClientConnection>, mpsc::Receiver<Arc<String>>) {
        let (tx, rx) = mpsc::channel(32);
        let conn = ClientConnection::new(id.into(), tx);
        if let Some(sid) = session {
            conn.bind_session(sid);
        }
        (Arc::new(conn), rx)
    }

    fn make_event(event_type: &str, session_id: Option<&str>) -> RpcEvent {
        RpcEvent {
            event_type: event_type.into(),
            session_id: session_id.map(Into::into),
            timestamp: "2026-01-01T00:00:00.000Z".into(),
            data: None,
            run_id: None,
        }
    }

    #[tokio::test]
    async fn add_connection() {
        let bm = BroadcastManager::new();
        let (conn, _rx) = make_connection_with_rx("c1", None);
        bm.add(conn).await;
        assert_eq!(bm.connection_count(), 1);
    }

    #[tokio::test]
    async fn remove_connection() {
        let bm = BroadcastManager::new();
        let (conn, _rx) = make_connection_with_rx("c1", None);
        bm.add(conn).await;
        bm.remove("c1").await;
        assert_eq!(bm.connection_count(), 0);
    }

    #[tokio::test]
    async fn remove_nonexistent_connection() {
        let bm = BroadcastManager::new();
        bm.remove("no_such").await;
        assert_eq!(bm.connection_count(), 0);
    }

    #[tokio::test]
    async fn broadcast_to_session() {
        let bm = BroadcastManager::new();
        let (conn1, mut rx1) = make_connection_with_rx("c1", Some("sess_a"));
        let (conn2, mut rx2) = make_connection_with_rx("c2", Some("sess_b"));
        let (conn3, mut rx3) = make_connection_with_rx("c3", Some("sess_a"));
        bm.add(conn1).await;
        bm.add(conn2).await;
        bm.add(conn3).await;

        let event = make_event("agent.start", Some("sess_a"));
        bm.broadcast_to_session("sess_a", &event).await;

        // conn1 and conn3 should receive, conn2 should not
        let msg1 = rx1.try_recv();
        assert!(msg1.is_ok());
        let msg3 = rx3.try_recv();
        assert!(msg3.is_ok());
        let msg2 = rx2.try_recv();
        assert!(msg2.is_err());
    }

    #[tokio::test]
    async fn broadcast_all() {
        let bm = BroadcastManager::new();
        let (conn1, mut rx1) = make_connection_with_rx("c1", Some("sess_a"));
        let (conn2, mut rx2) = make_connection_with_rx("c2", Some("sess_b"));
        bm.add(conn1).await;
        bm.add(conn2).await;

        let event = make_event("system.ready", None);
        bm.broadcast_all(&event).await;

        assert!(rx1.try_recv().is_ok());
        assert!(rx2.try_recv().is_ok());
    }

    #[tokio::test]
    async fn connection_count() {
        let bm = BroadcastManager::new();
        assert_eq!(bm.connection_count(), 0);

        let (c1, _rx1) = make_connection_with_rx("c1", None);
        let (c2, _rx2) = make_connection_with_rx("c2", None);
        bm.add(c1).await;
        assert_eq!(bm.connection_count(), 1);
        bm.add(c2).await;
        assert_eq!(bm.connection_count(), 2);
        bm.remove("c1").await;
        assert_eq!(bm.connection_count(), 1);
    }

    #[tokio::test]
    async fn session_connections() {
        let bm = BroadcastManager::new();
        let (c1, _rx1) = make_connection_with_rx("c1", Some("sess_a"));
        let (c2, _rx2) = make_connection_with_rx("c2", Some("sess_b"));
        let (c3, _rx3) = make_connection_with_rx("c3", Some("sess_a"));
        bm.add(c1).await;
        bm.add(c2).await;
        bm.add(c3).await;

        let sess_a = bm.session_connections("sess_a").await;
        assert_eq!(sess_a.len(), 2);

        let sess_b = bm.session_connections("sess_b").await;
        assert_eq!(sess_b.len(), 1);
    }

    #[tokio::test]
    async fn session_connections_empty_session() {
        let bm = BroadcastManager::new();
        let (c1, _rx1) = make_connection_with_rx("c1", Some("sess_a"));
        bm.add(c1).await;

        let conns = bm.session_connections("nonexistent").await;
        assert!(conns.is_empty());
    }

    #[tokio::test]
    async fn broadcast_to_empty_session() {
        let bm = BroadcastManager::new();
        let event = make_event("agent.start", Some("no_session"));
        // Should not panic
        bm.broadcast_to_session("no_session", &event).await;
    }

    #[tokio::test]
    async fn broadcast_all_to_empty_manager() {
        let bm = BroadcastManager::new();
        let event = make_event("system.ready", None);
        // Should not panic
        bm.broadcast_all(&event).await;
    }

    #[tokio::test]
    async fn broadcast_event_is_valid_json() {
        let bm = BroadcastManager::new();
        let (conn, mut rx) = make_connection_with_rx("c1", Some("sess_a"));
        bm.add(conn).await;

        let event = RpcEvent {
            event_type: "agent.text_delta".into(),
            session_id: Some("sess_a".into()),
            timestamp: "2026-02-13T15:30:00.000Z".into(),
            data: Some(serde_json::json!({"text": "hello"})),
            run_id: Some("run_1".into()),
        };
        bm.broadcast_to_session("sess_a", &event).await;

        let msg = rx.recv().await.unwrap();
        let parsed: serde_json::Value = serde_json::from_str(&*msg).unwrap();
        assert_eq!(parsed["type"], "agent.text_delta");
        assert_eq!(parsed["sessionId"], "sess_a");
        assert_eq!(parsed["data"]["text"], "hello");
        assert_eq!(parsed["runId"], "run_1");
    }

    #[tokio::test]
    async fn add_connection_overwrites_same_id() {
        let bm = BroadcastManager::new();
        let (c1, _rx1) = make_connection_with_rx("same_id", Some("sess_a"));
        let (c2, _rx2) = make_connection_with_rx("same_id", Some("sess_b"));
        bm.add(c1).await;
        bm.add(c2).await;
        assert_eq!(bm.connection_count(), 1);
        // Should be the second connection (sess_b)
        let conns = bm.session_connections("sess_b").await;
        assert_eq!(conns.len(), 1);
    }

    #[tokio::test]
    async fn unbound_connections_not_in_session_broadcast() {
        let bm = BroadcastManager::new();
        let (c1, mut rx1) = make_connection_with_rx("c1", None); // no session bound
        let (c2, mut rx2) = make_connection_with_rx("c2", Some("sess_a"));
        bm.add(c1).await;
        bm.add(c2).await;

        let event = make_event("agent.start", Some("sess_a"));
        bm.broadcast_to_session("sess_a", &event).await;

        // c1 should NOT receive (no session bound)
        assert!(rx1.try_recv().is_err());
        // c2 should receive
        assert!(rx2.try_recv().is_ok());
    }

    #[tokio::test]
    async fn default_broadcast_manager() {
        let bm = BroadcastManager::default();
        assert_eq!(bm.connection_count(), 0);
    }

    #[tokio::test]
    async fn unbound_connections_receive_broadcast_all() {
        let bm = BroadcastManager::new();
        let (c1, mut rx1) = make_connection_with_rx("c1", None);
        bm.add(c1).await;

        let event = make_event("system.ready", None);
        bm.broadcast_all(&event).await;

        assert!(rx1.try_recv().is_ok());
    }

    #[tokio::test]
    async fn broadcast_disconnects_slow_client_after_threshold() {
        let bm = BroadcastManager::new();
        // Create a slow client with buffer of 1
        let (tx, _rx) = mpsc::channel(1);
        let slow_conn = Arc::new(ClientConnection::new("slow".into(), tx));
        slow_conn.bind_session("s");

        // Create a fast client with large buffer
        let (fast_conn, mut fast_rx) = make_connection_with_rx("fast", Some("s"));

        bm.add(slow_conn.clone()).await;
        bm.add(fast_conn).await;

        // Fill slow client's channel
        let event = make_event("test.event", Some("s"));
        // First send fills the buffer
        bm.broadcast_to_session("s", &event).await;
        // Now send MAX_TOTAL_DROPS more to exceed the threshold
        for _ in 0..MAX_TOTAL_DROPS {
            bm.broadcast_to_session("s", &event).await;
        }

        // Slow client should have been disconnected
        assert_eq!(bm.connection_count(), 1);
        // Fast client should still be connected and received all messages
        assert!(fast_rx.try_recv().is_ok());
    }

    #[tokio::test]
    async fn broadcast_keeps_fast_client() {
        let bm = BroadcastManager::new();
        let (fast, mut rx) = make_connection_with_rx("fast", Some("s"));
        bm.add(fast).await;

        let event = make_event("test.event", Some("s"));
        for _ in 0..20 {
            bm.broadcast_to_session("s", &event).await;
            // Drain to keep channel clear (simulating a fast client)
            while rx.try_recv().is_ok() {}
        }

        // Fast client should still be connected
        assert_eq!(bm.connection_count(), 1);
    }

    #[test]
    fn slow_client_threshold_constant_value() {
        assert_eq!(MAX_TOTAL_DROPS, 100);
    }

    #[tokio::test]
    async fn connection_count_consistent_after_add_remove_overwrite() {
        let bm = BroadcastManager::new();
        let (c1, _rx1) = make_connection_with_rx("c1", None);
        let (c2, _rx2) = make_connection_with_rx("c2", None);
        let (c1_dup, _rx3) = make_connection_with_rx("c1", Some("s"));
        bm.add(c1).await;
        bm.add(c2).await;
        // Overwrite c1 — count should stay 2
        bm.add(c1_dup).await;
        assert_eq!(bm.connection_count(), 2);
        bm.remove("c1").await;
        assert_eq!(bm.connection_count(), 1);
        bm.remove("c2").await;
        assert_eq!(bm.connection_count(), 0);
    }

    #[tokio::test]
    async fn connection_count_decremented_on_slow_client_removal() {
        let bm = BroadcastManager::new();
        let (tx, _rx) = mpsc::channel(1);
        let slow = Arc::new(ClientConnection::new("slow".into(), tx));
        slow.bind_session("s");
        let (fast, _fast_rx) = make_connection_with_rx("fast", Some("s"));
        bm.add(slow).await;
        bm.add(fast).await;
        assert_eq!(bm.connection_count(), 2);

        let event = make_event("test.drop", Some("s"));
        // Fill channel + exceed threshold
        for _ in 0..=MAX_TOTAL_DROPS {
            bm.broadcast_to_session("s", &event).await;
        }
        // Slow client removed, count decremented
        assert_eq!(bm.connection_count(), 1);
    }

    #[tokio::test]
    async fn broadcast_all_disconnects_slow_client() {
        let bm = BroadcastManager::new();
        let (tx, _rx) = mpsc::channel(1);
        let slow = Arc::new(ClientConnection::new("slow".into(), tx));
        let (fast, mut fast_rx) = make_connection_with_rx("fast", None);
        bm.add(slow).await;
        bm.add(fast).await;

        let event = make_event("test.event", None);
        // First send fills the slow client's buffer
        bm.broadcast_all(&event).await;
        // Exceed threshold
        for _ in 0..MAX_TOTAL_DROPS {
            bm.broadcast_all(&event).await;
        }
        assert_eq!(bm.connection_count(), 1);
        assert!(fast_rx.try_recv().is_ok());
    }

    #[tokio::test]
    async fn broadcast_to_session_only_removes_slow_in_target() {
        let bm = BroadcastManager::new();
        // Slow client in session A
        let (tx, _rx) = mpsc::channel(1);
        let slow_a = Arc::new(ClientConnection::new("slow_a".into(), tx));
        slow_a.bind_session("a");
        // Fast client in session B
        let (fast_b, _fast_rx) = make_connection_with_rx("fast_b", Some("b"));
        bm.add(slow_a).await;
        bm.add(fast_b).await;

        let event = make_event("test.event", Some("a"));
        bm.broadcast_to_session("a", &event).await;
        for _ in 0..MAX_TOTAL_DROPS {
            bm.broadcast_to_session("a", &event).await;
        }
        // Slow client in A removed, B unaffected
        assert_eq!(bm.connection_count(), 1);
        let b_conns = bm.session_connections("b").await;
        assert_eq!(b_conns.len(), 1);
    }

    #[tokio::test]
    async fn broadcast_arc_shared_not_cloned() {
        let bm = BroadcastManager::new();
        let (c1, mut rx1) = make_connection_with_rx("c1", Some("s"));
        let (c2, mut rx2) = make_connection_with_rx("c2", Some("s"));
        bm.add(c1).await;
        bm.add(c2).await;

        let event = make_event("test.arc", Some("s"));
        bm.broadcast_to_session("s", &event).await;

        let msg1 = rx1.recv().await.unwrap();
        let msg2 = rx2.recv().await.unwrap();
        // Both receivers share the same Arc — same pointer, refcount == 2
        assert!(Arc::ptr_eq(&msg1, &msg2));
        assert_eq!(Arc::strong_count(&msg1), 2);
        // Content is identical
        assert_eq!(&*msg1, &*msg2);
        // After dropping one, the other becomes sole owner
        drop(msg2);
        assert_eq!(Arc::strong_count(&msg1), 1);
    }
}
