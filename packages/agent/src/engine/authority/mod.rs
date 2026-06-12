//! Engine authority ownership: grants, leases, and compensation records.
//!
//! ## Submodules
//!
//! | Module | Responsibility |
//! |--------|----------------|
//! | `compensation` | Append-only compensation audit records for resource-changing invocations. |
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
//! - Grants with `remainingInvocations` consume one durable budget unit after
//!   idempotency replay/schema checks and before handler dispatch; replayed
//!   idempotency results do not consume again.
//! - Lease state has active/released/expired transitions enforced by the store.
//! - Compensation is audit-only durable state in this branch: the only accepted
//!   status is `recorded`, and future automated rollback must add a new owner,
//!   status transitions, and tests instead of overloading the audit record.
//! - SQLite-backed authority stores apply shared storage pragmas and validate
//!   the shared storage schema before grant, lease, or compensation tables are
//!   used.
//!
//! ## Test Ownership
//!
//! Authority behavior tests live under `engine/tests/authority`. Shared engine
//! fixtures live under `engine/tests/fixtures`.

pub mod compensation;
pub mod grants;
pub mod leases;
