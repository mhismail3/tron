//! Durability subsystem tests.

pub(in crate::engine::tests) use super::fixtures::*;

mod ledger_idempotency;
mod materialized_files;
mod queue_inspection_persistence;
mod queue_lifecycle;
mod resource_contracts;
mod resource_output_contracts;
mod resource_wrappers;
mod sqlite_storage_discipline;
mod state_primitives;
mod streams;
