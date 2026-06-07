//! Agent-owned engine stream publication.

use serde_json::{Value, json};

use crate::domains::agent::contract;
use crate::engine::{
    EngineHostHandle, Invocation, InvocationId, PublishStreamEvent, TraceId, VisibilityScope,
};

/// Typed publisher for agent runtime events.
pub(crate) struct AgentStreamPublisher<'a> {
    engine_host: &'a EngineHostHandle,
}

impl<'a> AgentStreamPublisher<'a> {
    pub(crate) fn new(engine_host: &'a EngineHostHandle) -> Self {
        Self { engine_host }
    }

    pub(crate) async fn prompt(
        &self,
        invocation: &Invocation,
        session_id: &str,
        action: &str,
        payload: Value,
    ) {
        let _ = self
            .engine_host
            .publish_stream_event(PublishStreamEvent {
                topic: contract::STREAM_TOPICS[0].to_owned(),
                payload: json!({
                    "type": format!("agent.prompt.{action}"),
                    "action": action,
                    "sessionId": session_id,
                    "traceId": invocation.causal_context.trace_id.as_str(),
                    "invocationId": invocation.id.as_str(),
                    "parentInvocationId": invocation
                        .causal_context
                        .parent_invocation_id
                        .as_ref()
                        .map(|id| id.as_str()),
                    "idempotencyKey": invocation.causal_context.idempotency_key.clone(),
                    "payload": payload,
                }),
                visibility: VisibilityScope::Session,
                session_id: Some(session_id.to_owned()),
                workspace_id: invocation.causal_context.workspace_id.clone(),
                producer: "agent::prompt".to_owned(),
                trace_id: Some(invocation.causal_context.trace_id.clone()),
                parent_invocation_id: Some(invocation.id.clone()),
            })
            .await;
    }

    pub(crate) async fn prompt_runtime(
        &self,
        workspace_id: Option<String>,
        trace_id: Option<TraceId>,
        parent_invocation_id: Option<InvocationId>,
        session_id: &str,
        action: &str,
        payload: Value,
    ) {
        let _ = self
            .engine_host
            .publish_stream_event(PublishStreamEvent {
                topic: contract::STREAM_TOPICS[0].to_owned(),
                payload: json!({
                    "type": format!("agent.prompt.{action}"),
                    "action": action,
                    "sessionId": session_id,
                    "payload": payload,
                }),
                visibility: VisibilityScope::Session,
                session_id: Some(session_id.to_owned()),
                workspace_id,
                producer: "agent::prompt_apply".to_owned(),
                trace_id,
                parent_invocation_id,
            })
            .await;
    }
}
