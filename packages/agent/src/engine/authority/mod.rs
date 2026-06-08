//! Engine authority ownership: grants, leases, and compensation records.
//!
//! ## Submodules
//!
//! | Module | Responsibility |
//! |--------|----------------|
//! | `compensation` | Compensation records and rollback audit state for resource-changing invocations. |
//! | `grants` | Durable authority grants, grant derivation, and invocation authorization. |
//! | `leases` | Resource lease acquisition and release for shared-state mutation. |
//!
//! ## Entry Points
//!
//! The engine root re-exports authority store types for host construction.
//! Runtime callers enter through `EngineHost` and `EngineHostHandle`, which
//! resolve grants and leases before handlers run.
//!
//! ## Dependency Direction
//!
//! Authority depends on kernel ids/types, invocation records, and SQLite codecs.
//! It does not depend on transports, domains, provider clients, or app startup.
//!
//! ## Invariants
//!
//! - Caller-supplied authority scopes are audit context, not permission truth.
//! - Grants are resolved from the engine-owned store before execution.
//! - Lease/compensation state records inspectable mutation ownership.
//!
//! ## Test Ownership
//!
//! Authority behavior tests live under `engine/tests/authority`. Shared engine
//! fixtures live under `engine/tests/fixtures`.

pub mod compensation;
pub mod grants;
pub mod leases;
