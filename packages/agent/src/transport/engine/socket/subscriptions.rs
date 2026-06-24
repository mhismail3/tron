use std::collections::BTreeMap;
use std::sync::Arc;

use serde_json::{Value, json};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;

use crate::engine::{StreamActorScope, StreamCursor};
use crate::shared::server::context::ServerRuntimeContext;
use crate::shared::server::error_mapping::engine_error_to_capability_error;
use crate::shared::server::errors::INVALID_PARAMS;

use super::outbound::send_engine_ws_value_async;
use super::stream_projection::{
    protocol_event_value, stream_event_matches_filters, visibility_for_context,
};
use super::wire::{AckMessage, PollMessage, SubscribeMessage, checked_limit, protocol_error};
use super::{EngineWsSession, PUSH_POLL_INTERVAL, STREAM_MAX_LIMIT};

#[derive(Clone, Debug)]
pub(super) struct SubscriptionState {
    pub(super) topic: String,
    pub(super) cursor: StreamCursor,
    pub(super) filters: Option<Value>,
    pub(super) session_id: Option<String>,
    pub(super) workspace_id: Option<String>,
}

impl EngineWsSession {
    pub(super) async fn handle_subscribe(&mut self, id: Option<String>, value: Value) -> bool {
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

    pub(super) async fn handle_poll(&mut self, id: Option<String>, value: Value) -> bool {
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

    pub(super) async fn handle_ack(&mut self, id: Option<String>, value: Value) -> bool {
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
}

pub(super) async fn push_subscription_events(
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
