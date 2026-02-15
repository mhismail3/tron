use std::sync::Arc;

use tokio::sync::broadcast;
use tron_core::events::AgentEvent;

use crate::client::ClientRegistry;
use crate::compat;

/// Subscribes to the engine's AgentEvent broadcast and forwards events
/// to connected WebSocket clients.
pub struct EventBridge {
    registry: Arc<ClientRegistry>,
}

impl EventBridge {
    pub fn new(registry: Arc<ClientRegistry>) -> Self {
        Self { registry }
    }

    /// Start the bridge. Spawns a task that reads from the broadcast channel
    /// and sends serialized events to matching WebSocket clients.
    pub fn start(&self, mut rx: broadcast::Receiver<AgentEvent>) -> tokio::task::JoinHandle<()> {
        let registry = Arc::clone(&self.registry);

        tokio::spawn(async move {
            loop {
                match rx.recv().await {
                    Ok(event) => {
                        let session_id = event.session_id();
                        let wire_event = compat::agent_event_to_wire(&event);
                        if let Ok(json) = serde_json::to_string(&wire_event) {
                            registry.broadcast_to_session(session_id, &json);
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        tracing::warn!(skipped = n, "Event bridge lagged, dropped events");
                    }
                    Err(broadcast::error::RecvError::Closed) => {
                        tracing::info!("Event bridge channel closed");
                        break;
                    }
                }
            }
        })
    }
}

/// Create an event bridge wired to a broadcast channel.
pub fn create_bridge(
    registry: Arc<ClientRegistry>,
    rx: broadcast::Receiver<AgentEvent>,
) -> tokio::task::JoinHandle<()> {
    let bridge = EventBridge::new(registry);
    bridge.start(rx)
}

/// Serialize an agent event directly to a string (bypassing iOS compat for internal use).
pub fn serialize_event(event: &AgentEvent) -> Option<String> {
    let wire = compat::agent_event_to_wire(event);
    serde_json::to_string(&wire).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tron_core::ids::{AgentId, SessionId};

    #[test]
    fn serialize_turn_start_event() {
        let event = AgentEvent::TurnStart {
            session_id: SessionId::new(),
            agent_id: AgentId::new(),
            turn: 1,
        };
        let json = serialize_event(&event).unwrap();
        assert!(json.contains("\"type\":\"turn_start\""));
        assert!(json.contains("\"turn\":1"));
    }

    #[test]
    fn serialize_text_delta_event() {
        let event = AgentEvent::TextDelta {
            session_id: SessionId::new(),
            agent_id: AgentId::new(),
            delta: "Hello".into(),
        };
        let json = serialize_event(&event).unwrap();
        assert!(json.contains("\"type\":\"text_delta\""));
        assert!(json.contains("Hello"));
    }

    #[tokio::test]
    async fn bridge_forwards_to_session_clients() {
        let registry = Arc::new(ClientRegistry::new(32));
        let (tx, rx) = broadcast::channel(100);

        let (client_id, client_rx) = registry.register();
        let session_id = SessionId::new();
        registry.set_session(&client_id, session_id.clone()).await;

        let handle = create_bridge(Arc::clone(&registry), rx);

        // Send an event
        let event = AgentEvent::TurnStart {
            session_id: session_id.clone(),
            agent_id: AgentId::new(),
            turn: 1,
        };
        tx.send(event).unwrap();

        // Give the bridge task time to process
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        let msg = client_rx.try_recv().unwrap();
        assert!(msg.contains("turn_start"));

        handle.abort();
    }

    #[tokio::test]
    async fn bridge_ignores_unrelated_sessions() {
        let registry = Arc::new(ClientRegistry::new(32));
        let (tx, rx) = broadcast::channel(100);

        let (client_id, client_rx) = registry.register();
        let client_session = SessionId::new();
        registry.set_session(&client_id, client_session).await;

        let _handle = create_bridge(Arc::clone(&registry), rx);

        // Send event for a different session
        let other_session = SessionId::new();
        let event = AgentEvent::TurnStart {
            session_id: other_session,
            agent_id: AgentId::new(),
            turn: 1,
        };
        tx.send(event).unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        // Client should not receive the event
        assert!(client_rx.try_recv().is_none());
    }
}
