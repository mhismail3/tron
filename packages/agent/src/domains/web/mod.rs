//! Web source provenance domain.
//!
//! Slice 8A restores only explicit direct URL fetch as source evidence. Slice
//! 8B adds read-only source list/inspect operations for citation assembly. Slice
//! 8C adds deterministic HTML/XHTML readable-text extraction for higher-quality
//! citation snippets while preserving captured raw bytes as the durable source
//! hash. Slice 8D adds explicit archive lifecycle updates for current-session
//! source records while preserving source evidence for replay/citation audit. The
//! provider-visible surface remains the single `capability::execute` primitive
//! with `web_fetch`, `web_source_list`, `web_source_inspect`, and
//! `web_source_archive` operation
//! values; this package owns URL validation, network authority checks, bounded
//! HTTP fetching, source/cache resource evidence, readable-text extraction,
//! redaction metadata, replay refs, read-only citation summaries, archive
//! lifecycle metadata, and `web.lifecycle` events.
//! URL authority checks must cover initial URLs, every redirect target before
//! it is followed, and DNS-resolved socket addresses before network I/O.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `archive` | Current-session web source archive lifecycle updates |
//! | `extract` | Deterministic HTML/XHTML readable-text and title extraction |
//! | `fetch` | Direct bounded URL fetch and source provenance resource writes |
//! | `network_policy` | URL, redirect-target, and DNS-resolved address safety checks |
//! | `source` | Bounded citation summaries for active and exact archived web sources |
//!
//! # INVARIANT: web fetch is explicit and provenance-backed
//!
//! This domain must not add search providers, browser automation, crawling,
//! login/cookie/session reuse, credential handling, process/shell network
//! side channels, deletion/pruning, TTL cleanup, or public `/engine` web
//! functions. `web_fetch` is the only network operation and must fail closed
//! unless the trusted runtime context carries a derived grant whose network
//! policy explicitly permits direct declared fetch. Source list/inspect/archive
//! operations are resource inspections or append-only resource lifecycle updates
//! and must remain valid under `networkPolicy none`.

use crate::domains::registration::worker::{DomainRegistrationContext, DomainWorkerModule};

pub(crate) mod archive;
mod extract;
pub(crate) mod fetch;
mod network_policy;
pub(crate) mod source;

pub(crate) const WORKER: &str = "web";
pub(crate) const WEB_LIFECYCLE_TOPIC: &str = "web.lifecycle";
pub(crate) const READ_SCOPE: &str = "web.read";
pub(crate) const WRITE_SCOPE: &str = "web.write";
pub(crate) const WEB_SOURCE_SCHEMA_VERSION: &str = "tron.web_source.v1";

/// Web dependencies narrowed from server setup.
#[derive(Clone)]
pub(crate) struct Deps {
    pub(crate) engine_host: crate::engine::EngineHostHandle,
    #[cfg(test)]
    pub(crate) dns_overrides:
        Option<std::sync::Arc<std::collections::HashMap<String, Vec<std::net::SocketAddr>>>>,
}

pub(crate) fn worker_module(
    _deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        WORKER,
        &[WEB_LIFECYCLE_TOPIC],
        Vec::new(),
    )
}

#[cfg(test)]
mod tests;
