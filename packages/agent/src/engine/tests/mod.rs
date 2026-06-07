//! Engine test suite organized by substrate concern.
//!
//! Keep new engine tests in one of the focused modules below. This file should
//! stay limited to module declarations and shared fixture re-exports.

mod support;

pub(in crate::engine::tests) use support::*;

mod catalog_discovery;
mod external_worker;
mod grant_authority;
mod host_invocation;
mod idempotency;
mod ids_types;
mod ledger_idempotency;
mod memory_retain_resources;
mod meta_primitives;
mod notification_resources;
mod productization_closeout;
mod prompt_library_resources;
mod resource_kernel;
mod restart_chaos;
mod state_queue;
mod streams;
mod subagent_lineage;
mod triggers;
