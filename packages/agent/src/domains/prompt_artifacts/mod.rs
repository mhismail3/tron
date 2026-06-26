//! Durable prompt artifact resource foundation.
//!
//! Slice 16A adds backend custody for explicit, opt-in prompt artifacts before
//! any automatic prompt-history capture, prompt-body persistence, native snippet
//! UI, prompt injection, context inclusion, learned behavior, or settings
//! migration work. This domain owns `prompt_artifact` resources that store
//! bounded metadata, content refs/fingerprints, retention state, trace/replay
//! refs, source/evidence refs, fingerprinted idempotency evidence, and lifecycle
//! events. Provider-visible projections stay byte-bounded while preserving
//! UTF-8 character boundaries.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `authority` | Prompt artifact/resource grant and selector checks |
//! | `contract` | Worker id, stream topic, scope, and schema constants |
//! | `projection` | Bounded provider-safe prompt artifact projections |
//! | `service` | Timestamp-injected record/list/inspect behavior |
//! | `validation` | Artifact kind, metadata, ref, retention, idempotency, and privacy bounds |
//! | `tests` | Resource schema, authority, scope, replay, and redaction regressions |
//!
//! # INVARIANT: prompt artifacts store metadata, not prompt bodies
//!
//! Prompt artifact truth lives in current-session or current-workspace engine
//! resources whose payloads carry bounded metadata and refs/fingerprints only.
//! These operations do not accept raw prompt bodies, provider-visible raw prompt
//! payloads, prompt messages, template/snippet bodies, raw idempotency keys,
//! absolute or unsafe paths, token-like material, automatic capture flags,
//! prompt injection, or context-inclusion requests. Prompt artifact timestamps
//! are supplied by `capability::execute` or tests; this domain does not sample
//! wall-clock time directly.

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};

mod authority;
pub(crate) mod contract;
mod projection;
pub(crate) mod service;
mod validation;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) engine_host: crate::engine::EngineHostHandle,
}

pub(crate) use crate::engine::{PROMPT_ARTIFACT_KIND, PROMPT_ARTIFACT_SCHEMA_ID};

pub(crate) fn worker_module(
    _deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        contract::WORKER,
        &[contract::PROMPT_ARTIFACT_LIFECYCLE_TOPIC],
        Vec::new(),
    )
}

#[cfg(test)]
mod tests;
