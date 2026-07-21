//! Engine type contracts grouped by kernel concern.
//!
//! `catalog` owns revision counters, function admission, stream delivery,
//! and health; `function` owns executable definitions and their
//! two concrete idempotency extents. These are deliberately distinct types:
//! catalog admission, duplicate suppression, and event delivery are unrelated
//! runtime decisions and must not grow back into a generic authority scope.
//! Provider projection is likewise a closed typed model/worker contract; a
//! generic function-metadata escape hatch is intentionally absent.
//! The live catalog is rebuildable and its definitions are not a persistence
//! or wire format; only types embedded in real durable records implement serde.
//! Persistent worker bundles and lifecycle state belong to
//! `domains::worker_kernel`.

mod catalog;
mod function;

pub use catalog::{
    CatalogRevision, FunctionHealth, FunctionRevision, FunctionVisibility, StreamVisibility,
};
pub use function::FunctionDefinition;
pub use function::{
    DedupeScope, DirectWorkerToolContract, EffectClass, IdempotencyContract, IdempotencyScope,
    ModelToolContract, ReplayBehavior, RiskLevel,
};
