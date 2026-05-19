//! Concern-owned tests for the MCP product protocol.
//!
//! Keep this root declaration-only; protocol fixtures live in `support`,
//! and each behavior area owns its test module.

mod support;

mod capability_index;
mod client;
mod manager;
mod router;
