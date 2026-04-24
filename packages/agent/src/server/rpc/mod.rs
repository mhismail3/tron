//! # RPC
//!
//! JSON-RPC 2.0 protocol layer, method registry, and handlers.
//!
//! Implements the full RPC surface that clients connect to:
//! - Session: create, resume, list, delete, fork, getHead, getState, reconstruct
//! - Agent: prompt, abort, queuePrompt, dequeuePrompt, clearQueue
//! - Model: list, switch
//! - Context: getSnapshot, compact, clear, canAcceptTurn, shouldCompact
//! - Events: getHistory, getSince, subscribe, append
//! - Settings: get, update
//! - Skills: list, get, refresh, remove
//! - Plus: browser, device, task, transcription, worktree, tree
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
pub(crate) mod client_logs;
pub mod context;
pub(crate) mod context_commands;
pub(crate) mod context_queries;
pub(crate) mod context_service;
pub mod errors;
pub(crate) mod filesystem_service;
pub(crate) mod git_service;
pub mod handlers;
pub(crate) mod interactive_tool_enrichment;
pub(crate) mod notification_inbox;
pub(crate) mod prompt_queue;
pub mod registry;
pub(crate) mod sandbox_service;
pub(crate) mod session_commands;
pub mod session_context;
pub(crate) mod session_queries;
pub(crate) mod session_reconstruct;
pub(crate) mod settings_service;
pub mod types;
pub mod validation;
pub(crate) mod voice_notes_service;
