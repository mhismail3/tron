//! Minimal engine-kernel contracts shared by every domain.
//!
//! | Module | Responsibility |
//! | --- | --- |
//! | [`errors`] | Stable engine failure categories and results. |
//! | [`ids`] | Validated identifiers for functions, workers, traces, invocations, and resources. |
//! | [`policy`] | Kernel-level policy value types. |
//! | [`schema`] | Enforced JSON Schema subset used before authority derivation and dispatch. |
//! | [`types`] | Core invocation, resource, grant, and catalog records. |
//!
//! INVARIANT: schema keywords admitted by canonical capability contracts are
//! executable validation rules here, never documentation-only annotations.

pub mod errors;
pub mod ids;
pub mod policy;
pub mod schema;
pub mod types;
