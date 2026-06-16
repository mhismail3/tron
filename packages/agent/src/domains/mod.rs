//! Domain-owned primitive engine surface.
//!
//! Each declared child module is part of the retained bare loop: startup and
//! system metadata, provider/auth/settings setup, session/message/log truth,
//! model providers, blobs, and the single model-facing
//! `capability::execute` primitive. Product/tool domains are intentionally not
//! declared on this branch.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `capability` | Single model-facing `execute` primitive |
//! | `registration` | Startup registration plus shared domain contract/binding helpers |
//! | domain modules | Retained loop infrastructure for agent, auth, blob, logs, message, model, session, settings, system, transcription, and worker lifecycle |
//!
//! Each retained domain `contract.rs` is the local source of truth for that
//! worker's function ids, schemas, idempotency, leases, compensation, stream
//! topics, and operation keys. Each domain `deps.rs` narrows setup context into
//! the service handles that worker actually needs. `handlers.rs` is a
//! declarative operation-key binding table backed by the shared method-agnostic
//! `bindings` helper, so completeness failures happen during worker
//! construction instead of as late runtime branches.
//!
//! ## Entry Points
//!
//! The intended execution flow is:
//! `/engine frame -> EngineTransportRequest -> EngineTriggerRuntime -> domain
//! worker -> contract operation key -> handlers.rs -> domain owner -> narrow
//! deps/service -> engine ledger/streams/queues/grants/leases`.
//!
//! Startup enters the domain tree through
//! `transport::runtime::setup::register_server_domains_for_context`. That
//! facade delegates to the crate-private registration owner, which is the only
//! non-test code allowed to wire concrete domain worker modules. Individual
//! domains expose their public behavior through `contract.rs` definitions and
//! handler tables, not through transport-specific functions.
//!
//! ## Invariants
//!
//! Domain methods here are canonical operation keys only. Public client
//! protocols translate into the transport-neutral engine envelope before
//! reaching these handlers.
//!
//! Product/tool domains retired by the primitive teardown must remain absent
//! from this module tree and startup registration unless a restoration slice
//! reintroduces the behavior as a narrow worker-owned contract. The
//! transcription domain is restored only as local speech-to-text for composer
//! input; saved voice notes and media storage remain absent. The worker
//! lifecycle domain is the post-baseline package/launch substrate for
//! self-updating workers; it is not a restored product tool domain. New domain
//! behavior must add a contract, deps narrowing, handler binding, tests, and
//! README/domain-doc updates together.
//!
//! ## Test Ownership
//!
//! Domain-local tests live next to the domain service, provider, or store they
//! exercise. Shared registration/binding behavior belongs under
//! `domains/registration`; end-to-end transport/domain routing belongs in
//! integration/static tests rather than a broad domain root test.

pub mod agent;
pub mod auth;
pub mod blob;
pub mod capability;
pub mod logs;
pub mod message;
pub mod model;
pub mod registration;
/// Session domain: lifecycle, reads, reconstruction, and context artifact services.
pub mod session;
pub mod settings;
pub mod system;
pub mod transcription;
pub mod worker_lifecycle;
