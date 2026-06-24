//! Primitive execute domain worker.
//!
//! This module owns the only model-facing tool on the primitive branch:
//! `capability::execute`. Concrete host actions happen through direct primitive
//! operations after the trusted agent runtime derives a least-privilege child
//! grant for the current call. `replay_manifest` is the read-only evidence
//! operation: it returns the current session replay manifest without creating a
//! trace record. Catalog-discovery operations are inspect-only additions to the
//! same primitive: search/inspect read current metadata, while conformance
//! writes only durable catalog-discovery report evidence.
//! Memory audit operations are also inspect-only additions: they expose
//! resource-backed memory status/list/inspect facts without retaining or
//! injecting private memory body content.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `contract` | Single `capability::execute` contract and provider schema |
//! | `operations` | Direct primitive operation implementations |
//!
//! # INVARIANT: the model-facing surface is tiny
//!
//! Provider integrations must expose exactly this one tool. Additional behavior
//! can only appear later as agent-owned state or generated helper substrate, not
//! as checked-in target functions.
//! File access through this tool must use the hardened `filesystem_*` operation
//! package; legacy `file_read`/`file_write` operation names are not a supported
//! model-facing surface.
//! Agent-launched executions persist trace provider ownership and canonical
//! working directory from trusted `CausalContext` runtime metadata, not from
//! model-id string parsing, shell aliases, caller-supplied public context, or
//! process-cwd fallback. `capability::execute` rejects bootstrap/root grants and
//! runs only with derived scoped grants whose file roots, state authority, and
//! network policy match the requested primitive operation. Working-directory
//! metadata is required only for file/process operations; catalog discovery must
//! remain pure metadata inspection or resource-backed report creation. Replay
//! manifest reads deliberately bypass trace insertion so the exported manifest
//! is not changed by the read.

pub(crate) mod contract;
mod operations;
pub(crate) use operations::execute_value;

use std::sync::Arc;

use crate::domains::jobs;
use crate::domains::registration::catalog::{CapabilitySpec, function_definition_for_capability};
use crate::domains::registration::worker::{
    DomainFunctionRegistration, DomainRegistrationContext, DomainWorkerModule,
};
use crate::domains::session::event_store::EventStore;
use crate::engine::{EngineError, InProcessFunctionHandler, Invocation};
use crate::shared::server::error_mapping::capability_error_to_engine;
use chrono::Utc;
use serde_json::Value;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) engine_host: crate::engine::EngineHostHandle,
    pub(crate) event_store: Arc<EventStore>,
    pub(crate) shutdown_coordinator:
        Option<Arc<crate::app::lifecycle::shutdown::ShutdownCoordinator>>,
    pub(crate) jobs_reconcile: jobs::service::ReconcileContext,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            engine_host: deps.engine_host.clone(),
            event_store: Arc::clone(&deps.event_store),
            shutdown_coordinator: deps.shutdown_coordinator.clone(),
            jobs_reconcile: jobs::service::ReconcileContext {
                startup_cutoff: Utc::now(),
            },
        }
    }
}

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    let domain_deps = Deps::from_engine(deps);
    let mut registrations = function_registrations(contract::capabilities()?, domain_deps)?;
    for registration in &mut registrations {
        merge_metadata(
            &mut registration.definition.metadata,
            contract::model_metadata(registration.definition.id.as_str()),
        );
    }
    crate::domains::registration::worker::domain_worker_module(
        "capability",
        contract::STREAM_TOPICS,
        registrations,
    )
}

fn merge_metadata(target: &mut Value, extra: Value) {
    if extra.is_null() {
        return;
    }
    match (target, extra) {
        (Value::Object(target), Value::Object(extra)) => {
            for (key, value) in extra {
                let _ = target.insert(key, value);
            }
        }
        (target, extra) => {
            *target = extra;
        }
    }
}

fn function_registrations(
    specs: Vec<CapabilitySpec>,
    deps: Deps,
) -> crate::engine::Result<Vec<DomainFunctionRegistration>> {
    let mut registrations = Vec::with_capacity(specs.len());
    for spec in specs {
        if spec.operation_key != "execute" {
            return Err(EngineError::PolicyViolation(format!(
                "unexpected capability operation '{}'",
                spec.operation_key
            )));
        }
        registrations.push(DomainFunctionRegistration {
            definition: function_definition_for_capability(&spec),
            handler: Arc::new(ExecuteHandler { deps: deps.clone() }),
        });
    }
    Ok(registrations)
}

struct ExecuteHandler {
    deps: Deps,
}

#[async_trait::async_trait]
impl InProcessFunctionHandler for ExecuteHandler {
    async fn invoke(&self, invocation: Invocation) -> Result<Value, EngineError> {
        execute_value(&invocation, &self.deps)
            .await
            .map_err(capability_error_to_engine)
    }
}
