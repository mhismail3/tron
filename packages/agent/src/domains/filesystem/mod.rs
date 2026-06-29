//! Filesystem domain.
//!
//! This domain owns two deliberately separate surfaces:
//!
//! - the human-facing workspace picker subset: home discovery, bounded
//!   directory browsing, hidden entry visibility, and folder creation;
//! - the Phase 2 filesystem agent toolbox: bounded read/list/find/glob/search,
//!   diff, write preview/commit, and exact-text patch application under the
//!   trusted working-directory root.
//!
//! The toolbox is not a retired-surface resurrection. It consumes existing engine
//! primitives for authority roots, resources, idempotency, leases,
//! compensation, streams, traces, and replay evidence. Phase 3 Slice 24A
//! declares the existing agent toolbox operations in the pending-review
//! `file_git_module` manifest and derives exact filesystem/resource authority
//! for them without adding new provider-visible tools.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `agent_tools` | Agent filesystem toolbox with path authority and evidence |
//! | `contract` | Narrow `filesystem::*` workspace-browser contracts |
//! | `handlers` | Operation-key binding table |
//! | `service` | Hardened local filesystem reads/writes for selector UX |
//!
//! # INVARIANT: picker and toolbox stay separated
//!
//! This domain may expose `filesystem::get_home`, `filesystem::list_dir`, and
//! `filesystem::create_dir` for authenticated iOS UI selection flows. Agent
//! file tools must resolve paths only from trusted runtime working-directory
//! metadata, reject traversal and symlink escapes, bound all reads/searches, and
//! return resource-backed evidence for mutating previews/commits.

use std::path::PathBuf;

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};
use crate::shared::foundation::paths;

mod agent_support;
pub(crate) mod agent_tools;
pub(crate) mod contract;
mod handlers;
mod service;

pub(crate) const WORKER: &str = "filesystem";
pub(crate) const FILESYSTEM_LIFECYCLE_TOPIC: &str = "filesystem.lifecycle";
pub(crate) const READ_SCOPE: &str = "filesystem.read";
pub(crate) const WRITE_SCOPE: &str = "filesystem.write";
const STREAM_TOPICS: &[&str] = &[FILESYSTEM_LIFECYCLE_TOPIC];

#[derive(Clone)]
pub(crate) struct Deps {
    home_dir: PathBuf,
    engine_host: crate::engine::EngineHostHandle,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            home_dir: PathBuf::from(paths::home_dir()),
            engine_host: deps.engine_host.clone(),
        }
    }

    #[cfg(test)]
    fn for_home(home_dir: PathBuf) -> Self {
        Self {
            home_dir,
            engine_host: crate::engine::EngineHostHandle::new_in_memory()
                .expect("test engine host"),
        }
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
