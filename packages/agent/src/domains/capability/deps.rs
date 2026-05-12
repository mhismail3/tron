//! Domain-specific dependency bundle for the capability worker.

use std::sync::Arc;

use super::embeddings::{EmbeddingProvider, default_embedding_provider};
use super::registry::{SharedCapabilityRegistryStore, open_capability_registry_store};
use crate::domains::worker::DomainRegistrationContext;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) engine_host: crate::engine::EngineHostHandle,
    pub(crate) registry_store: SharedCapabilityRegistryStore,
    pub(crate) embedding_provider: Arc<dyn EmbeddingProvider>,
    pub(crate) profile_runtime: Arc<crate::domains::agent::runner::profile_runtime::ProfileRuntime>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        let storage_path = deps
            .engine_host
            .storage_path_for_setup()
            .expect("engine host storage path must be readable during capability setup");
        Self {
            engine_host: deps.engine_host.clone(),
            registry_store: open_capability_registry_store(storage_path)
                .expect("capability registry store must open"),
            embedding_provider: default_embedding_provider(),
            profile_runtime: deps.profile_runtime.clone(),
        }
    }
}
