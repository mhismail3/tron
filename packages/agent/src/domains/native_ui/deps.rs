//! Narrow dependencies for the native UI domain.

use std::collections::BTreeMap;
use std::sync::{Arc, RwLock};

use crate::domains::agent::r#loop::profile_runtime::ProfileRuntime;
use crate::domains::registration::worker::DomainRegistrationContext;
use crate::domains::session::event_store::EventStore;
use crate::engine::EngineHostHandle;

use super::model::ClientCatalog;
use super::store::NativeUIStore;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) engine_host: EngineHostHandle,
    pub(super) event_store: Arc<EventStore>,
    pub(super) profile_runtime: Arc<ProfileRuntime>,
    pub(super) store: NativeUIStore,
    pub(super) client_catalogs: Arc<RwLock<BTreeMap<String, ClientCatalog>>>,
    /// Connection-independent surface ordering. A reconstruction establishes a
    /// new snapshot barrier; live records after that barrier remain strictly
    /// monotonic for each logical surface for the lifetime of the server.
    pub(super) surface_sequences: Arc<RwLock<BTreeMap<String, u64>>>,
    /// Serializes snapshot projection/barrier capture with stream publication.
    /// Without this boundary a snapshot could capture old data but a newer
    /// sequence, causing the client to discard the update that repairs it.
    pub(super) surface_publication: Arc<tokio::sync::Mutex<()>>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> crate::engine::Result<Self> {
        let storage_path = deps.engine_host.storage_path_for_setup()?;
        let store = NativeUIStore::open(storage_path.as_deref()).map_err(|error| {
            crate::engine::EngineError::HandlerFailed(format!(
                "failed to initialize native UI store: {error}"
            ))
        })?;
        Ok(Self {
            engine_host: deps.engine_host.clone(),
            event_store: deps.event_store.clone(),
            profile_runtime: deps.profile_runtime.clone(),
            store,
            client_catalogs: Arc::new(RwLock::new(BTreeMap::new())),
            surface_sequences: Arc::new(RwLock::new(BTreeMap::new())),
            surface_publication: Arc::new(tokio::sync::Mutex::new(())),
        })
    }
}
