//! capability domain worker.
//!
//! This module owns the collapsed model-facing harness. It does not implement
//! filesystem, web, MCP, shell, UI, or app behavior itself; it exposes stable
//! discovery, inspection, and execution primitives over the live engine catalog.
//! The runnable catalog remains the execution source of truth, while this
//! domain maintains the durable capability registry/index/audit layer in the
//! engine ledger database.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `contract` | Canonical `capability::*` function contracts and model metadata |
//! | `deps` | Narrow dependency bundle for catalog, registry-store, embedding, and invocation access |
//! | `embeddings` | Embedded first-party ONNX/tokenizer provider for offline local search |
//! | `handlers` | Declarative operation bindings for `search`, `inspect`, and `execute` |
//! | `operations` | Catalog projection, binding resolution, and delegated execution |
//! | `registry` | Durable catalog projection, plugin manifests, binding decisions, search index, inspection handles, and primer rendering |
//! | `types` | Typed contract, implementation, binding, inspection, and execution records |
//!
//! # INVARIANT: the model-facing surface is tiny
//!
//! Provider integrations should only expose the three capability primitives. All
//! other behavior must remain discoverable/executable as worker-owned catalog
//! entries rather than prompt-expanded hardcoded tools.
//!
//! # INVARIANT: search is local and explicit about degradation
//!
//! The default search policy requires the binary-embedded first-party embedding
//! model plus the persistent `sqlite-vec` index. Lexical-only operation is
//! allowed only when profile policy opts into degraded search; failures surface
//! as structured capability errors.

pub(crate) mod contract;
pub(crate) mod deps;
pub(crate) mod embeddings;
pub(crate) mod handlers;
mod operations;
pub(crate) mod registry;
mod types;
pub(crate) use deps::Deps;
pub(crate) use operations::{execute_value, inspect_value, render_capability_primer, search_value};

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
