//! Runtime lifecycle and invocation evidence publication.

use super::*;

impl WorkerRuntime {
    /// Publish one global worker lifecycle or operational invalidation.
    ///
    /// Session Context must never infer invocation ownership from these
    /// unscoped events. Invocation evidence uses
    /// [`Self::publish_invocation_event`] instead.
    pub(in crate::domains::worker_kernel) async fn publish_event(
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

    /// Publish invocation evidence with its durable originating session.
    ///
    /// The stream remains an invalidation hint; the invocation ledger is the
    /// authoritative projection. Descendant work inherits `origin_session_id`,
    /// while scheduled or otherwise sessionless work deliberately stays
    /// unscoped.
    pub(super) async fn publish_invocation_event(
        &self,
        invocation: &InvocationRecord,
        payload: Value,
    ) {
        let _ = self
            .host
            .publish_stream_event(PublishStreamEvent {
                topic: "worker.invocations".to_owned(),
                payload,
                visibility: StreamVisibility::System,
                session_id: invocation.origin_session_id.clone(),
                workspace_id: None,
                producer: "worker_kernel".to_owned(),
                trace_id: TraceId::new(invocation.trace_id.clone()).ok(),
                parent_invocation_id: None,
            })
            .await;
    }
}
