//! Memory foundation and engine contract domain.
//!
//! This worker owns the source-backed memory contract for Phase 2 Slice 3:
//! engine identity, policy/mode selection, canonical memory records,
//! deterministic preview-backed retrieval evidence, prompt inclusion traces,
//! query/decision evidence, eval-run resources, and migration envelopes. It
//! does not implement semantic/vector retrieval, embeddings, generated
//! summarization, hooks, rules, procedural skills, or automatic prompt memory.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `contract` | Memory function contracts and schemas |
//! | `errors` | Domain-local error helpers |
//! | `handlers` | Operation binding table |
//! | `migration` | Migration export/import envelope behavior |
//! | `prompt_trace` | Provider-safe memory prompt trace assembly |
//! | `query_decision` | Query/result and decision evidence records plus provider-safe list/inspect projections |
//! | `query_decision_validation` | Bounds and authority/grant leakage guards for query/decision evidence |
//! | `retrieval` | Deterministic resource-backed retrieval over record refs/previews |
//! | `retention` | Retention/edit/delete policy support evidence |
//! | `schema_tests` | Test-only resource schema drift guards |
//! | `service` | Resource-backed memory policy, record lifecycle, list, and inspect behavior |
//! | `support` | Payload parsing, stream publication, and resource projections |
//!
//! # INVARIANT: no hidden prompt memory
//!
//! Prompt assembly may include only explicit bounded record preview snippets
//! when the current memory policy enables `bounded_snippets`; otherwise it
//! emits audit/status facts only. Record body content is never injected into
//! provider context; prompt traces record considered/included/excluded refs,
//! snippets, policy evidence, decisions, and reasons.
//! `bodyRef` payloads must be custody pointers only: retain, edit, and
//! migration import reject inline body-like keys at any nested depth.
//! Policy lookup is hierarchical: an explicit session policy wins, then an
//! explicit workspace policy, then system policy, then the implicit disabled
//! default.
//! Record-id operations must verify that the target record resource scope
//! matches the caller's current memory scope before returning or mutating it.
//! Provider-visible memory list/inspect projections must use compact redacted
//! resource/event/evidence views: raw scope ids, owner actor ids,
//! trace/invocation ids, grant ids, grant-id-shaped historical evidence keys,
//! authority ids, and authority metadata are never returned through memory
//! capability results.

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};
pub(crate) use crate::engine::{
    MEMORY_DECISION_KIND, MEMORY_DECISION_SCHEMA_ID, MEMORY_ENGINE_KIND, MEMORY_ENGINE_SCHEMA_ID,
    MEMORY_MIGRATION_ENVELOPE_KIND, MEMORY_MIGRATION_ENVELOPE_SCHEMA_ID, MEMORY_POLICY_KIND,
    MEMORY_POLICY_SCHEMA_ID, MEMORY_PROMPT_TRACE_KIND, MEMORY_PROMPT_TRACE_SCHEMA_ID,
    MEMORY_QUERY_KIND, MEMORY_QUERY_SCHEMA_ID, MEMORY_RECORD_KIND, MEMORY_RECORD_SCHEMA_ID,
};

pub(crate) mod contract;
mod errors;
mod handlers;
mod migration;
mod prompt_trace;
mod query_decision;
mod query_decision_validation;
mod retention;
mod retrieval;
pub(crate) mod service;
mod support;

pub(crate) const WORKER: &str = "memory";
pub(crate) const MEMORY_LIFECYCLE_TOPIC: &str = "memory.lifecycle";
pub(crate) const READ_SCOPE: &str = "memory.read";
pub(crate) const WRITE_SCOPE: &str = "memory.write";

pub(crate) const STATUS_FUNCTION: &str = "memory::status";
pub(crate) const CONFIGURE_FUNCTION: &str = "memory::configure_policy";
pub(crate) const RETAIN_FUNCTION: &str = "memory::retain";
pub(crate) const EDIT_FUNCTION: &str = "memory::edit";
pub(crate) const TOMBSTONE_FUNCTION: &str = "memory::tombstone";
pub(crate) const LIST_FUNCTION: &str = "memory::list";
pub(crate) const INSPECT_FUNCTION: &str = "memory::inspect";
pub(crate) const EXPORT_FUNCTION: &str = "memory::migrate_export";
pub(crate) const IMPORT_FUNCTION: &str = "memory::migrate_import";
pub(crate) const PROMPT_TRACE_FUNCTION: &str = "memory::record_prompt_trace";
pub(crate) const RECORD_QUERY_FUNCTION: &str = "memory::record_query";
pub(crate) const LIST_QUERIES_FUNCTION: &str = "memory::query_list";
pub(crate) const INSPECT_QUERY_FUNCTION: &str = "memory::query_inspect";
pub(crate) const RECORD_DECISION_FUNCTION: &str = "memory::record_decision";
pub(crate) const LIST_DECISIONS_FUNCTION: &str = "memory::decision_list";
pub(crate) const INSPECT_DECISION_FUNCTION: &str = "memory::decision_inspect";

/// Memory dependencies narrowed from server setup.
#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) engine_host: crate::engine::EngineHostHandle,
}

impl Deps {
    pub(crate) fn from_engine(deps: &DomainRegistrationContext) -> Self {
        Self {
            engine_host: deps.engine_host.clone(),
        }
    }
}

/// Build the domain worker registration.
pub(crate) fn worker_module(
    deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        WORKER,
        &[MEMORY_LIFECYCLE_TOPIC],
        handlers::function_registrations(contract::capabilities()?, Deps::from_engine(deps))?,
    )
}

#[cfg(test)]
mod schema_tests;
#[cfg(test)]
mod tests;
