//! Domain-specific dependency bundle for the voice_notes worker.

use crate::domains::worker::DomainRegistrationContext;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) transcription_engine:
        Arc<std::sync::OnceLock<Arc<crate::domains::transcription::MlxEngine>>>,
    pub(super) engine_host: crate::engine::EngineHostHandle,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            transcription_engine: deps.transcription_engine.clone(),
            engine_host: deps.engine_host.clone(),
        }
    }
}
