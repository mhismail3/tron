//! `/engine` WebSocket protocol over the canonical engine transport envelope.
//!
//! This module owns only WebSocket framing, protocol validation, correlation
//! ids, heartbeat, and stream cursor subscription state. Worker/client
//! discover/inspect/watch/invoke/promote messages are translated into
//! [`EngineTransportRequest`] and then dispatched through the canonical engine
//! transport path. Model providers do not receive this transport surface; they
//! receive only the capability-domain `execute` orchestrator.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use axum::extract::ws::{Message, WebSocket};
use futures::{SinkExt, StreamExt};
use metrics::counter;
use serde_json::{Map, Value, json};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::engine::{StreamActorScope, StreamCursor};
use crate::shared::server::context::ServerRuntimeContext;
use crate::shared::server::error_mapping::engine_error_to_capability_error;
use crate::shared::server::errors::{CapabilityError, INVALID_PARAMS};
use crate::shared::server::validation::{
    MAX_JSON_DEPTH, sanitize_error_message, validate_json_depth,
};
use crate::transport::engine::{
    EngineTransportBuildRequest, EngineTransportContext, build_engine_transport_request,
    dispatch_engine_transport_request,
};

const PROTOCOL_VERSION: u64 = 1;
const MIN_PROTOCOL_VERSION: u64 = 1;
const OUTBOUND_QUEUE_CAPACITY: usize = 256;
const STREAM_DEFAULT_LIMIT: usize = 100;
const STREAM_MAX_LIMIT: usize = 500;
const PUSH_POLL_INTERVAL: std::time::Duration = std::time::Duration::from_millis(250);

mod outbound;
mod stream_projection;
mod wire;

use outbound::{send_engine_ws_value, send_engine_ws_value_async};
#[cfg(test)]
use stream_projection::server_payload_from_stream_event;
use stream_projection::{
    protocol_event_value, stream_event_matches_filters, visibility_for_context,
};
use wire::{
    AckMessage, HeartbeatMessage, HelloMessage, InvokeMessage, PollMessage, PromoteMessage,
    RequestMessage, SubscribeMessage, WireContext, checked_limit, now_timestamp, optional_id,
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

#[derive(Clone, Debug)]
struct SubscriptionState {
    topic: String,
    cursor: StreamCursor,
    filters: Option<Value>,
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

    async fn handle_subscribe(&mut self, id: Option<String>, value: Value) -> bool {
        let message = match serde_json::from_value::<SubscribeMessage>(value) {
            Ok(message) => message,
            Err(error) => {
                return self.send_error(
                    id,
                    protocol_error(INVALID_PARAMS, format!("invalid subscribe: {error}"), None),
                );
            }
        };
        if message.topic.trim().is_empty() {
            return self.send_error(
                message.id,
                protocol_error(INVALID_PARAMS, "stream topic must not be empty", None),
            );
        }
        let limit = match checked_limit(message.limit) {
            Ok(limit) => limit,
            Err(error) => return self.send_error(message.id, error),
        };
        let cursor = match message.cursor {
            Some(cursor) => StreamCursor(cursor),
            None => match self
                .ctx
                .engine_host
                .latest_stream_cursor(&message.topic)
                .await
            {
                Ok(cursor) => cursor,
                Err(error) => {
                    return self.send_error(message.id, engine_error_to_capability_error(error));
                }
            },
        };
        let context = self.merged_context(message.context);
        let subscription_id = format!("engine-ws:{}:{}", self.client_id, uuid::Uuid::now_v7());
        let visibility = visibility_for_context(&context);
        match self
            .ctx
            .engine_host
            .subscribe_stream(
                subscription_id.clone(),
                message.topic.clone(),
                cursor,
                visibility,
                context.session_id.clone(),
                context.workspace_id.clone(),
            )
            .await
        {
            Ok(subscription) => {
                self.subscriptions.lock().await.insert(
                    subscription_id.clone(),
                    SubscriptionState {
                        topic: message.topic.clone(),
                        cursor,
                        filters: message.filters,
                        session_id: context.session_id,
                        workspace_id: context.workspace_id,
                    },
                );
                self.send_success(
                    message.id,
                    json!({
                        "subscriptionId": subscription.subscription_id,
                        "topic": subscription.topic,
                        "cursor": subscription.cursor.0,
                        "limit": limit,
                    }),
                    None,
                )
            }
            Err(error) => self.send_error(message.id, engine_error_to_capability_error(error)),
        }
    }

    async fn handle_poll(&mut self, id: Option<String>, value: Value) -> bool {
        let message = match serde_json::from_value::<PollMessage>(value) {
            Ok(message) => message,
            Err(error) => {
                return self.send_error(
                    id,
                    protocol_error(INVALID_PARAMS, format!("invalid poll: {error}"), None),
                );
            }
        };
        let limit = match checked_limit(message.limit) {
            Ok(limit) => limit,
            Err(error) => return self.send_error(message.id, error),
        };
        if let Some(subscription_id) = message.subscription_id {
            let Some(subscription) = self
                .subscriptions
                .lock()
                .await
                .get(&subscription_id)
                .cloned()
            else {
                return self.send_error(
                    message.id,
                    protocol_error(
                        "STREAM_SUBSCRIPTION_NOT_FOUND",
                        format!("stream subscription {subscription_id} was not found"),
                        None,
                    ),
                );
            };
            let after = Some(StreamCursor(
                message.cursor.unwrap_or(subscription.cursor.0),
            ));
            let actor = StreamActorScope::scoped(
                subscription.session_id.clone(),
                subscription.workspace_id.clone(),
            );
            return self
                .send_stream_page(
                    message.id,
                    &subscription_id,
                    after,
                    limit,
                    &actor,
                    subscription.filters.as_ref(),
                )
                .await;
        }
        let Some(topic) = message.topic else {
            return self.send_error(
                message.id,
                protocol_error(
                    INVALID_PARAMS,
                    "poll requires either subscriptionId or topic",
                    None,
                ),
            );
        };
        if topic.trim().is_empty() {
            return self.send_error(
                message.id,
                protocol_error(INVALID_PARAMS, "stream topic must not be empty", None),
            );
        }
        let context = self.merged_context(message.context);
        let subscription_id = format!(
            "engine-ws-stateless:{}:{}",
            self.client_id,
            uuid::Uuid::now_v7()
        );
        let Some(cursor) = message.cursor.map(StreamCursor) else {
            return self.send_error(
                message.id,
                protocol_error(
                    INVALID_PARAMS,
                    "topic poll requires an explicit cursor; omit cursor only for live subscribe",
                    None,
                ),
            );
        };
        let visibility = visibility_for_context(&context);
        let subscribe_result = self
            .ctx
            .engine_host
            .subscribe_stream(
                subscription_id.clone(),
                topic,
                cursor,
                visibility,
                context.session_id.clone(),
                context.workspace_id.clone(),
            )
            .await;
        if let Err(error) = subscribe_result {
            return self.send_error(message.id, engine_error_to_capability_error(error));
        }
        let actor = StreamActorScope::scoped(context.session_id, context.workspace_id);
        let sent = self
            .send_stream_page(
                message.id,
                &subscription_id,
                Some(cursor),
                limit,
                &actor,
                message.filters.as_ref(),
            )
            .await;
        let _ = self
            .ctx
            .engine_host
            .unsubscribe_stream(&subscription_id)
            .await;
        sent
    }

    async fn send_stream_page(
        &self,
        id: Option<String>,
        subscription_id: &str,
        after: Option<StreamCursor>,
        limit: usize,
        actor: &StreamActorScope,
        filters: Option<&Value>,
    ) -> bool {
        match self
            .ctx
            .engine_host
            .poll_stream(subscription_id, after, limit, actor)
            .await
        {
            Ok(page) => {
                let events = page
                    .events
                    .iter()
                    .filter(|event| stream_event_matches_filters(event, filters))
                    .map(|event| protocol_event_value(event, None))
                    .collect::<Vec<_>>();
                self.send_success(
                    id,
                    json!({
                        "events": events,
                        "nextCursor": page.next_cursor.0,
                        "hasMore": page.has_more,
                    }),
                    None,
                )
            }
            Err(error) => self.send_error(id, engine_error_to_capability_error(error)),
        }
    }

    async fn handle_ack(&mut self, id: Option<String>, value: Value) -> bool {
        let message = match serde_json::from_value::<AckMessage>(value) {
            Ok(message) => message,
            Err(error) => {
                return self.send_error(
                    id,
                    protocol_error(INVALID_PARAMS, format!("invalid ack: {error}"), None),
                );
            }
        };
        {
            let mut subscriptions = self.subscriptions.lock().await;
            let Some(subscription) = subscriptions.get_mut(&message.subscription_id) else {
                return self.send_error(
                    message.id,
                    protocol_error(
                        "STREAM_SUBSCRIPTION_NOT_FOUND",
                        format!(
                            "stream subscription {} was not found",
                            message.subscription_id
                        ),
                        None,
                    ),
                );
            };
            subscription.cursor = std::cmp::max(subscription.cursor, StreamCursor(message.cursor));
        }
        if let Err(error) = self
            .ctx
            .engine_host
            .acknowledge_stream(&message.subscription_id, StreamCursor(message.cursor))
            .await
        {
            return self.send_error(message.id, engine_error_to_capability_error(error));
        }
        self.send_success_async(
            message.id,
            json!({
                "acknowledged": true,
                "subscriptionId": message.subscription_id,
                "cursor": message.cursor,
            }),
            None,
        )
        .await
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
            authority_scopes: override_context.authority_scopes,
            runtime_metadata: override_context.runtime_metadata,
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
        let sanitized_msg = sanitize_error_message(&error);
        self.send_value(json!({
            "type": "response",
            "id": id,
            "ok": false,
            "error": {
                "code": error.code(),
                "message": sanitized_msg,
                "details": error.details(),
            },
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

async fn push_subscription_events(
    ctx: Arc<ServerRuntimeContext>,
    out_tx: mpsc::Sender<String>,
    subscriptions: Arc<tokio::sync::Mutex<BTreeMap<String, SubscriptionState>>>,
    cancel: CancellationToken,
) {
    let mut ticker = tokio::time::interval(PUSH_POLL_INTERVAL);
    let _ = ticker.tick().await;
    loop {
        tokio::select! {
            () = cancel.cancelled() => break,
            _ = ticker.tick() => {
                let snapshot = subscriptions
                    .lock()
                    .await
                    .iter()
                    .map(|(id, state)| (id.clone(), state.clone()))
                    .collect::<Vec<_>>();
                for (subscription_id, state) in snapshot {
                    let actor = StreamActorScope::scoped(
                        state.session_id.clone(),
                        state.workspace_id.clone(),
                    );
                    let page = match ctx
                        .engine_host
                        .poll_stream(
                            &subscription_id,
                            Some(state.cursor),
                            STREAM_MAX_LIMIT,
                            &actor,
                        )
                        .await
                    {
                        Ok(page) => page,
                        Err(error) => {
                            tracing::debug!(%subscription_id, %error, "engine stream push poll failed");
                            continue;
                        }
                    };
                    let mut latest_delivered_cursor = state.cursor;
                    let matched_events = page
                        .events
                        .iter()
                        .filter(|event| stream_event_matches_filters(event, state.filters.as_ref()))
                        .collect::<Vec<_>>();
                    if !page.events.is_empty() {
                        tracing::debug!(
                            %subscription_id,
                            topic = %state.topic,
                            cursor = state.cursor.0,
                            next_cursor = page.next_cursor.0,
                            page_events = page.events.len(),
                            matched_events = matched_events.len(),
                            "engine stream push page polled"
                        );
                    }
                    for event in matched_events {
                        latest_delivered_cursor = event.cursor;
                        if !send_engine_ws_value_async(
                            &out_tx,
                            &cancel,
                            protocol_event_value(event, Some(subscription_id.clone())),
                        )
                        .await
                        {
                            cancel.cancel();
                            return;
                        }
                    }
                    // Polling is visibility-scoped by the engine and then
                    // narrowed by client filters such as `sessionId`. Even
                    // when a page contains only filtered-out rows, the
                    // subscription must advance past those rows or live
                    // session streams can starve behind older events from
                    // other sessions.
                    let latest_seen_cursor = std::cmp::max(
                        latest_delivered_cursor.0,
                        page.next_cursor.0,
                    );
                    if latest_seen_cursor > state.cursor.0 {
                        if let Some(subscription) =
                            subscriptions.lock().await.get_mut(&subscription_id)
                        {
                            if subscription.cursor.0 < latest_seen_cursor {
                                subscription.cursor = StreamCursor(latest_seen_cursor);
                            }
                        }
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests;
