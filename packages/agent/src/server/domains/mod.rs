//! Domain-owned Tron capability surface.
//!
//! Each child directory is a server-owned worker namespace. Domains own their
//! canonical `namespace::function` implementations plus nearby services and
//! tests. Shared errors, params, validation, and event payloads live in
//! `server::shared`; transports only build engine requests.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `catalog` | Aggregated discovery, diagnostics, and guardrail view over domain-owned contracts |
//! | `contract` | Method-agnostic builders for domain-owned `contract.rs` records |
//! | `registration` | Startup loop that registers worker modules returned by domains |
//! | `worker` | Shared setup-only domain worker module and function registration types |
//! | domain modules | Engine-owned behavior for agent, settings, tools, MCP, git/worktree, session, cron, and the rest of Tron |
//!
//! Each domain `contract.rs` is the local source of truth for that worker's
//! function ids, schemas, authority, risk, idempotency, leases, compensation,
//! stream topics, and operation keys. Each domain `deps.rs` narrows setup
//! context into the service handles that worker actually needs. `handlers.rs`
//! is a declarative operation-key binding table backed by the shared
//! method-agnostic `bindings` helper, so completeness failures happen during
//! worker construction instead of as late runtime branches. Flow-critical
//! domains keep executable bodies in operation-owned workflow files; runtime
//! support follows the same pattern (`agent/runtime/service/*`,
//! `agent/runtime/runtime/*`, `session/context/*`). Event-emitting domains
//! publish through typed `stream.rs` publishers for their declared topics. The
//! catalog only aggregates those records; it does not derive domain policy from
//! central method tables.
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

pub(crate) mod agent;
pub(crate) mod auth;
pub(crate) mod bindings;
pub(crate) mod blob;
pub(crate) mod browser;
pub(crate) mod catalog;
pub(crate) mod codex_app;
pub(crate) mod context;
pub(crate) mod contract;
/// Cron domain: scheduled triggers, automation state, and cron event projection.
pub mod cron;
pub(crate) mod device;
pub(crate) mod display;
pub(crate) mod events;
pub(crate) mod filesystem;
pub(crate) mod git;
pub(crate) mod import;
pub(crate) mod job;
pub(crate) mod logs;
pub(crate) mod mcp;
pub(crate) mod memory;
pub(crate) mod message;
pub(crate) mod model;
pub(crate) mod notifications;
pub(crate) mod plan;
pub(crate) mod prompt_library;
pub(crate) mod registration;
pub(crate) mod repo;
pub(crate) mod sandbox;
/// Session domain: lifecycle, reads, reconstruction, and context artifact services.
pub mod session;
pub(crate) mod settings;
pub(crate) mod skills;
pub(crate) mod system;
pub(crate) mod tools;
pub(crate) mod transcription;
pub(crate) mod tree;
pub(crate) mod voice_notes;
pub(crate) mod worker;
pub(crate) mod worktree;
