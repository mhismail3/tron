//! Events-owned engine stream publication.

use serde_json::json;

use crate::engine::{EngineHostHandle, Invocation, PublishStreamEvent, VisibilityScope};
use crate::events::sqlite::row_types::EventRow;
use crate::server::shared::events as event_wire;

/// Typed publisher for persisted session event rows.
pub(crate) struct EventsStreamPublisher<'a> {
    engine_host: &'a EngineHostHandle,
}

impl<'a> EventsStreamPublisher<'a> {
    pub(crate) fn new(engine_host: &'a EngineHostHandle) -> Self {
        Self { engine_host }
    }

    pub(crate) async fn session_event(
        &self,
        invocation: &Invocation,
        event: &EventRow,
        workspace_id: Option<String>,
    ) {
        let _ = self
            .engine_host
            .publish_stream_event(PublishStreamEvent {
                topic: "events.session".to_owned(),
                payload: json!({
                    "serverEvent": event_wire::event_row_to_server_payload(event),
                    "sourceEventType": event.event_type.clone(),
                    "sourceSequence": event.sequence,
                }),
                visibility: VisibilityScope::Session,
                session_id: Some(event.session_id.clone()),
                workspace_id,
                producer: "events::append".to_owned(),
                trace_id: Some(invocation.causal_context.trace_id.clone()),
                parent_invocation_id: Some(invocation.id.clone()),
            })
            .await;
    }
}
