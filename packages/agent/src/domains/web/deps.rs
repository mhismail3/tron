//! Domain-specific dependency bundle for the web worker.

use std::path::PathBuf;

use crate::domains::worker::DomainRegistrationContext;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) client: reqwest::Client,
    pub(crate) auth_path: PathBuf,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            client: deps.tool_runtime.http_client.clone(),
            auth_path: deps.auth_path.clone(),
        }
    }
}
