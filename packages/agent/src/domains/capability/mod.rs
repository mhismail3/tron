//! Primitive execute domain worker.
//!
//! This module owns the only model-facing tool on the primitive branch:
//! `capability::execute`. It intentionally does not expose a capability catalog,
//! registry, recipe, plugin, conformance, policy-profile, search, or inspection
//! plane. Concrete host actions happen through direct primitive operations.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `contract` | Single `capability::execute` contract and provider schema |
//! | `deps` | Narrow dependency bundle containing the engine host handle |
//! | `handlers` | Declarative binding for `execute` |
//! | `operations` | Direct primitive operation implementations |
//!
//! # INVARIANT: the model-facing surface is tiny
//!
//! Provider integrations must expose exactly this one tool. Additional behavior
//! can only appear later as agent-owned state or generated helper substrate, not
//! as checked-in catalog functions.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod handlers;
mod operations;
pub(crate) use deps::Deps;
pub(crate) use operations::execute_value;

use serde_json::Value;

use crate::domains::worker::{DomainRegistrationContext, DomainWorkerModule};

pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    let domain_deps = Deps::from_engine(deps);
    let mut registrations =
        handlers::function_registrations(contract::capabilities()?, domain_deps)?;
    for registration in &mut registrations {
        merge_metadata(
            &mut registration.definition.metadata,
            contract::model_metadata(registration.definition.id.as_str()),
        );
    }
    crate::domains::worker::domain_worker_module(
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
