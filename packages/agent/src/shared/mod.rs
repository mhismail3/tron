//! Cross-owner foundation, protocol, server, storage, and observability code.
//!
//! Shared code exists only when multiple owners need the same primitive. If a
//! helper is app-, transport-, engine-, or domain-specific, it belongs with that
//! owner instead of here.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | [`foundation`] | Constants, IDs, paths, profile specs, retry/text helpers, and shared errors |
//! | [`protocol`] | Public DTOs for content, events, messages, memory, and model capability data |
//! | [`server`] | Transport-neutral runtime context, validation, params, and capability errors |
//! | [`storage`] | SQLite storage helpers used by engine, session, logs, and runtime surfaces |
//! | [`observability`] | Tracing/log persistence transport and test capture helpers |
//!
//! ## Entry Points
//!
//! - [`foundation::paths`] and [`foundation::profile`] own filesystem/profile
//!   source truth shared by app, domains, iOS/Mac parity checks, and tests.
//! - [`server::context::ServerRuntimeContext`] is the transport-neutral handle
//!   bundle passed into retained domains and runtime services.
//! - [`storage::StorageRuntime`] owns database startup maintenance,
//!   checkpoint/export/stats/retention helpers, and payload blob helpers.
//! - [`observability::init_subscriber`] and
//!   [`observability::init_subscriber_with_sqlite`] own tracing setup.
//!
//! ## Invariants
//!
//! - Shared modules must be used by multiple owners.
//! - Shared protocol types are DTOs and neutral content/event shapes, not
//!   product policy or transport behavior.
//! - Storage helpers expose reusable primitives; domain-specific schema and
//!   lifecycle rules stay with their domain or engine store owner.
//! - Test-only fixtures remain behind explicit test-support modules and must
//!   not become production dependency shortcuts.
//!
//! ## Test Ownership
//!
//! Shared helper tests live in the owning submodule (`foundation/*/tests`,
//! `protocol/*/tests`, `storage/tests.rs`, and observability test utilities).
//! Cross-owner path/privacy/static checks belong in integration targets under
//! `packages/agent/tests/`.

#![deny(unsafe_code)]

pub mod foundation;
pub mod observability;
pub mod protocol;
pub mod server;
pub mod storage;
