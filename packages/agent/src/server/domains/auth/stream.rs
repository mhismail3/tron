//! Auth-owned engine stream publication.

use serde_json::{Value, json};

use crate::engine::{EngineHostHandle, Invocation, PublishStreamEvent, VisibilityScope};
use crate::server::shared::events::ServerEventPayload;

use super::contract;

/// Typed publisher for auth account/credential changes.
pub(crate) struct AuthStreamPublisher<'a> {
    engine_host: &'a EngineHostHandle,
}

impl<'a> AuthStreamPublisher<'a> {
    pub(crate) fn new(engine_host: &'a EngineHostHandle) -> Self {
        Self { engine_host }
    }

    pub(crate) async fn updated(&self, invocation: &Invocation, masked_state: &Value) {
        let event = ServerEventPayload::new("auth.updated", None, Some(masked_state.clone()));
        if let Err(error) = self
            .engine_host
            .publish_stream_event(PublishStreamEvent {
                topic: contract::STREAM_TOPICS[0].to_owned(),
                payload: json!({
                    "serverEvent": event,
                    "__broadcastScope": { "kind": "all" },
                    "sourceEventType": "auth.updated",
                }),
                visibility: VisibilityScope::System,
                session_id: invocation.causal_context.session_id.clone(),
                workspace_id: invocation.causal_context.workspace_id.clone(),
                producer: "auth".to_owned(),
                trace_id: Some(invocation.causal_context.trace_id.clone()),
                parent_invocation_id: Some(invocation.id.clone()),
            })
            .await
        {
            tracing::warn!(error = %error, "failed to publish auth updated stream event");
        }
    }
}
