//! Engine test suite organized by substrate concern.
//!
//! Keep new engine tests in one of the focused modules below. This file should
//! stay limited to module declarations and shared fixture re-exports.

mod support;

pub(in crate::engine::tests) use support::*;

mod approval;
mod catalog_discovery;
mod domain_outputs;
mod external_worker;
mod generated_ui;
mod grant_authority;
mod host_invocation;
mod ids_types;
mod leases_compensation;
mod ledger_idempotency;
mod meta_primitives;
mod module_activation;
mod prompt_library_resources;
mod resource_kernel;
mod state_queue;
mod streams;
mod triggers;
