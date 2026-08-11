//! Minimal trusted-local host primitives.
//!
//! This domain owns the four general host operations that remain in Tron's
//! minimal model surface: [`read`](contract::READ_FUNCTION),
//! [`write`](contract::WRITE_FUNCTION), [`edit`](contract::EDIT_FUNCTION), and
//! [`bash`](contract::BASH_FUNCTION). Directory inspection is a mode of
//! `read`; search, Git, HTTP clients, transforms, and pipelines are composed
//! through Bash or the sandboxed code runtime instead of receiving one fixed
//! schema each.
//!
//! ## Transitional custody
//!
//! The handlers currently reuse the proven bounded I/O, atomic publication,
//! process-tree, and workspace-claim implementation while that custody moves
//! out of `worker_kernel`. Provider contracts and routing are owned here now;
//! no Worker model primitive aliases are projected.
//!
//! ## Invariants
//!
//! - Relative paths resolve from trusted causal working-directory context.
//! - File and directory reads remain bounded and deterministic.
//! - Writes and edits preserve compare-and-swap and atomic same-directory
//!   publication.
//! - Bash is an explicit trusted-host escape, not a sandbox. It retains bounded
//!   stdin/output/deadline and durable process-tree cancellation.

use std::sync::Arc;

use crate::domains::registration::composition::{
    DomainFunctionRegistration, DomainRegistrationContext,
};
use crate::domains::worker_kernel::WorkerRuntime;

pub(crate) mod contract;
mod handlers;
pub(crate) mod process_custody;

#[derive(Clone)]
pub(crate) struct Deps {
    runtime: Arc<WorkerRuntime>,
}

pub(crate) fn function_registrations(
    _deps: &DomainRegistrationContext,
    runtime: Arc<WorkerRuntime>,
) -> crate::engine::Result<Vec<DomainFunctionRegistration>> {
    handlers::bind_functions(contract::function_definitions()?, Deps { runtime })
}

#[cfg(test)]
mod tests;
