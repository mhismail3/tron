//! # tron-rpc
//!
//! JSON-RPC 2.0 protocol layer, method registry, and handlers.
//!
//! Implements the full RPC surface that iOS connects to:
//! - Session: create, get, list, fork, delete, archive
//! - Agent: message, abort, respond
//! - Model: list, switch
//! - Context: get, compact
//! - Events: list, sync
//! - Settings: get, update
//! - Skills: list, get
//! - Plus: browser, canvas, device, sandbox, task, transcription, worktree adapters
//!
//! All 30 `RpcEventType` variants are a Rust enum matching the `TypeScript` wire format exactly.

#![deny(unsafe_code)]
