//! Engine type contracts grouped by kernel concern.
//!
//! `catalog` owns revision counters, function admission, stream delivery,
//! and health; `function` owns executable definitions and their
//! two concrete idempotency extents. These are deliberately distinct types:
//! catalog admission, duplicate suppression, and event delivery are unrelated
//! runtime decisions and must not grow back into a generic authority scope.
//! Persistent worker bundles and lifecycle state belong to
//! `domains::worker_kernel`.

mod catalog;
mod function;

pub use catalog::{
    CatalogRevision, FunctionHealth, FunctionRevision, FunctionVisibility, StreamVisibility,
};
pub use function::FunctionDefinition;
pub use function::{
    DedupeScope, EffectClass, IdempotencyContract, IdempotencyScope, ReplayBehavior, RiskLevel,
};
