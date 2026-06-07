//! Domain-owned primitive engine surface.
//!
//! Each declared child module is part of the retained bare loop: startup and
//! system metadata, provider/auth/settings setup, session/message/log truth,
//! model providers, context inspection, blobs, and the single model-facing
//! `capability::execute` primitive. Product/tool domains are intentionally not
//! declared on this branch.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `catalog` | Shared helpers for retained contract definitions |
//! | `capability` | Single model-facing `execute` primitive |
//! | `contract` | Method-agnostic builders for domain-owned `contract.rs` records |
//! | `registration` | Startup loop that registers worker modules returned by domains |
//! | `worker` | Shared setup-only domain worker module and function registration types |
//! | domain modules | Retained loop infrastructure for agent, auth, blob, context, logs, message, model, session, settings, and system |
//!
//! Each retained domain `contract.rs` is the local source of truth for that
//! worker's function ids, schemas, idempotency, leases, compensation, stream
//! topics, and operation keys. Each domain `deps.rs` narrows setup context into
//! the service handles that worker actually needs. `handlers.rs` is a
//! declarative operation-key binding table backed by the shared method-agnostic
//! `bindings` helper, so completeness failures happen during worker
//! construction instead of as late runtime branches.
//!
//! The intended execution flow is:
//! `/engine frame -> EngineTransportRequest -> EngineTriggerRuntime -> domain
//! worker -> contract operation key -> handlers.rs -> operations/ -> narrow
//! deps/service -> engine ledger/streams/queues/approvals/leases`.
//!
//! # INVARIANT: no transport-owned behavior
//!
//! Domain methods here are canonical operation keys only. Public client
//! protocols translate into the transport-neutral engine envelope before
//! reaching these handlers.

pub mod agent;
pub mod auth;
pub mod bindings;
pub mod blob;
pub mod capability;
pub mod capability_support;
pub mod catalog;
pub mod context;
pub mod contract;
pub mod logs;
pub mod message;
pub mod model;
pub mod registration;
/// Session domain: lifecycle, reads, reconstruction, and context artifact services.
pub mod session;
pub mod settings;
pub mod system;
pub mod worker;
