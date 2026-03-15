//! Device request/response broker.
//!
//! Implements a request/response pattern over the existing WebSocket event
//! channel. Server broadcasts a `device.request` event, iOS handles it locally,
//! and sends the result back via a `device.respond` RPC call.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use metrics::{counter, gauge, histogram};
use parking_lot::Mutex;
use serde_json::{Value, json};
use tokio::sync::oneshot;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::server::rpc::types::RpcEvent;
use crate::server::websocket::broadcast::BroadcastManager;

/// Broker for device request/response round-trips.
///
/// # Flow
///
/// 1. Tool calls `broker.request(method, params)`.
/// 2. Broker generates a `requestId`, stores a oneshot sender, and broadcasts
///    a `device.request` event via `BroadcastManager`.
/// 3. iOS receives the event, dispatches to a local handler, and sends the
///    result back via the `device.respond` RPC call.
/// 4. The `device.respond` handler calls `broker.resolve(requestId, result)`,
///    which completes the oneshot and unblocks the tool.
pub struct DeviceRequestBroker {
    pending: Mutex<HashMap<String, PendingRequest>>,
    broadcast: Arc<BroadcastManager>,
    shutdown: CancellationToken,
}

struct PendingRequest {
    session_id: String,
    tx: oneshot::Sender<Value>,
}

impl DeviceRequestBroker {
    /// Create a new broker backed by the given broadcast manager.
    pub fn new(broadcast: Arc<BroadcastManager>, shutdown: CancellationToken) -> Self {
        Self {
            pending: Mutex::new(HashMap::new()),
            broadcast,
            shutdown,
        }
    }

    /// Send a request to the iOS device and await the response.
    pub async fn request(
        &self,
        session_id: &str,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> Result<Value, DeviceRequestError> {
        let start = std::time::Instant::now();
        let request_id = Uuid::new_v4().to_string();
        let (tx, rx) = oneshot::channel();

        let pending_count = {
            let mut pending = self.pending.lock();
            let _ = pending.insert(
                request_id.clone(),
                PendingRequest {
                    session_id: session_id.to_string(),
                    tx,
                },
            );
            pending.len()
        };
        gauge!("device_requests_pending").set(pending_count as f64);
        counter!("device_requests_started_total").increment(1);

        let event = RpcEvent {
            event_type: "device.request".into(),
            session_id: Some(session_id.to_string()),
            timestamp: chrono::Utc::now().to_rfc3339(),
            data: Some(json!({
                "requestId": request_id,
                "sessionId": session_id,
                "method": method,
                "params": params,
            })),
            run_id: None,
        };
        self.broadcast
            .broadcast_to_session(session_id, &event)
            .await;

        let shutdown = self.shutdown.clone();
        tokio::select! {
            result = tokio::time::timeout(timeout, rx) => match result {
                Ok(Ok(value)) => {
                    counter!("device_requests_completed_total", "outcome" => "success").increment(1);
                    histogram!("device_request_duration_seconds", "outcome" => "success")
                        .record(start.elapsed().as_secs_f64());
                    Ok(value)
                }
                Ok(Err(_)) => {
                    let _ = self.remove_pending(&request_id);
                    counter!("device_requests_completed_total", "outcome" => "cancelled").increment(1);
                    histogram!("device_request_duration_seconds", "outcome" => "cancelled")
                        .record(start.elapsed().as_secs_f64());
                    Err(DeviceRequestError::Cancelled)
                }
                Err(_) => {
                    let _ = self.remove_pending(&request_id);
                    counter!("device_requests_completed_total", "outcome" => "timeout").increment(1);
                    histogram!("device_request_duration_seconds", "outcome" => "timeout")
                        .record(start.elapsed().as_secs_f64());
                    Err(DeviceRequestError::Timeout)
                }
            },
            () = shutdown.cancelled() => {
                let _ = self.remove_pending(&request_id);
                // Sender was dropped (broker shutting down or request cancelled)
                counter!("device_requests_completed_total", "outcome" => "cancelled").increment(1);
                histogram!("device_request_duration_seconds", "outcome" => "cancelled")
                    .record(start.elapsed().as_secs_f64());
                Err(DeviceRequestError::Cancelled)
            }
        }
    }

    /// Resolve a pending request with the given result. Returns `true` if a
    /// matching request was found and resolved.
    pub fn resolve(&self, request_id: &str, result: Value) -> bool {
        if let Some(pending) = self.remove_pending(request_id) {
            counter!("device_request_resolve_total", "outcome" => "resolved").increment(1);
            pending.tx.send(result).is_ok()
        } else {
            counter!("device_request_resolve_total", "outcome" => "missing").increment(1);
            false
        }
    }

    /// Cancel all pending requests for a given session.
    pub fn cancel_session_pending(&self, session_id: &str) {
        let pending_count = {
            let mut pending = self.pending.lock();
            let before = pending.len();
            pending.retain(|_, request| request.session_id != session_id);
            let removed = before.saturating_sub(pending.len());
            if removed > 0 {
                counter!("device_requests_cancelled_total", "scope" => "session")
                    .increment(removed as u64);
            }
            pending.len()
        };
        gauge!("device_requests_pending").set(pending_count as f64);
    }

    /// Cancel all pending requests. Dropping senders causes receivers
    /// to get `DeviceRequestError::Cancelled`.
    pub fn cancel_all_pending(&self) {
        let cleared = {
            let mut pending = self.pending.lock();
            let cleared = pending.len();
            if cleared > 0 {
                tracing::debug!(
                    count = pending.len(),
                    "cancelling all pending device requests"
                );
                pending.clear();
            }
            cleared
        };
        gauge!("device_requests_pending").set(0.0);
        if cleared > 0 {
            tracing::debug!(count = cleared, "cancelled all pending device requests");
            counter!("device_requests_cancelled_total", "scope" => "all").increment(cleared as u64);
        }
    }

    /// Number of pending (unresolved) requests.
    pub fn pending_count(&self) -> usize {
        self.pending.lock().len()
    }

    fn remove_pending(&self, request_id: &str) -> Option<PendingRequest> {
        let (removed, remaining) = {
            let mut pending = self.pending.lock();
            let removed = pending.remove(request_id);
            let remaining = pending.len();
            (removed, remaining)
        };
        gauge!("device_requests_pending").set(remaining as f64);
        removed
    }
}

/// Errors from device request/response.
#[derive(Debug, thiserror::Error)]
pub enum DeviceRequestError {
    /// iOS app didn't respond within the timeout.
    #[error("Device request timed out (iOS app not connected?)")]
    Timeout,
    /// Request was cancelled (broker shutting down).
    #[error("Device request cancelled")]
    Cancelled,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_broker() -> DeviceRequestBroker {
        let broadcast = Arc::new(BroadcastManager::new());
        DeviceRequestBroker::new(broadcast, CancellationToken::new())
    }

    #[test]
    fn resolve_without_request_returns_false() {
        let broker = make_broker();
        assert!(!broker.resolve("nonexistent", json!(42)));
    }

    #[tokio::test]
    async fn request_and_resolve() {
        let broker = Arc::new(make_broker());
        let broker2 = broker.clone();

        let handle = tokio::spawn(async move {
            broker2
                .request(
                    "session-a",
                    "test.method",
                    json!({"key": "val"}),
                    Duration::from_secs(5),
                )
                .await
        });

        // Give the request time to register
        tokio::time::sleep(Duration::from_millis(50)).await;

        // Find the pending request and resolve it
        assert_eq!(broker.pending_count(), 1);
        let request_id = broker.pending.lock().keys().next().cloned().unwrap();
        assert!(broker.resolve(&request_id, json!({"result": "ok"})));

        let result = handle.await.unwrap().unwrap();
        assert_eq!(result["result"], "ok");
        assert_eq!(broker.pending_count(), 0);
    }

    #[tokio::test]
    async fn request_timeout() {
        let broker = make_broker();
        let result = broker
            .request(
                "session-a",
                "test.slow",
                json!({}),
                Duration::from_millis(10),
            )
            .await;
        assert!(matches!(result, Err(DeviceRequestError::Timeout)));
        assert_eq!(broker.pending_count(), 0);
    }

    #[test]
    fn resolve_returns_false_for_already_resolved() {
        let broker = make_broker();
        // No pending request
        assert!(!broker.resolve("id-1", json!(null)));
    }

    #[test]
    fn pending_count_starts_at_zero() {
        let broker = make_broker();
        assert_eq!(broker.pending_count(), 0);
    }

    #[tokio::test]
    async fn cancel_all_pending_clears_entries() {
        let broker = Arc::new(make_broker());
        let broker2 = broker.clone();

        let handle = tokio::spawn(async move {
            broker2
                .request(
                    "session-a",
                    "test.method",
                    json!({}),
                    Duration::from_secs(5),
                )
                .await
        });

        // Wait for the request to register
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(broker.pending_count(), 1);

        // Cancel all — should clear pending and cause receiver to get Cancelled
        broker.cancel_all_pending();
        assert_eq!(broker.pending_count(), 0);

        let result = handle.await.unwrap();
        assert!(matches!(result, Err(DeviceRequestError::Cancelled)));
    }

    #[test]
    fn cancel_all_pending_empty_is_noop() {
        let broker = make_broker();
        broker.cancel_all_pending(); // should not panic
        assert_eq!(broker.pending_count(), 0);
    }

    #[tokio::test]
    async fn cancel_all_pending_then_resolve_returns_false() {
        let broker = Arc::new(make_broker());
        let broker2 = broker.clone();

        let handle = tokio::spawn(async move {
            broker2
                .request(
                    "session-a",
                    "test.method",
                    json!({}),
                    Duration::from_secs(5),
                )
                .await
        });

        tokio::time::sleep(Duration::from_millis(50)).await;
        let request_id = broker.pending.lock().keys().next().cloned().unwrap();

        broker.cancel_all_pending();

        // Late resolve should return false (entry already gone)
        assert!(!broker.resolve(&request_id, json!({"result": "late"})));

        let _ = handle.await;
    }

    #[tokio::test]
    async fn request_only_reaches_target_session() {
        let broadcast = Arc::new(BroadcastManager::new());
        let broker = Arc::new(DeviceRequestBroker::new(
            broadcast.clone(),
            CancellationToken::new(),
        ));

        let (session_a_tx, mut session_a_rx) = tokio::sync::mpsc::unbounded_channel();
        let conn_a = Arc::new(crate::server::websocket::connection::ClientConnection::new(
            "conn-a".into(),
            session_a_tx,
        ));
        conn_a.bind_session("session-a");
        broadcast.add(conn_a).await;

        let (session_b_tx, mut session_b_rx) = tokio::sync::mpsc::unbounded_channel();
        let conn_b = Arc::new(crate::server::websocket::connection::ClientConnection::new(
            "conn-b".into(),
            session_b_tx,
        ));
        conn_b.bind_session("session-b");
        broadcast.add(conn_b).await;

        let broker_clone = broker.clone();
        let request = tokio::spawn(async move {
            broker_clone
                .request(
                    "session-a",
                    "contacts.search",
                    json!({"query": "alice"}),
                    Duration::from_secs(5),
                )
                .await
        });

        let targeted = session_a_rx.recv().await.unwrap();
        let event: serde_json::Value = serde_json::from_str(&targeted).unwrap();
        let request_id = event["data"]["requestId"].as_str().unwrap().to_string();
        assert_eq!(event["sessionId"], "session-a");
        assert!(session_b_rx.try_recv().is_err());

        assert!(broker.resolve(&request_id, json!({"ok": true})));
        let result = request.await.unwrap().unwrap();
        assert_eq!(result["ok"], true);
    }

    #[tokio::test]
    async fn cancel_session_pending_only_cancels_matching_session() {
        let broker = Arc::new(make_broker());

        let first = {
            let broker = broker.clone();
            tokio::spawn(async move {
                broker
                    .request(
                        "session-a",
                        "test.method",
                        json!({}),
                        Duration::from_secs(5),
                    )
                    .await
            })
        };
        let second = {
            let broker = broker.clone();
            tokio::spawn(async move {
                broker
                    .request(
                        "session-b",
                        "test.method",
                        json!({}),
                        Duration::from_secs(5),
                    )
                    .await
            })
        };

        tokio::time::sleep(Duration::from_millis(50)).await;
        broker.cancel_session_pending("session-a");

        let remaining_request_id = broker
            .pending
            .lock()
            .iter()
            .find(|(_, request)| request.session_id == "session-b")
            .map(|(request_id, _)| request_id.clone())
            .unwrap();
        assert!(broker.resolve(&remaining_request_id, json!({"ok": true})));

        assert!(matches!(
            first.await.unwrap(),
            Err(DeviceRequestError::Cancelled)
        ));
        assert_eq!(second.await.unwrap().unwrap()["ok"], true);
    }

    #[tokio::test]
    async fn shutdown_token_cancels_pending_requests() {
        let cancel = CancellationToken::new();
        let broker = Arc::new(DeviceRequestBroker::new(
            Arc::new(BroadcastManager::new()),
            cancel.clone(),
        ));

        let broker_clone = broker.clone();
        let handle = tokio::spawn(async move {
            broker_clone
                .request(
                    "session-a",
                    "test.method",
                    json!({}),
                    Duration::from_secs(5),
                )
                .await
        });

        tokio::time::sleep(Duration::from_millis(50)).await;
        cancel.cancel();

        assert!(matches!(
            handle.await.unwrap(),
            Err(DeviceRequestError::Cancelled)
        ));
        assert_eq!(broker.pending_count(), 0);
    }
}
