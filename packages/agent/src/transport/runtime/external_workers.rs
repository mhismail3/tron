//! Loopback WebSocket endpoint for local engine workers.
//!
//! External workers are local participants in the live capability catalog. This
//! endpoint accepts authenticated loopback connections, speaks the engine worker
//! protocol, and delegates lifecycle policy to [`EngineExternalWorkerRuntime`]:
//! volatile registrations are removed on disconnect/heartbeat timeout, durable
//! local registrations are marked unhealthy, and worker stream publication goes
//! through `stream::publish`. Connection, registration, timeout, disconnect,
//! unregister, and health-change events are also published through the stream
//! primitive on `worker.lifecycle`. If a socket drops while target invocations
//! are pending, those waiters complete immediately with `WORKER_DISCONNECTED`
//! so the queue runtime can record retry/dead-letter truth without waiting for
//! the per-invocation timeout.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use axum::extract::ws::{Message, WebSocket};
use futures::{SinkExt, StreamExt};
use tokio::sync::{Mutex, mpsc, oneshot};

use crate::engine::{
    EngineError, EngineExternalWorkerRuntime, InvocationId, WorkerDisconnect, WorkerHello,
    WorkerInvocationResult, WorkerInvoke, WorkerProtocolMessage,
};

/// Shared server-owned external-worker runtime.
pub type SharedExternalWorkerRuntime = Arc<Mutex<EngineExternalWorkerRuntime>>;

/// Run one authenticated loopback worker WebSocket session.
pub async fn run_external_worker_socket(socket: WebSocket, runtime: SharedExternalWorkerRuntime) {
    let (mut sender, mut receiver) = socket.split();
    let (outgoing_tx, mut outgoing_rx) = mpsc::unbounded_channel::<Message>();
    let pending = Arc::new(Mutex::new(std::collections::HashMap::<
        String,
        oneshot::Sender<WorkerInvocationResult>,
    >::new()));
    let writer = tokio::spawn(async move {
        while let Some(message) = outgoing_rx.recv().await {
            if sender.send(message).await.is_err() {
                break;
            }
        }
    });
    let invoker = Arc::new(SocketWorkerInvoker {
        outgoing: outgoing_tx.clone(),
        pending: pending.clone(),
    });
    let mut worker_id = None;
    while let Some(message) = receiver.next().await {
        let message = match message {
            Ok(Message::Text(text)) => text,
            Ok(Message::Close(_)) => break,
            Ok(Message::Ping(bytes)) => {
                let _ = outgoing_tx.send(Message::Pong(bytes));
                continue;
            }
            Ok(Message::Pong(_)) | Ok(Message::Binary(_)) => continue,
            Err(error) => {
                tracing::warn!(%error, "external worker websocket receive failed");
                break;
            }
        };
        let parsed = match serde_json::from_str::<WorkerProtocolMessage>(&message) {
            Ok(parsed) => parsed,
            Err(error) => {
                let _ = outgoing_tx.send(Message::Text(
                    serde_json::json!({
                        "type": "error",
                        "message": format!("invalid worker protocol message: {error}")
                    })
                    .to_string()
                    .into(),
                ));
                continue;
            }
        };
        if let WorkerProtocolMessage::Hello(hello) = &parsed {
            let WorkerHello { worker, .. } = hello.as_ref();
            worker_id = Some(worker.id.clone());
        }
        if let WorkerProtocolMessage::Result(result) = &parsed {
            if let Some(sender) = pending.lock().await.remove(result.invocation_id.as_str()) {
                let _ = sender.send(result.clone());
            }
            continue;
        }
        let response = {
            let mut runtime = runtime.lock().await;
            let response = runtime.handle_message(parsed).await;
            if let Some(worker_id) = worker_id.clone()
                && response.is_ok()
            {
                let _ = runtime.attach_invoker(worker_id, invoker.clone());
            }
            response
        };
        match response {
            Ok(Some(response)) => {
                if let Ok(text) = serde_json::to_string(&response) {
                    let _ = outgoing_tx.send(Message::Text(text.into()));
                }
            }
            Ok(None) => {}
            Err(error) => {
                let _ = outgoing_tx.send(Message::Text(
                    serde_json::json!({
                        "type": "error",
                        "message": error.to_string()
                    })
                    .to_string()
                    .into(),
                ));
            }
        }
    }
    if let Some(worker_id) = worker_id {
        let mut runtime = runtime.lock().await;
        let _ = runtime
            .disconnect(WorkerDisconnect {
                worker_id,
                reason: "websocket disconnected".to_owned(),
            })
            .await;
    }
    fail_pending_invocations(&pending, "external worker websocket disconnected").await;
    writer.abort();
}

async fn fail_pending_invocations(
    pending: &Arc<
        Mutex<std::collections::HashMap<String, oneshot::Sender<WorkerInvocationResult>>>,
    >,
    reason: &str,
) {
    let pending = std::mem::take(&mut *pending.lock().await);
    for (invocation_id, sender) in pending {
        let invocation_id =
            InvocationId::new(invocation_id).expect("pending invocation ids are engine-generated");
        let _ = sender.send(WorkerInvocationResult {
            invocation_id,
            result: None,
            error: Some(serde_json::json!({
                "code": "WORKER_DISCONNECTED",
                "message": reason,
            })),
        });
    }
}

struct SocketWorkerInvoker {
    outgoing: mpsc::UnboundedSender<Message>,
    pending: Arc<Mutex<std::collections::HashMap<String, oneshot::Sender<WorkerInvocationResult>>>>,
}

#[async_trait]
impl crate::engine::runtime::external_workers::ExternalWorkerInvoker for SocketWorkerInvoker {
    async fn invoke(&self, invoke: WorkerInvoke) -> crate::engine::Result<WorkerInvocationResult> {
        let invocation_id = invoke.invocation_id.to_string();
        let (tx, rx) = oneshot::channel();
        self.pending.lock().await.insert(invocation_id.clone(), tx);
        let message = WorkerProtocolMessage::Invoke(invoke);
        let text = serde_json::to_string(&message).map_err(|error| {
            EngineError::HandlerFailed(format!(
                "failed to serialize external worker invocation: {error}"
            ))
        })?;
        if self.outgoing.send(Message::Text(text.into())).is_err() {
            let _ = self.pending.lock().await.remove(&invocation_id);
            return Err(EngineError::WorkerTransportFailure {
                code: "WORKER_CONNECTION_CLOSED".to_owned(),
                message: "external worker connection is closed".to_owned(),
            });
        }
        match tokio::time::timeout(Duration::from_secs(30), rx).await {
            Ok(Ok(result)) => Ok(result),
            Ok(Err(_)) => {
                let _ = self.pending.lock().await.remove(&invocation_id);
                Err(EngineError::WorkerTransportFailure {
                    code: "WORKER_INVOCATION_CANCELLED".to_owned(),
                    message: format!("external worker invocation {invocation_id} was cancelled"),
                })
            }
            Err(_) => {
                let _ = self.pending.lock().await.remove(&invocation_id);
                Err(EngineError::WorkerTransportFailure {
                    code: "WORKER_INVOCATION_TIMEOUT".to_owned(),
                    message: format!("external worker invocation {invocation_id} timed out"),
                })
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::{
        ActorKind, AuthorityGrantId, FunctionId, TraceId, WorkerInvoke,
        runtime::external_workers::ExternalWorkerInvoker,
    };
    use serde_json::json;

    fn worker_invoke(invocation_id: InvocationId) -> WorkerInvoke {
        WorkerInvoke {
            invocation_id,
            function_id: FunctionId::new("rwo_n16::queued_echo").unwrap(),
            payload: json!({"message": "pending"}),
            actor_kind: ActorKind::Agent,
            authority_grant_id: AuthorityGrantId::new("worker-runtime").unwrap(),
            authority_scopes: vec!["rwo_n16.invoke".to_owned()],
            trace_id: TraceId::new("rwo-n16-trace").unwrap(),
            parent_invocation_id: None,
            trigger_id: None,
            idempotency_key: Some("rwo-n16-target".to_owned()),
            session_id: Some("session-rwo-n16".to_owned()),
            workspace_id: None,
            timeout_ms: 30_000,
        }
    }

    #[tokio::test]
    async fn websocket_disconnect_fails_pending_worker_invocations() {
        let (outgoing, mut outgoing_rx) = mpsc::unbounded_channel();
        let pending = Arc::new(Mutex::new(std::collections::HashMap::new()));
        let invoker = SocketWorkerInvoker {
            outgoing,
            pending: Arc::clone(&pending),
        };
        let invocation_id = InvocationId::generate();
        let running = tokio::spawn({
            let invocation_id = invocation_id.clone();
            async move { invoker.invoke(worker_invoke(invocation_id)).await }
        });

        let sent = outgoing_rx.recv().await.expect("invoke should be sent");
        assert!(matches!(sent, Message::Text(_)));
        fail_pending_invocations(&pending, "test disconnect").await;

        let result = running
            .await
            .expect("invoke task should finish")
            .expect("disconnect is represented as a worker result");
        assert_eq!(result.invocation_id, invocation_id);
        assert_eq!(
            result.error.as_ref().unwrap()["code"],
            json!("WORKER_DISCONNECTED")
        );
        assert!(
            pending.lock().await.is_empty(),
            "disconnect must drain pending invocation waiters"
        );
    }
}
