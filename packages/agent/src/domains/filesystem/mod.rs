//! Filesystem domain.
//!
//! This fixed product-infrastructure domain owns only the human-facing
//! workspace picker and new-session checkout placement: home discovery,
//! bounded directory browsing, hidden-entry visibility, folder creation,
//! bounded Git-repository inspection, and deterministic branch/worktree
//! preparation. Model and worker filesystem access belongs exclusively to the
//! worker kernel's direct host primitives.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `contract` | Four narrow `filesystem::*` workspace-picker contracts |
//! | `handlers` | Operation-key binding table |
//! | `service` | Hardened local filesystem reads/writes for selector UX |
//! | `source_control` | Bounded Git inspection and transactional session-checkout preparation |
//!
//! # INVARIANT: picker is product infrastructure, not a model toolbox
//!
//! This domain exposes exactly `filesystem::get_home`, `filesystem::list_dir`,
//! `filesystem::create_dir`, and `filesystem::inspect_source_control` for
//! authenticated client selection flows. It must never grow a parallel agent
//! filesystem or Git-management surface.

use std::path::PathBuf;

use crate::domains::registration::composition::{
    DomainFunctionRegistration, DomainRegistrationContext,
};
use crate::shared::foundation::paths;

pub(crate) mod contract;
mod handlers;
mod service;
pub(crate) mod source_control;

pub(crate) const WORKER: &str = "filesystem";
#[derive(Clone)]
pub(crate) struct Deps {
    home_dir: PathBuf,
}

impl Deps {
    pub(crate) fn from_engine(_deps: &DomainRegistrationContext) -> Self {
        Self {
            home_dir: PathBuf::from(paths::home_dir()),
        }
    }

    #[cfg(test)]
    fn for_home(home_dir: PathBuf) -> Self {
        Self { home_dir }
    }
}

pub(crate) fn function_registrations(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<Vec<DomainFunctionRegistration>> {
    handlers::bind_functions(contract::function_definitions()?, Deps::from_engine(deps))
}

#[cfg(test)]
mod tests;
