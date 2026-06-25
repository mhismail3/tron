//! Device request/response broker.
//!
//! Implements a request/response pattern over engine streams. Server publishes
//! a `device.request` event scoped to the session, the client handles it
//! locally, and sends the result back via the `device::respond` capability.
//! This broker is not the APNs token owner, notification inbox owner, badge
//! policy owner, or push transport. Slice 13 device registration and inbox
//! delivery evidence live under `domains::device` and `domains::notifications`.

use std::collections::HashMap;
use std::time::Duration;

use metrics::{counter, gauge, histogram};
use parking_lot::Mutex;
use serde_json::{Value, json};
use tokio::sync::oneshot;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::engine::{EngineHostHandle, PublishStreamEvent, VisibilityScope};
use crate::shared::server::events::ServerEventPayload;

/// Broker for device request/response round-trips.
///
/// # Flow
///
/// 1. Capability invocations `broker.request(method, params)`.
/// 2. Broker generates a `requestId`, stores a oneshot sender, and broadcasts
///    a `device.request` event to the session stream.
/// 3. iOS receives the event, dispatches to a local handler, and sends the
///    result back via the `device::respond` capability.
/// 4. `device::respond` calls `broker.resolve(requestId, result)`,
///    which completes the oneshot and unblocks the capability.
pub struct DeviceRequestBroker {
    pending: Mutex<HashMap<String, PendingRequest>>,
    engine_host: EngineHostHandle,
    shutdown: CancellationToken,
}

struct PendingRequest {
    session_id: String,
    tx: oneshot::Sender<Value>,
}

impl DeviceRequestBroker {
    /// Create a new broker backed by the engine stream store.
    pub fn new(engine_host: EngineHostHandle, shutdown: CancellationToken) -> Self {
        Self {
            pending: Mutex::new(HashMap::new()),
            engine_host,
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

        let event = ServerEventPayload {
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
            sequence: None,
            workspace_id: None,
            trace_id: None,
            parent_invocation_id: None,
            source_event_id: None,
            source_sequence: None,
            stream_cursor: None,
        };
        if let Err(error) = self
            .engine_host
            .publish_stream_event(PublishStreamEvent {
                topic: "events.session".to_owned(),
                payload: json!({
                    "serverEvent": event.clone(),
                    "sourceEventType": event.event_type.clone(),
                }),
                visibility: VisibilityScope::Session,
                session_id: Some(session_id.to_owned()),
                workspace_id: None,
                producer: "device".to_owned(),
                trace_id: None,
                parent_invocation_id: None,
            })
            .await
        {
            tracing::warn!(
                session_id,
                method,
                error = %error,
                "device request stream publication failed"
            );
        }

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
    use std::sync::Arc;

    use crate::engine::{EngineHostHandle, StreamActorScope, StreamCursor};

    fn make_host() -> EngineHostHandle {
        EngineHostHandle::new_in_memory().unwrap()
    }

    fn make_broker() -> DeviceRequestBroker {
        DeviceRequestBroker::new(make_host(), CancellationToken::new())
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
        let host = make_host();
        host.subscribe_stream(
            "device-session-a".to_owned(),
            "events.session".to_owned(),
            StreamCursor(0),
            VisibilityScope::Session,
            Some("session-a".to_owned()),
            None,
        )
        .await
        .unwrap();
        host.subscribe_stream(
            "device-session-b".to_owned(),
            "events.session".to_owned(),
            StreamCursor(0),
            VisibilityScope::Session,
            Some("session-b".to_owned()),
            None,
        )
        .await
        .unwrap();
        let broker = Arc::new(DeviceRequestBroker::new(
            host.clone(),
            CancellationToken::new(),
        ));

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

        let page_a = poll_until_event(&host, "device-session-a", Some("session-a")).await;
        let event = page_a.events[0]
            .payload
            .get("serverEvent")
            .cloned()
            .unwrap();
        let request_id = event["data"]["requestId"].as_str().unwrap().to_string();
        assert_eq!(event["sessionId"], "session-a");
        let page_b = host
            .poll_stream(
                "device-session-b",
                Some(StreamCursor(0)),
                10,
                &StreamActorScope::scoped(Some("session-b".to_owned()), None),
            )
            .await
            .unwrap();
        assert!(page_b.events.is_empty());

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
        let broker = Arc::new(DeviceRequestBroker::new(make_host(), cancel.clone()));

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

    async fn poll_until_event(
        host: &EngineHostHandle,
        subscription_id: &str,
        session_id: Option<&str>,
    ) -> crate::engine::EngineStreamPage {
        let actor = StreamActorScope::scoped(session_id.map(ToOwned::to_owned), None);
        for _ in 0..20 {
            let page = host
                .poll_stream(subscription_id, Some(StreamCursor(0)), 10, &actor)
                .await
                .unwrap();
            if !page.events.is_empty() {
                return page;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("timed out waiting for device stream event");
    }
}
