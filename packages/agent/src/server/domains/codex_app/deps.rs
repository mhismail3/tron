//! Domain-specific dependency bundle for the codex_app worker.

use super::*;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) codex_app_server: Option<Arc<CodexAppServerManager>>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainSetupContext) -> Self {
        Self {
            codex_app_server: deps.codex_app_server.clone(),
        }
    }
}
