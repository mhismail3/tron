//! Job-owned engine stream publication.

use serde_json::json;

use crate::engine::{EngineHostHandle, Invocation, PublishStreamEvent, VisibilityScope};
use crate::server::domains::job::contract;

/// Typed publisher for job status events.
pub(crate) struct JobStreamPublisher<'a> {
    engine_host: &'a EngineHostHandle,
}

impl<'a> JobStreamPublisher<'a> {
    pub(crate) fn new(engine_host: &'a EngineHostHandle) -> Self {
        Self { engine_host }
    }

    pub(crate) async fn status(
        &self,
        invocation: &Invocation,
        session_id: &str,
        job_id: &str,
        action: &str,
    ) {
        let _ = self
            .engine_host
            .publish_stream_event(PublishStreamEvent {
                topic: contract::STREAM_TOPICS[0].to_owned(),
                payload: json!({
                    "sessionId": session_id,
                    "jobId": job_id,
                    "action": action,
                }),
                visibility: VisibilityScope::Session,
                session_id: Some(session_id.to_owned()),
                workspace_id: invocation.causal_context.workspace_id.clone(),
                producer: "job".to_owned(),
                trace_id: Some(invocation.causal_context.trace_id.clone()),
                parent_invocation_id: Some(invocation.id.clone()),
            })
            .await;
    }
}
