//! Domain-specific dependency bundle for the codex_app worker.

use crate::server::domains::worker::DomainRegistrationContext;
use crate::server::platform::codex_app::CodexAppServerManager;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) codex_app_server: Option<Arc<CodexAppServerManager>>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            codex_app_server: deps.codex_app_server.clone(),
        }
    }
}
