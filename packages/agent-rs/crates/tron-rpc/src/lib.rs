//! # tron-rpc
//!
//! JSON-RPC 2.0 protocol layer, method registry, and handlers.
//!
//! Implements the full RPC surface that iOS connects to:
//! - Session: create, resume, list, delete, fork, getHead, getState
//! - Agent: prompt, abort, getState
//! - Model: list, switch
//! - Context: getSnapshot, compact, clear, canAcceptTurn, shouldCompact
//! - Events: getHistory, getSince, subscribe, append
//! - Settings: get, update
//! - Skills: list, get, refresh, remove
//! - Plus: browser, canvas, device, task, transcription, worktree, tree adapters

#![deny(unsafe_code)]
#![allow(unused_results)]

pub mod context;
pub mod errors;
pub mod handlers;
pub mod registry;
pub mod types;
