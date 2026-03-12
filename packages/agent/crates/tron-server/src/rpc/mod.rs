//! # RPC
//!
//! JSON-RPC 2.0 protocol layer, method registry, and handlers.
//!
//! Implements the full RPC surface that clients connect to:
//! - Session: create, resume, list, delete, fork, getHead, getState
//! - Agent: prompt, abort, getState
//! - Model: list, switch
//! - Context: getSnapshot, compact, clear, canAcceptTurn, shouldCompact
//! - Events: getHistory, getSince, subscribe, append
//! - Settings: get, update
//! - Skills: list, get, refresh, remove
//! - Plus: browser, canvas, device, task, transcription, worktree, tree

pub(crate) mod client_logs;
pub mod context;
pub mod errors;
pub mod handlers;
pub mod memory_ledger;
pub(crate) mod notification_inbox;
pub mod registry;
pub mod session_context;
pub mod types;
pub mod validation;
