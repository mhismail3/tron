//! Trusted-local persistent worker kernel.
//!
//! This domain is the executable self-extension path. A complete bundle is
//! staged, dependency-locked, smoke-tested, atomically versioned, activated,
//! and projected as a direct typed model tool by one `worker_upsert` call.
//! Filesystem bundles are canonical; the dedicated SQLite database is a
//! rebuildable route/trigger indexes plus durable attempt, causal-trace,
//! invocation, inbox, health, and audit ledgers.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `contract` | Fixed direct worker-management contracts |
//! | `handlers` | Model/client operation bindings |
//! | `persistence` | Canonical bundles, snapshots, index reconstruction, and durable operational ledgers |
//! | `runtime` | Runners, concurrency, dispatch, dynamic tools, and supervision |
//! | `types` | Worker bundle and durable runtime DTOs |
//!
//! # Invariants
//!
//! Worker activation is atomic with respect to the canonical active pointer:
//! failed dependency, smoke-test, or health-check work never changes the active
//! version. Successful pre-activation evidence is sealed into the immutable
//! version before hashing. The rebuildable SQLite indexes commit before the
//! pointer; startup reconstruction therefore recovers a crash before pointer
//! publication to the prior version. A reported pointer-write failure removes
//! the unpublished candidate before rebuilding those indexes.
//! Failure while registering an already-published direct tool disables it and
//! records the failure rather than leaving an enabled but unreachable worker.
//! Local worker execution is deliberately not capability-authorized. Named
//! secret values are injected only at runtime; known vault values are rejected
//! from candidate bundles and invocation inputs, then redacted from outputs and
//! errors so they never enter manifests, operational records, events, or logs.
//! Every claimed delivery creates a numbered attempt. Interrupted attempts are
//! terminalized before their invocation is requeued, making at-least-once
//! redelivery and causal-loop suppression directly inspectable. An engine event
//! beyond the causal ceiling is durably recorded as terminal suppression before
//! its cursor advances. A matched event that cannot satisfy the worker input
//! schema is a terminal worker failure, not an endlessly retried delivery. A
//! persistence failure retains the cursor for retry.
//! The worker lifecycle observer always runs: edits to the
//! `autonomousWorkers` profile setting hide or restore the fixed and dynamic
//! model-tool surface, cancel or resume dispatch, and stop resident services
//! without a server restart or a change to canonical worker state.
//! Authenticated clients retain read access and lifecycle/stop controls while
//! autonomy is off, but authoring and invocation remain blocked. Lazy resident
//! processes remain supervised between invocations: an exit or three
//! consecutive health-check failures disables routing and creates a durable
//! high-visibility inbox result. System inbox failures without invocation rows
//! remain eligible for one-time attachment to the next relevant session.

use std::sync::Arc;

use serde_json::{Value, json};

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};

mod contract;
mod core_proposals;
mod handlers;
mod persistence;
mod runtime;
mod types;

pub(crate) use runtime::WorkerRuntime;

pub(crate) fn list_state_snapshots() -> Result<Vec<std::path::PathBuf>, String> {
    persistence::list_snapshots(&crate::shared::foundation::paths::tron_home())
        .map_err(|error| error.to_string())
}

pub(crate) fn restore_state_snapshot(
    snapshot: &std::path::Path,
) -> Result<std::path::PathBuf, String> {
    persistence::restore_snapshot(snapshot, &crate::shared::foundation::paths::tron_home())
        .map_err(|error| error.to_string())
}

pub(crate) const STREAM_TOPICS: &[&str] = &["worker.lifecycle", "worker.invocations"];

pub(crate) struct Registration {
    pub(crate) module: DomainWorkerModule,
    pub(crate) runtime: Arc<WorkerRuntime>,
}

pub(crate) fn registration(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<Registration> {
    let autonomous = deps.profile_runtime.current().settings.autonomous_workers;
    let current_profile = deps.profile_runtime.current();
    let store = persistence::WorkerStore::open(
        deps.profile_runtime.home().to_path_buf(),
        current_profile.profile_name(),
    )
    .map_err(crate::engine::EngineError::HandlerFailed)?;
    let runtime = WorkerRuntime::new(
        store,
        deps.engine_host.clone(),
        deps.orchestrator.clone(),
        deps.session_manager.clone(),
        deps.event_store.clone(),
        deps.profile_runtime.clone(),
    )
    .map_err(crate::engine::EngineError::HandlerFailed)?;
    let mut functions = handlers::function_registrations(
        contract::capabilities()?,
        handlers::Deps {
            runtime: Arc::clone(&runtime),
        },
    )?;
    for registration in &mut functions {
        let mut metadata = registration
            .definition
            .metadata
            .as_object()
            .cloned()
            .unwrap_or_default();
        let _ = metadata.insert("workerKernel".to_owned(), Value::Bool(true));
        let _ = metadata.insert("trustedLocalKernel".to_owned(), Value::Bool(true));
        let operation = registration
            .definition
            .id
            .as_str()
            .split_once("::")
            .map(|(_, operation)| operation)
            .unwrap_or_default();
        let model_name = match operation {
            "filesystem_read" => Some("filesystem_read"),
            "filesystem_list" => Some("filesystem_list"),
            "filesystem_search_text" => Some("filesystem_search_text"),
            "filesystem_write" => Some("filesystem_write"),
            "process_run" => Some("process_run"),
            "web_fetch" => Some("web_fetch"),
            "core_proposal_create" => Some("core_proposal_create"),
            "core_proposal_list" => Some("core_proposal_list"),
            "core_proposal_inspect" => Some("core_proposal_inspect"),
            "core_proposal_apply" => Some("core_proposal_apply"),
            "upsert" => Some("worker_upsert"),
            "discover" => Some("worker_discover"),
            "list" => Some("worker_list"),
            "inspect" => Some("worker_inspect"),
            "invoke" => Some("worker_invoke"),
            "disable" => Some("worker_disable"),
            "enable" => Some("worker_enable"),
            "rollback" => Some("worker_rollback"),
            "retire" => Some("worker_retire"),
            "purge" => Some("worker_purge"),
            "inbox" => Some("worker_inbox"),
            "runs" => Some("worker_runs"),
            "webhook_rotate" => Some("worker_webhook_rotate"),
            "stop_all" => Some("worker_stop_all"),
            _ => None,
        };
        if let Some(model_name) = model_name {
            let _ = metadata.insert("modelPrimitive".to_owned(), Value::Bool(autonomous));
            let _ = metadata.insert(
                "modelPrimitiveName".to_owned(),
                Value::String(model_name.to_owned()),
            );
            let _ = metadata.insert("contextPrimerLevel".to_owned(), json!("primitive"));
        }
        registration.definition.metadata = Value::Object(metadata);
    }
    runtime
        .configure_kernel_primitives(
            functions
                .iter()
                .filter(|registration| {
                    registration
                        .definition
                        .metadata
                        .get("modelPrimitiveName")
                        .is_some()
                })
                .map(|registration| {
                    (
                        registration.definition.clone(),
                        Arc::downgrade(&registration.handler),
                    )
                })
                .collect(),
        )
        .map_err(crate::engine::EngineError::HandlerFailed)?;
    let module = crate::domains::registration::worker::domain_worker_module(
        "worker_kernel",
        STREAM_TOPICS,
        functions,
    )?;
    Ok(Registration { module, runtime })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn replay_fixture_describes_executable_expected_outcome() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../tests/fixtures/last30days_worker_gap.json"
        ))
        .unwrap();
        assert_eq!(fixture["observedOutcome"]["kind"], "inert_proposal");
        assert_eq!(
            fixture["expectedOutcome"]["atomicOperation"],
            "worker_upsert"
        );
        assert_eq!(fixture["expectedOutcome"]["directTypedTool"], true);
    }
}
