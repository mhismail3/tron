//! Primitive store backends.
//!
//! The fixed kernel retains only scoped state and streams; worker bundles and
//! operational ledgers own adaptation state.

use std::sync::{Arc, Mutex as StdMutex};

use serde_json::Value;

use crate::engine::durability::state::{
    EngineStateEntry, EngineStateScope, InMemoryEngineStateStore, SqliteEngineStateStore,
};
use crate::engine::durability::streams::{
    EngineStreamPage, InMemoryEngineStreamStore, PublishStreamEvent, SqliteEngineStreamStore,
    StreamActorScope, StreamCursor,
};
use crate::engine::kernel::errors::Result;

pub(in crate::engine) enum StreamStoreBackend {
    InMemory(InMemoryEngineStreamStore),
    Sqlite(SqliteEngineStreamStore),
}

impl StreamStoreBackend {
    pub(in crate::engine) fn publish(&mut self, event: PublishStreamEvent) -> Result<StreamCursor> {
        match self {
            Self::InMemory(store) => store.publish(event),
            Self::Sqlite(store) => store.publish(event),
        }
    }

    pub(in crate::engine) fn latest_cursor(&self, topic: &str) -> Result<StreamCursor> {
        match self {
            Self::InMemory(store) => Ok(store.latest_cursor(topic)),
            Self::Sqlite(store) => store.latest_cursor(topic),
        }
    }

    pub(in crate::engine) fn poll_topic(
        &self,
        topic: &str,
        after: StreamCursor,
        limit: usize,
        actor: &StreamActorScope,
    ) -> Result<EngineStreamPage> {
        match self {
            Self::InMemory(store) => store.poll_topic(topic, after, limit, actor),
            Self::Sqlite(store) => store.poll_topic(topic, after, limit, actor),
        }
    }

    pub(in crate::engine) fn list_by_session(
        &self,
        session_id: &str,
    ) -> Result<Vec<crate::engine::durability::streams::EngineStreamEvent>> {
        match self {
            Self::InMemory(store) => store.list_by_session(session_id),
            Self::Sqlite(store) => store.list_by_session(session_id),
        }
    }
}

pub(in crate::engine) enum StateStoreBackend {
    InMemory(InMemoryEngineStateStore),
    Sqlite(SqliteEngineStateStore),
}

impl StateStoreBackend {
    pub(in crate::engine) fn get(
        &self,
        scope: EngineStateScope,
        namespace: &str,
        key: &str,
    ) -> Result<Option<EngineStateEntry>> {
        match self {
            Self::InMemory(store) => store.get(scope, namespace, key),
            Self::Sqlite(store) => store.get(scope, namespace, key),
        }
    }

    pub(in crate::engine) fn set(
        &mut self,
        scope: EngineStateScope,
        namespace: String,
        key: String,
        value: Value,
    ) -> Result<EngineStateEntry> {
        match self {
            Self::InMemory(store) => store.set(scope, namespace, key, value),
            Self::Sqlite(store) => store.set(scope, namespace, key, value),
        }
    }

    pub(in crate::engine) fn delete(
        &mut self,
        scope: EngineStateScope,
        namespace: &str,
        key: &str,
    ) -> Result<bool> {
        match self {
            Self::InMemory(store) => store.delete(scope, namespace, key),
            Self::Sqlite(store) => store.delete(scope, namespace, key),
        }
    }

    pub(in crate::engine) fn list(
        &self,
        scope: EngineStateScope,
        namespace: &str,
        key_prefix: Option<&str>,
        limit: usize,
    ) -> Result<Vec<EngineStateEntry>> {
        match self {
            Self::InMemory(store) => store.list(scope, namespace, key_prefix, limit),
            Self::Sqlite(store) => store.list(scope, namespace, key_prefix, limit),
        }
    }
}

/// Engine primitive store bundle.
#[derive(Clone)]
pub(in crate::engine) struct PrimitiveStores {
    pub(in crate::engine) streams: Arc<StdMutex<StreamStoreBackend>>,
    pub(in crate::engine) state: Arc<StdMutex<StateStoreBackend>>,
}

impl PrimitiveStores {
    pub(in crate::engine) fn in_memory() -> Self {
        Self {
            streams: Arc::new(StdMutex::new(StreamStoreBackend::InMemory(
                InMemoryEngineStreamStore::new(),
            ))),
            state: Arc::new(StdMutex::new(StateStoreBackend::InMemory(
                InMemoryEngineStateStore::new(),
            ))),
        }
    }

    pub(in crate::engine) fn sqlite(path: &std::path::Path) -> Result<Self> {
        Ok(Self {
            streams: Arc::new(StdMutex::new(StreamStoreBackend::Sqlite(
                SqliteEngineStreamStore::open(path)?,
            ))),
            state: Arc::new(StdMutex::new(StateStoreBackend::Sqlite(
                SqliteEngineStateStore::open(path)?,
            ))),
        })
    }
}
