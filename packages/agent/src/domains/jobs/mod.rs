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
//! Public job status/list and module-owned program execution use redacted
//! projections that expose job/output refs, fingerprints, durations,
//! truncation, exit, timeout, cancellation, and cleanup metadata only. Raw
//! command text, canonical working directories, grant ids, idempotency keys,
//! stdout/stderr previews, and raw job/output payloads stay out of those
//! provider-facing lifecycle projections. `job_log` is the bounded preview
//! surface for stdout/stderr when the task explicitly needs output text.
//! One runtime state is created by the domain composition root and shared by
//! both the direct jobs worker and capability execution paths. Construction is
//! side-effect free; startup reconciliation and shutdown cancellation activate
//! only after the complete engine setup succeeds, and production reconciliation
//! is tracked by the shutdown owner. Coordinator-free embeddings skip eager
//! reconciliation and use the same on-demand path before lifecycle
//! reads/cancel/cleanup. Persisted `running` job resources from before the
//! current service instance are reconciled:
//! owned jobs continue under their runtime handle, while non-owned stale jobs
//! are marked with inspectable unknown/failure terminal evidence. Reconciliation
//! uses an internal scoped scan so a newest-first public list page full of live
//! or post-startup rows cannot hide older stale records; targeted
//! status/log/cancel paths also recheck the addressed resource after scope
//! validation before returning it.
//! The adapter seam for future module replacement is supervised-runtime
//! authority plus durable lifecycle parity: a replacement must preserve
//! resource-backed job/output evidence, provider-safe refs plus terminal
//! exit/duration/timeout/cancellation/truncation facts, replay/idempotency
//! evidence, bounded side effects, and rollback/disable metadata before binding
//! policy may later consider routing.

use std::sync::Arc;

use chrono::Utc;

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

/// Per-composition jobs process and reconciliation state.
///
/// Clones retain the same live-process registry and startup boundary so every
/// jobs entry point in one server instance observes one lifecycle owner.
#[derive(Clone)]
pub(crate) struct RuntimeState {
    runtime: runtime::JobRuntime,
    reconcile: service::ReconcileContext,
}

impl RuntimeState {
    pub(crate) fn new() -> Self {
        Self {
            runtime: runtime::JobRuntime::default(),
            reconcile: service::ReconcileContext {
                startup_cutoff: Utc::now(),
            },
        }
    }

    pub(crate) fn runtime(&self) -> runtime::JobRuntime {
        self.runtime.clone()
    }

    pub(crate) fn reconcile(&self) -> service::ReconcileContext {
        self.reconcile.clone()
    }
}

/// Jobs dependencies narrowed from server setup.
#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) engine_host: crate::engine::EngineHostHandle,
    pub(crate) shutdown_coordinator: Option<Arc<ShutdownCoordinator>>,
    pub(crate) state: RuntimeState,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext, state: RuntimeState) -> Self {
        Self {
            engine_host: deps.engine_host.clone(),
            shutdown_coordinator: deps.shutdown_coordinator.clone(),
            state,
        }
    }

    pub(crate) fn activate_after_registration(self) {
        let Some(shutdown) = self.shutdown_coordinator else {
            return;
        };
        let runtime_for_shutdown = self.state.runtime();
        shutdown.register_phase_callback(ShutdownPhase::Capabilities, "jobs", move || {
            let runtime = runtime_for_shutdown.clone();
            async move {
                runtime.cancel_all("server_shutdown").await;
            }
        });
        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            let engine_host = self.engine_host;
            let runtime_for_reconcile = self.state.runtime();
            let reconcile_for_startup = self.state.reconcile();
            let task = handle.spawn(async move {
                match service::reconcile_stale_running_jobs(
                    &engine_host,
                    runtime_for_reconcile,
                    reconcile_for_startup,
                    None,
                )
                .await
                {
                    Ok(count) if count > 0 => {
                        tracing::warn!(
                            component = "jobs",
                            reconciled_count = count,
                            "reconciled stale running job resources at jobs domain startup"
                        );
                    }
                    Ok(_) => {}
                    Err(error) => {
                        tracing::warn!(
                            component = "jobs",
                            error = %error,
                            "failed to reconcile stale running job resources at jobs domain startup"
                        );
                    }
                }
            });
            shutdown.register_task(task);
        }
    }
}

/// Build the domain worker registration.
pub(crate) fn worker_module(deps: Deps) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        WORKER,
        &[JOBS_LIFECYCLE_TOPIC],
        handlers::function_registrations(contract::capabilities()?, deps)?,
    )
}

#[cfg(test)]
mod race_tests;
#[cfg(test)]
mod schema_tests;
#[cfg(test)]
mod tests;
