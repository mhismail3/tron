//! `/engine` WebSocket protocol over the canonical engine transport envelope.
//!
//! This module owns only WebSocket framing, protocol validation, correlation
//! ids, heartbeat, and stream cursor subscription state. Worker/client
//! discover/inspect/watch/invoke/promote messages are translated into
//! [`crate::transport::engine::EngineTransportRequest`] and then dispatched
//! through the canonical engine transport path. Public context is limited to
//! session/workspace/trace correlation; authority scopes and runtime metadata
//! are not accepted on the wire. Model providers do not receive this transport
//! surface; they receive only the capability-domain `execute` orchestrator.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use axum::extract::ws::{Message, WebSocket};
use futures::{SinkExt, StreamExt};
use metrics::counter;
use serde_json::{Map, Value, json};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

#[cfg(test)]
use crate::engine::{StreamActorScope, StreamCursor};
use crate::shared::server::context::ServerRuntimeContext;
use crate::shared::server::errors::{CapabilityError, INVALID_PARAMS};
use crate::shared::server::failure::FailureOrigin;
use crate::shared::server::validation::{MAX_JSON_DEPTH, validate_json_depth};
use crate::transport::engine::{
    EngineTransportBuildRequest, EngineTransportContext, build_engine_transport_request,
    dispatch_engine_transport_request,
};

const PROTOCOL_VERSION: u64 = 1;
const MIN_PROTOCOL_VERSION: u64 = 1;
pub(crate) const MAX_ENGINE_WS_FRAME_BYTES: usize = 1024 * 1024;
const OUTBOUND_QUEUE_CAPACITY: usize = 256;
const STREAM_DEFAULT_LIMIT: usize = 100;
const STREAM_MAX_LIMIT: usize = 500;
const PUSH_POLL_INTERVAL: std::time::Duration = std::time::Duration::from_millis(250);

mod outbound;
mod stream_projection;
mod subscriptions;
mod wire;

use outbound::{send_engine_ws_value, send_engine_ws_value_async};
#[cfg(test)]
use stream_projection::{server_payload_from_stream_event, stream_event_matches_filters};
use subscriptions::{SubscriptionState, push_subscription_events};
use wire::{
    HeartbeatMessage, HelloMessage, InvokeMessage, PromoteMessage, RequestMessage, WireContext,
    now_timestamp, optional_id, protocol_error,
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

/// Run one authenticated `/engine` client WebSocket connection.
pub async fn run_engine_ws_session(
    ws: WebSocket,
    client_id: String,
    ctx: Arc<ServerRuntimeContext>,
    clients: Arc<EngineClientRegistry>,
) {
    clients.add();
    counter!("engine_ws_connections_total").increment(1);
    let (mut ws_tx, mut ws_rx) = ws.split();
    let (out_tx, mut out_rx) = mpsc::channel::<String>(OUTBOUND_QUEUE_CAPACITY);
    let writer = tokio::spawn(async move {
        while let Some(text) = out_rx.recv().await {
            if ws_tx.send(Message::Text(text.into())).await.is_err() {
                break;
            }
        }
    });

    let subscriptions = Arc::new(tokio::sync::Mutex::new(BTreeMap::new()));
    let cancel = CancellationToken::new();
    let push_task = tokio::spawn(push_subscription_events(
        ctx.clone(),
        out_tx.clone(),
        subscriptions.clone(),
        cancel.clone(),
    ));
    let mut session = EngineWsSession::new(client_id, ctx, out_tx, subscriptions, cancel.clone());
    while let Some(frame) = ws_rx.next().await {
        match frame {
            Ok(Message::Text(text)) => {
                if !session.handle_text(&text).await {
                    break;
                }
            }
            Ok(Message::Close(_)) => break,
            Ok(Message::Ping(_)) | Ok(Message::Pong(_)) | Ok(Message::Binary(_)) => {}
            Err(error) => {
                tracing::debug!(%error, "engine WebSocket receive failed");
                break;
            }
        }
    }
    cancel.cancel();
    session.cleanup().await;
    drop(session);
    let _ = push_task.await;
    let _ = writer.await;
    clients.remove();
}

struct EngineWsSession {
    client_id: String,
    ctx: Arc<ServerRuntimeContext>,
    out_tx: mpsc::Sender<String>,
    subscriptions: Arc<tokio::sync::Mutex<BTreeMap<String, SubscriptionState>>>,
    cancel: CancellationToken,
    hello: Option<HelloState>,
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
    ) -> Self {
        Self {
            client_id,
            ctx,
            out_tx,
            subscriptions,
            cancel,
            hello: None,
        }
    }

    async fn handle_text(&mut self, text: &str) -> bool {
        if text.len() > MAX_ENGINE_WS_FRAME_BYTES {
            return self.send_error(
                None,
                protocol_error(
                    INVALID_PARAMS,
                    format!(
                        "engine WebSocket frame exceeds maximum size ({} > {} bytes)",
                        text.len(),
                        MAX_ENGINE_WS_FRAME_BYTES
                    ),
                    None,
                ),
            );
        }
        let value = match serde_json::from_str::<Value>(text) {
            Ok(value) => value,
            Err(error) => {
                return self.send_error(
                    None,
                    protocol_error(INVALID_PARAMS, format!("malformed JSON: {error}"), None),
                );
            }
        };
        if let Err(error) = validate_json_depth(&value, MAX_JSON_DEPTH) {
            return self.send_error(None, error);
        }
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
            "discover" => self.handle_request_message(id, "discover", value).await,
            "inspect" => self.handle_request_message(id, "inspect", value).await,
            "watch" => self.handle_request_message(id, "watch", value).await,
            "invoke" => self.handle_invoke(id, value).await,
            "promote" => self.handle_promote(id, value).await,
            "subscribe" => self.handle_subscribe(id, value).await,
            "poll" => self.handle_poll(id, value).await,
            "ack" => self.handle_ack(id, value).await,
            "heartbeat" => self.handle_heartbeat(id, value).await,
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
        self.send_value(json!({
            "type": "hello.ok",
            "id": message.id,
            "protocolVersion": PROTOCOL_VERSION,
            "minimumSupportedVersion": MIN_PROTOCOL_VERSION,
            "serverId": "tron-engine",
        }))
    }

    async fn handle_request_message(
        &self,
        id: Option<String>,
        public_method: &'static str,
        value: Value,
    ) -> bool {
        let message = match serde_json::from_value::<RequestMessage>(value) {
            Ok(message) => message,
            Err(error) => {
                return self.send_error(
                    id,
                    protocol_error(
                        INVALID_PARAMS,
                        format!("invalid request message: {error}"),
                        None,
                    ),
                );
            }
        };
        self.dispatch_transport(message.id, public_method, message.request, message.context)
            .await
    }

    async fn handle_invoke(&self, id: Option<String>, value: Value) -> bool {
        let message = match serde_json::from_value::<InvokeMessage>(value) {
            Ok(message) => message,
            Err(error) => {
                return self.send_error(
                    id,
                    protocol_error(INVALID_PARAMS, format!("invalid invoke: {error}"), None),
                );
            }
        };
        let mut payload = Map::new();
        payload.insert("functionId".to_owned(), Value::String(message.function_id));
        payload.insert(
            "payload".to_owned(),
            message.payload.unwrap_or_else(|| json!({})),
        );
        if let Some(key) = message.idempotency_key {
            payload.insert("idempotencyKey".to_owned(), Value::String(key));
        }
        self.dispatch_transport(
            message.id,
            "invoke",
            Value::Object(payload),
            message.context,
        )
        .await
    }

    async fn handle_promote(&self, id: Option<String>, value: Value) -> bool {
        let message = match serde_json::from_value::<PromoteMessage>(value) {
            Ok(message) => message,
            Err(error) => {
                return self.send_error(
                    id,
                    protocol_error(INVALID_PARAMS, format!("invalid promote: {error}"), None),
                );
            }
        };
        let mut payload = Map::new();
        payload.insert("functionId".to_owned(), Value::String(message.function_id));
        payload.insert(
            "targetVisibility".to_owned(),
            Value::String(message.target_visibility),
        );
        payload.insert(
            "idempotencyKey".to_owned(),
            Value::String(message.idempotency_key),
        );
        if let Some(workspace_id) = message.workspace_id {
            payload.insert("workspaceId".to_owned(), Value::String(workspace_id));
        }
        self.dispatch_transport(
            message.id,
            "promote",
            Value::Object(payload),
            message.context,
        )
        .await
    }

    async fn dispatch_transport(
        &self,
        id: Option<String>,
        public_method: &'static str,
        params_payload: Value,
        context_override: Option<WireContext>,
    ) -> bool {
        let context = self.merged_context(context_override);
        let correlation_id = id
            .clone()
            .unwrap_or_else(|| uuid::Uuid::now_v7().to_string());
        let envelope = match build_engine_transport_request(EngineTransportBuildRequest {
            correlation_id,
            public_method: public_method.to_owned(),
            params_payload,
            context,
        }) {
            Ok(Some(envelope)) => envelope,
            Ok(None) => {
                return self.send_error(
                    id,
                    protocol_error(
                        INVALID_PARAMS,
                        format!("engine method {public_method} is not registered"),
                        None,
                    ),
                );
            }
            Err(error) => return self.send_error(id, error),
        };
        let trace_id = envelope.causal_context.trace_id.to_string();
        match dispatch_engine_transport_request(&self.ctx, envelope).await {
            Ok(result) => self.send_success(id, result, Some(trace_id)),
            Err(error) => self.send_error_with_trace(id, error, Some(trace_id)),
        }
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

    fn send_error(&self, id: Option<String>, error: CapabilityError) -> bool {
        self.send_error_with_trace(id, error, None)
    }

    fn send_error_with_trace(
        &self,
        id: Option<String>,
        error: CapabilityError,
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
        let subscriptions = std::mem::take(&mut *self.subscriptions.lock().await);
        for subscription_id in subscriptions.keys() {
            let _ = self
                .ctx
                .engine_host
                .unsubscribe_stream(subscription_id)
                .await;
        }
    }
}

#[cfg(test)]
mod tests;
