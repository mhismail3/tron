//! Durable media and voice-note resource foundation.
//!
//! Slice 14A adds backend custody for media artifacts before any native iOS
//! capture UI, waveform/detail views, or server transcription changes. This
//! domain owns `media_artifact` resources, bounded metadata, blob-ref custody,
//! redacted list/inspect projections, retention fields, source refs,
//! trace/replay refs, fingerprinted idempotency evidence, and lifecycle events.
//! It records metadata about existing local composer transcription output only;
//! raw audio and raw caller idempotency keys are never returned to providers by
//! these operations.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `authority` | Media/resource grant and selector checks |
//! | `contract` | Worker id, stream topic, scope, and schema constants |
//! | `projection` | Bounded provider-safe media projections |
//! | `service` | Timestamp-injected create/list/inspect/archive behavior |
//! | `validation` | MIME allow-list, size limits, retention, refs, and text bounds |
//! | `tests` | Resource schema, authority, scope, redaction, replay, and lifecycle regressions |
//!
//! # INVARIANT: media resources store refs, not bytes
//!
//! Media truth lives in current-session or current-workspace engine resources
//! whose payloads carry durable blob/storage refs and bounded metadata only.
//! These operations do not accept raw audio/base64 data, do not call
//! transcription providers, do not expose provider-visible raw audio, and store
//! idempotency evidence as deterministic fingerprints rather than raw caller
//! keys. Media timestamps are supplied by `capability::execute` or tests; this
//! domain does not sample wall-clock time directly.

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

pub(crate) use crate::engine::{MEDIA_ARTIFACT_KIND, MEDIA_ARTIFACT_SCHEMA_ID};

pub(crate) fn worker_module(
    _deps: &DomainRegistrationContext,
) -> crate::engine::Result<DomainWorkerModule> {
    crate::domains::registration::worker::domain_worker_module(
        contract::WORKER,
        &[contract::MEDIA_LIFECYCLE_TOPIC],
        Vec::new(),
    )
}

#[cfg(test)]
mod tests;
