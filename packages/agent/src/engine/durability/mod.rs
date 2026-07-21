//! Engine durability ownership: ledger, state, and streams.
//!
//! ## Submodules
//!
//! | Module | Responsibility |
//! |--------|----------------|
//! | `ledger` | Invocation, idempotency, and catalog-change truth. |
//! | `replay` | Read-only session replay snapshot DTOs for engine-owned rows. |
//! | `state` | Scoped kernel key-value state for runtime overlays. |
//! | `streams` | Durable stream events read through caller-owned cursors. |
//!
//! ## Entry Points
//!
//! Store types are re-exported by `engine` for host construction. Runtime
//! access flows through `EngineHost` or primitive handlers, not through
//! transport or domain code reaching into store internals.
//!
//! ## Dependency Direction
//!
//! Durability depends on kernel ids/types, invocation records, validation, and
//! SQLite storage helpers. It does not depend on app, transport, provider, or
//! domain runtimes.
//!
//! ## Invariants
//!
//! - Durable records are source of truth, not projections over stream logs.
//! - Invocation and idempotency result records are credential-redacted copies;
//!   the live caller result is not the durable audit representation.
//! - SQLite codecs stay inside the store owner that persists the row shape.
//! - SQLite-backed durability constructors apply shared storage pragmas and
//!   validate the shared storage schema before owner-specific tables are used.
//! - Large JSON payloads are stored through shared storage payload refs with an
//!   explicit owner kind/owner id/field/retention class, so retention,
//!   checkpoints, and exports stay owned by the shared storage runtime instead
//!   of individual engine stores.
//!
//! ## Test Ownership
//!
//! Durability behavior tests live under `engine/tests/durability`, split by
//! ledger and state/stream behavior.

pub mod ledger;
pub(crate) mod replay;
pub mod state;
pub mod streams;
