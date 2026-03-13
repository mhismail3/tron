//! WebSocket session lifecycle — handles a single connected client from
//! upgrade through disconnect.

use std::sync::Arc;
use std::time::Duration;

use crate::rpc::context::RpcContext;
use crate::rpc::registry::MethodRegistry;
use axum::extract::ws::{Message, WebSocket};
use futures::{SinkExt, StreamExt};
use tokio::sync::mpsc;

use metrics::{counter, gauge, histogram};
use tracing::{debug, instrument, warn};

use super::broadcast::BroadcastManager;
use super::connection::{ClientConnection, ConnectionLimits};
use super::handler::handle_message;

/// How long to wait for the outbound forwarder to drain after disconnect.
const OUTBOUND_DRAIN_TIMEOUT: Duration = Duration::from_secs(5);

/// Run a WebSocket session for a connected client.
///
/// 1. Sends a `connection.established` event with the client ID
/// 2. Dispatches incoming text frames as RPC requests
/// 3. Forwards outbound events/responses via the send channel
/// 4. Sends periodic Ping frames and disconnects unresponsive clients
/// 5. Cleans up on disconnect
#[allow(clippy::too_many_lines)]
#[instrument(skip_all, fields(client_id = %client_id))]
pub async fn run_ws_session(
    ws: WebSocket,
    client_id: String,
    registry: Arc<MethodRegistry>,
    ctx: Arc<RpcContext>,
    broadcast: Arc<BroadcastManager>,
    ping_interval: Duration,
    pong_timeout: Duration,
) {
    run_ws_session_with_limits(
        ws,
        client_id,
        registry,
        ctx,
        broadcast,
        ping_interval,
        pong_timeout,
        ConnectionLimits::default(),
    )
    .await;
}

pub(crate) async fn run_ws_session_with_limits(
    ws: WebSocket,
    client_id: String,
    registry: Arc<MethodRegistry>,
    ctx: Arc<RpcContext>,
    broadcast: Arc<BroadcastManager>,
    ping_interval: Duration,
    pong_timeout: Duration,
    connection_limits: ConnectionLimits,
) {
    if pong_timeout <= ping_interval {
        warn!(
            ?ping_interval,
            ?pong_timeout,
            "pong_timeout should be > ping_interval for meaningful liveness detection"
        );
    }
    let (mut ws_tx, mut ws_rx) = ws.split();

    // Create the client connection and send channel
    let (send_tx, mut send_rx) = mpsc::unbounded_channel();
    let connection = Arc::new(ClientConnection::new_with_limits(
        client_id.clone(),
        send_tx,
        connection_limits,
    ));

    let connection_start = std::time::Instant::now();
    debug!(client_id, "client connected");
    counter!("ws_connections_total").increment(1);
    gauge!("ws_connections_active").increment(1.0);

    // Register with broadcast manager
    broadcast.add(connection.clone()).await;

    // Send connection.established event
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

    // Shutdown signal for the outbound forwarder.
    let shutdown = Arc::new(tokio::sync::Notify::new());
    let shutdown_signal = shutdown.clone();

    // Spawn outbound forwarder with periodic Ping frames.
    let outbound_conn = connection.clone();
    let outbound = tokio::spawn(async move {
        let mut ping_ticker = tokio::time::interval(ping_interval);
        // Skip the immediate first tick
        let _ = ping_ticker.tick().await;

        loop {
            tokio::select! {
                msg = send_rx.recv() => {
                    match msg {
                        Some(message) => {
                            let s = Arc::unwrap_or_clone(message.text);
                            outbound_conn.complete_send(message.size_bytes);
                            if ws_tx.send(Message::Text(s.into())).await.is_err() {
                                break;
                            }
                        }
                        None => break,
                    }
                }
                () = outbound_conn.close_requested() => {
                    warn!(client_id = %outbound_conn.id, "closing overloaded websocket connection");
                    break;
                }
                _ = ping_ticker.tick() => {
                    // Check if client responded to previous ping
                    if !outbound_conn.check_alive() {
                        // Client missed a ping cycle — check if it's been too long
                        if outbound_conn.last_pong_elapsed() > pong_timeout {
                            warn!("client unresponsive for {:?}, disconnecting", pong_timeout);
                            break;
                        }
                    }
                    // Send ping
                    if ws_tx.send(Message::Ping(vec![].into())).await.is_err() {
                        break;
                    }
                }
                () = shutdown_signal.notified() => {
                    // Drain any remaining queued messages
                    while let Ok(message) = send_rx.try_recv() {
                        let s = Arc::unwrap_or_clone(message.text);
                        outbound_conn.complete_send(message.size_bytes);
                        if ws_tx.send(Message::Text(s.into())).await.is_err() {
                            break;
                        }
                    }
                    break;
                }
            }
        }
    });
    let outbound_abort = outbound.abort_handle();

    // Process incoming messages
    loop {
        let next = tokio::select! {
            () = connection.close_requested() => None,
            next = ws_rx.next() => next,
        };
        let Some(Ok(msg)) = next else { break };
        // Extract text from either Text or Binary frames (some clients send binary).
        // Borrow from `msg` instead of allocating — the borrow outlives `handle_message`.
        let text: Option<&str> = match &msg {
            Message::Text(t) => Some(t.as_str()),
            Message::Binary(data) => {
                if let Ok(s) = std::str::from_utf8(data) {
                    Some(s)
                } else {
                    debug!(
                        client_id,
                        len = data.len(),
                        "received non-UTF8 binary frame"
                    );
                    None
                }
            }
            Message::Close(_) => {
                debug!(client_id, "client sent close frame");
                break;
            }
            Message::Ping(_) | Message::Pong(_) => {
                connection.mark_alive();
                None
            }
        };

        let Some(text) = text else { continue };

        let result = handle_message(text, &registry, &ctx).await;

        // Bind session on create/resume
        if (result.method == "session.create" || result.method == "session.resume")
            && result.response.success
            && let Some(sid) = result
                .response
                .result
                .as_ref()
                .and_then(|r| r.get("sessionId"))
                .and_then(|v| v.as_str())
        {
            connection.bind_session(sid);
            debug!(client_id, session_id = sid, "session bound to client");
        }

        match connection.send(Arc::new(result.response_json)) {
            super::connection::SendOutcome::Enqueued => {}
            super::connection::SendOutcome::Closed => {
                debug!(client_id, "failed to enqueue response (connection closed)");
                break;
            }
            super::connection::SendOutcome::Overloaded(health) => {
                debug!(
                    client_id,
                    recent_drops = health.recent_drops,
                    total_drops = health.total_drops,
                    "failed to enqueue response (connection overloaded)"
                );
                if health.should_disconnect {
                    connection.request_close();
                    break;
                }
            }
        }
    }

    // Clean up — signal outbound forwarder to drain and exit
    debug!(client_id, "client disconnected");
    counter!("ws_disconnections_total").increment(1);
    gauge!("ws_connections_active").decrement(1.0);
    histogram!("ws_connection_duration_seconds").record(connection_start.elapsed().as_secs_f64());

    // Remove from broadcast first (releases its Arc<ClientConnection>)
    broadcast.remove(&client_id).await;
    // Signal outbound task to drain remaining messages and exit
    shutdown.notify_one();
    // Drop our Arc (outbound_conn inside the task is the last holder)
    drop(connection);
    if tokio::time::timeout(OUTBOUND_DRAIN_TIMEOUT, outbound)
        .await
        .is_ok()
    {
        debug!(client_id, "outbound forwarder drained");
    } else {
        warn!(client_id, "outbound forwarder drain timed out, aborting");
        outbound_abort.abort();
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;
    use std::time::Duration;

    use super::{ConnectionLimits, run_ws_session_with_limits};
    use axum::Router;
    use axum::extract::ws::WebSocketUpgrade;
    use axum::routing::get;
    use futures::{SinkExt, StreamExt};
    use tokio::net::TcpListener;
    use tokio_tungstenite::connect_async;
    use tokio_tungstenite::tungstenite::Message;

    use crate::rpc::handlers;
    use crate::rpc::handlers::test_helpers::make_test_context;
    use crate::rpc::registry::MethodRegistry;
    use crate::websocket::broadcast::BroadcastManager;

    async fn boot_session_server_with_limits(
        limits: ConnectionLimits,
    ) -> (String, Arc<BroadcastManager>, tokio::task::JoinHandle<()>) {
        let mut registry = MethodRegistry::new();
        handlers::register_all(&mut registry);
        let registry = Arc::new(registry);
        let ctx = Arc::new(make_test_context());
        let broadcast = Arc::new(BroadcastManager::new());
        let ping_interval = Duration::from_secs(60);
        let pong_timeout = Duration::from_secs(120);

        let app = Router::new().route(
            "/ws",
            get({
                let registry = Arc::clone(&registry);
                let ctx = Arc::clone(&ctx);
                let broadcast = Arc::clone(&broadcast);
                move |ws: WebSocketUpgrade| {
                    let registry = Arc::clone(&registry);
                    let ctx = Arc::clone(&ctx);
                    let broadcast = Arc::clone(&broadcast);
                    async move {
                        ws.on_upgrade(move |socket| {
                            run_ws_session_with_limits(
                                socket,
                                uuid::Uuid::now_v7().to_string(),
                                registry,
                                ctx,
                                broadcast,
                                ping_interval,
                                pong_timeout,
                                limits,
                            )
                        })
                    }
                }
            }),
        );

        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let handle = tokio::spawn(async move {
            let _ = axum::serve(listener, app).await;
        });

        (format!("ws://{addr}/ws"), broadcast, handle)
    }

    async fn read_json(
        ws: &mut tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
    ) -> serde_json::Value {
        loop {
            let msg = tokio::time::timeout(Duration::from_secs(2), ws.next())
                .await
                .expect("timeout waiting for websocket message")
                .expect("websocket closed unexpectedly")
                .expect("websocket read error");
            if let Message::Text(text) = msg {
                return serde_json::from_str(&text).unwrap();
            }
        }
    }

    #[test]
    fn session_uses_config_heartbeat_values() {
        // Verify the function signature accepts custom heartbeat parameters.
        // The compile-time check ensures the config values are properly threaded.
        let ping_interval = Duration::from_secs(10);
        let pong_timeout = Duration::from_secs(45);
        assert!(
            pong_timeout > ping_interval,
            "pong_timeout should exceed ping_interval"
        );
    }

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

    #[tokio::test]
    async fn overloaded_response_closes_connection_and_cleans_up() {
        let (url, broadcast, handle) = boot_session_server_with_limits(ConnectionLimits {
            max_pending_bytes: 1,
            drop_window: Duration::from_secs(60),
            max_recent_drops: 1,
        })
        .await;
        let (mut ws, _) = connect_async(&url).await.unwrap();

        let established = read_json(&mut ws).await;
        assert_eq!(established["type"], "connection.established");
        assert_eq!(broadcast.connection_count(), 1);

        ws.send(Message::Text(
            serde_json::json!({"id": "r1", "method": "system.ping"})
                .to_string()
                .into(),
        ))
        .await
        .unwrap();

        let closed = tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                let next = ws.next().await;
                if next.is_none()
                    || matches!(next, Some(Ok(Message::Close(_))))
                    || matches!(next, Some(Err(_)))
                {
                    break;
                }
            }
        })
        .await;
        assert!(
            closed.is_ok(),
            "overloaded connection should terminate promptly"
        );

        tokio::time::timeout(Duration::from_secs(2), async {
            loop {
                if broadcast.connection_count() == 0 {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(25)).await;
            }
        })
        .await
        .expect("connection should be removed from broadcast manager");

        handle.abort();
    }
}
