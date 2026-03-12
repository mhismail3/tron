//! Device request/response broker.
//!
//! Implements a request/response pattern over the existing WebSocket event
//! channel. Server broadcasts a `device.request` event, iOS handles it locally,
//! and sends the result back via a `device.respond` RPC call.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use parking_lot::Mutex;
use serde_json::{Value, json};
use tokio::sync::oneshot;
use uuid::Uuid;

use crate::rpc::types::RpcEvent;
use crate::websocket::broadcast::BroadcastManager;

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
    pending: Mutex<HashMap<String, oneshot::Sender<Value>>>,
    broadcast: Arc<BroadcastManager>,
}

impl DeviceRequestBroker {
    /// Create a new broker backed by the given broadcast manager.
    pub fn new(broadcast: Arc<BroadcastManager>) -> Self {
        Self {
            pending: Mutex::new(HashMap::new()),
            broadcast,
        }
    }

    /// Send a request to the iOS device and await the response.
    pub async fn request(
        &self,
        method: &str,
        params: Value,
        timeout: Duration,
    ) -> Result<Value, DeviceRequestError> {
        let request_id = Uuid::new_v4().to_string();
        let (tx, rx) = oneshot::channel();

        let _ = self.pending.lock().insert(request_id.clone(), tx);

        let event = RpcEvent {
            event_type: "device.request".into(),
            session_id: None,
            timestamp: chrono::Utc::now().to_rfc3339(),
            data: Some(json!({
                "requestId": request_id,
                "method": method,
                "params": params,
            })),
            run_id: None,
        };
        self.broadcast.broadcast_all(&event).await;

        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(value)) => Ok(value),
            Ok(Err(_)) => {
                // Sender was dropped (broker shutting down or request cancelled)
                Err(DeviceRequestError::Cancelled)
            }
            Err(_) => {
                let _ = self.pending.lock().remove(&request_id);
                Err(DeviceRequestError::Timeout)
            }
        }
    }

    /// Resolve a pending request with the given result. Returns `true` if a
    /// matching request was found and resolved.
    pub fn resolve(&self, request_id: &str, result: Value) -> bool {
        if let Some(tx) = self.pending.lock().remove(request_id) {
            tx.send(result).is_ok()
        } else {
            false
        }
    }

    /// Cancel all pending requests. Dropping senders causes receivers
    /// to get `DeviceRequestError::Cancelled`.
    pub fn cancel_all_pending(&self) {
        let mut pending = self.pending.lock();
        if !pending.is_empty() {
            tracing::debug!(
                count = pending.len(),
                "cancelling all pending device requests"
            );
            pending.clear();
        }
    }

    /// Number of pending (unresolved) requests.
    pub fn pending_count(&self) -> usize {
        self.pending.lock().len()
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
        DeviceRequestBroker::new(broadcast)
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
                .request("test.method", json!({"key": "val"}), Duration::from_secs(5))
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
            .request("test.slow", json!({}), Duration::from_millis(10))
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
                .request("test.method", json!({}), Duration::from_secs(5))
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
                .request("test.method", json!({}), Duration::from_secs(5))
                .await
        });

        tokio::time::sleep(Duration::from_millis(50)).await;
        let request_id = broker.pending.lock().keys().next().cloned().unwrap();

        broker.cancel_all_pending();

        // Late resolve should return false (entry already gone)
        assert!(!broker.resolve(&request_id, json!({"result": "late"})));

        let _ = handle.await;
    }
}
