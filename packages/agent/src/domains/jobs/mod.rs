//! Durable jobs and process lifecycle domain.
//!
//! This Slice 5A domain owns non-interactive local command jobs as durable
//! resources. It does not implement PTY sessions, interpreters, git, web,
//! subagents, scheduling, notifications, or native iOS panels.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `contract` | Job function contracts and schemas |
//! | `errors` | Domain-local error helpers |
//! | `handlers` | Operation-key binding table |
//! | `race_tests` | Test-only cancellation/finalization interleaving coverage |
//! | `runtime` | Bounded process spawning, output capture, and cancellation handles |
//! | `schema_tests` | Test-only resource/schema drift guards |
//! | `service` | Job resource lifecycle, status/list/log/cancel/cleanup behavior |
//! | `support` | Payload parsing, resource refs, scope, and stream helpers |
//! | `types` | Serializable job resource and output records |
//!
//! # INVARIANT: job lifecycle is package-owned
//!
//! The engine provides resources, streams, authority, traces, and replay. This
//! domain owns process-job semantics over those primitives. `process_run`
//! remains the short synchronous primitive; durable jobs are a separate
//! resource-backed lifecycle and must keep network policy fail-closed.

use std::sync::{Arc, LazyLock};

use crate::app::lifecycle::shutdown::{ShutdownCoordinator, ShutdownPhase};
use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};
pub(crate) use crate::engine::{JOB_PROCESS_KIND, JOB_PROCESS_SCHEMA_ID};

pub(crate) mod contract;
mod errors;
mod handlers;
mod runtime;
pub(crate) mod service;
mod support;
mod types;

pub(crate) const WORKER: &str = "jobs";
pub(crate) const JOBS_LIFECYCLE_TOPIC: &str = "jobs.lifecycle";
pub(crate) const READ_SCOPE: &str = "jobs.read";
pub(crate) const WRITE_SCOPE: &str = "jobs.write";

pub(crate) const START_FUNCTION: &str = "jobs::start";
pub(crate) const STATUS_FUNCTION: &str = "jobs::status";
pub(crate) const LIST_FUNCTION: &str = "jobs::list";
pub(crate) const LOG_FUNCTION: &str = "jobs::log";
pub(crate) const CANCEL_FUNCTION: &str = "jobs::cancel";
pub(crate) const CLEANUP_FUNCTION: &str = "jobs::cleanup";

static JOB_RUNTIME: LazyLock<runtime::JobRuntime> = LazyLock::new(runtime::JobRuntime::default);

/// Jobs dependencies narrowed from server setup.
#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) engine_host: crate::engine::EngineHostHandle,
    pub(crate) shutdown_coordinator: Option<Arc<ShutdownCoordinator>>,
    pub(crate) runtime: runtime::JobRuntime,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        let runtime = JOB_RUNTIME.clone();
        if let Some(shutdown) = &deps.shutdown_coordinator {
            let runtime_for_shutdown = runtime.clone();
            shutdown.register_phase_callback(ShutdownPhase::Capabilities, "jobs", move || {
                let runtime = runtime_for_shutdown.clone();
                async move {
                    runtime.cancel_all("server_shutdown").await;
                }
            });
        }
        Self {
            engine_host: deps.engine_host.clone(),
            shutdown_coordinator: deps.shutdown_coordinator.clone(),
            runtime,
        }
    }
}

pub(crate) fn runtime() -> runtime::JobRuntime {
    JOB_RUNTIME.clone()
}

/// Build the domain worker registration.
pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        WORKER,
        &[JOBS_LIFECYCLE_TOPIC],
        handlers::function_registrations(contract::capabilities()?, Deps::from_engine(deps))?,
    )
}

#[cfg(test)]
mod race_tests;
#[cfg(test)]
mod schema_tests;
#[cfg(test)]
mod tests;
