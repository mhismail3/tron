//! Primitive substrate store methods exposed through `EngineHostHandle`.

use super::*;
use crate::engine::durability::state::{EngineStateEntry, EngineStateScope};

impl EngineHostHandle {
    /// Write one kernel-owned state entry without creating a nested primitive
    /// invocation. Used for runtime overlays whose authoring operation is
    /// already ledgered (for example `worker_discover`).
    pub(crate) async fn write_engine_state(
        &self,
        scope: EngineStateScope,
        namespace: impl Into<String>,
        key: impl Into<String>,
        value: Value,
    ) -> Result<EngineStateEntry> {
        let store = self.inner.lock().await.primitives.state.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("state store lock poisoned".to_owned()))?
            .set(scope, namespace.into(), key.into(), value)
    }

    /// Read one kernel-owned state entry for a runtime overlay.
    pub(crate) async fn read_engine_state(
        &self,
        scope: EngineStateScope,
        namespace: &str,
        key: &str,
    ) -> Result<Option<EngineStateEntry>> {
        let store = self.inner.lock().await.primitives.state.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("state store lock poisoned".to_owned()))?
            .get(scope, namespace, key)
    }

    /// List a bounded set of kernel-owned state entries for a runtime overlay.
    pub(crate) async fn list_engine_state(
        &self,
        scope: EngineStateScope,
        namespace: &str,
        key_prefix: Option<&str>,
        limit: usize,
    ) -> Result<Vec<EngineStateEntry>> {
        let store = self.inner.lock().await.primitives.state.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("state store lock poisoned".to_owned()))?
            .list(scope, namespace, key_prefix, limit)
    }

    /// Delete one kernel-owned runtime-overlay entry.
    pub(crate) async fn delete_engine_state(
        &self,
        scope: EngineStateScope,
        namespace: &str,
        key: &str,
    ) -> Result<bool> {
        let store = self.inner.lock().await.primitives.state.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("state store lock poisoned".to_owned()))?
            .delete(scope, namespace, key)
    }

    /// Read durable engine rows for one session without invoking any functions.
    pub(crate) async fn replay_snapshot(
        &self,
        session_id: &str,
    ) -> Result<crate::engine::durability::replay::EngineReplaySnapshot> {
        let (invocations, idempotency_entries, streams) = {
            let host = self.inner.lock().await;
            (
                host.catalog.ledger_invocations_by_session(session_id)?,
                host.catalog.ledger_idempotency_by_session(session_id)?,
                host.primitives.streams.clone(),
            )
        };

        let stream_events = streams
            .lock()
            .map_err(|_| EngineError::HandlerFailed("stream store lock poisoned".to_owned()))?
            .list_by_session(session_id)?;
        Ok(crate::engine::durability::replay::EngineReplaySnapshot {
            invocations,
            idempotency_entries,
            streams: stream_events,
        })
    }

    /// Publish directly to the engine stream store.
    pub async fn publish_stream_event(&self, event: PublishStreamEvent) -> Result<StreamCursor> {
        let store = self.inner.lock().await.primitives.streams.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("stream store lock poisoned".to_owned()))?
            .publish(event)
    }

    /// Return the latest stream cursor for one topic.
    pub async fn latest_stream_cursor(&self, topic: &str) -> Result<StreamCursor> {
        let store = self.inner.lock().await.primitives.streams.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("stream store lock poisoned".to_owned()))?
            .latest_cursor(topic)
    }

    /// Poll an engine stream topic from an explicit cursor without creating a
    /// durable subscription. Callers own cursor persistence; authenticated
    /// transports keep live-subscription lifecycle in connection state.
    pub(crate) async fn poll_stream_topic(
        &self,
        topic: &str,
        after: StreamCursor,
        limit: usize,
        actor: &StreamActorScope,
    ) -> Result<EngineStreamPage> {
        let store = self.inner.lock().await.primitives.streams.clone();
        store
            .lock()
            .map_err(|_| EngineError::HandlerFailed("stream store lock poisoned".to_owned()))?
            .poll_topic(topic, after, limit, actor)
    }
}
