//! Engine type contracts grouped by kernel concern.
//!
//! `catalog` owns revision counters, visibility, provenance, and change
//! metadata; `worker` and `function` own the concrete catalog definitions.

mod catalog;
mod function;
mod worker;

pub use catalog::{
    CatalogChange, CatalogChangeClass, CatalogChangeKind, CatalogRevision, CatalogSubjectKind,
    FunctionHealth, FunctionRevision, Provenance, VisibilityScope, WorkerRevision,
};
pub use function::FunctionDefinition;
pub use function::{
    DeliveryMode, EffectClass, IdempotencyContract, IdempotencyKeySource, IdempotencyScope,
    LedgerKind, ReplayBehavior, RiskLevel,
};
pub use worker::{WorkerDefinition, WorkerKind, WorkerLifecycleState};
