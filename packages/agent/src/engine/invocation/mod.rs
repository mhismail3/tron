//! Engine invocation ownership.
//!
//! This module owns the typed invocation request/result contracts and the
//! privileged host that dispatches engine functions, records durable outcomes,
//! and exposes invocation history to higher-level domains.
//!
//! ## Submodules
//!
//! | Module | Responsibility |
//! |--------|----------------|
//! | `host` | Catalog-backed invocation host, dispatch policy, recording, queue/stream/resource integration. |
//! | `model` | Invocation, causal context, result, and durable invocation record DTOs. |
//!
//! ## Entry Points
//!
//! `Invocation` is the executable request, `InvocationResult` is the handler
//! return value, and `InvocationRecord` is the durable ledger projection. Use
//! `InvocationRecord::from_result_at` when replay/import tests need a stable
//! completion timestamp; production dispatch uses `from_result`.
//!
//! ## Invariants
//!
//! - Invocation IDs and causal context are created before dispatch and copied
//!   into the durable record.
//! - Durable records preserve session/workspace/trace/idempotency references so
//!   replay manifests can explain why an invocation occurred.
//! - Production timestamps remain wall-clock values; deterministic tests and
//!   replay/import paths inject timestamps explicitly.

pub mod host;
pub mod model;
