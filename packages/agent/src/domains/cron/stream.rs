//! Typed stream publisher for the cron domain.

use serde_json::json;

use crate::domains::cron::contract;
use crate::engine::{EngineHostHandle, Invocation, PublishStreamEvent, VisibilityScope};

#[derive(Clone)]
pub(crate) struct CronStreamPublisher {
    engine_host: EngineHostHandle,
}

impl CronStreamPublisher {
    pub(crate) fn new(engine_host: EngineHostHandle) -> Self {
        Self { engine_host }
    }

    pub(crate) async fn job_lifecycle(
        &self,
        invocation: &Invocation,
        kind: &str,
        job_id: &str,
        scheduled_at: Option<String>,
    ) {
        let _ = self
            .engine_host
            .publish_stream_event(PublishStreamEvent {
                topic: contract::STREAM_TOPICS[0].to_owned(),
                payload: json!({
                    "kind": kind,
                    "jobId": job_id,
                    "scheduledAt": scheduled_at,
                    "traceId": invocation.causal_context.trace_id.as_str(),
                    "triggerId": invocation
                        .causal_context
                        .trigger_id
                        .as_ref()
                        .map(crate::engine::TriggerId::as_str),
                }),
                visibility: VisibilityScope::System,
                session_id: invocation.causal_context.session_id.clone(),
                workspace_id: invocation.causal_context.workspace_id.clone(),
                producer: "cron".to_owned(),
                trace_id: Some(invocation.causal_context.trace_id.clone()),
                parent_invocation_id: invocation.causal_context.parent_invocation_id.clone(),
            })
            .await;
    }
}
