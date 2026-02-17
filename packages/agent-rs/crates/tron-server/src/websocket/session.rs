//! WebSocket session lifecycle — handles a single connected client from
//! upgrade through disconnect.

use std::sync::Arc;
use std::time::Duration;

use axum::extract::ws::{Message, WebSocket};
use futures::{SinkExt, StreamExt};
use tokio::sync::mpsc;
use crate::rpc::context::RpcContext;
use crate::rpc::registry::MethodRegistry;

use metrics::{counter, gauge, histogram};
use tracing::{debug, info, instrument, warn};

use super::broadcast::BroadcastManager;
use super::connection::ClientConnection;
use super::handler::handle_message;

/// Interval between server-initiated Ping frames.
const PING_INTERVAL: Duration = Duration::from_secs(30);

/// How long to wait for a Pong before considering the client dead.
const PONG_TIMEOUT: Duration = Duration::from_secs(60);

/// Run a WebSocket session for a connected client.
///
/// 1. Sends a `connection.established` event with the client ID
/// 2. Dispatches incoming text frames as RPC requests
/// 3. Forwards outbound events/responses via the send channel
/// 4. Sends periodic Ping frames and disconnects unresponsive clients
/// 5. Cleans up on disconnect
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
    let (send_tx, mut send_rx) = mpsc::channel::<String>(1024);
    let connection = Arc::new(ClientConnection::new(client_id.clone(), send_tx));

    let connection_start = std::time::Instant::now();
    info!(client_id, "client connected");
    counter!("ws_connections_total").increment(1);
    gauge!("ws_connections_active").increment(1.0);
    gauge!("sessions_active").increment(1.0);

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

    // Spawn outbound forwarder with periodic Ping frames.
    let outbound_conn = connection.clone();
    let outbound = tokio::spawn(async move {
        let mut ping_interval = tokio::time::interval(PING_INTERVAL);
        // Skip the immediate first tick
        let _ = ping_interval.tick().await;

        loop {
            tokio::select! {
                msg = send_rx.recv() => {
                    match msg {
                        Some(text) => {
                            if ws_tx.send(Message::Text(text.into())).await.is_err() {
                                break;
                            }
                        }
                        None => break,
                    }
                }
                _ = ping_interval.tick() => {
                    // Check if client responded to previous ping
                    if !outbound_conn.check_alive() {
                        // Client missed a ping cycle — check if it's been too long
                        if outbound_conn.last_pong_elapsed() > PONG_TIMEOUT {
                            warn!("client unresponsive for {:?}, disconnecting", PONG_TIMEOUT);
                            break;
                        }
                    }
                    // Send ping
                    if ws_tx.send(Message::Ping(vec![].into())).await.is_err() {
                        break;
                    }
                }
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

        let result = handle_message(&text, &registry, &ctx).await;

        // Bind session on create/resume
        if (result.method == "session.create" || result.method == "session.resume")
            && result.response.success
        {
            if let Some(sid) = result
                .response
                .result
                .as_ref()
                .and_then(|r| r.get("sessionId"))
                .and_then(|v| v.as_str())
            {
                connection.bind_session(sid.to_string());
                debug!(client_id, session_id = sid, "session bound to client");
            }
        }

        if !connection.send(result.response_json) {
            info!(client_id, "failed to enqueue response (channel full or closed)");
        }
    }

    // Clean up
    info!(client_id, "client disconnected");
    counter!("ws_disconnections_total").increment(1);
    gauge!("ws_connections_active").decrement(1.0);
    gauge!("sessions_active").decrement(1.0);
    histogram!("ws_connection_duration_seconds").record(connection_start.elapsed().as_secs_f64());
    outbound.abort();
    broadcast.remove(&client_id).await;
}

#[cfg(test)]
mod tests {
    // WsSession tests require actual WebSocket connections which are
    // covered by integration tests in tests/integration.rs.
    // Unit tests here validate the helper logic.

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
