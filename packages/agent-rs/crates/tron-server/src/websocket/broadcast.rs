//! Event fan-out to connected WebSocket clients.

use std::collections::HashMap;
use std::sync::Arc;

use tokio::sync::RwLock;
use tracing::{debug, warn};
use tron_rpc::types::RpcEvent;

use super::connection::ClientConnection;

/// Manages event broadcasting to connected clients.
pub struct BroadcastManager {
    /// Connected clients indexed by connection ID.
    connections: RwLock<HashMap<String, Arc<ClientConnection>>>,
}

impl BroadcastManager {
    /// Create a new broadcast manager.
    pub fn new() -> Self {
        Self {
            connections: RwLock::new(HashMap::new()),
        }
    }

    /// Add a connection.
    pub async fn add(&self, connection: Arc<ClientConnection>) {
        let mut conns = self.connections.write().await;
        let _ = conns.insert(connection.id.clone(), connection);
    }

    /// Remove a connection by ID.
    pub async fn remove(&self, connection_id: &str) {
        let mut conns = self.connections.write().await;
        let _ = conns.remove(connection_id);
    }

    /// Broadcast an event to all connections bound to the given session.
    pub async fn broadcast_to_session(&self, session_id: &str, event: &RpcEvent) {
        let json = match serde_json::to_string(event) {
            Ok(j) => j,
            Err(e) => {
                warn!(event_type = event.event_type, error = %e, "failed to serialize event");
                return;
            }
        };
        let conns = self.connections.read().await;
        let recipients = conns
            .values()
            .filter(|c| c.session_id().as_deref() == Some(session_id))
            .count();
        debug!(
            event_type = event.event_type,
            session_id,
            recipients,
            "broadcast event to session"
        );
        for conn in conns.values() {
            if conn.session_id().as_deref() == Some(session_id)
                && !conn.send(json.clone())
            {
                warn!(conn_id = %conn.id, session_id, "failed to send event to client");
            }
        }
    }

    /// Broadcast an event to all connections.
    pub async fn broadcast_all(&self, event: &RpcEvent) {
        let json = match serde_json::to_string(event) {
            Ok(j) => j,
            Err(e) => {
                warn!(event_type = event.event_type, error = %e, "failed to serialize event");
                return;
            }
        };
        let conns = self.connections.read().await;
        let recipients = conns.len();
        debug!(
            event_type = event.event_type,
            recipients, "broadcast event to all"
        );
        for conn in conns.values() {
            if !conn.send(json.clone()) {
                warn!(conn_id = %conn.id, "failed to send event to client");
            }
        }
    }

    /// Number of active connections.
    pub async fn connection_count(&self) -> usize {
        self.connections.read().await.len()
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
    ) -> (Arc<ClientConnection>, mpsc::Receiver<String>) {
        let (tx, rx) = mpsc::channel(32);
        let conn = ClientConnection::new(id.into(), tx);
        if let Some(sid) = session {
            conn.bind_session(sid.into());
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
        assert_eq!(bm.connection_count().await, 1);
    }

    #[tokio::test]
    async fn remove_connection() {
        let bm = BroadcastManager::new();
        let (conn, _rx) = make_connection_with_rx("c1", None);
        bm.add(conn).await;
        bm.remove("c1").await;
        assert_eq!(bm.connection_count().await, 0);
    }

    #[tokio::test]
    async fn remove_nonexistent_connection() {
        let bm = BroadcastManager::new();
        bm.remove("no_such").await;
        assert_eq!(bm.connection_count().await, 0);
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
        assert_eq!(bm.connection_count().await, 0);

        let (c1, _rx1) = make_connection_with_rx("c1", None);
        let (c2, _rx2) = make_connection_with_rx("c2", None);
        bm.add(c1).await;
        assert_eq!(bm.connection_count().await, 1);
        bm.add(c2).await;
        assert_eq!(bm.connection_count().await, 2);
        bm.remove("c1").await;
        assert_eq!(bm.connection_count().await, 1);
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
        let parsed: serde_json::Value = serde_json::from_str(&msg).unwrap();
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
        assert_eq!(bm.connection_count().await, 1);
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
        assert_eq!(bm.connection_count().await, 0);
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
}
