//! Engine type contracts grouped by kernel concern.
//!
//! `catalog` owns revision counters, visibility, provenance, and change
//! metadata; `function` owns the executable catalog definition. Persistent
//! worker bundles and lifecycle state belong to `domains::worker_kernel`.

mod catalog;
mod function;

pub use catalog::{
    CatalogChange, CatalogChangeClass, CatalogChangeKind, CatalogRevision, CatalogSubjectKind,
    FunctionHealth, FunctionRevision, Provenance, VisibilityScope,
};
pub use function::FunctionDefinition;
pub use function::{EffectClass, IdempotencyContract, IdempotencyScope, ReplayBehavior, RiskLevel};
