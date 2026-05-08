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
//! | `worker` | Shared domain worker module and function registration types |
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

use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicU16, Ordering};
use std::time::Instant;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::engine::{Invocation, VisibilityScope};
use crate::events::EventStore;
use crate::prompt_library::store;
use crate::runtime::orchestrator::orchestrator::Orchestrator;
use crate::runtime::orchestrator::session_manager::SessionManager;
use crate::runtime::profile_runtime::ProfileRuntime;
use crate::server::domains::filesystem::service as filesystem_service;
use crate::server::domains::logs::client_logs::{ClientLogEntry, ClientLogsService};
use crate::server::domains::notifications::inbox::NotificationInboxService;
use crate::server::platform::codex_app::CodexAppServerManager;
use crate::server::shared::context::run_blocking_task;
use crate::server::shared::error_mapping::{map_cron_error, map_event_store_error};
use crate::server::shared::errors;
use crate::server::shared::errors::{CLIENT_VERSION_UNSUPPORTED, CapabilityError, to_json_value};
use crate::server::shared::params::{
    opt_array, opt_bool, opt_string, opt_u64, require_param, require_string_param,
};
use crate::server::shared::validation::validate_string_param;
use crate::skills::registry::SkillRegistry;

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

pub(crate) use worker::{
    DomainFunctionRegistration, DomainRegistrationContext, DomainWorkerModule, domain_worker_module,
};
