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
//! the per-invocation timeout. Worker result frames are consumed only by the
//! pending invocation map owned by that socket connection; they are not routed
//! through the runtime message handler as standalone commands. Inbound worker
//! frames are size-capped before JSON parsing. The first validated Hello binds
//! an opaque runtime generation lease; pre-Hello operations, second Hellos,
//! foreign worker ids, active duplicates, and stale cleanup fail closed without
//! changing another connection. Runtime retirement shares one cancellation
//! signal across the socket reader, writer, pending calls, and captured invoker
//! clones; it closes admission before catalog cleanup and cannot leave work
//! waiting for the invocation timeout. Outbound writes use a bounded channel
//! plus send timeout. Every upgraded socket is registered with graceful
//! shutdown before the HTTP upgrade completes. Shutdown interrupts reads and
//! bounded sends, closes outbound admission, drains pending calls, retires only
//! the owned runtime generation, and joins the socket writer before the session
//! exits.

use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use axum::extract::ws::{Message, WebSocket};
use futures::{SinkExt, StreamExt};
use tokio::sync::{Mutex, mpsc, oneshot};
use tokio_util::sync::CancellationToken;

use crate::engine::{
    EngineError, EngineExternalWorkerRuntime, ExternalWorkerInvoker, InvocationId,
    WorkerInvocationResult, WorkerInvoke, WorkerProtocolMessage,
};

const EXTERNAL_WORKER_OUTBOUND_CAPACITY: usize = 128;
const EXTERNAL_WORKER_OUTBOUND_SEND_TIMEOUT: Duration = Duration::from_secs(5);
pub(crate) const MAX_EXTERNAL_WORKER_FRAME_BYTES: usize = 1024 * 1024;

/// Shared server-owned external-worker runtime.
pub type SharedExternalWorkerRuntime = Arc<Mutex<EngineExternalWorkerRuntime>>;

/// Run one authenticated loopback worker WebSocket session.
pub(crate) async fn run_external_worker_socket(
    socket: WebSocket,
    runtime: SharedExternalWorkerRuntime,
    shutdown: CancellationToken,
) {
    let (mut sender, mut receiver) = socket.split();
    let (outgoing_tx, mut outgoing_rx) =
        mpsc::channel::<Message>(EXTERNAL_WORKER_OUTBOUND_CAPACITY);
    let pending = Arc::new(Mutex::new(std::collections::HashMap::<
        String,
        oneshot::Sender<WorkerInvocationResult>,
    >::new()));
    let connection_retired = CancellationToken::new();
    let writer_closed = CancellationToken::new();
    let writer_closed_signal = writer_closed.clone();
    let writer_retired = connection_retired.clone();
    let writer = tokio::spawn(async move {
        loop {
            let message = tokio::select! {
                biased;
                () = writer_retired.cancelled() => break,
                message = outgoing_rx.recv() => {
                    let Some(message) = message else {
                        break;
                    };
                    message
                }
            };
            let sent = tokio::select! {
                biased;
                () = writer_retired.cancelled() => break,
                result = sender.send(message) => result,
            };
            if sent.is_err() {
                break;
            }
        }
        writer_closed_signal.cancel();
    });
    let invoker = Arc::new(SocketWorkerInvoker {
        outgoing: outgoing_tx.clone(),
        pending: pending.clone(),
        retired: connection_retired.clone(),
    });
    let mut connection = None;
    loop {
        let message = tokio::select! {
            biased;
            () = shutdown.cancelled() => break,
            () = connection_retired.cancelled() => break,
            () = writer_closed.cancelled() => break,
            message = receiver.next() => {
                let Some(message) = message else {
                    break;
                };
                message
            }
        };
        let message = match message {
            Ok(Message::Text(text)) => text,
            Ok(Message::Close(_)) => break,
            Ok(Message::Ping(bytes)) => {
                if !send_outbound(
                    &outgoing_tx,
                    Message::Pong(bytes),
                    &shutdown,
                    &connection_retired,
                    &writer_closed,
                )
                .await
                {
                    break;
                }
                continue;
            }
            Ok(Message::Pong(_)) | Ok(Message::Binary(_)) => continue,
            Err(error) => {
                tracing::warn!(%error, "external worker websocket receive failed");
                break;
            }
        };
        if message.len() > MAX_EXTERNAL_WORKER_FRAME_BYTES {
            let _ = send_protocol_error(
                &outgoing_tx,
                format!(
                    "worker protocol frame exceeds maximum size ({} > {} bytes)",
                    message.len(),
                    MAX_EXTERNAL_WORKER_FRAME_BYTES
                ),
                &shutdown,
                &connection_retired,
                &writer_closed,
            )
            .await;
            break;
        }
        let parsed = match serde_json::from_str::<WorkerProtocolMessage>(&message) {
            Ok(parsed) => parsed,
            Err(error) => {
                if !send_protocol_error(
                    &outgoing_tx,
                    format!("invalid worker protocol message: {error}"),
                    &shutdown,
                    &connection_retired,
                    &writer_closed,
                )
                .await
                {
                    break;
                }
                continue;
            }
        };
        if connection.is_none() {
            let WorkerProtocolMessage::Hello(hello) = parsed else {
                if !send_protocol_error(
                    &outgoing_tx,
                    "external worker hello is required before operational messages",
                    &shutdown,
                    &connection_retired,
                    &writer_closed,
                )
                .await
                {
                    break;
                }
                continue;
            };
            let accepted = runtime
                .lock()
                .await
                .accept_connection(*hello, invoker.clone())
                .await;
            match accepted {
                Ok((lease, snapshot)) => {
                    connection = Some(lease);
                    let response = WorkerProtocolMessage::CatalogSnapshot(snapshot);
                    if let Ok(text) = serde_json::to_string(&response)
                        && !send_outbound(
                            &outgoing_tx,
                            Message::Text(text.into()),
                            &shutdown,
                            &connection_retired,
                            &writer_closed,
                        )
                        .await
                    {
                        break;
                    }
                }
                Err(error) => {
                    if !send_protocol_error(
                        &outgoing_tx,
                        error.to_string(),
                        &shutdown,
                        &connection_retired,
                        &writer_closed,
                    )
                    .await
                    {
                        break;
                    }
                }
            }
            continue;
        }
        let lease = connection.as_ref().expect("bound connection checked above");
        if let WorkerProtocolMessage::Result(result) = &parsed {
            let runtime = runtime.lock().await;
            if !runtime.is_current_connection(lease) {
                drop(runtime);
                let _ = send_protocol_error(
                    &outgoing_tx,
                    format!(
                        "external worker connection lease is no longer current for {}",
                        lease.worker_id()
                    ),
                    &shutdown,
                    &connection_retired,
                    &writer_closed,
                )
                .await;
                break;
            }
            if let Some(sender) = pending.lock().await.remove(result.invocation_id.as_str()) {
                let _ = sender.send(result.clone());
            }
            drop(runtime);
            continue;
        }
        let (response, connection_current) = {
            let mut runtime = runtime.lock().await;
            let response = runtime.handle_connection_message(lease, parsed).await;
            let current = runtime.is_current_connection(lease);
            (response, current)
        };
        match response {
            Ok(Some(response)) => {
                if let Ok(text) = serde_json::to_string(&response) {
                    if !send_outbound(
                        &outgoing_tx,
                        Message::Text(text.into()),
                        &shutdown,
                        &connection_retired,
                        &writer_closed,
                    )
                    .await
                    {
                        break;
                    }
                }
            }
            Ok(None) => {}
            Err(error) => {
                if !send_protocol_error(
                    &outgoing_tx,
                    error.to_string(),
                    &shutdown,
                    &connection_retired,
                    &writer_closed,
                )
                .await
                {
                    break;
                }
            }
        }
        if !connection_current {
            break;
        }
    }
    connection_retired.cancel();
    writer.abort();
    let _ = writer.await;
    fail_pending_invocations(&pending, "external worker websocket disconnected").await;
    if let Some(connection) = connection {
        let mut runtime = runtime.lock().await;
        if let Err(error) = runtime
            .disconnect_connection(&connection, "websocket disconnected")
            .await
        {
            tracing::warn!(%error, "external worker websocket cleanup failed");
        }
    }
}

async fn send_protocol_error(
    outgoing: &mpsc::Sender<Message>,
    error: impl Into<String>,
    shutdown: &CancellationToken,
    connection_retired: &CancellationToken,
    writer_closed: &CancellationToken,
) -> bool {
    send_outbound(
        outgoing,
        Message::Text(
            serde_json::json!({
                "type": "error",
                "message": error.into(),
            })
            .to_string()
            .into(),
        ),
        shutdown,
        connection_retired,
        writer_closed,
    )
    .await
}

async fn send_outbound(
    outgoing: &mpsc::Sender<Message>,
    message: Message,
    shutdown: &CancellationToken,
    connection_retired: &CancellationToken,
    writer_closed: &CancellationToken,
) -> bool {
    tokio::select! {
        biased;
        () = shutdown.cancelled() => false,
        () = connection_retired.cancelled() => false,
        () = writer_closed.cancelled() => false,
        result = tokio::time::timeout(
            EXTERNAL_WORKER_OUTBOUND_SEND_TIMEOUT,
            outgoing.send(message),
        ) => matches!(result, Ok(Ok(()))),
    }
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
    outgoing: mpsc::Sender<Message>,
    pending: Arc<Mutex<std::collections::HashMap<String, oneshot::Sender<WorkerInvocationResult>>>>,
    retired: CancellationToken,
}

#[async_trait]
impl ExternalWorkerInvoker for SocketWorkerInvoker {
    async fn invoke(&self, invoke: WorkerInvoke) -> crate::engine::Result<WorkerInvocationResult> {
        if self.retired.is_cancelled() {
            return Err(worker_retired_error());
        }
        let invocation_id = invoke.invocation_id.to_string();
        let message = WorkerProtocolMessage::Invoke(invoke);
        let text = serde_json::to_string(&message).map_err(|error| {
            EngineError::HandlerFailed(format!(
                "failed to serialize external worker invocation: {error}"
            ))
        })?;
        let (tx, rx) = oneshot::channel();
        let mut pending = tokio::select! {
            biased;
            () = self.retired.cancelled() => return Err(worker_retired_error()),
            pending = self.pending.lock() => pending,
        };
        if self.retired.is_cancelled() {
            return Err(worker_retired_error());
        }
        pending.insert(invocation_id.clone(), tx);
        drop(pending);
        let send = tokio::select! {
            biased;
            () = self.retired.cancelled() => {
                let _ = self.pending.lock().await.remove(&invocation_id);
                return Err(worker_retired_error());
            }
            result = tokio::time::timeout(
                EXTERNAL_WORKER_OUTBOUND_SEND_TIMEOUT,
                self.outgoing.send(Message::Text(text.into())),
            ) => result,
        };
        match send {
            Ok(Ok(())) => {}
            Ok(Err(_)) => {
                let _ = self.pending.lock().await.remove(&invocation_id);
                if self.retired.is_cancelled() {
                    return Err(worker_retired_error());
                }
                return Err(EngineError::WorkerTransportFailure {
                    code: "WORKER_CONNECTION_CLOSED".to_owned(),
                    message: "external worker connection is closed".to_owned(),
                });
            }
            Err(_) => {
                let _ = self.pending.lock().await.remove(&invocation_id);
                return Err(EngineError::WorkerTransportFailure {
                    code: "WORKER_OUTBOUND_BACKPRESSURE_TIMEOUT".to_owned(),
                    message: "external worker outbound queue stayed full".to_owned(),
                });
            }
        }
        let result = tokio::select! {
            biased;
            result = tokio::time::timeout(Duration::from_secs(30), rx) => result,
            () = self.retired.cancelled() => {
                let _ = self.pending.lock().await.remove(&invocation_id);
                return Err(worker_retired_error());
            }
        };
        match result {
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

    fn retire(&self) {
        self.retired.cancel();
    }
}

fn worker_retired_error() -> EngineError {
    EngineError::WorkerTransportFailure {
        code: "WORKER_DISCONNECTED".to_owned(),
        message: "external worker connection was retired".to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::{
        ActorKind, AuthorityGrantId, ExternalWorkerInvoker, FunctionId, TraceId, WorkerInvoke,
    };
    use serde_json::json;

    fn worker_invoke(invocation_id: InvocationId) -> WorkerInvoke {
        WorkerInvoke {
            invocation_id,
            function_id: FunctionId::new("rwo_n16::queued_echo").unwrap(),
            payload: json!({"message": "pending"}),
            actor_kind: ActorKind::Agent,
            authority_grant_id: Some(AuthorityGrantId::new("worker-runtime").unwrap()),
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
    async fn worker_retirement_fails_pending_and_closes_captured_invoker_admission() {
        let (outgoing, mut outgoing_rx) = mpsc::channel(EXTERNAL_WORKER_OUTBOUND_CAPACITY);
        let pending = Arc::new(Mutex::new(std::collections::HashMap::new()));
        let retired = CancellationToken::new();
        let invoker = Arc::new(SocketWorkerInvoker {
            outgoing,
            pending: Arc::clone(&pending),
            retired,
        });
        let captured_invoker = Arc::clone(&invoker);
        let invocation_id = InvocationId::generate();
        let running = tokio::spawn({
            let invoker = Arc::clone(&invoker);
            let invocation_id = invocation_id.clone();
            async move { invoker.invoke(worker_invoke(invocation_id)).await }
        });

        let sent = outgoing_rx.recv().await.expect("invoke should be sent");
        assert!(matches!(sent, Message::Text(_)));
        invoker.retire();

        let error = tokio::time::timeout(Duration::from_secs(1), running)
            .await
            .expect("retirement must wake a pending invocation")
            .expect("invoke task should finish")
            .expect_err("retired invocation must fail");
        assert!(matches!(
            error,
            EngineError::WorkerTransportFailure { ref code, .. }
                if code == "WORKER_DISCONNECTED"
        ));

        let error = captured_invoker
            .invoke(worker_invoke(InvocationId::generate()))
            .await
            .expect_err("a captured invoker must reject work after retirement");
        assert!(matches!(
            error,
            EngineError::WorkerTransportFailure { ref code, .. }
                if code == "WORKER_DISCONNECTED"
        ));
        assert!(
            matches!(
                outgoing_rx.try_recv(),
                Err(mpsc::error::TryRecvError::Empty)
            ),
            "retired invokers must not enqueue outbound work"
        );
        assert!(
            pending.lock().await.is_empty(),
            "retirement must drain pending invocation waiters"
        );
    }

    #[tokio::test]
    async fn accepted_worker_result_wins_over_later_retirement() {
        let (outgoing, mut outgoing_rx) = mpsc::channel(EXTERNAL_WORKER_OUTBOUND_CAPACITY);
        let pending = Arc::new(Mutex::new(std::collections::HashMap::new()));
        let invoker = Arc::new(SocketWorkerInvoker {
            outgoing,
            pending: Arc::clone(&pending),
            retired: CancellationToken::new(),
        });
        let invocation_id = InvocationId::generate();
        let running = tokio::spawn({
            let invoker = Arc::clone(&invoker);
            let invocation_id = invocation_id.clone();
            async move { invoker.invoke(worker_invoke(invocation_id)).await }
        });
        assert!(matches!(outgoing_rx.recv().await, Some(Message::Text(_))));

        let sender = pending
            .lock()
            .await
            .remove(invocation_id.as_str())
            .expect("accepted invocation owns a pending result sender");
        sender
            .send(WorkerInvocationResult {
                invocation_id: invocation_id.clone(),
                result: Some(json!({"accepted": true})),
                error: None,
            })
            .expect("accepted result receiver remains live");
        invoker.retire();

        let result = tokio::time::timeout(Duration::from_secs(1), running)
            .await
            .expect("accepted result must complete promptly")
            .expect("invoke task should finish")
            .expect("accepted result must beat later retirement");
        assert_eq!(result.invocation_id, invocation_id);
        assert_eq!(result.result, Some(json!({"accepted": true})));
    }

    #[tokio::test(start_paused = true)]
    async fn worker_invocation_fails_when_outbound_queue_stays_full() {
        let (outgoing, _outgoing_rx) = mpsc::channel(1);
        outgoing
            .send(Message::Text("already queued".into()))
            .await
            .expect("test queue should accept the first message");
        let pending = Arc::new(Mutex::new(std::collections::HashMap::new()));
        let invoker = SocketWorkerInvoker {
            outgoing,
            pending: Arc::clone(&pending),
            retired: CancellationToken::new(),
        };
        let invocation_id = InvocationId::generate();

        let running =
            tokio::spawn(async move { invoker.invoke(worker_invoke(invocation_id)).await });
        tokio::task::yield_now().await;
        tokio::time::advance(EXTERNAL_WORKER_OUTBOUND_SEND_TIMEOUT).await;

        let error = running
            .await
            .expect("invoke task should finish")
            .expect_err("full outbound queue should fail invocation send");
        assert!(matches!(
            error,
            EngineError::WorkerTransportFailure { ref code, .. }
                if code == "WORKER_OUTBOUND_BACKPRESSURE_TIMEOUT"
        ));
        assert!(
            pending.lock().await.is_empty(),
            "backpressure failure must remove the pending waiter"
        );
    }
}
