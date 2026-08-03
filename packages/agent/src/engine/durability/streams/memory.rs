//! In-memory engine stream store.

use chrono::Utc;

use super::{
    EngineStreamEvent, EngineStreamPage, PublishStreamEvent, StreamActorScope, StreamCursor,
    stream_scope_visible,
};
use crate::engine::kernel::errors::{EngineError, Result};

/// In-memory stream store.
#[derive(Default)]
pub struct InMemoryEngineStreamStore {
    next_cursor: u64,
    events: Vec<EngineStreamEvent>,
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

    /// Poll a topic directly from an explicit cursor without durable subscriber state.
    pub(crate) fn poll_topic(
        &self,
        topic: &str,
        after: StreamCursor,
        limit: usize,
        actor: &StreamActorScope,
    ) -> Result<EngineStreamPage> {
        if topic.trim().is_empty() {
            return Err(EngineError::PolicyViolation(
                "stream topic must not be empty".to_owned(),
            ));
        }
        if limit == 0 {
            return Err(EngineError::PolicyViolation(
                "stream poll limit must be greater than zero".to_owned(),
            ));
        }
        let limit = limit.min(500);
        let mut visible = self
            .events
            .iter()
            .filter(|event| event.topic == topic)
            .filter(|event| event.cursor > after)
            .filter(|event| {
                stream_scope_visible(&event.visibility, event.session_id.as_deref(), actor)
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
