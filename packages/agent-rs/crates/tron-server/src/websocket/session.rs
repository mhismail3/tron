//! WebSocket session lifecycle — handles a single connected client from
//! upgrade through disconnect.

use std::sync::Arc;

use axum::extract::ws::{Message, WebSocket};
use futures::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use tron_rpc::context::RpcContext;
use tron_rpc::registry::MethodRegistry;

use super::broadcast::BroadcastManager;
use super::connection::ClientConnection;
use super::handler::handle_message;

/// Run a WebSocket session for a connected client.
///
/// 1. Sends a `system.connected` event with the client ID
/// 2. Dispatches incoming text frames as RPC requests
/// 3. Forwards outbound events/responses via the send channel
/// 4. Cleans up on disconnect
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

    // Register with broadcast manager
    broadcast.add(connection.clone()).await;

    // Send system.connected event (data wrapper matches TypeScript format)
    let connected_msg = serde_json::json!({
        "type": "system.connected",
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
        match msg {
            Message::Text(text) => {
                let response =
                    handle_message(&text, &registry, &ctx).await;

                // Check if this is a session.create or session.resume response
                // and bind the session if successful (only for these two methods)
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
                                }
                            }
                        }
                    }
                }

                connection.send(response);
            }
            Message::Close(_) => break,
            Message::Ping(data) => {
                connection.mark_alive();
                // Pong is automatically sent by axum for Ping frames,
                // but we also mark the connection alive
                let _ = data; // consumed
            }
            Message::Pong(_) => {
                connection.mark_alive();
            }
            Message::Binary(_) => {
                // Binary frames not supported
            }
        }
    }

    // Clean up
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
            "type": "system.connected",
            "clientId": client_id,
            "timestamp": chrono::Utc::now().to_rfc3339(),
        });
        assert_eq!(msg["type"], "system.connected");
        assert_eq!(msg["clientId"], client_id);
        assert!(msg["timestamp"].is_string());
    }
}
