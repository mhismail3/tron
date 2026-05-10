//! `/engine` WebSocket protocol over the canonical engine transport envelope.
//!
//! This module owns only WebSocket framing, protocol validation, correlation
//! ids, heartbeat, and stream cursor subscription state. Discover/inspect/watch
//! invoke/promote messages are translated into [`EngineTransportRequest`] and
//! then dispatched through the canonical engine transport path.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use axum::extract::ws::{Message, WebSocket};
use futures::{SinkExt, StreamExt};
use metrics::counter;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::engine::{StreamActorScope, StreamCursor, VisibilityScope};
use crate::shared::server::context::ServerRuntimeContext;
use crate::shared::server::error_mapping::engine_error_to_capability_error;
use crate::shared::server::errors::{CapabilityError, INVALID_PARAMS};
use crate::shared::server::events::ServerEventPayload;
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
        let revision = self.ctx.engine_host.catalog_revision().await;
        self.send_value(json!({
            "type": "hello.ok",
            "id": message.id,
            "protocolVersion": PROTOCOL_VERSION,
            "minimumSupportedVersion": MIN_PROTOCOL_VERSION,
            "serverId": "tron-engine",
            "currentCatalogRevision": revision.0,
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
        if let Some(revision) = message.expected_revision {
            payload.insert("expectedFunctionRevision".to_owned(), json!(revision));
        }
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
            "expectedFunctionRevision".to_owned(),
            json!(message.expected_function_revision),
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
            Ok(result) => {
                let revision = self.ctx.engine_host.catalog_revision().await;
                self.send_success(id, result, Some(trace_id), Some(revision.0))
            }
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
        let cursor = StreamCursor(message.cursor.unwrap_or(0));
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
        let cursor = StreamCursor(message.cursor.unwrap_or(0));
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
        }
    }

    fn send_success(
        &self,
        id: Option<String>,
        result: Value,
        trace_id: Option<String>,
        catalog_revision: Option<u64>,
    ) -> bool {
        self.send_value(json!({
            "type": "response",
            "id": id,
            "ok": true,
            "result": result,
            "traceId": trace_id,
            "catalogRevision": catalog_revision,
        }))
    }

    async fn send_success_async(
        &self,
        id: Option<String>,
        result: Value,
        trace_id: Option<String>,
        catalog_revision: Option<u64>,
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
                "catalogRevision": catalog_revision,
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
        let mut value = value;
        remove_null_transport_fields(&mut value);
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

fn send_engine_ws_value(out_tx: &mpsc::Sender<String>, value: Value) -> bool {
    let mut value = value;
    remove_null_transport_fields(&mut value);
    let json = match serde_json::to_string(&value) {
        Ok(json) => json,
        Err(error) => {
            tracing::error!(%error, "failed to serialize engine WebSocket response");
            return false;
        }
    };
    match out_tx.try_send(json) {
        Ok(()) => true,
        Err(mpsc::error::TrySendError::Full(_)) => {
            counter!("engine_ws_overload_total").increment(1);
            tracing::warn!("engine WebSocket outbound queue overloaded; closing connection");
            false
        }
        Err(mpsc::error::TrySendError::Closed(_)) => false,
    }
}

async fn send_engine_ws_value_async(
    out_tx: &mpsc::Sender<String>,
    cancel: &CancellationToken,
    value: Value,
) -> bool {
    let mut value = value;
    remove_null_transport_fields(&mut value);
    let json = match serde_json::to_string(&value) {
        Ok(json) => json,
        Err(error) => {
            tracing::error!(%error, "failed to serialize engine WebSocket push event");
            return false;
        }
    };
    tokio::select! {
        () = cancel.cancelled() => false,
        result = out_tx.send(json) => {
            if result.is_err() {
                tracing::debug!("engine WebSocket outbound queue closed while sending stream event");
                return false;
            }
            true
        }
    }
}

fn remove_null_transport_fields(value: &mut Value) {
    if let Value::Object(object) = value {
        object.retain(|_, value| !value.is_null());
        if let Some(Value::Object(error)) = object.get_mut("error") {
            error.retain(|_, value| !value.is_null());
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct HelloMessage {
    #[serde(rename = "type")]
    _message_type: String,
    id: Option<String>,
    protocol_version: u64,
    #[serde(default)]
    _client_name: Option<String>,
    #[serde(default)]
    _client_version: Option<String>,
    #[serde(default)]
    session_id: Option<String>,
    #[serde(default)]
    workspace_id: Option<String>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct WireContext {
    #[serde(default)]
    session_id: Option<String>,
    #[serde(default)]
    workspace_id: Option<String>,
    #[serde(default)]
    trace_id: Option<String>,
    #[serde(default)]
    parent_invocation_id: Option<String>,
    #[serde(default)]
    authority_scopes: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct InvokeMessage {
    #[serde(rename = "type")]
    _message_type: String,
    id: Option<String>,
    function_id: String,
    #[serde(default)]
    payload: Option<Value>,
    #[serde(default)]
    expected_revision: Option<u64>,
    #[serde(default)]
    idempotency_key: Option<String>,
    #[serde(default)]
    context: Option<WireContext>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PromoteMessage {
    #[serde(rename = "type")]
    _message_type: String,
    id: Option<String>,
    function_id: String,
    target_visibility: String,
    expected_function_revision: u64,
    #[serde(default)]
    workspace_id: Option<String>,
    idempotency_key: String,
    #[serde(default)]
    context: Option<WireContext>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct SubscribeMessage {
    #[serde(rename = "type")]
    _message_type: String,
    id: Option<String>,
    topic: String,
    #[serde(default)]
    cursor: Option<u64>,
    #[serde(default)]
    filters: Option<Value>,
    #[serde(default)]
    limit: Option<usize>,
    #[serde(default)]
    context: Option<WireContext>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PollMessage {
    #[serde(rename = "type")]
    _message_type: String,
    id: Option<String>,
    #[serde(default)]
    subscription_id: Option<String>,
    #[serde(default)]
    topic: Option<String>,
    #[serde(default)]
    cursor: Option<u64>,
    #[serde(default)]
    filters: Option<Value>,
    #[serde(default)]
    limit: Option<usize>,
    #[serde(default)]
    context: Option<WireContext>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct AckMessage {
    #[serde(rename = "type")]
    _message_type: String,
    id: Option<String>,
    subscription_id: String,
    cursor: u64,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct HeartbeatMessage {
    #[serde(rename = "type")]
    _message_type: String,
    id: Option<String>,
    #[serde(default)]
    timestamp: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ProtocolEvent {
    #[serde(rename = "type")]
    message_type: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    subscription_id: Option<String>,
    topic: String,
    cursor: u64,
    event: ServerEventPayload,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RequestMessage {
    #[serde(rename = "type")]
    _message_type: String,
    #[serde(default)]
    id: Option<String>,
    request: Value,
    #[serde(default)]
    context: Option<WireContext>,
}

fn optional_id(object: &Map<String, Value>) -> Result<Option<String>, CapabilityError> {
    match object.get("id") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => {
            if value.trim().is_empty() {
                Err(protocol_error(
                    INVALID_PARAMS,
                    "engine message id must be a non-empty string when present",
                    None,
                ))
            } else {
                Ok(Some(value.clone()))
            }
        }
        Some(_) => Err(protocol_error(
            INVALID_PARAMS,
            "engine message id must be a non-empty string when present",
            None,
        )),
    }
}

fn checked_limit(limit: Option<usize>) -> Result<usize, CapabilityError> {
    let limit = limit.unwrap_or(STREAM_DEFAULT_LIMIT);
    if limit == 0 {
        return Err(protocol_error(
            INVALID_PARAMS,
            "stream limit must be greater than zero",
            None,
        ));
    }
    Ok(limit.min(STREAM_MAX_LIMIT))
}

fn visibility_for_context(context: &EngineTransportContext) -> VisibilityScope {
    if context.session_id.is_some() {
        VisibilityScope::Session
    } else if context.workspace_id.is_some() {
        VisibilityScope::Workspace
    } else {
        VisibilityScope::System
    }
}

fn protocol_event_value(
    event: &crate::engine::EngineStreamEvent,
    subscription_id: Option<String>,
) -> Value {
    serde_json::to_value(ProtocolEvent {
        message_type: "event",
        subscription_id,
        topic: event.topic.clone(),
        cursor: event.cursor.0,
        event: server_payload_from_stream_event(event),
    })
    .expect("protocol event serializes")
}

fn server_payload_from_stream_event(
    event: &crate::engine::EngineStreamEvent,
) -> ServerEventPayload {
    if let Some(value) = event.payload.get("serverEvent")
        && let Ok(mut payload) = serde_json::from_value::<ServerEventPayload>(value.clone())
    {
        payload.stream_cursor = Some(event.cursor.0);
        if payload.trace_id.is_none() {
            payload.trace_id = event.trace_id.as_ref().map(ToString::to_string);
        }
        if payload.parent_invocation_id.is_none() {
            payload.parent_invocation_id =
                event.parent_invocation_id.as_ref().map(ToString::to_string);
        }
        return payload;
    }
    let event_type = event
        .payload
        .get("type")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| format!("engine.{}", event.topic.replace('.', "_")));
    let mut payload = ServerEventPayload::new(
        event_type,
        event.session_id.clone(),
        Some(event.payload.clone()),
    );
    payload.workspace_id.clone_from(&event.workspace_id);
    payload.timestamp = event
        .created_at
        .to_rfc3339_opts(chrono::SecondsFormat::Millis, true);
    payload.trace_id = event.trace_id.as_ref().map(ToString::to_string);
    payload.parent_invocation_id = event.parent_invocation_id.as_ref().map(ToString::to_string);
    payload.stream_cursor = Some(event.cursor.0);
    payload
}

fn stream_event_matches_filters(
    event: &crate::engine::EngineStreamEvent,
    filters: Option<&Value>,
) -> bool {
    let Some(filters) = filters else {
        return true;
    };
    let Some(object) = filters.as_object() else {
        return false;
    };
    if let Some(session_id) = object.get("sessionId").and_then(Value::as_str)
        && stream_event_session_id(event).as_deref() != Some(session_id)
    {
        return false;
    }
    if let Some(workspace_id) = object.get("workspaceId").and_then(Value::as_str)
        && stream_event_workspace_id(event).as_deref() != Some(workspace_id)
    {
        return false;
    }
    if let Some(event_type) = object.get("eventType").and_then(Value::as_str) {
        return server_payload_from_stream_event(event).event_type == event_type;
    }
    if let Some(types) = object.get("eventTypes").and_then(Value::as_array) {
        let event_type = server_payload_from_stream_event(event).event_type;
        return types
            .iter()
            .any(|value| value.as_str() == Some(event_type.as_str()));
    }
    true
}

fn stream_event_session_id(event: &crate::engine::EngineStreamEvent) -> Option<String> {
    event.session_id.clone().or_else(|| {
        server_payload_from_stream_event(event)
            .session_id
            .as_ref()
            .map(ToOwned::to_owned)
    })
}

fn stream_event_workspace_id(event: &crate::engine::EngineStreamEvent) -> Option<String> {
    event.workspace_id.clone().or_else(|| {
        server_payload_from_stream_event(event)
            .workspace_id
            .as_ref()
            .map(ToOwned::to_owned)
    })
}

fn protocol_error(
    code: impl Into<String>,
    message: impl Into<String>,
    details: Option<Value>,
) -> CapabilityError {
    CapabilityError::Custom {
        code: code.into(),
        message: message.into(),
        details,
    }
}

fn now_timestamp() -> String {
    chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::{PublishStreamEvent, VisibilityScope};
    use crate::shared::server::test_support::make_test_context;
    use serde_json::json;

    fn test_session() -> (EngineWsSession, mpsc::Receiver<String>) {
        let ctx = Arc::new(make_test_context());
        let (tx, rx) = mpsc::channel(OUTBOUND_QUEUE_CAPACITY);
        (
            EngineWsSession::new(
                "client-1".to_owned(),
                ctx,
                tx,
                Arc::new(tokio::sync::Mutex::new(BTreeMap::new())),
                CancellationToken::new(),
            ),
            rx,
        )
    }

    #[tokio::test]
    async fn hello_sets_defaults_and_returns_catalog_revision() {
        let (mut session, _rx) = test_session();
        assert!(
            session
                .handle_text(r#"{"type":"hello","id":"h1","protocolVersion":1,"sessionId":"s1"}"#)
                .await
        );
        assert_eq!(
            session.hello.as_ref().unwrap().session_id.as_deref(),
            Some("s1")
        );
    }

    #[test]
    fn invoke_message_maps_to_engine_invoke_payload() {
        let value = json!({
            "type": "invoke",
            "id": "i1",
            "functionId": "system::ping",
            "payload": {"protocolVersion": 1},
            "expectedRevision": 3,
            "idempotencyKey": "idem-1",
            "context": {"sessionId": "s1", "traceId": "trace-1", "authorityScopes": ["system.read"]}
        });
        let message: InvokeMessage = serde_json::from_value(value).unwrap();
        assert_eq!(message.function_id, "system::ping");
        assert_eq!(message.expected_revision, Some(3));
        assert_eq!(
            message.context.unwrap().authority_scopes,
            vec!["system.read".to_owned()]
        );
    }

    #[test]
    fn stream_filters_match_neutral_server_event_scope() {
        let event = crate::engine::EngineStreamEvent {
            cursor: StreamCursor(7),
            topic: "events.session".to_owned(),
            payload: json!({
                "serverEvent": ServerEventPayload::new(
                    "session.created",
                    Some("session-a".to_owned()),
                    Some(json!({"title": "Test Session"}))
                )
            }),
            visibility: VisibilityScope::System,
            session_id: None,
            workspace_id: None,
            producer: "test".to_owned(),
            trace_id: None,
            parent_invocation_id: None,
            created_at: chrono::Utc::now(),
        };

        assert!(stream_event_matches_filters(
            &event,
            Some(&json!({"sessionId": "session-a"}))
        ));
        assert!(!stream_event_matches_filters(
            &event,
            Some(&json!({"sessionId": "session-b"}))
        ));
    }

    #[tokio::test]
    async fn stream_poll_returns_neutral_events() {
        let (mut session, _rx) = test_session();
        session.hello = Some(HelloState {
            session_id: Some("s1".to_owned()),
            workspace_id: None,
        });
        let cursor = session
            .ctx
            .engine_host
            .publish_stream_event(PublishStreamEvent {
                topic: "events.session".to_owned(),
                payload: json!({
                    "serverEvent": ServerEventPayload::new(
                        "agent.ready",
                        Some("s1".to_owned()),
                        Some(json!({"ready": true}))
                    )
                }),
                visibility: VisibilityScope::Session,
                session_id: Some("s1".to_owned()),
                workspace_id: None,
                producer: "test".to_owned(),
                trace_id: None,
                parent_invocation_id: None,
            })
            .await
            .unwrap();
        assert_eq!(cursor.0, 1);

        assert!(
            session
                .handle_text(r#"{"type":"subscribe","id":"s","topic":"events.session"}"#)
                .await
        );
        let subscription_id = session
            .subscriptions
            .lock()
            .await
            .keys()
            .next()
            .unwrap()
            .clone();
        let page = session
            .ctx
            .engine_host
            .poll_stream(
                &subscription_id,
                Some(StreamCursor(0)),
                100,
                &StreamActorScope::scoped(Some("s1".to_owned()), None),
            )
            .await
            .unwrap();
        let event = server_payload_from_stream_event(&page.events[0]);
        assert_eq!(event.event_type, "agent.ready");
        assert_eq!(event.stream_cursor, Some(1));
    }

    #[tokio::test]
    async fn ack_response_applies_backpressure_instead_of_closing_socket() {
        let ctx = Arc::new(make_test_context());
        ctx.engine_host
            .subscribe_stream(
                "sub-ack".to_owned(),
                "events.session".to_owned(),
                StreamCursor(0),
                VisibilityScope::Session,
                Some("s1".to_owned()),
                None,
            )
            .await
            .unwrap();
        let (tx, mut rx) = mpsc::channel(1);
        tx.try_send("occupied".to_owned()).unwrap();
        let mut session = EngineWsSession::new(
            "client-ack".to_owned(),
            ctx,
            tx,
            Arc::new(tokio::sync::Mutex::new(BTreeMap::from([(
                "sub-ack".to_owned(),
                SubscriptionState {
                    topic: "events.session".to_owned(),
                    cursor: StreamCursor(0),
                    filters: None,
                    session_id: Some("s1".to_owned()),
                    workspace_id: None,
                },
            )]))),
            CancellationToken::new(),
        );
        let ack_task = tokio::spawn(async move {
            session
                .handle_text(
                    r#"{"type":"ack","id":"ack-1","subscriptionId":"sub-ack","cursor":42}"#,
                )
                .await
        });

        tokio::time::sleep(std::time::Duration::from_millis(25)).await;
        assert!(
            !ack_task.is_finished(),
            "ack responses should wait for outbound capacity instead of closing the socket"
        );

        assert_eq!(rx.recv().await.as_deref(), Some("occupied"));
        assert!(ack_task.await.unwrap());
        let response = tokio::time::timeout(std::time::Duration::from_secs(1), rx.recv())
            .await
            .unwrap()
            .unwrap();
        let value: Value = serde_json::from_str(&response).unwrap();
        assert_eq!(value.get("ok").and_then(Value::as_bool), Some(true));
        assert_eq!(
            value.pointer("/result/cursor").and_then(Value::as_u64),
            Some(42)
        );
    }

    #[tokio::test]
    async fn push_subscription_advances_past_filtered_stream_pages() {
        let ctx = Arc::new(make_test_context());
        let target_session = "session-target";
        let other_session = "session-other";

        for index in 0..(STREAM_MAX_LIMIT + 1) {
            ctx.engine_host
                .publish_stream_event(PublishStreamEvent {
                    topic: "events.session".to_owned(),
                    payload: json!({
                        "serverEvent": ServerEventPayload::new(
                            "agent.delta",
                            Some(other_session.to_owned()),
                            Some(json!({"index": index}))
                        )
                    }),
                    visibility: VisibilityScope::System,
                    session_id: None,
                    workspace_id: None,
                    producer: "test".to_owned(),
                    trace_id: None,
                    parent_invocation_id: None,
                })
                .await
                .unwrap();
        }
        let target_cursor = ctx
            .engine_host
            .publish_stream_event(PublishStreamEvent {
                topic: "events.session".to_owned(),
                payload: json!({
                    "serverEvent": ServerEventPayload::new(
                        "agent.ready",
                        Some(target_session.to_owned()),
                        Some(json!({"ready": true}))
                    )
                }),
                visibility: VisibilityScope::Session,
                session_id: Some(target_session.to_owned()),
                workspace_id: None,
                producer: "test".to_owned(),
                trace_id: None,
                parent_invocation_id: None,
            })
            .await
            .unwrap();

        let subscription_id = "sub-target".to_owned();
        ctx.engine_host
            .subscribe_stream(
                subscription_id.clone(),
                "events.session".to_owned(),
                StreamCursor(0),
                VisibilityScope::Session,
                Some(target_session.to_owned()),
                None,
            )
            .await
            .unwrap();
        let subscriptions = Arc::new(tokio::sync::Mutex::new(BTreeMap::from([(
            subscription_id.clone(),
            SubscriptionState {
                topic: "events.session".to_owned(),
                cursor: StreamCursor(0),
                filters: Some(json!({"sessionId": target_session})),
                session_id: Some(target_session.to_owned()),
                workspace_id: None,
            },
        )])));
        let (out_tx, mut out_rx) = mpsc::channel(OUTBOUND_QUEUE_CAPACITY);
        let cancel = CancellationToken::new();
        let push_task = tokio::spawn(push_subscription_events(
            ctx,
            out_tx,
            subscriptions.clone(),
            cancel.clone(),
        ));

        let delivered = tokio::time::timeout(std::time::Duration::from_secs(2), async {
            while let Some(message) = out_rx.recv().await {
                let value: Value = serde_json::from_str(&message).unwrap();
                if value.get("type").and_then(Value::as_str) == Some("event") {
                    return value;
                }
            }
            panic!("stream push task closed before delivering target event");
        })
        .await
        .expect("filtered stream pages should not starve later matching events");

        cancel.cancel();
        push_task.await.unwrap();

        assert_eq!(
            delivered
                .pointer("/event/sessionId")
                .and_then(Value::as_str),
            Some(target_session)
        );
        assert_eq!(
            delivered.pointer("/event/type").and_then(Value::as_str),
            Some("agent.ready")
        );
        assert_eq!(
            delivered
                .pointer("/event/streamCursor")
                .and_then(Value::as_u64)
                .map(StreamCursor),
            Some(target_cursor)
        );
        let cursor = subscriptions
            .lock()
            .await
            .get(&subscription_id)
            .unwrap()
            .cursor;
        assert!(
            cursor >= target_cursor,
            "subscription cursor should advance to at least the delivered target cursor"
        );
    }

    #[tokio::test]
    async fn push_subscription_applies_backpressure_to_catch_up_bursts() {
        let ctx = Arc::new(make_test_context());
        let target_session = "session-burst";
        let total_events = OUTBOUND_QUEUE_CAPACITY + 24;

        for index in 0..total_events {
            ctx.engine_host
                .publish_stream_event(PublishStreamEvent {
                    topic: "events.session".to_owned(),
                    payload: json!({
                        "serverEvent": ServerEventPayload::new(
                            "agent.text_delta",
                            Some(target_session.to_owned()),
                            Some(json!({"delta": index.to_string()}))
                        )
                    }),
                    visibility: VisibilityScope::Session,
                    session_id: Some(target_session.to_owned()),
                    workspace_id: None,
                    producer: "test".to_owned(),
                    trace_id: None,
                    parent_invocation_id: None,
                })
                .await
                .unwrap();
        }

        let subscription_id = "sub-burst".to_owned();
        ctx.engine_host
            .subscribe_stream(
                subscription_id.clone(),
                "events.session".to_owned(),
                StreamCursor(0),
                VisibilityScope::Session,
                Some(target_session.to_owned()),
                None,
            )
            .await
            .unwrap();
        let subscriptions = Arc::new(tokio::sync::Mutex::new(BTreeMap::from([(
            subscription_id,
            SubscriptionState {
                topic: "events.session".to_owned(),
                cursor: StreamCursor(0),
                filters: Some(json!({"sessionId": target_session})),
                session_id: Some(target_session.to_owned()),
                workspace_id: None,
            },
        )])));
        let (out_tx, mut out_rx) = mpsc::channel(OUTBOUND_QUEUE_CAPACITY);
        let cancel = CancellationToken::new();
        let push_task = tokio::spawn(push_subscription_events(
            ctx,
            out_tx,
            subscriptions,
            cancel.clone(),
        ));

        tokio::time::sleep(PUSH_POLL_INTERVAL * 2).await;
        assert!(
            !cancel.is_cancelled(),
            "catch-up bursts must apply channel backpressure instead of closing the socket"
        );

        let mut delivered = 0usize;
        tokio::time::timeout(std::time::Duration::from_secs(3), async {
            while delivered < total_events {
                let message = out_rx.recv().await.expect("push stream should stay open");
                let value: Value = serde_json::from_str(&message).unwrap();
                if value.get("type").and_then(Value::as_str) == Some("event") {
                    delivered += 1;
                }
            }
        })
        .await
        .expect("backpressured catch-up burst should drain completely");

        cancel.cancel();
        push_task.await.unwrap();
        assert_eq!(delivered, total_events);
    }
}
