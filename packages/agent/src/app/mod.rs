//! Application bootstrap and process lifecycle shell.
//!
//! `app` owns process startup, server assembly, health endpoints, onboarding
//! state, and shutdown coordination. It wires owners together; it does not own
//! domain behavior or engine execution policy.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | [`cli`] | Terminal parsing/dispatch with concern-owned notification-auth, OAuth, and snapshot commands |
//! | [`browser_operator`] | Closed Chrome Native Messaging actuator with separate protocol and lifecycle owners |
//! | [`bootstrap`] | Runtime assembly, service initialization, database open, and server bind |
//! | [`health`] | Health/metrics endpoints and disk checks |
//! | `legacy_archive` | Verified meaningful-data archive and receipt-backed offline minimal-core reset |
//! | [`lifecycle`] | Onboarding, bearer-token state, and shutdown coordination |
//!
//! ## Entry Points
//!
//! - [`bootstrap::run`] is the binary-owned startup entry after `main.rs`
//!   parses [`cli::Cli`].
//! - [`bootstrap::server::TronServer`] owns the Axum router, runtime context,
//!   shutdown handle and engine client registry.
//! - [`health::health_check`] and [`health::deep_health_check`] provide the
//!   liveness/readiness probes used by wrappers, scripts, and CI.
//! - [`lifecycle::shutdown::ShutdownCoordinator`] is the shared shutdown token
//!   and task-drain boundary.
//!
//! ## Invariants
//!
//! - App code wires engine, domain workers, transports, health, metrics,
//!   onboarding, and shutdown; executable domain work belongs to `domains::*`
//!   workers and engine primitives.
//! - Startup opens storage, applies runtime schema/pragmas, registers retained
//!   workers, and only then binds the server.
//! - Bearer-token and onboarded-marker paths come from shared path helpers; app
//!   bootstrap must not invent alternate data roots.
//! - Shutdown is signal-owned and drain-aware so managed worker/runtime tasks
//!   stop before the process exits.
//! - CLI concerns share one parser and dispatcher; credential and snapshot
//!   modules never create a second command registry.
//! - The browser host has one socket owner. Protocol validation does not start
//!   lifecycle tasks, and lifecycle helpers do not interpret browser actions.
//! - Authority-empty code evaluation re-enters the exact installed Tron binary
//!   through one hidden helper mode. There is no separately packaged helper
//!   binary whose signature or protocol version can drift from the server.
//!
//! ## Test Ownership
//!
//! `bootstrap/tests.rs` owns server assembly, route shape, startup ordering,
//! and shutdown behavior. Submodule-local unit tests own pure health,
//! onboarding, disk, and shutdown helpers. Cross-process or database path
//! assertions belong in integration/static targets under `packages/agent/tests/`.

pub mod bootstrap;
pub(crate) mod browser_operator;
pub mod cli;
pub mod health;
pub(crate) mod legacy_archive;
pub mod lifecycle;
