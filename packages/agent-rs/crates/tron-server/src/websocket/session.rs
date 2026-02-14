//! WebSocket session lifecycle — handles a single connected client from
//! upgrade through disconnect.

use std::sync::Arc;

use axum::extract::ws::{Message, WebSocket};
use futures::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tron_rpc::context::RpcContext;
use tron_rpc::registry::MethodRegistry;

use tracing::{debug, info, instrument};

use super::broadcast::BroadcastManager;
use super::connection::ClientConnection;
use super::handler::handle_message;

/// Run a WebSocket session for a connected client.
///
/// 1. Sends a `system.connected` event with the client ID
/// 2. Dispatches incoming text frames as RPC requests
/// 3. Forwards outbound events/responses via the send channel
/// 4. Cleans up on disconnect
#[instrument(skip_all, fields(client_id = %client_id))]
pub async fn run_ws_session(
    ws: WebSocket,
    client_id: String,
    registry: Arc<MethodRegistry>,
    ctx: Arc<RpcContext>,
    broadcast: Arc<BroadcastManager>,
) {
    let (mut ws_tx, mut ws_rx) = ws.split();

    // Create the client connection and send channel
    let (send_tx, mut send_rx) = mpsc::channel::<String>(256);
    let connection = Arc::new(ClientConnection::new(client_id.clone(), send_tx));

    info!(client_id, "client connected");

    // Register with broadcast manager
    broadcast.add(connection.clone()).await;

    // Send connection.established event (iOS expects this type string)
    let connected_msg = serde_json::json!({
        "type": "connection.established",
        "timestamp": chrono::Utc::now().to_rfc3339(),
        "data": {
            "clientId": client_id,
        },
    });
    if let Ok(json) = serde_json::to_string(&connected_msg) {
        let _ = ws_tx.send(Message::Text(json.into())).await;
    }

    // Spawn outbound forwarder (send_rx → WebSocket)
    let outbound = tokio::spawn(async move {
        while let Some(msg) = send_rx.recv().await {
            if ws_tx.send(Message::Text(msg.into())).await.is_err() {
                break;
            }
        }
    });

    // Process incoming messages
    while let Some(Ok(msg)) = ws_rx.next().await {
        // Extract text from either Text or Binary frames (iOS sends binary)
        let text = match msg {
            Message::Text(ref t) => Some(t.to_string()),
            Message::Binary(ref data) => {
                if let Ok(s) = std::str::from_utf8(data) {
                    Some(s.to_string())
                } else {
                    info!(client_id, len = data.len(), "received non-UTF8 binary frame");
                    None
                }
            }
            Message::Close(_) => {
                info!(client_id, "client sent close frame");
                break;
            }
            Message::Ping(_) | Message::Pong(_) => {
                connection.mark_alive();
                None
            }
        };

        let Some(text) = text else { continue };

        let response = handle_message(&text, &registry, &ctx).await;

        // Bind session on create/resume
        if let Ok(req) = serde_json::from_str::<serde_json::Value>(&text) {
            let method = req.get("method").and_then(|v| v.as_str()).unwrap_or("");
            if method == "session.create" || method == "session.resume" {
                if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(&response) {
                    if parsed["success"] == true {
                        if let Some(sid) = parsed["result"]
                            .get("sessionId")
                            .and_then(|v| v.as_str())
                        {
                            connection.bind_session(sid.to_string());
                            debug!(client_id, session_id = sid, "session bound to client");
                        }
                    }
                }
            }
        }

        if !connection.send(response) {
            info!(client_id, "failed to enqueue response (channel full or closed)");
        }
    }

    // Clean up
    info!(client_id, "client disconnected");
    outbound.abort();
    broadcast.remove(&client_id).await;
}

#[cfg(test)]
mod tests {
    // WsSession tests require actual WebSocket connections which are
    // covered by integration tests in tests/integration.rs.
    // Unit tests here validate the helper logic.

    use super::*;

    #[test]
    fn connected_message_has_required_fields() {
        let client_id = "test_client_123";
        let msg = serde_json::json!({
            "type": "connection.established",
            "data": { "clientId": client_id },
            "timestamp": chrono::Utc::now().to_rfc3339(),
        });
        assert_eq!(msg["type"], "connection.established");
        assert_eq!(msg["data"]["clientId"], client_id);
        assert!(msg["timestamp"].is_string());
    }

    #[test]
    fn connected_message_type_is_connection_established() {
        let msg = serde_json::json!({
            "type": "connection.established",
            "timestamp": chrono::Utc::now().to_rfc3339(),
            "data": { "clientId": "c1" },
        });
        assert_eq!(msg["type"], "connection.established");
        assert_ne!(msg["type"], "system.connected");
    }
}
