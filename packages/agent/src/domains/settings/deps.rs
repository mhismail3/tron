//! Domain-specific dependency bundle for the settings worker.

use crate::domains::registration::composition::DomainRegistrationContext;
use crate::domains::settings::SettingsRuntime;
use std::path::PathBuf;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) settings_runtime: Arc<SettingsRuntime>,
    pub(super) settings_path: PathBuf,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            settings_runtime: deps.settings_runtime.clone(),
            settings_path: deps.settings_path.clone(),
        }
    }
}
