//! Engine type contracts grouped by kernel concern.
//!
//! `catalog` owns revision counters, visibility, provenance, and change
//! metadata; `worker`, `function`, and `trigger` own the catalog definitions
//! for those concrete subjects.

mod catalog;
mod function;
mod trigger;
mod worker;

pub use catalog::{
    CatalogChange, CatalogChangeClass, CatalogChangeKind, CatalogRevision, CatalogSubjectKind,
    FunctionHealth, FunctionRevision, Provenance, TriggerRevision, VisibilityScope, WorkerRevision,
};
pub use function::FunctionDefinition;
pub use function::{
    AuthorityRequirement, CompensationContract, CompensationKind, DeliveryMode,
    DurableOutputContract, EffectClass, IdempotencyContract, IdempotencyKeySource,
    IdempotencyScope, LedgerKind, ReplayBehavior, ResourceLeaseFailureBehavior,
    ResourceLeaseRequirement, RiskLevel,
};
pub use trigger::{TriggerDefinition, TriggerTypeDefinition};
pub use worker::{WorkerDefinition, WorkerKind, WorkerLifecycleState};
