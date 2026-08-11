//! `/engine` WebSocket protocol over the canonical engine transport envelope.
//!
//! This module owns only WebSocket framing, protocol validation, correlation
//! ids, server-driven heartbeat, and stream cursor subscription state. One
//! stack-owned connection lease covers registry accounting, while bounded
//! connection-owned task sets own the socket writer, subscription pump, and
//! concurrently dispatched invocations. Worker/client invoke messages are translated into
//! [`crate::transport::engine::EngineTransportRequest`] and then dispatched
//! through the canonical engine transport path. Public context is limited to
//! session/workspace/trace correlation; authority scopes and trusted execution
//! inputs are not accepted on the wire. Model providers receive their own
//! direct typed tool surface rather than this authenticated client transport.
//!
//! A peer remains live while it returns Pong or any other inbound activity.
//! Missing activity after a sent Ping retires the socket; teardown cancels its
//! pumps, drops connection-local stream cursors, and bounds child-task drain.
//! Explicit unsubscribe releases one cursor idempotently, while the fixed
//! per-connection subscription ceiling bounds the 250 ms push-poll workload.
//! Invocation dispatch is also bounded per connection: a slow read or write
//! cannot prevent the socket from admitting independent resume, reconstruction,
//! or subscription requests, while correlation ids preserve response ownership.
//! Native terminal attachments share authentication and socket lifecycle but
//! use ordered PTY sequences rather than the durable generic event stream.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

use axum::extract::ws::{Message, WebSocket};
use futures::{SinkExt, StreamExt};
use metrics::counter;
use serde_json::{Value, json};
use tokio::sync::mpsc;
use tokio::task::JoinSet;
use tokio::time::MissedTickBehavior;
use tokio_util::sync::CancellationToken;

#[cfg(test)]
use crate::engine::StreamCursor;
use crate::shared::server::context::ServerRuntimeContext;
use crate::shared::server::errors::{INVALID_PARAMS, NOT_AVAILABLE, ToolError};
use crate::shared::server::failure::FailureOrigin;
use crate::shared::server::validation::{MAX_JSON_DEPTH, validate_json_depth};
use crate::transport::engine::{
    EngineTransportBuildRequest, EngineTransportContext, build_engine_transport_request,
    dispatch_engine_transport_request,
};

const PROTOCOL_VERSION: u64 = 1;
const MIN_PROTOCOL_VERSION: u64 = 1;
const OUTBOUND_QUEUE_CAPACITY: usize = 256;
const STREAM_DEFAULT_LIMIT: usize = 100;
const STREAM_MAX_LIMIT: usize = 500;
const MAX_ACTIVE_SUBSCRIPTIONS_PER_CONNECTION: usize = 64;
const MAX_IN_FLIGHT_INVOCATIONS_PER_CONNECTION: usize = 32;
const PUSH_POLL_INTERVAL: std::time::Duration = std::time::Duration::from_millis(250);
const CONTROL_QUEUE_CAPACITY: usize = 1;
const CHILD_TASK_DRAIN_TIMEOUT: Duration = Duration::from_secs(5);
mod outbound;
mod stream_projection;
mod subscriptions;
mod wire;

use outbound::{send_engine_ws_value, send_engine_ws_value_async};
#[cfg(test)]
use stream_projection::stream_event_matches_filters;
use subscriptions::{SubscriptionState, push_subscription_events};
use wire::{
    HeartbeatMessage, HelloMessage, InvokeMessage, WireContext, now_timestamp, optional_id,
    protocol_error,
};

/// Tracks connected `/engine` clients.
#[derive(Default)]
pub struct EngineClientRegistry {
    active: AtomicUsize,
}

impl EngineClientRegistry {
    /// Create an empty client registry.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Number of active engine clients.
    #[must_use]
    pub fn connection_count(&self) -> usize {
        self.active.load(Ordering::Relaxed)
    }

    fn add(&self) {
        let _ = self.active.fetch_add(1, Ordering::Relaxed);
        metrics::gauge!("engine_ws_connections_active").set(self.connection_count() as f64);
    }

    fn remove(&self) {
        let _ = self.active.fetch_sub(1, Ordering::Relaxed);
        metrics::gauge!("engine_ws_connections_active").set(self.connection_count() as f64);
    }
}

/// Exact connection-count ownership for one upgraded `/engine` socket.
///
/// The lease is intentionally stack-owned by `run_engine_ws_session`: normal
/// return, panic unwinding, and task cancellation all retire the registry entry.
struct EngineClientLease {
    clients: Arc<EngineClientRegistry>,
}

impl EngineClientLease {
    fn acquire(clients: Arc<EngineClientRegistry>) -> Self {
        clients.add();
        counter!("engine_ws_connections_total").increment(1);
        Self { clients }
    }
}

impl Drop for EngineClientLease {
    fn drop(&mut self) {
        self.clients.remove();
        counter!("engine_ws_disconnections_total").increment(1);
    }
}

/// Run one authenticated `/engine` client WebSocket connection.
pub async fn run_engine_ws_session(
    ws: WebSocket,
    client_id: String,
    ctx: Arc<ServerRuntimeContext>,
    clients: Arc<EngineClientRegistry>,
    shutdown: CancellationToken,
    max_frame_bytes: usize,
    heartbeat_interval: Duration,
    heartbeat_timeout: Duration,
) {
    let _client_lease = EngineClientLease::acquire(clients);
    let (mut ws_tx, mut ws_rx) = ws.split();
    let (out_tx, mut out_rx) = mpsc::channel::<String>(OUTBOUND_QUEUE_CAPACITY);
    let (control_tx, mut control_rx) = mpsc::channel::<Message>(CONTROL_QUEUE_CAPACITY);
    let cancel = CancellationToken::new();
    let writer_cancel = cancel.clone();
    let mut child_tasks = JoinSet::new();
    child_tasks.spawn(async move {
        loop {
            let message = tokio::select! {
                biased;
                Some(message) = control_rx.recv() => message,
                Some(text) = out_rx.recv() => Message::Text(text.into()),
                else => break,
            };
            if ws_tx.send(message).await.is_err() {
                break;
            }
        }
        writer_cancel.cancel();
    });

    let subscriptions = Arc::new(tokio::sync::Mutex::new(BTreeMap::new()));
    child_tasks.spawn(push_subscription_events(
        ctx.clone(),
        out_tx.clone(),
        subscriptions.clone(),
        cancel.clone(),
    ));
    let mut session = EngineWsSession::new(
        client_id,
        ctx,
        out_tx,
        subscriptions,
        cancel.clone(),
        max_frame_bytes,
    );

    let mut heartbeat = tokio::time::interval(heartbeat_interval);
    heartbeat.set_missed_tick_behavior(MissedTickBehavior::Delay);
    let _ = heartbeat.tick().await;
    let mut first_unanswered_ping_at: Option<Instant> = None;

    loop {
        tokio::select! {
            biased;
            () = shutdown.cancelled() => break,
            () = cancel.cancelled() => break,
            frame = ws_rx.next() => {
                let Some(frame) = frame else { break };
                match frame {
                    Ok(Message::Text(text)) => {
                        first_unanswered_ping_at = None;
                        if !session.handle_text(&text).await {
                            break;
                        }
                    }
                    Ok(Message::Close(_)) => break,
                    Ok(Message::Ping(_)) | Ok(Message::Pong(_)) | Ok(Message::Binary(_)) => {
                        first_unanswered_ping_at = None;
                    }
                    Err(error) => {
                        tracing::debug!(%error, "engine WebSocket receive failed");
                        break;
                    }
                }
            }
            _ = heartbeat.tick() => {
                if let Some(sent_at) = first_unanswered_ping_at {
                    if sent_at.elapsed() >= heartbeat_timeout {
                        tracing::debug!(
                            timeout_ms = heartbeat_timeout.as_millis(),
                            "engine WebSocket heartbeat timed out"
                        );
                        break;
                    }
                    continue;
                }
                match control_tx.try_send(Message::Ping(Vec::new().into())) {
                    Ok(()) => first_unanswered_ping_at = Some(Instant::now()),
                    Err(mpsc::error::TrySendError::Full(_)) => {
                        // An earlier Ping can still be queued when inbound
                        // activity clears its prior deadline. Give that queued
                        // probe the full timeout rather than treating one busy
                        // writer interval as a dead connection.
                        first_unanswered_ping_at = Some(Instant::now());
                    }
                    Err(mpsc::error::TrySendError::Closed(_)) => break,
                }
            }
        }
    }

    cancel.cancel();
    drop(ws_rx);
    session.cleanup().await;
    drop(session);
    drop(control_tx);
    drain_child_tasks(&mut child_tasks).await;
}

async fn drain_child_tasks(child_tasks: &mut JoinSet<()>) {
    let drained = tokio::time::timeout(CHILD_TASK_DRAIN_TIMEOUT, async {
        while child_tasks.join_next().await.is_some() {}
    })
    .await;
    if drained.is_err() {
        tracing::warn!("engine WebSocket child tasks exceeded drain timeout; aborting");
        child_tasks.abort_all();
        while child_tasks.join_next().await.is_some() {}
    }
}

struct EngineWsSession {
    client_id: String,
    ctx: Arc<ServerRuntimeContext>,
    out_tx: mpsc::Sender<String>,
    subscriptions: Arc<tokio::sync::Mutex<BTreeMap<String, SubscriptionState>>>,
    terminal_attachments: Arc<tokio::sync::Mutex<BTreeMap<String, CancellationToken>>>,
    cancel: CancellationToken,
    max_frame_bytes: usize,
    hello: Option<HelloState>,
    invoke_tasks: JoinSet<()>,
}

#[derive(Clone, Debug, Default)]
struct HelloState {
    session_id: Option<String>,
    workspace_id: Option<String>,
}

impl EngineWsSession {
    fn new(
        client_id: String,
        ctx: Arc<ServerRuntimeContext>,
        out_tx: mpsc::Sender<String>,
        subscriptions: Arc<tokio::sync::Mutex<BTreeMap<String, SubscriptionState>>>,
        cancel: CancellationToken,
        max_frame_bytes: usize,
    ) -> Self {
        Self {
            client_id,
            ctx,
            out_tx,
            subscriptions,
            terminal_attachments: Arc::new(tokio::sync::Mutex::new(BTreeMap::new())),
            cancel,
            max_frame_bytes,
            hello: None,
            invoke_tasks: JoinSet::new(),
        }
    }

    async fn handle_text(&mut self, text: &str) -> bool {
        let value = match serde_json::from_str::<Value>(text) {
            Ok(value) => value,
            Err(error) => {
                return self.send_error(
                    None,
                    protocol_error(INVALID_PARAMS, format!("malformed JSON: {error}"), None),
                );
            }
        };
        let Some(object) = value.as_object() else {
            return self.send_error(
                None,
                protocol_error(INVALID_PARAMS, "engine messages must be JSON objects", None),
            );
        };
        let id = match optional_id(object) {
            Ok(id) => id,
            Err(error) => return self.send_error(None, error),
        };
        if text.len() > self.max_frame_bytes {
            return self.send_error(
                id,
                protocol_error(
                    INVALID_PARAMS,
                    format!(
                        "engine WebSocket frame exceeds maximum size ({} > {} bytes)",
                        text.len(),
                        self.max_frame_bytes
                    ),
                    None,
                ),
            );
        }
        if let Err(error) = validate_json_depth(&value, MAX_JSON_DEPTH) {
            return self.send_error(id, error);
        }
        let message_type = match object.get("type").and_then(Value::as_str) {
            Some(value) if !value.trim().is_empty() => value,
            _ => {
                return self.send_error(
                    id,
                    protocol_error(INVALID_PARAMS, "engine message missing type", None),
                );
            }
        };

        match message_type {
            "hello" => self.handle_hello(id, value).await,
            "invoke" => self.handle_invoke(id, value).await,
            "subscribe" => self.handle_subscribe(id, value).await,
            "unsubscribe" => self.handle_unsubscribe(id, value).await,
            "poll" => self.handle_poll(id, value).await,
            "ack" => self.handle_ack(id, value).await,
            "heartbeat" => self.handle_heartbeat(id, value).await,
            "terminal.attach" => self.handle_terminal_attach(id, value).await,
            "terminal.detach" => self.handle_terminal_detach(id, value).await,
            "goodbye" => {
                let _ = self.send_value(json!({
                    "type": "goodbye.ok",
                    "id": id,
                    "serverTimestamp": now_timestamp(),
                }));
                false
            }
            other => self.send_error(
                id,
                protocol_error(
                    INVALID_PARAMS,
                    format!("unknown engine message type '{other}'"),
                    None,
                ),
            ),
        }
    }

    async fn handle_hello(&mut self, id: Option<String>, value: Value) -> bool {
        let message = match serde_json::from_value::<HelloMessage>(value) {
            Ok(message) => message,
            Err(error) => {
                return self.send_error(
                    id,
                    protocol_error(INVALID_PARAMS, format!("invalid hello: {error}"), None),
                );
            }
        };
        if !(MIN_PROTOCOL_VERSION..=PROTOCOL_VERSION).contains(&message.protocol_version) {
            return self.send_error(
                message.id,
                protocol_error(
                    "UNSUPPORTED_PROTOCOL_VERSION",
                    format!(
                        "engine protocol version {} is not supported",
                        message.protocol_version
                    ),
                    Some(json!({
                        "minimumSupportedVersion": MIN_PROTOCOL_VERSION,
                        "protocolVersion": PROTOCOL_VERSION,
                    })),
                ),
            );
        }
        self.hello = Some(HelloState {
            session_id: message.session_id,
            workspace_id: message.workspace_id,
        });
        let capabilities = [
            crate::domains::terminal::CAPABILITY,
            crate::domains::worker_kernel::AGENT_COORDINATION_CAPABILITY,
        ];
        self.send_value(json!({
            "type": "hello.ok",
            "id": message.id,
            "protocolVersion": PROTOCOL_VERSION,
            "minimumSupportedVersion": MIN_PROTOCOL_VERSION,
            "serverId": "tron-engine",
            "maxMessageSize": self.max_frame_bytes,
            "capabilities": capabilities,
        }))
    }

    async fn handle_terminal_attach(&self, id: Option<String>, value: Value) -> bool {
        let terminal_id = match value.get("terminalId").and_then(Value::as_str) {
            Some(value) if !value.is_empty() => value.to_owned(),
            _ => {
                return self.send_error(
                    id,
                    protocol_error(INVALID_PARAMS, "terminalId is required", None),
                );
            }
        };
        let after = value
            .get("afterSequence")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let attachment = match self.ctx.terminal_service.attach(&terminal_id, after) {
            Ok(value) => value,
            Err(error) => return self.send_error(id, error),
        };
        let attachment_id = match value.get("attachmentId") {
            None => format!("termatt_{}", uuid::Uuid::now_v7().simple()),
            Some(Value::String(value))
                if !value.is_empty()
                    && value.len() <= 96
                    && value
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || b"-_".contains(&byte)) =>
            {
                value.clone()
            }
            Some(_) => {
                return self.send_error(
                    id,
                    protocol_error(INVALID_PARAMS, "attachmentId is invalid", None),
                );
            }
        };
        let token = self.cancel.child_token();
        {
            let mut attachments = self.terminal_attachments.lock().await;
            if attachments.len() >= 8 {
                return self.send_error(
                    id,
                    protocol_error(NOT_AVAILABLE, "terminal attachment limit reached", None),
                );
            }
            if attachments.contains_key(&attachment_id) {
                return self.send_error(
                    id,
                    protocol_error(INVALID_PARAMS, "attachmentId is already active", None),
                );
            }
            attachments.insert(attachment_id.clone(), token.clone());
        }
        if !self.send_value(json!({"type":"terminal.attach.ok","id":id,"attachmentId":attachment_id,"terminalId":terminal_id,"generation":attachment.generation,"earliestSequence":attachment.earliest_sequence,"latestSequence":attachment.latest_sequence,"resetRequired":after>0 && after<attachment.earliest_sequence})) { return false; }
        let out_tx = self.out_tx.clone();
        let connection_cancel = self.cancel.clone();
        let attachment_id_for_task = attachment_id.clone();
        let attachments = Arc::clone(&self.terminal_attachments);
        tokio::spawn(async move {
            async {
                let mut last = after;
                for chunk in attachment.backlog {
                    if chunk.sequence <= last {
                        continue;
                    }
                    if !send_engine_ws_value_async(&out_tx, &connection_cancel, json!({"type":"terminal.output","attachmentId":attachment_id_for_task,"terminalId":chunk.terminal_id,"generation":chunk.generation,"sequence":chunk.sequence,"dataBase64":chunk.data_base64})).await { return; }
                    last = chunk.sequence;
                }
                let Some(mut receiver) = attachment.receiver else {
                    let _ = send_engine_ws_value_async(&out_tx, &connection_cancel, json!({"type":"terminal.status","attachmentId":attachment_id_for_task,"terminalId":terminal_id,"generation":attachment.generation,"state":attachment.state,"exitCode":attachment.exit_code,"lastSequence":last})).await;
                    return;
                };
                loop {
                    tokio::select! {
                        () = token.cancelled() => return,
                        received = receiver.recv() => match received {
                            Ok(crate::domains::terminal::TerminalStreamEvent::Output(chunk)) if chunk.sequence > last => {
                                if !send_engine_ws_value_async(&out_tx, &connection_cancel, json!({"type":"terminal.output","attachmentId":attachment_id_for_task,"terminalId":chunk.terminal_id,"generation":chunk.generation,"sequence":chunk.sequence,"dataBase64":chunk.data_base64})).await { return; }
                                last = chunk.sequence;
                            }
                            Ok(crate::domains::terminal::TerminalStreamEvent::Output(_)) => {}
                            Ok(crate::domains::terminal::TerminalStreamEvent::Status{terminal_id,generation,state,exit_code}) => {
                                let _ = send_engine_ws_value_async(&out_tx, &connection_cancel, json!({"type":"terminal.status","attachmentId":attachment_id_for_task,"terminalId":terminal_id,"generation":generation,"state":state,"exitCode":exit_code,"lastSequence":last})).await;
                                return;
                            }
                            Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {
                                let _ = send_engine_ws_value_async(&out_tx, &connection_cancel, json!({"type":"terminal.status","attachmentId":attachment_id_for_task,"state":"catch_up_required","lastSequence":last})).await;
                                return;
                            }
                            Err(_) => return,
                        }
                    }
                }
            }
            .await;
            attachments.lock().await.remove(&attachment_id_for_task);
        });
        true
    }

    async fn handle_terminal_detach(&self, id: Option<String>, value: Value) -> bool {
        let Some(attachment_id) = value.get("attachmentId").and_then(Value::as_str) else {
            return self.send_error(
                id,
                protocol_error(INVALID_PARAMS, "attachmentId is required", None),
            );
        };
        if let Some(token) = self.terminal_attachments.lock().await.remove(attachment_id) {
            token.cancel();
        }
        self.send_value(json!({"type":"terminal.detach.ok","id":id,"attachmentId":attachment_id}))
    }

    async fn handle_invoke(&mut self, id: Option<String>, value: Value) -> bool {
        let message = match serde_json::from_value::<InvokeMessage>(value) {
            Ok(message) => message,
            Err(error) => {
                return self.send_error(
                    id,
                    protocol_error(INVALID_PARAMS, format!("invalid invoke: {error}"), None),
                );
            }
        };
        let payload = json!({
            "functionId": message.function_id,
            "payload": message.payload.unwrap_or_else(|| json!({})),
            "idempotencyKey": message.idempotency_key,
        });
        let context = self.merged_context(message.context);
        let correlation_id = message
            .id
            .clone()
            .unwrap_or_else(|| uuid::Uuid::now_v7().to_string());
        let envelope = match build_engine_transport_request(EngineTransportBuildRequest {
            correlation_id,
            params_payload: payload,
            context,
        }) {
            Ok(envelope) => envelope,
            Err(error) => return self.send_error(message.id, error),
        };

        while let Some(result) = self.invoke_tasks.try_join_next() {
            if let Err(error) = result {
                tracing::warn!(%error, "engine WebSocket invocation task failed");
            }
        }
        if self.invoke_tasks.len() >= MAX_IN_FLIGHT_INVOCATIONS_PER_CONNECTION {
            return self.send_error(
                message.id,
                ToolError::NotAvailable {
                    message: "engine WebSocket invocation limit reached; retry shortly".to_owned(),
                },
            );
        }

        let response_id = message.id;
        let trace_id = envelope.causal_context.trace_id.to_string();
        let ctx = Arc::clone(&self.ctx);
        let out_tx = self.out_tx.clone();
        let cancel = self.cancel.clone();
        self.invoke_tasks.spawn(async move {
            let result = tokio::select! {
                biased;
                () = cancel.cancelled() => return,
                result = dispatch_engine_transport_request(&ctx, envelope) => result,
            };
            let response = match result {
                Ok(result) => json!({
                    "type": "response",
                    "id": response_id,
                    "ok": true,
                    "result": result,
                    "traceId": trace_id,
                }),
                Err(error) => {
                    let failure = error
                        .to_failure(FailureOrigin::Transport)
                        .with_trace_id(Some(trace_id.clone()));
                    json!({
                        "type": "response",
                        "id": response_id,
                        "ok": false,
                        "error": failure.to_value(),
                        "traceId": trace_id,
                    })
                }
            };
            if !send_engine_ws_value_async(&out_tx, &cancel, response).await {
                cancel.cancel();
            }
        });
        true
    }

    async fn handle_heartbeat(&self, id: Option<String>, value: Value) -> bool {
        let message = match serde_json::from_value::<HeartbeatMessage>(value) {
            Ok(message) => message,
            Err(error) => {
                return self.send_error(
                    id,
                    protocol_error(INVALID_PARAMS, format!("invalid heartbeat: {error}"), None),
                );
            }
        };
        self.send_value(json!({
            "type": "heartbeat.ack",
            "id": message.id,
            "timestamp": message.timestamp,
            "serverTimestamp": now_timestamp(),
        }))
    }

    fn merged_context(&self, override_context: Option<WireContext>) -> EngineTransportContext {
        let hello = self.hello.clone().unwrap_or_default();
        let override_context = override_context.unwrap_or_default();
        EngineTransportContext {
            session_id: override_context.session_id.or(hello.session_id),
            workspace_id: override_context.workspace_id.or(hello.workspace_id),
            trace_id: override_context.trace_id,
            parent_invocation_id: override_context.parent_invocation_id,
        }
    }

    fn send_success(&self, id: Option<String>, result: Value, trace_id: Option<String>) -> bool {
        self.send_value(json!({
            "type": "response",
            "id": id,
            "ok": true,
            "result": result,
            "traceId": trace_id,
        }))
    }

    async fn send_success_async(
        &self,
        id: Option<String>,
        result: Value,
        trace_id: Option<String>,
    ) -> bool {
        send_engine_ws_value_async(
            &self.out_tx,
            &self.cancel,
            json!({
                "type": "response",
                "id": id,
                "ok": true,
                "result": result,
                "traceId": trace_id,
            }),
        )
        .await
    }

    fn send_error(&self, id: Option<String>, error: ToolError) -> bool {
        self.send_error_with_trace(id, error, None)
    }

    fn send_error_with_trace(
        &self,
        id: Option<String>,
        error: ToolError,
        trace_id: Option<String>,
    ) -> bool {
        let failure = error
            .to_failure(FailureOrigin::Transport)
            .with_trace_id(trace_id.clone());
        self.send_value(json!({
            "type": "response",
            "id": id,
            "ok": false,
            "error": failure.to_value(),
            "traceId": trace_id,
        }))
    }

    fn send_value(&self, value: Value) -> bool {
        send_engine_ws_value(&self.out_tx, value)
    }

    async fn cleanup(&mut self) {
        self.cancel.cancel();
        self.subscriptions.lock().await.clear();
        drain_child_tasks(&mut self.invoke_tasks).await;
    }
}

#[cfg(test)]
mod tests;
