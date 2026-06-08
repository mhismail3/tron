//! Engine runtime ownership for external workers, worker protocol, and triggers.
//!
//! ## Submodules
//!
//! | Module | Responsibility |
//! |--------|----------------|
//! | `external_workers` | Loopback external-worker lifecycle, registration, invocation proxying, and health. |
//! | `triggers` | Trigger dispatch runtime, cascade bounds, and trigger metadata recording. |
//! | `worker_protocol` | `/engine/workers` protocol DTOs and scoped worker token model. |
//!
//! ## Entry Points
//!
//! `EngineExternalWorkerRuntime` manages connected local workers.
//! `EngineTriggerRuntime` dispatches registered triggers through the engine
//! host. Protocol DTOs are consumed by transport runtime code.
//!
//! ## Dependency Direction
//!
//! Runtime depends on the engine host, kernel contracts, durability stores, and
//! worker protocol DTOs. It does not depend on HTTP handlers, domains, app
//! bootstrap, or provider-specific model clients.
//!
//! ## Invariants
//!
//! - External workers are loopback/local and scoped by accepted worker tokens.
//! - Disconnected durable workers remain catalog truth but fail closed as
//!   unhealthy until reconnect.
//! - Trigger cascades carry explicit depth/path budgets.
//!
//! ## Test Ownership
//!
//! Runtime behavior tests live under `engine/tests/runtime`, with separate
//! modules for external workers, restart behavior, soak coverage, and triggers.

pub mod external_workers;
pub mod triggers;
pub mod worker_protocol;
