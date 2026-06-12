//! Engine durability ownership: ledger, queue, resources, state, and streams.
//!
//! ## Submodules
//!
//! | Module | Responsibility |
//! |--------|----------------|
//! | `ledger` | Invocation, idempotency, catalog-change, and worker restart truth. |
//! | `queue` | Durable at-least-once invocation handoff and retry lifecycle. |
//! | `replay` | Read-only session replay snapshot DTOs for engine-owned rows. |
//! | `resources` | Typed resource, version, link, event, and UI-surface substrate. |
//! | `state` | Scoped primitive key-value state with compare-and-set revisioning. |
//! | `streams` | Durable stream events, cursors, and subscriptions. |
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
//! domain workers.
//!
//! ## Invariants
//!
//! - Durable records are source of truth, not projections over stream logs.
//! - Queue attempts and resource versions retain causality and trace identity.
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
//! ledger, queue/state/stream, resource contracts, materialized files, and
//! wrapper resources.

pub mod ledger;
pub mod queue;
pub(crate) mod replay;
pub mod resources;
pub mod state;
pub mod streams;
