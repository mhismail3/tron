//! Filesystem domain.
//!
//! This fixed product-infrastructure domain owns only the human-facing
//! workspace picker: home discovery, bounded directory browsing, hidden-entry
//! visibility, and folder creation. Model and worker filesystem access belongs
//! exclusively to the worker kernel's direct host primitives.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `contract` | Three narrow `filesystem::*` workspace-browser contracts |
//! | `handlers` | Operation-key binding table |
//! | `service` | Hardened local filesystem reads/writes for selector UX |
//!
//! # INVARIANT: picker is product infrastructure, not a model toolbox
//!
//! This domain exposes exactly `filesystem::get_home`, `filesystem::list_dir`,
//! and `filesystem::create_dir` for authenticated client selection flows. It
//! must never grow a parallel agent filesystem surface.

use std::path::PathBuf;

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};
use crate::shared::foundation::paths;

pub(crate) mod contract;
mod handlers;
mod service;

pub(crate) const WORKER: &str = "filesystem";
const STREAM_TOPICS: &[&str] = &[];

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

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        WORKER,
        STREAM_TOPICS,
        handlers::function_registrations(contract::capabilities()?, Deps::from_engine(deps))?,
    )
}

#[cfg(test)]
mod tests;
