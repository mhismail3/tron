//! Engine test suite organized by substrate concern.
//!
//! Keep new engine tests in one of the focused modules below. This file should
//! stay limited to module declarations and shared fixture re-exports.

mod support;

pub(in crate::engine::tests) use support::*;

mod catalog_discovery;
mod external_worker;
mod external_worker_soak;
mod grant_authority;
mod host_invocation;
mod idempotency;
mod ids_types;
mod ledger_idempotency;
mod meta_primitives;
mod resource_kernel;
mod restart_chaos;
mod state_queue;
mod streams;
mod triggers;
