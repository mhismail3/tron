//! Primitive execute domain worker.
//!
//! This module owns the only model-facing tool on the primitive branch:
//! `capability::execute`. Concrete host actions happen through direct primitive
//! operations.
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
//! Agent-launched executions persist trace provider ownership and canonical
//! working directory from trusted `CausalContext` runtime metadata, not from
//! model-id string parsing or shell aliases.

pub(crate) mod contract;
mod operations;
pub(crate) use operations::execute_value;

use std::sync::Arc;

use crate::domains::registration::catalog::{CapabilitySpec, function_definition_for_capability};
use crate::domains::registration::worker::{
    DomainFunctionRegistration, DomainRegistrationContext, DomainWorkerModule,
};
use crate::domains::session::event_store::EventStore;
use crate::engine::{EngineError, InProcessFunctionHandler, Invocation};
use crate::shared::server::error_mapping::capability_error_to_engine;
use serde_json::Value;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) engine_host: crate::engine::EngineHostHandle,
    pub(crate) event_store: Arc<EventStore>,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            engine_host: deps.engine_host.clone(),
            event_store: Arc::clone(&deps.event_store),
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
