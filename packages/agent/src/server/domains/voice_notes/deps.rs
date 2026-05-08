//! Domain-specific dependency bundle for the voice_notes worker.

use super::*;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) transcription_engine: Arc<std::sync::OnceLock<Arc<crate::transcription::MlxEngine>>>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            transcription_engine: deps.transcription_engine.clone(),
        }
    }
}
