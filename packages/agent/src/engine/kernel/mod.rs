//! Minimal engine-kernel contracts shared by every domain.
//!
//! | Module | Responsibility |
//! | --- | --- |
//! | [`errors`] | Stable engine failure categories and results. |
//! | [`ids`] | Validated identifiers for functions, workers, triggers, traces, and invocations. |
//! | [`policy`] | Registration, visibility, delivery, and routability checks. |
//! | [`schema`] | Enforced JSON Schema subset used before dispatch. |
//! | [`types`] | Core function, worker, invocation, and catalog records. |
//!
//! INVARIANT: schema keywords admitted by canonical function contracts are
//! executable validation rules here, never documentation-only annotations.
//! This includes schema-valued `additionalProperties`, which keeps dynamic
//! string maps and similar extensible objects typed at runtime, plus string
//! `pattern` constraints that reject malformed provider arguments pre-dispatch.

pub mod errors;
pub mod ids;
pub mod policy;
pub mod schema;
pub mod types;
