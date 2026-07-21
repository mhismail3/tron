//! Runtime lifecycle and invocation evidence publication.

use super::*;

impl WorkerRuntime {
    pub(super) async fn publish_event(
        &self,
        topic: &str,
        payload: Value,
        trace_id: Option<TraceId>,
    ) {
        let _ = self
            .host
            .publish_stream_event(PublishStreamEvent {
                topic: topic.to_owned(),
                payload,
                visibility: StreamVisibility::System,
                session_id: None,
                workspace_id: None,
                producer: "worker_kernel".to_owned(),
                trace_id,
                parent_invocation_id: None,
            })
            .await;
    }
}
