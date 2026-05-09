//! Domain-specific dependency bundle for the transcription worker.

use crate::domains::worker::DomainRegistrationContext;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) transcription_engine:
        Arc<std::sync::OnceLock<Arc<crate::domains::transcription::MlxEngine>>>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            transcription_engine: deps.transcription_engine.clone(),
        }
    }
}
