//! Domain-specific dependency bundle for the auth worker.

use crate::server::domains::worker::DomainRegistrationContext;
use std::path::PathBuf;
use std::sync::Arc;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) auth_path: PathBuf,
    pub(super) engine_host: crate::engine::EngineHostHandle,
    pub(super) oauth_flows: Arc<
        tokio::sync::Mutex<
            std::collections::HashMap<
                String,
                crate::server::domains::auth::flows::PendingOAuthFlow,
            >,
        >,
    >,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            auth_path: deps.auth_path.clone(),
            engine_host: deps.engine_host.clone(),
            oauth_flows: deps.oauth_flows.clone(),
        }
    }
}
