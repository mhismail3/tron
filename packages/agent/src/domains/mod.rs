//! Domain-owned Tron capability surface.
//!
//! Each child directory is a server-owned worker namespace. Domains own their
//! canonical `namespace::function` implementations plus nearby services and
//! tests. Shared errors, params, validation, and event payloads live in
//! `shared::server`; transports only build engine requests.
//!
//! ## Submodules
//!
//! | Module | Purpose |
//! |--------|---------|
//! | `catalog` | Aggregated discovery, diagnostics, and guardrail view over domain-owned contracts |
//! | `capability` | Single model-facing `execute` orchestrator over the live catalog |
//! | `contract` | Method-agnostic builders for domain-owned `contract.rs` records |
//! | `registration` | Startup loop that registers worker modules returned by domains |
//! | `worker` | Shared setup-only domain worker module and function registration types |
//! | domain modules | Engine-owned behavior for agent, settings, capability support, MCP, git/worktree, session, cron, and the rest of Tron |
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

pub mod agent;
pub mod auth;
pub mod bindings;
pub mod blob;
pub mod browser;
pub mod capability;
pub mod capability_support;
pub mod catalog;
pub mod context;
pub mod contract;
/// Cron domain: scheduled triggers, automation state, and cron event projection.
pub mod cron;
pub mod device;
pub mod display;
pub mod events;
pub mod filesystem;
pub mod git;
pub mod import;
pub mod job;
pub mod logs;
pub mod mcp;
pub mod memory;
pub mod message;
pub mod model;
pub mod notifications;
pub mod plan;
pub mod process;
pub mod program;
pub mod prompt_library;
pub mod registration;
pub mod repo;
pub mod sandbox;
/// Session domain: lifecycle, reads, reconstruction, and context artifact services.
pub mod session;
pub mod settings;
pub mod skills;
pub mod system;
pub mod transcription;
pub mod tree;
pub mod voice_notes;
pub mod web;
pub mod worker;
pub mod worktree;
