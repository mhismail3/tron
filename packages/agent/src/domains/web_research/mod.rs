//! Metadata-only web browser and research custody.
//!
//! Web research owns durable `web_research_request`, `web_research_review`,
//! and `web_research_source` resources. These records coordinate future browser
//! and research module-pack work without adding search, crawling, browser
//! automation, login/cookie reuse, network access, raw page capture, or runtime
//! execution. Provider-visible access is limited to `capability::execute`
//! operations for request/review/source record, list, and inspect. The existing
//! `web` domain remains the only direct URL fetch and robots-policy network
//! owner.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `authority` | Web-research/resource grant and exact selector checks |
//! | `contract` | Worker id, stream topic, scope, and schema constants |
//! | `payload_safety` | Raw web/browser/local/secret payload denial |
//! | `projection` | Bounded provider-safe request/review/source projections |
//! | `records` | Metadata-only payload, idempotency, refs, and proof builders |
//! | `resource_store` | Resource inspection, lifecycle stream, kind/schema helpers |
//! | `service` | Timestamp-injected record/list/inspect behavior |
//! | `validation` | Text, ref, lifecycle, label, id, and bounded metadata checks |
//! | `tests` | Schema, authority, replay, projection, and redaction regressions |
//!
//! # INVARIANT: research custody is not browsing
//!
//! This domain records bounded summaries, policy labels, resource refs,
//! citation refs, robots evidence refs, dependency-request refs, trace/replay
//! refs, current-scope linkage, side-effect proof, and idempotency fingerprints
//! only. It must not store raw HTML, page dumps, browser logs, cookies,
//! credentials, local paths, commands, source code, file contents, raw grant or
//! authority ids, token-like strings, personal-info literals, debug payloads,
//! hidden chain-of-thought, package-manager output, or raw dependency
//! artifacts. All operations require `networkPolicy: none`.

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};

mod authority;
pub(crate) mod contract;
mod payload_safety;
mod projection;
mod records;
mod resource_store;
pub(crate) mod service;
mod validation;

#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) engine_host: crate::engine::EngineHostHandle,
}

pub(crate) use crate::engine::{
    WEB_RESEARCH_REQUEST_KIND, WEB_RESEARCH_REQUEST_SCHEMA_ID, WEB_RESEARCH_REVIEW_KIND,
    WEB_RESEARCH_REVIEW_SCHEMA_ID, WEB_RESEARCH_SOURCE_KIND, WEB_RESEARCH_SOURCE_SCHEMA_ID,
};

pub(crate) fn worker_module(
    _deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        contract::WORKER,
        &[contract::WEB_RESEARCH_LIFECYCLE_TOPIC],
        Vec::new(),
    )
}

#[cfg(test)]
mod tests;
