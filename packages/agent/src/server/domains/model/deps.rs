//! Domain-specific dependency bundle for the model worker.

use super::*;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) auth_path: PathBuf,
    pub(super) server_context: Arc<ServerCapabilityContext>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainSetupContext) -> Self {
        Self {
            auth_path: deps.auth_path.clone(),
            server_context: deps.server_context.clone(),
        }
    }
}
