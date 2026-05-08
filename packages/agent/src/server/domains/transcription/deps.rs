//! Domain-specific dependency bundle for the transcription worker.

use super::*;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) transcription_engine: Arc<std::sync::OnceLock<Arc<crate::transcription::MlxEngine>>>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainSetupContext) -> Self {
        Self {
            transcription_engine: deps.transcription_engine.clone(),
        }
    }
}
