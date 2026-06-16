//! Domain-specific dependency bundle for the transcription worker.

use std::sync::Arc;

use crate::domains::agent::r#loop::profile_runtime::ProfileRuntime;
use crate::domains::registration::worker::DomainRegistrationContext;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) transcription_engine: crate::domains::transcription::SharedTranscriptionEngine,
    pub(super) profile_runtime: Arc<ProfileRuntime>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            transcription_engine: deps.transcription_engine.clone(),
            profile_runtime: deps.profile_runtime.clone(),
        }
    }
}
