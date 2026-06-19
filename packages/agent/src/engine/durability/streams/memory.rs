//! In-memory engine stream store.

use std::collections::BTreeMap;

use chrono::Utc;

use super::{
    EngineStreamEvent, EngineStreamPage, EngineStreamSubscription, PublishStreamEvent,
    StreamActorScope, StreamCursor, stream_scope_visible,
};
use crate::engine::kernel::errors::{EngineError, Result};
use crate::engine::kernel::types::VisibilityScope;

/// In-memory stream store.
#[derive(Default)]
pub struct InMemoryEngineStreamStore {
    next_cursor: u64,
    events: Vec<EngineStreamEvent>,
    subscriptions: BTreeMap<String, EngineStreamSubscription>,
}

impl InMemoryEngineStreamStore {
    /// Create an empty store.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Publish one event and return its cursor.
    pub fn publish(&mut self, event: PublishStreamEvent) -> Result<StreamCursor> {
        if event.topic.trim().is_empty() {
            return Err(EngineError::PolicyViolation(
                "stream topic must not be empty".to_owned(),
            ));
        }
        self.next_cursor += 1;
        let cursor = StreamCursor(self.next_cursor);
        self.events.push(EngineStreamEvent {
            cursor,
            topic: event.topic,
            payload: event.payload,
            visibility: event.visibility,
            session_id: event.session_id,
            workspace_id: event.workspace_id,
            producer: event.producer,
            trace_id: event.trace_id,
            parent_invocation_id: event.parent_invocation_id,
            created_at: Utc::now(),
        });
        Ok(cursor)
    }

    /// Create or update a subscription.
    pub fn subscribe(
        &mut self,
        subscription_id: String,
        topic: String,
        cursor: StreamCursor,
        visibility: VisibilityScope,
        session_id: Option<String>,
        workspace_id: Option<String>,
    ) -> Result<EngineStreamSubscription> {
        if subscription_id.trim().is_empty() {
            return Err(EngineError::PolicyViolation(
                "stream subscription id must not be empty".to_owned(),
            ));
        }
        if topic.trim().is_empty() {
            return Err(EngineError::PolicyViolation(
                "stream topic must not be empty".to_owned(),
            ));
        }
        let subscription = EngineStreamSubscription {
            subscription_id: subscription_id.clone(),
            topic,
            cursor,
            visibility,
            session_id,
            workspace_id,
            active: true,
            created_at: Utc::now(),
        };
        self.subscriptions
            .insert(subscription_id, subscription.clone());
        Ok(subscription)
    }

    /// Return the latest cursor assigned for a topic.
    #[must_use]
    pub fn latest_cursor(&self, topic: &str) -> StreamCursor {
        self.events
            .iter()
            .rev()
            .find(|event| event.topic == topic)
            .map(|event| event.cursor)
            .unwrap_or_default()
    }

    /// Mark a subscription inactive.
    pub fn unsubscribe(&mut self, subscription_id: &str) -> Result<bool> {
        let Some(subscription) = self.subscriptions.get_mut(subscription_id) else {
            return Ok(false);
        };
        let was_active = subscription.active;
        subscription.active = false;
        Ok(was_active)
    }

    /// Advance a subscription cursor after client delivery.
    pub fn acknowledge(
        &mut self,
        subscription_id: &str,
        cursor: StreamCursor,
    ) -> Result<EngineStreamSubscription> {
        let Some(subscription) = self.subscriptions.get_mut(subscription_id) else {
            return Err(EngineError::NotFound {
                kind: "stream_subscription",
                id: subscription_id.to_owned(),
            });
        };
        if !subscription.active {
            return Err(EngineError::PolicyViolation(format!(
                "stream subscription {subscription_id} is inactive"
            )));
        }
        if subscription.cursor < cursor {
            subscription.cursor = cursor;
        }
        Ok(subscription.clone())
    }

    /// Poll a subscription after a cursor.
    pub fn poll(
        &self,
        subscription_id: &str,
        after: Option<StreamCursor>,
        limit: usize,
        actor: &StreamActorScope,
    ) -> Result<EngineStreamPage> {
        if limit == 0 {
            return Err(EngineError::PolicyViolation(
                "stream poll limit must be greater than zero".to_owned(),
            ));
        }
        let subscription =
            self.subscriptions
                .get(subscription_id)
                .ok_or_else(|| EngineError::NotFound {
                    kind: "stream_subscription",
                    id: subscription_id.to_owned(),
                })?;
        if !subscription.active {
            return Err(EngineError::PolicyViolation(format!(
                "stream subscription {subscription_id} is inactive"
            )));
        }
        if !stream_scope_visible(
            &subscription.visibility,
            subscription.session_id.as_deref(),
            subscription.workspace_id.as_deref(),
            actor,
        ) {
            return Err(EngineError::PolicyViolation(format!(
                "stream subscription {subscription_id} is not visible"
            )));
        }
        let after = after.unwrap_or(subscription.cursor);
        let limit = limit.min(500);
        let mut visible = self
            .events
            .iter()
            .filter(|event| event.topic == subscription.topic)
            .filter(|event| event.cursor > after)
            .filter(|event| {
                stream_scope_visible(
                    &event.visibility,
                    event.session_id.as_deref(),
                    event.workspace_id.as_deref(),
                    actor,
                )
            })
            .cloned()
            .collect::<Vec<_>>();
        visible.sort_by_key(|event| event.cursor);
        let has_more = visible.len() > limit;
        let mut next_cursor = after;
        let events = visible
            .into_iter()
            .take(limit)
            .map(|event| {
                next_cursor = event.cursor;
                event
            })
            .collect::<Vec<_>>();
        Ok(EngineStreamPage {
            events,
            next_cursor,
            has_more,
        })
    }

    /// List stream records scoped to one session for replay.
    pub fn list_by_session(&self, session_id: &str) -> Result<Vec<EngineStreamEvent>> {
        let mut events = self
            .events
            .iter()
            .filter(|event| event.session_id.as_deref() == Some(session_id))
            .cloned()
            .collect::<Vec<_>>();
        events.sort_by_key(|event| event.cursor);
        Ok(events)
    }
}
