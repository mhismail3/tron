//! Domain-specific dependency bundle for the settings worker.

use crate::domains::agent::runner::profile_runtime::ProfileRuntime;
use crate::domains::worker::DomainRegistrationContext;
use std::path::PathBuf;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) profile_runtime: Arc<ProfileRuntime>,
    pub(super) settings_path: PathBuf,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            profile_runtime: deps.profile_runtime.clone(),
            settings_path: deps.settings_path.clone(),
        }
    }
}
