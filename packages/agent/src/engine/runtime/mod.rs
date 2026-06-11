//! Engine runtime ownership for external workers, worker protocol, and triggers.
//!
//! ## Submodules
//!
//! | Module | Responsibility |
//! |--------|----------------|
//! | `external_workers` | Loopback external-worker lifecycle, governed activation binding, registration, invocation proxying, and health. |
//! | `triggers` | Trigger dispatch runtime, cascade bounds, and trigger metadata recording. |
//! | `worker_activation_bundle_vault` | Process-memory custody for one-shot activation bundle stdin handoff. |
//! | `worker_orchestration` | Governed direct-exec process supervision for already issued worker activations. |
//! | `worker_protocol` | `/engine/workers` protocol DTOs and scoped worker token model. |
//!
//! ## Entry Points
//!
//! `EngineExternalWorkerRuntime` manages connected local workers.
//! `EngineTriggerRuntime` dispatches registered triggers through the engine
//! host. Activation tokens bind reviewed capability-definition governance to a
//! volatile worker connection. Activation bundles may be held only in the
//! in-memory vault until a reviewed launch consumes them into child stdin.
//! Worker orchestration may start a reviewed local process for an already issued
//! activation, but readiness still comes only from the external-worker
//! hello/register path. Protocol DTOs are consumed by transport runtime code.
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
//! - Visible external workers must bind session/workspace scope in the scoped
//!   token, present an active grant at the token revision, and keep namespace,
//!   trigger, stream, and result ownership inside the accepted connection.
//! - Governed activation workers must match the activation resource, token
//!   fingerprint, governance fingerprint, expected function, exact namespace,
//!   volatile mode, and session/workspace scope before registration.
//! - Orchestrated workers use direct executable invocation only, have no
//!   scheduler/restart ownership, and record redacted `worker_process` audit
//!   resources before any readiness is trusted.
//! - Activation bundles are never durable runtime state; the vault is
//!   process-memory only, TTL-bound, and one-shot.
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
pub mod worker_activation_bundle_vault;
pub mod worker_orchestration;
pub mod worker_protocol;
