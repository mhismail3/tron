//! Durable, broker-only TypeScript execution for persistent agents.
//!
//! This module is intentionally not registered as a provider tool yet. It is
//! the engine-owned substrate behind a future small `code` surface: TypeScript
//! is stripped with Oxc, evaluated in a capability-empty QuickJS context, and
//! every accepted cell plus broker effect is journaled before the result can be
//! observed. A runtime is logical rather than a long-lived heap. Rehydration
//! recompiles the immutable successful-cell journal as one program, so
//! top-level lexical bindings and top-level `await` survive process restarts.
//!
//! ## Modules
//!
//! | Module | Responsibility |
//! |---|---|
//! | [`compiler`] | TypeScript validation and deterministic type stripping |
//! | [`evaluator`] | Authority-free QuickJS context and frozen broker SDK |
//! | [`store`] | Runtime, cell, call, and audit persistence in `tron.sqlite` |
//! | [`process_evaluator`] | Disposable helper custody and nested-call replay |
//! | [`service`] | Idempotent `run`, `inspect`, and manual `reset` operations |
//! | [`services`] | Closed fixed native-service registry and owner boundary |
//! | [`skills`] | Profile/project skill discovery and digest-pinned modules |
//! | [`state`] | Per-capability SQLite state with SQL authorization |
//! | [`helper`] | Versioned stdio helper protocol for process isolation |
//!
//! # Invariants
//!
//! - No filesystem, environment, network, process, credential, or module-loader
//!   authority exists inside QuickJS. All effects cross the versioned broker.
//! - Only successful cells enter the replay program. Failed/cancelled/timed-out
//!   cells remain audit evidence but cannot change later lexical state.
//! - A replayed broker call must match its original operation and canonical
//!   request hash exactly; divergence stops execution.
//! - Journal consolidation is explicit. Automatic heap snapshots are forbidden
//!   because they cannot prove replay equivalence.
//! - Skill code is resolved below an admitted root, content-digest pinned for a
//!   call, and receives only the same frozen broker SDK.

mod broker;
mod compiler;
mod evaluator;
pub mod helper;
mod process_evaluator;
mod service;
mod services;
mod skills;
mod state;
mod store;
mod types;

pub use compiler::{CompiledSource, SourceKind, compile_typescript};
pub use evaluator::{Broker, BrokerError, EvaluationLimits, NoopBroker};
pub use process_evaluator::{AsyncBroker, CodeHelper, RejectingAsyncBroker};
pub use service::{CodeRuntimeError, CodeRuntimeService};
pub use services::{
    FixedService, FixedServiceDescriptor, FixedServiceError, FixedServiceId,
    FixedServiceInvocation, FixedServiceRegistry,
};
pub use skills::{
    ResolvedSkillModule, SkillCatalog, SkillDescriptor, SkillInvocationResult, SkillOrigin,
    SkillPage, SkillSummary,
};
pub use state::{
    CapabilityState, StateEffect, StateEffectResult, StateError, StateInfo, StateQuery,
    StateStatement,
};
pub use types::{CellStatus, CodeInspect, CodeReset, CodeRunRequest, CodeRunResult, RuntimeLimits};

#[cfg(test)]
mod tests;
