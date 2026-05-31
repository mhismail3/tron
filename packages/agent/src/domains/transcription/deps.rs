//! Domain-specific dependency bundle for the transcription worker.

use crate::domains::worker::DomainRegistrationContext;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) transcription_engine: crate::domains::transcription::SharedTranscriptionEngine,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            transcription_engine: deps.transcription_engine.clone(),
        }
    }
}
