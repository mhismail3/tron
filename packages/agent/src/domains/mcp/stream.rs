//! MCP-owned engine stream publication.

use serde_json::{Value, json};

use crate::domains::mcp::contract;
use crate::engine::{EngineHostHandle, Invocation, PublishStreamEvent, VisibilityScope};
use crate::shared::server::events::ServerEventPayload;

/// Typed publisher for MCP health and catalog events.
pub(crate) struct McpStreamPublisher<'a> {
    engine_host: &'a EngineHostHandle,
}

impl<'a> McpStreamPublisher<'a> {
    pub(crate) fn new(engine_host: &'a EngineHostHandle) -> Self {
        Self { engine_host }
    }

    pub(crate) async fn status_changed(&self, invocation: &Invocation, status: Value) {
        let event = ServerEventPayload::new("mcp.status_changed", None, Some(status));
        if let Err(error) = self
            .engine_host
            .publish_stream_event(PublishStreamEvent {
                topic: contract::STREAM_TOPICS[0].to_owned(),
                payload: json!({
                    "serverEvent": event,
                    "__broadcastScope": { "kind": "all" },
                    "sourceEventType": "mcp.status_changed",
                }),
                visibility: VisibilityScope::System,
                session_id: invocation.causal_context.session_id.clone(),
                workspace_id: invocation.causal_context.workspace_id.clone(),
                producer: "mcp".to_owned(),
                trace_id: Some(invocation.causal_context.trace_id.clone()),
                parent_invocation_id: Some(invocation.id.clone()),
            })
            .await
        {
            tracing::warn!(error = %error, "failed to publish MCP status stream event");
        }
    }
}
