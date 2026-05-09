//! Loopback WebSocket endpoint for local engine workers.
//!
//! External workers are local participants in the live capability catalog. This
//! endpoint accepts authenticated loopback connections, speaks the engine worker
//! protocol, and delegates lifecycle policy to [`EngineExternalWorkerRuntime`]:
//! volatile registrations are removed on disconnect/heartbeat timeout, durable
//! local registrations are marked unhealthy, and worker stream publication goes
//! through `stream::publish`. Connection, registration, timeout, disconnect,
//! unregister, and health-change events are also published through the stream
//! primitive on `worker.lifecycle`.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use axum::extract::ws::{Message, WebSocket};
use futures::{SinkExt, StreamExt};
use tokio::sync::{Mutex, mpsc, oneshot};

use crate::engine::{
    EngineError, EngineExternalWorkerRuntime, WorkerDisconnect, WorkerHello,
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
        if let WorkerProtocolMessage::Hello(WorkerHello { worker, .. }) = &parsed {
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
    writer.abort();
}

struct SocketWorkerInvoker {
    outgoing: mpsc::UnboundedSender<Message>,
    pending: Arc<Mutex<std::collections::HashMap<String, oneshot::Sender<WorkerInvocationResult>>>>,
}

#[async_trait]
impl crate::engine::external::ExternalWorkerInvoker for SocketWorkerInvoker {
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
            return Err(EngineError::HandlerFailed(
                "external worker connection is closed".to_owned(),
            ));
        }
        tokio::time::timeout(Duration::from_secs(30), rx)
            .await
            .map_err(|_| {
                EngineError::HandlerFailed(format!(
                    "external worker invocation {invocation_id} timed out"
                ))
            })?
            .map_err(|_| {
                EngineError::HandlerFailed(format!(
                    "external worker invocation {invocation_id} was cancelled"
                ))
            })
    }
}
