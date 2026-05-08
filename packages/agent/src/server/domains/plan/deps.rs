//! Domain-specific dependency bundle for the plan worker.

use super::*;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(super) session_manager: Arc<SessionManager>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            session_manager: deps.session_manager.clone(),
        }
    }
}
