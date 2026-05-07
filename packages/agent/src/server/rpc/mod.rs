//! # RPC
//!
//! JSON-RPC 2.0 protocol layer, method registry, and transport bindings.
//!
//! Implements the full RPC surface that clients connect to:
//! - Session: create, resume, list, delete, fork, getHead, getState, reconstruct
//! - Agent: prompt, status, abort/tool, queue, and confirmation/answer controls
//! - Model: list, switch
//! - Context: getSnapshot, compact, clear, canAcceptTurn, shouldCompact
//! - Events: getHistory, getSince, subscribe, append
//! - Settings: get, update, resetToDefaults
//! - Approval: get, list, resolve
//! - Skills: list, get, refresh, activate, deactivate, active
//! - Plus: browser, device, task, transcription, worktree, tree
//!
//! Transport-binding registration carries an execution policy. Quick and
//! blocking-read calls run under bounded timeouts, while mutating calls do not
//! use the generic timeout wrapper because a timed-out response must never
//! leave a write continuing in the background. Production blocking work is
//! owned by [`context::BlockingTaskSupervisor`] via
//! [`context::RpcContext::run_blocking`], which enforces concurrency limits and
//! drains through server shutdown.
//!
//! The context also owns the shared engine host handle. JSON-RPC is now a
//! transport-binding layer over canonical engine functions, not a method-owned
//! business layer. Every public registration is a binding generated from the
//! canonical capability catalog: the registry validates method existence/depth,
//! then dispatches JSON-RPC as a `json_rpc` trigger into a canonical
//! `namespace::function` id such as
//! `skills::activate` or `agent::prompt`. The five `engine.*` methods are the
//! canonical public capability transport for discover, inspect, watch, invoke,
//! and promote; the older 170 domain method names remain compatibility aliases.
//! Compatibility `rpc::<method>` names are metadata only and must not become
//! executable or agent-facing ids again.
//!
//! Read triggers carry `rpc.read` plus the domain read scope. Write triggers
//! carry `rpc.write`, the domain write scope, strict schemas, engine-ledger
//! idempotency, and approval/lease/compensation metadata when the effect class
//! requires it. Job background/cancel and agent prompt commands enqueue hidden
//! apply functions and synchronously drain their own receipts for current wire
//! compatibility. `agent::prompt_apply` now hands off actual turn execution to
//! the hidden `agent::run_turn` boundary so the turn runner can continue moving
//! behind canonical engine functions without changing client acknowledgements.
//!
//! # INVARIANT: no per-client rate limiting (L7, trusted-local)
//!
//! The RPC layer does NOT rate-limit inbound calls per client,
//! per-method, or per-connection. Under the trusted-local threat
//! model that is intentional — the only callers are the user's own
//! devices, and the 1 MB body cap + JSON depth check
//! ([`validation`]) plus connection-level backpressure
//! ([`crate::server::websocket::broadcast`] drop detection) are
//! sufficient for accidental-runaway protection.
//!
//! Hardening path for a future threat-model shift: a
//! [tower::limit::RateLimit]-style layer in
//! `crate::server::websocket` keyed on `(connection_id, method)`,
//! with per-method quotas loaded from settings.

pub(crate) mod agent_commands;
pub(crate) mod agent_runtime;
pub(crate) mod auth_flows;
pub mod bindings;
pub(crate) mod client_logs;
pub mod context;
pub(crate) mod context_commands;
pub(crate) mod context_queries;
pub(crate) mod context_service;
pub mod engine_bridge;
pub(crate) mod error_mapping;
pub mod errors;
pub(crate) mod events_wire;
pub(crate) mod filesystem_service;
pub(crate) mod git_service;
pub(crate) mod interactive_tool_enrichment;
pub(crate) mod memory_retain;
pub(crate) mod model_catalog;
pub(crate) mod notification_inbox;
pub(crate) mod params;
pub(crate) mod prompt_queue;
pub(crate) mod protocol;
pub mod registry;
pub(crate) mod sandbox_service;
pub(crate) mod session_commands;
pub mod session_context;
pub(crate) mod session_queries;
pub(crate) mod session_reconstruct;
pub(crate) mod skill_state;
#[cfg(test)]
pub(crate) mod test_support;
pub mod types;
pub mod validation;
pub(crate) mod voice_notes_service;
